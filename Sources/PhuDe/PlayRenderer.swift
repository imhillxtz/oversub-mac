import AppKit
import CoreVideo
import Metal
import MetalFX
import QuartzCore

/// Tuỳ chọn vẽ chụp lại từ luồng chính, để luồng nhận hình đọc mà không phải chạm vào PlaySettings.
struct PlayRenderOptions: Equatable {
    var range: PlaySettings.Range = .auto
    var matrix: PlaySettings.Matrix = .auto
    var gamut: PlaySettings.Gamut = .srgb
    var hdr: PlaySettings.HDR = .off
    var upscaler: PlayEffects.Upscaler = .bilinear
    var sharpen: PlaySettings.Sharpen = .off
    var antiAlias = false
    var frameGen: PlayInterpolator.Mode = .off
    /// Phóng cho kín vùng vẽ, cắt phần thừa (thay vì giữ trọn hình với viền đen).
    var fill = false
    var latency: PlaySettings.Latency = .lowest
    /// Cỡ vùng vẽ theo điểm ảnh thật của màn hình.
    var drawableSize: CGSize = .zero
    /// Cửa sổ còn hiện (bị thu nhỏ hay che kín thì khỏi vẽ).
    var visible = true
    /// Đang kéo đổi cỡ: tạm không dùng MetalFX và Anime4K (dựng lại bộ phóng hay texture ở mỗi cỡ rất tốn).
    var resizing = false
    /// Độ sáng vượt mức trắng SDR mà màn hình đang cho phép (EDR).
    var headroom: Double = 1
}

/// Vẽ khung hình capture card bằng Metal: đổi YCbCr sang RGB theo dải sáng và ma trận đã chọn (chỗ hay làm lệch màu so với
/// TV), đổi HDR10 về SDR hoặc hiện HDR bằng EDR, rồi đặt vừa khung với viền đen. Khi bật bộ chỉnh hình thì đổi màu vào texture
/// trung gian ở độ phân giải gốc, chèn khung (`PlayInterpolator`), khử răng cưa, phóng to và làm nét (`PlayEffects`) rồi mới
/// đặt vào khung. Mọi hàm (trừ `update`) chạy trên một hàng đợi nhận hình duy nhất.
final class PlayRenderer: @unchecked Sendable {
    let layer = CAMetalLayer()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var cache: CVMetalTextureCache?
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var library: MTLLibrary?

    private let lock = NSLock()
    private var pending = PlayRenderOptions()
    /// Khoảng cách giữa hai khung của tín hiệu (giây), cho chế độ Mượt.
    var frameInterval: Double = 1.0 / 60

    // Trạng thái chỉ dùng trong luồng nhận hình.
    private var layerConfig: (PlaySettings.HDR, PlaySettings.Gamut, PlaySettings.Latency, Bool)?
    private lazy var effects = PlayEffects(device: device) { DebugLog.write("Màn hình chơi: \($0)") }
    private lazy var interpolator = PlayInterpolator(device: device) { DebugLog.write("Màn hình chơi: \($0)") }
    // Số liệu xử lý hình cho nhật ký và menu (ghi trên luồng nhận hình, GPU xong thì ghi ở luồng khác nên có khoá).
    private let statsLock = NSLock()
    private var gpuTotal = 0.0, gpuFrames = 0, presented = 0
    private var lastFxLog = Date()
    private var lastStages = ""
    private var processing: (ms: Double, stages: String)?
    /// Thời gian GPU trung bình mỗi lần vẽ (ms) và các bước xử lý ở lần thống kê gần nhất, cho menu (gọi được từ luồng chính).
    func processingInfo() -> (ms: Double, stages: String)? {
        statsLock.lock(); defer { statsLock.unlock() }
        return processing
    }
    // Đo 2 giây một lần cho số trễ thêm trong menu và Cài đặt: thời gian GPU của đúng một cách xử lý (đổi cách, đổi cỡ giữa
    // chừng thì bỏ lần đo đó). `cost` mang tín hiệu, cỡ khung hình và hệ số GPU của máy (xem PlayCost).
    private var winGpu = 0.0, winFrames = 0
    private var winStart = Date()
    private var winKey = ""
    private var winMixed = true
    private var cost = PlayCost.saved
    private var measuredLag: Double?
    private var lastCostSave = Date.distantPast
    /// Tín hiệu, cỡ khung hình, hệ số GPU đang dùng và độ trễ thêm đo được của cách đang dùng (gọi được từ luồng chính).
    func costInfo() -> (cost: PlayCost, measured: Double?) {
        statsLock.lock(); defer { statsLock.unlock() }
        return (cost, measuredLag)
    }
    private(set) var detector = RangeDetector()
    private var sampleTick = 0
    /// Cách hiểu đang dùng, để ghi nhật ký và hiện trong menu.
    private(set) var current = Interpretation()

    struct Interpretation: Equatable {
        var full = false
        var matrix = "709"
        var bits = 8
        var auto = true
    }

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
        layer.device = dev
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 2
        layer.displaySyncEnabled = true
        do {
            library = try dev.makeLibrary(source: Self.shader, options: nil)
        } catch {
            DebugLog.write("Màn hình chơi: không dựng được bộ vẽ Metal: \(error)")
            return nil
        }
    }

    var supportsSuperResolution: Bool { MTLFXSpatialScalerDescriptor.supportsDevice(device) }

    /// Có bước xử lý nào sau đổi màu không (không có thì vẽ thẳng vào drawable, trễ thấp nhất).
    private static func processing(_ o: PlayRenderOptions) -> Bool {
        o.upscaler != .bilinear || o.sharpen != .off || o.antiAlias || o.frameGen != .off
    }

    /// Gọi từ luồng chính khi tuỳ chọn, cỡ cửa sổ hay trạng thái hiện đổi.
    func update(_ change: (inout PlayRenderOptions) -> Void) {
        lock.lock(); change(&pending); lock.unlock()
    }

    private var options: PlayRenderOptions { lock.lock(); defer { lock.unlock() }; return pending }

    /// Bắt đầu tín hiệu mới (mở cửa sổ, đổi thiết bị hay định dạng): dò lại dải sáng từ đầu.
    func resetDetection(baselineFull: Bool) { detector = RangeDetector(baselineFull: baselineFull) }

    /// Độ sáng thấp nhất và cao nhất từ lần hỏi trước (cho nhật ký). Gọi trên luồng nhận hình.
    func takeStats() -> (Int, Int)? { detector.takeStats() }

    /// Số khung bỏ vẽ theo lý do từ lần hỏi trước (cho nhật ký). Chỉ dùng trên luồng nhận hình.
    private var skips: [String: Int] = [:]
    func takeSkips() -> String {
        defer { skips = [:] }
        return skips.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
    private func skip(_ why: String) -> Bool {
        skips[why, default: 0] += 1
        return false
    }

    // MARK: Vẽ

    /// Vẽ một khung. Trả về false nếu bỏ qua (cửa sổ không hiện, chưa có cỡ, định dạng lạ).
    @discardableResult
    func render(_ pb: CVPixelBuffer) -> Bool {
        let o = options
        let type = CVPixelBufferGetPixelFormatType(pb)
        let tenBit = type == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || type == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let biplanar = tenBit || type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        // 4:2:2 đóng gói (định dạng gốc của nhiều capture card): đọc thẳng, khỏi để macOS đổi sang 4:2:0 cho từng khung.
        let packed: MTLPixelFormat? = type == kCVPixelFormatType_422YpCbCr8 ? .bgrg422 : type == kCVPixelFormatType_422YpCbCr8_yuvs ? .gbgr422 : nil
        guard (biplanar && CVPixelBufferGetPlaneCount(pb) == 2) || packed != nil else { return skip("định dạng lạ") }

        // Dò dải sáng cả khi cửa sổ đang ẩn, khoảng 4 lần mỗi giây.
        sampleTick += 1
        if sampleTick % 15 == 1 { sample(pb, tenBit: tenBit, packedYOffset: packed == nil ? nil : (type == kCVPixelFormatType_422YpCbCr8 ? 1 : 0)) }
        let formatFull = type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || type == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let full: Bool
        switch o.range {
        case .full: full = true
        case .limited: full = false
        case .auto: full = detector.decision ?? formatFull
        }
        let matrix = matrixName(pb, o)
        current = Interpretation(full: full, matrix: matrix, bits: tenBit ? 10 : 8, auto: o.range == .auto)

        guard o.visible, o.drawableSize.width >= 16, o.drawableSize.height >= 16, let cache else { return skip("cửa sổ ẩn") }
        configureLayer(o)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let frameTextures: [CVMetalTexture]
        if let packed {
            guard let t = texture(pb, plane: 0, format: packed, cache: cache, width: w, height: h) else { return skip("texture") }
            frameTextures = [t]
        } else {
            guard let yTex = texture(pb, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm, cache: cache),
                  let cTex = texture(pb, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm, cache: cache) else { return skip("texture") }
            frameTextures = [yTex, cTex]
        }
        let source = frameTextures.compactMap(CVMetalTextureGetTexture)
        guard source.count == frameTextures.count else { return skip("texture") }
        let convert = packed == nil ? "fyuv" : "fy422"

        // Vừa khung: giữ trọn hình, dư thì viền đen. Lấp đầy: phủ kín vùng vẽ, cắt đều phần thừa ở hai bên hoặc trên dưới
        // (hình 16:9 trên màn 16:10 của MacBook mất khoảng 5% mỗi bên trái phải).
        let dw = Double(o.drawableSize.width), dh = Double(o.drawableSize.height)
        let srcAspect = Double(w) / Double(h), dstAspect = dw / dh
        var cu = 0.0, cv = 0.0   // phần cắt ở mỗi bên, theo chiều ngang và dọc (0...0,5)
        if o.fill {
            if dstAspect < srcAspect { cu = (1 - dstAspect / srcAspect) / 2 } else { cv = (1 - srcAspect / dstAspect) / 2 }
        }
        let cw = Double(w) * (1 - 2 * cu), ch = Double(h) * (1 - 2 * cv)
        let fitW: Double, fitH: Double
        if o.fill { fitW = dw; fitH = dh }
        else if dstAspect > srcAspect { fitH = dh; fitW = (dh * srcAspect).rounded() } else { fitW = dw; fitH = (dw / srcAspect).rounded() }

        var p = Params()
        p.src = SIMD4(Float(cu), Float(cv), Float(1 - cu), Float(1 - cv))
        p.yuv = Self.levels(full: full, tenBit: tenBit)
        p.coef = Self.coefficients(matrix)
        p.sharp = SIMD4(0, 1 / Float(w), 1 / Float(h), 0.12)   // làm nét giờ do RCAS đảm nhận (PlayEffects)
        p.mode = SIMD4(Float(o.hdr == .off ? 0 : o.hdr == .tone ? 1 : 2), Float(o.headroom), o.gamut == .p3 ? 1 : 0, 0)

        guard let cb = queue.makeCommandBuffer() else { return skip("command buffer") }
        let outFormat = layer.pixelFormat
        var shown = 0
        if Self.processing(o) {
            // Đổi màu vào texture trung gian ở độ phân giải gốc (đã cắt theo Lấp đầy), rồi chèn khung, khử răng cưa, phóng, làm nét.
            let sw = max(16, Int(cw.rounded())), sh = max(16, Int(ch.rounded()))
            let gen = o.resizing ? PlayInterpolator.Mode.off : PlayCost.effective(o.frameGen, fps: 1 / max(frameInterval, 0.001))
            guard let slot = gen != .off ? interpolator.nextSlot(width: sw, height: sh) : effects.texture("source", sw, sh) else { return skip("texture") }
            p.dst = SIMD4(-1, -1, 1, 1)
            draw(cb, target: slot, clear: false, pipeline: convert, format: slot.pixelFormat, params: p, textures: source)
            var duplicate = false
            if gen == .thirty {
                let off: Int? = packed == nil ? nil : (type == kCVPixelFormatType_422YpCbCr8 ? 1 : 0)
                duplicate = interpolator.isDuplicate(PlayInterpolator.signature(pb, packedYOffset: off, tenBit: tenBit))
            }
            let outs = gen != .off ? interpolator.push(cb, mode: gen, interval: frameInterval, duplicate: duplicate)
                                   : [PlayInterpolator.Output(texture: slot, after: 0, synthetic: false)]
            let vp = PlayEffects.Viewport(x: Int(((dw - fitW) / 2).rounded()), y: Int(((dh - fitH) / 2).rounded()), w: Int(fitW), h: Int(fitH))
            // RCAS: 0 là mạnh nhất, mỗi 1 giảm một nửa. Đang kéo đổi cỡ thì chỉ phóng song tuyến (khỏi dựng lại texture mỗi cỡ).
            let stops: Float?
            switch o.sharpen {
            case .off: stops = nil
            case .low: stops = 1.0
            case .medium: stops = 0.5
            case .high: stops = 0.0
            }
            let fx = PlayEffects.Options(upscaler: o.resizing ? .bilinear : o.upscaler, sharpenStops: o.resizing ? nil : stops,
                                         antiAlias: o.antiAlias, hdr: o.hdr == .edr)
            for out in outs {
                guard let drawable = layer.nextDrawable() else { break }
                if !effects.encode(cb, source: out.texture, target: drawable.texture, vp: vp, options: fx) {
                    var q = Params()
                    q.dst = SIMD4(Float(-fitW / dw), Float(-fitH / dh), Float(fitW / dw), Float(fitH / dh))
                    draw(cb, target: drawable.texture, clear: true, pipeline: "frgb", format: outFormat, params: q, textures: [out.texture])
                }
                countPresented(drawable)
                if out.after > 0 {
                    cb.present(drawable, afterMinimumDuration: out.after * (o.latency == .smooth ? 0.95 : 0.9))
                } else if o.latency == .smooth {
                    cb.present(drawable, afterMinimumDuration: frameInterval / Double(outs.count) * 0.95)
                } else {
                    cb.present(drawable)
                }
                shown += 1
            }
            lastStages = ((gen == .off ? [] : [gen == .double ? "chèn khung x2" : "chèn khung 30→60"]) + effects.lastStages)
                .joined(separator: " → ")
        } else {
            guard let drawable = layer.nextDrawable() else { return skip("drawable") }
            p.dst = SIMD4(Float(-fitW / dw), Float(-fitH / dh), Float(fitW / dw), Float(fitH / dh))
            draw(cb, target: drawable.texture, clear: true, pipeline: convert, format: outFormat, params: p, textures: source)
            countPresented(drawable)
            if o.latency == .smooth {
                cb.present(drawable, afterMinimumDuration: frameInterval * 0.95)
            } else {
                cb.present(drawable)
            }
            shown = 1
            lastStages = ""
        }
        // Giữ texture của khung tới khi GPU vẽ xong; ghi thời gian GPU.
        cb.addCompletedHandler { [weak self] cb in
            _ = frameTextures
            guard let self, cb.gpuEndTime > cb.gpuStartTime else { return }
            self.statsLock.lock()
            self.gpuTotal += cb.gpuEndTime - cb.gpuStartTime
            self.gpuFrames += 1
            self.winGpu += cb.gpuEndTime - cb.gpuStartTime
            self.winFrames += 1
            self.statsLock.unlock()
        }
        cb.commit()
        let processed = Self.processing(o)
        let values: PlayCost.Values = processed
            ? (o.resizing ? .bilinear : o.upscaler, o.resizing ? .off : o.sharpen, o.antiAlias, o.resizing ? .off : o.frameGen)
            : (.bilinear, .off, false, .off)
        updateCost(values, source: (cw.rounded(), ch.rounded()), output: (fitW, fitH), resizing: o.resizing)
        logProcessing(o)
        return shown > 0 ? true : skip("drawable")
    }

    private func countPresented(_ d: CAMetalDrawable) {
        d.addPresentedHandler { [weak self] d in
            guard let self, d.presentedTime > 0 else { return }
            self.statsLock.lock(); self.presented += 1; self.statsLock.unlock()
        }
    }

    /// Mỗi 10 giây ghi các bước xử lý, thời gian GPU và số khung hiện được mỗi giây (chèn khung x2 thì phải gần 120).
    private func logProcessing(_ o: PlayRenderOptions) {
        let elapsed = Date().timeIntervalSince(lastFxLog)
        guard elapsed >= 10 else { return }
        statsLock.lock()
        let ms = gpuFrames > 0 ? gpuTotal / Double(gpuFrames) * 1000 : 0
        let fps = Double(presented) / elapsed
        gpuTotal = 0; gpuFrames = 0; presented = 0
        let stages = lastStages.isEmpty ? "vẽ thẳng" : lastStages
        processing = (ms, stages)
        statsLock.unlock()
        lastFxLog = Date()
        let fg = o.frameGen == .off ? "" : String(format: ", chèn %d khung, %d khung lặp", interpolator.syntheticFrames, interpolator.duplicateFrames)
        let c = costInfo()
        let lag = c.measured.map { String(format: "; trễ thêm đo được %.1f ms", $0) } ?? ""
        DebugLog.write(String(format: "Màn hình chơi: xử lý hình %@; GPU %.2f ms mỗi lần vẽ; hiện %.1f khung/giây%@%@; hệ số GPU %.2f",
                              stages, ms, fps, fg, lag, c.cost.factor))
    }

    /// Mỗi 2 giây: độ trễ thêm đo được của cách đang dùng, và chỉnh dần hệ số GPU của PlayCost theo số đo (chỉ khi có xử lý,
    /// vì vẽ thẳng quá nhẹ để so). Lưu lại 10 giây một lần cho trang Cài đặt.
    private func updateCost(_ v: PlayCost.Values, source: (Double, Double), output: (Double, Double), resizing: Bool) {
        let key = "\(v.upscaler)-\(v.sharpen)-\(v.antiAlias)-\(v.frameGen)-\(source)-\(output)-\(frameInterval)-\(resizing)"
        if key != winKey { winKey = key; winMixed = true }
        guard Date().timeIntervalSince(winStart) >= 2 else { return }
        statsLock.lock()
        let ms = winFrames > 0 ? winGpu / Double(winFrames) * 1000 : nil
        winGpu = 0; winFrames = 0
        var c = cost
        c.fps = 1 / max(frameInterval, 0.001)
        c.sourceW = source.0; c.sourceH = source.1
        c.outputW = output.0; c.outputH = output.1
        if winMixed || resizing {
            measuredLag = nil
        } else if !PlayCost.processing(v) {
            measuredLag = 0
        } else if let ms {
            let m = c.model(v)
            if m >= 0.5 { c.factor = min(8, max(0.5, c.factor * 0.7 + ms / m * 0.3)) }
            measuredLag = c.measured(gpu: ms, frameGen: v.frameGen)
        }
        cost = c
        statsLock.unlock()
        winMixed = false
        winStart = Date()
        if Date().timeIntervalSince(lastCostSave) >= 10 {
            lastCostSave = Date()
            c.save()
        }
    }

    private struct Params {
        var dst = SIMD4<Float>(-1, -1, 1, 1)
        var src = SIMD4<Float>(0, 0, 1, 1)
        var yuv = SIMD4<Float>(0, 1, 0.5, 1)
        var coef = SIMD4<Float>(0, 0, 0, 0)
        var sharp = SIMD4<Float>(0, 0, 0, 0)
        var mode = SIMD4<Float>(0, 1, 0, 0)
    }

    private func draw(_ cb: MTLCommandBuffer, target: MTLTexture, clear: Bool, pipeline name: String, format: MTLPixelFormat,
                      params: Params, textures: [MTLTexture]) {
        guard let state = pipeline(name, format: format) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var p = params
        enc.setRenderPipelineState(state)
        enc.setVertexBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        enc.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func pipeline(_ name: String, format: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = "\(name)-\(format.rawValue)"
        if let p = pipelines[key] { return p }
        guard let lib = library else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vquad")
        d.fragmentFunction = lib.makeFunction(name: name)
        d.colorAttachments[0].pixelFormat = format
        do {
            let p = try device.makeRenderPipelineState(descriptor: d)
            pipelines[key] = p
            return p
        } catch {
            DebugLog.write("Màn hình chơi: lỗi dựng pipeline \(key): \(error)")
            return nil
        }
    }

    private func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache,
                         width: Int? = nil, height: Int? = nil) -> CVMetalTexture? {
        var tex: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, width ?? CVPixelBufferGetWidthOfPlane(pb, plane),
                                                           height ?? CVPixelBufferGetHeightOfPlane(pb, plane), plane, &tex)
        return st == kCVReturnSuccess ? tex : nil
    }

    /// Kiểu điểm ảnh, không gian màu và số khung đệm của lớp vẽ theo tuỳ chọn HDR, không gian màu và độ trễ.
    private func configureLayer(_ o: PlayRenderOptions) {
        if layer.drawableSize != o.drawableSize { layer.drawableSize = o.drawableSize }
        // Chèn khung hiện hai drawable mỗi khung tín hiệu nên cần ba khung đệm.
        let triple = o.latency == .smooth || (o.frameGen != .off && Self.processing(o))
        if let cfg = layerConfig, cfg == (o.hdr, o.gamut, o.latency, triple) { return }
        layerConfig = (o.hdr, o.gamut, o.latency, triple)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if o.hdr == .edr {
            layer.pixelFormat = .rgba16Float
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: o.gamut == .p3 ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.extendedLinearSRGB)
        } else {
            layer.pixelFormat = .bgra8Unorm
            layer.wantsExtendedDynamicRangeContent = false
            layer.colorspace = CGColorSpace(name: o.gamut == .p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)
        }
        layer.maximumDrawableCount = triple ? 3 : 2
        CATransaction.commit()
        DebugLog.write("Màn hình chơi: lớp vẽ \(o.hdr == .edr ? "EDR rgba16Float" : "SDR bgra8"), \(o.gamut == .p3 ? "Display P3" : "sRGB"), \(triple ? "3" : "2") khung đệm")
    }

    // MARK: Màu

    /// Ma trận theo tuỳ chọn; Tự động thì theo thẻ của khung (card có ghi), không có thì HD dùng BT.709, SD dùng BT.601.
    /// Tín hiệu HDR10 luôn dùng BT.2020.
    private func matrixName(_ pb: CVPixelBuffer, _ o: PlayRenderOptions) -> String {
        if o.hdr != .off { return "2020" }
        switch o.matrix {
        case .bt709: return "709"
        case .bt601: return "601"
        case .auto:
            if let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String {
                if m == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) || m == (kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String) { return "601" }
                if m == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { return "2020" }
                return "709"
            }
            return CVPixelBufferGetHeight(pb) >= 720 ? "709" : "601"
        }
    }

    /// Hệ số đổi Cr→R, Cb→G, Cr→G, Cb→B.
    private static func coefficients(_ m: String) -> SIMD4<Float> {
        switch m {
        case "601": return SIMD4(1.402, 0.344136, 0.714136, 1.772)
        case "2020": return SIMD4(1.4746, 0.16455, 0.57135, 1.8814)
        default: return SIMD4(1.5748, 0.1873, 0.4681, 1.8556)
        }
    }

    /// Mức đen, độ giãn của độ sáng và mức giữa, độ giãn của màu (giá trị texture 0...1).
    /// Dải giới hạn: Y từ 16 tới 235, màu từ 16 tới 240. Dải đầy đủ: 0 tới 255. 10 bit nằm ở 10 bit cao của 16 bit.
    static func levels(full: Bool, tenBit: Bool) -> SIMD4<Float> {
        if tenBit {
            let u: Float = 64 / 65535
            return full ? SIMD4(0, 1 / (1023 * u), 512 * u, 1 / (1023 * u)) : SIMD4(64 * u, 1 / (876 * u), 512 * u, 1 / (896 * u))
        }
        return full ? SIMD4(0, 1, 128 / 255, 1) : SIMD4(16 / 255, 255 / 219, 128 / 255, 255 / 224)
    }

    /// Lấy mẫu 64×36 điểm độ sáng của khung (thang 8 bit) đưa cho bộ dò dải sáng. `packedYOffset`: khung 4:2:2 đóng gói,
    /// mỗi điểm hai byte, byte độ sáng đứng thứ mấy (2vuy là 1, yuvs là 0).
    private func sample(_ pb: CVPixelBuffer, tenBit: Bool, packedYOffset: Int?) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        if let off = packedYOffset {
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
            var values = [UInt8]()
            values.reserveCapacity(64 * 36)
            for j in 0..<36 {
                let y = (j * 2 + 1) * h / 72
                for i in 0..<64 {
                    let x = (i * 2 + 1) * w / 128
                    values.append(base.advanced(by: y * row + x * 2 + off).assumingMemoryBound(to: UInt8.self).pointee)
                }
            }
            detector.feed(values)
            return
        }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0), row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var values = [UInt8]()
        values.reserveCapacity(64 * 36)
        for j in 0..<36 {
            let y = (j * 2 + 1) * h / 72
            for i in 0..<64 {
                let x = (i * 2 + 1) * w / 128
                if tenBit {
                    let v = base.advanced(by: y * row + x * 2).assumingMemoryBound(to: UInt16.self).pointee >> 8
                    values.append(UInt8(v))
                } else {
                    values.append(base.advanced(by: y * row + x).assumingMemoryBound(to: UInt8.self).pointee)
                }
            }
        }
        detector.feed(values)
    }

    // MARK: Shader

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params { float4 dst; float4 src; float4 yuv; float4 coef; float4 sharp; float4 mode; };
    struct VOut { float4 pos [[position]]; float2 uv; };
    constexpr sampler smp(filter::linear, address::clamp_to_edge);

    vertex VOut vquad(uint vid [[vertex_id]], constant Params& p [[buffer(0)]]) {
        float2 c = float2(vid & 1, vid >> 1);
        VOut o;
        o.pos = float4(mix(p.dst.x, p.dst.z, c.x), mix(p.dst.w, p.dst.y, c.y), 0.0, 1.0);
        o.uv = float2(mix(p.src.x, p.src.z, c.x), mix(p.src.y, p.src.w, c.y));
        return o;
    }

    float3 pqToNits(float3 e) {
        const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
        float3 p = pow(clamp(e, 0.0, 1.0), 1.0 / m2);
        return 10000.0 * pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
    }

    float3 to709(float3 c) {
        return float3(dot(float3(1.6605, -0.5876, -0.0728), c), dot(float3(-0.1246, 1.1329, -0.0083), c), dot(float3(-0.0182, -0.1006, 1.1187), c));
    }

    float3 toP3(float3 c) {
        return float3(dot(float3(1.3436, -0.2822, -0.0614), c), dot(float3(-0.0653, 1.0758, -0.0105), c), dot(float3(0.0028, -0.0196, 1.0168), c));
    }

    float3 srgbEncode(float3 x) {
        x = clamp(x, 0.0, 1.0);
        return select(1.055 * pow(x, 1.0 / 2.4) - 0.055, 12.92 * x, x <= 0.0031308);
    }

    // Giữ nguyên tới 75% mức đỉnh, trên đó nén mềm dần về mức đỉnh, giữ tỉ lệ giữa ba kênh để không lệch sắc.
    float3 softClip(float3 rgb, float top) {
        float m = max(max(rgb.r, rgb.g), rgb.b);
        float knee = 0.75 * top;
        if (m <= knee) return rgb;
        float t = (m - knee) / (top - knee);
        return rgb * ((knee + (top - knee) * t / (1.0 + t)) / m);
    }

    float4 shade(float y, float2 cbcr, constant Params& p) {
        float2 c = (cbcr - p.yuv.z) * p.yuv.w;
        float Y = (y - p.yuv.x) * p.yuv.y;
        float3 rgb = float3(Y + p.coef.x * c.y, Y - p.coef.y * c.x - p.coef.z * c.y, Y + p.coef.w * c.x);
        if (p.mode.x < 0.5) return float4(clamp(rgb, 0.0, 1.0), 1.0);
        float3 lin = pqToNits(rgb) / 203.0;
        lin = max(p.mode.z > 0.5 ? toP3(lin) : to709(lin), 0.0);
        if (p.mode.x < 1.5) return float4(srgbEncode(softClip(lin, 1.0)), 1.0);
        return float4(softClip(lin, max(p.mode.y, 1.0)), 1.0);
    }

    // Làm nét kiểu unsharp trên độ sáng: so điểm với trung bình bốn điểm kề (theo lưới điểm ảnh gốc), giới hạn mức đẩy để
    // không viền sáng quanh chữ.
    float sharpen(float y, float n, constant Params& p) {
        return y + p.sharp.x * clamp(y - 0.25 * n, -p.sharp.w, p.sharp.w);
    }

    // 4:2:0 hai mặt phẳng: độ sáng ở texture 0, màu (Cb, Cr) ở texture 1.
    fragment float4 fyuv(VOut in [[stage_in]], texture2d<float> yT [[texture(0)]], texture2d<float> cT [[texture(1)]],
                         constant Params& p [[buffer(0)]]) {
        float y = yT.sample(smp, in.uv).r;
        if (p.sharp.x > 0.0) {
            float2 t = p.sharp.yz;
            y = sharpen(y, yT.sample(smp, in.uv + float2(t.x, 0)).r + yT.sample(smp, in.uv - float2(t.x, 0)).r
                         + yT.sample(smp, in.uv + float2(0, t.y)).r + yT.sample(smp, in.uv - float2(0, t.y)).r, p);
        }
        return shade(y, cT.sample(smp, in.uv).rg, p);
    }

    // 4:2:2 đóng gói (2vuy, yuvs) đọc qua kiểu BGRG422/GBGR422: phần cứng trả độ sáng ở kênh g, Cb ở b, Cr ở r.
    fragment float4 fy422(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant Params& p [[buffer(0)]]) {
        float4 s = t.sample(smp, in.uv);
        float y = s.g;
        if (p.sharp.x > 0.0) {
            float2 d = p.sharp.yz;
            y = sharpen(y, t.sample(smp, in.uv + float2(d.x, 0)).g + t.sample(smp, in.uv - float2(d.x, 0)).g
                         + t.sample(smp, in.uv + float2(0, d.y)).g + t.sample(smp, in.uv - float2(0, d.y)).g, p);
        }
        return shade(y, float2(s.b, s.r), p);
    }

    fragment float4 frgb(VOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
        return t.sample(smp, in.uv);
    }
    """
}

/// Dò dải sáng thật của tín hiệu từ số liệu độ sáng, vì card hay ghi sai: khung ghi "dải giới hạn" nhưng chứa cả giá trị dưới
/// 16 (máy chơi game xuất dải đầy đủ, card chuyển thẳng) thì hình bị gắt, mất chi tiết vùng tối; khung ghi "dải đầy đủ" mà độ
/// sáng chỉ nằm trong 16–235 thì hình nhạt, đen thành xám. Mỗi lần đổi cách hiểu đều ghi nhật ký kèm số liệu.
///
/// Đo trên card Hagibis với Switch 2 dải giới hạn (09/10/2026): khung đầu tiên card gửi là khung cũ dở dang (phần lớn độ sáng 0,
/// phần còn lại là hình), rồi màn đen độ sáng 16 khoảng 7,5 giây, rồi lúc hình hiện lại có một mảng tối lấm tấm độ sáng 0–15
/// trong khoảng 0,75 giây. Nên bằng chứng chỉ tính khi hình đã đứng 2 giây kể từ lúc mở và từ khung một màu gần nhất; hiểu là
/// dải đầy đủ mà 20 giây liền không còn độ sáng ngoài 12–243 thì quay về dải giới hạn, kể cả khi khung ghi dải giới hạn.
struct RangeDetector {
    var baselineFull = false
    /// nil: theo kiểu khung; true/false: đã dò ra dải đầy đủ hay giới hạn.
    private(set) var decision: Bool?
    /// Đếm từ lần đổi cách hiểu gần nhất. `contrastFrames`: số mẫu đủ tương phản kể từ lần cuối thấy độ sáng ngoài 12–243.
    private var lowFrames = 0, highFrames = 0, contrastFrames = 0, sampled = 0
    // Số liệu cho nhật ký, xoá sau mỗi lần đọc.
    private var minSeen = 255, maxSeen = 0
    private let started: Date
    /// Lúc mở hoặc lúc gần nhất gặp khung một màu: hình hiện lại sau đó vài khung còn lẫn rác.
    private var lastFlat: Date
    /// Lúc đổi cách hiểu hoặc lúc gần nhất thấy độ sáng ngoài 12–243.
    private var lastExtreme: Date

    /// Hình phải đứng bấy nhiêu giây sau lúc mở hay sau khung một màu thì mẫu mới được tính.
    static let settle: TimeInterval = 2
    /// Đang hiểu dải đầy đủ mà bấy nhiêu giây không còn độ sáng ngoài 12–243 thì quay về dải giới hạn.
    static let revert: TimeInterval = 20

    init(baselineFull: Bool = false, now: Date = Date()) {
        self.baselineFull = baselineFull
        started = now; lastFlat = now; lastExtreme = now
        #if DEVTOOLS
        if let dir = ProcessInfo.processInfo.environment["OVERSUB_PLAY_RANGE_DUMP"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("range-\(Int(now.timeIntervalSince1970 * 1000)).bin")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            dump = try? FileHandle(forWritingTo: url)
        }
        #endif
    }

    #if DEVTOOLS
    /// Bản dev: OVERSUB_PLAY_RANGE_DUMP=<thư mục> ghi mọi mẫu độ sáng vào một tệp mỗi tín hiệu (mỗi mẫu: số giây kể từ lúc dò
    /// lại kiểu Double, rồi 64×36 byte độ sáng), để thử luật dò trên số liệu card thật mà không phải mở card lại.
    private var dump: FileHandle?
    #endif

    /// Cách hiểu đang dùng khi để Tự động.
    var full: Bool { decision ?? baselineFull }

    mutating func feed(_ values: [UInt8], now: Date = Date()) {
        guard !values.isEmpty else { return }
        #if DEVTOOLS
        if let dump {
            var t = now.timeIntervalSince(started)
            dump.write(Data(bytes: &t, count: 8) + Data(values))
        }
        #endif
        sampled += 1
        let sorted = values.sorted()
        let lo = Int(sorted[sorted.count / 100]), hi = Int(sorted[sorted.count * 99 / 100])
        minSeen = min(minSeen, lo); maxSeen = max(maxSeen, hi)
        // Khung gần như một màu (card chưa có tín hiệu, màn hình đen lúc chuyển cảnh) không nói lên dải sáng: card hay tự phát
        // khung đen độ sáng 0 khi máy chơi game tắt, tính vào thì hiểu nhầm thành dải đầy đủ.
        guard hi - lo >= 40 else { lastFlat = now; return }
        guard now.timeIntervalSince(lastFlat) >= Self.settle else { return }
        let n = Double(values.count)
        let under = Double(values.filter { $0 < 10 }.count) / n
        let over = Double(values.filter { $0 > 250 }.count) / n
        if Double(values.filter { $0 < 12 || $0 > 243 }.count) / n >= 0.003 {
            lastExtreme = now; contrastFrames = 0
        } else if hi - lo >= 160 {
            contrastFrames += 1
        }
        if !full {
            if under >= 0.003 { lowFrames += 1 }
            if over >= 0.003 { highFrames += 1 }
            guard lowFrames >= 3 || highFrames >= 3 else { return }
            DebugLog.write("Màn hình chơi: \(baselineFull ? "" : "khung ghi dải giới hạn nhưng ")có \(lowFrames) lần thấy độ sáng dưới 10, \(highFrames) lần trên 250: hiểu là dải đầy đủ")
            switchTo(full: true, now: now)
        } else if now.timeIntervalSince(lastExtreme) >= Self.revert, contrastFrames >= 20 {
            DebugLog.write("Màn hình chơi: \(baselineFull ? "khung ghi dải đầy đủ nhưng " : "")\(Int(Self.revert)) giây liền (\(contrastFrames) lần lấy mẫu) độ sáng chỉ nằm trong 12–243: hiểu là dải giới hạn")
            switchTo(full: false, now: now)
        }
    }

    private mutating func switchTo(full: Bool, now: Date) {
        decision = full
        lowFrames = 0; highFrames = 0; contrastFrames = 0
        lastExtreme = now
    }

    /// Độ sáng thấp nhất và cao nhất (phân vị 1% và 99%) từ lần đọc trước, rồi xoá.
    mutating func takeStats() -> (Int, Int)? {
        defer { minSeen = 255; maxSeen = 0 }
        return maxSeen >= minSeen ? (minSeen, maxSeen) : nil
    }
}
