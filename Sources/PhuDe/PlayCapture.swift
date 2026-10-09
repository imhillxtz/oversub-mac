import AVFoundation
import IOKit
import AppKit

/// Phiên nhận hình và tiếng từ capture card. Hình đọc thẳng từ CoreMediaIO (`CMIOVideoStream`, không được thì AVCaptureSession)
/// trên `videoQueue`, rồi vẽ bằng Metal trên `renderQueue` riêng (không qua luồng chính, để trễ thấp). Hai luồng tách nhau vì
/// `nextDrawable` có thể chặn tới gần một giây khi WindowServer vẽ trễ (GPU bị app khác chiếm, đổi Space): trước đây việc vẽ nằm
/// trên luồng nhận hình nên hàng đợi của card đầy và khung bị mất hẳn (đo được lỗ hổng 688 ms, có lúc chỉ nhận 19 khung/giây).
/// Giờ luồng nhận hình luôn lấy hết khung, chỉ giữ khung mới nhất cho luồng vẽ; tiếng đi thẳng ra loa bằng AVCaptureAudioPreviewOutput. Mọi thay đổi phiên chạy trên `sessionQueue` (startRunning chặn luồng).
final class PlayCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let renderer: PlayRenderer
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "oversub.play.session")
    private let videoQueue = DispatchQueue(label: "oversub.play.video", qos: .userInteractive)
    private let renderQueue = DispatchQueue(label: "oversub.play.render", qos: .userInteractive)
    // Hộp chờ vẽ: luồng nhận hình đặt khung mới nhất, luồng vẽ lấy ra. Khung chưa kịp vẽ mà có khung mới thì bị thay.
    private let boxLock = NSLock()
    private var boxFrame: CVPixelBuffer?
    private var boxScheduled = false
    private var drawnTotal = 0, replacedTotal = 0   // ghi trên luồng vẽ hoặc dưới khoá, đọc dưới khoá
    private var drawnAtLog = 0, replacedAtLog = 0   // chỉ dùng trên videoQueue
    private let output = AVCaptureVideoDataOutput()
    private var audioOut: AVCaptureAudioPreviewOutput?
    private var direct: CMIOVideoStream?
    private var runtimeObserver: NSObjectProtocol?

    // Số liệu, chỉ dùng trên videoQueue (số khung đã vẽ nằm dưới boxLock).
    private var received = 0, dropped = 0
    private var windowReceived = 0, windowDropped = 0
    /// Nhịp khung thật của card (theo mốc thời gian card ghi), để biết hình giật do card gửi không đều hay do app vẽ chậm.
    private var cadence = Cadence()
    private var lastLog = Date()
    private var lastFrameAt = Date.distantPast

    /// Khung đầu tiên đã tới (gọi trên luồng chính).
    var onFirstFrame: ((String) -> Void)?

    init(renderer: PlayRenderer) {
        self.renderer = renderer
        super.init()
    }

    /// Thời điểm khung gần nhất tới (để báo "chưa có hình" khi card không nhận được tín hiệu HDMI).
    var secondsSinceLastFrame: Double {
        videoQueue.sync { Date().timeIntervalSince(lastFrameAt) }
    }

    struct Setup {
        let video: AVCaptureDevice
        let format: AVCaptureDevice.Format?
        let audio: AVCaptureDevice?
        let outputUID: String?
        let volume: Float
    }

    /// Mở phiên. `done` (luồng chính) nhận mô tả định dạng đang chạy, hoặc lỗi để hiện cho người dùng.
    func start(_ s: Setup, done: @escaping @MainActor (Result<String, Error>) -> Void) {
        sessionQueue.async { [self] in
            let result = Result { try configure(s) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    private func configure(_ s: Setup) throws -> String {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        audioOut = nil
        direct?.stop()
        direct = nil

        // Xin đúng định dạng gốc (4:2:0 hay 4:2:2) để macOS không phải đổi định dạng cho từng khung (đo trên card Hagibis:
        // bước đổi 4:2:2 sang 4:2:0 tốn đáng kể), và không giãn hay nén độ sáng trước khi tới bộ vẽ (giãn sai là mất vùng
        // tối, không lấy lại được). MJPEG thì giải mã ra 4:2:0 dải đầy đủ như ảnh JPEG.
        let native = s.format.map { CMFormatDescriptionGetMediaSubType($0.formatDescription) } ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var want: OSType
        switch native {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs: want = native
        case kCMVideoCodecType_JPEG_OpenDML, kCMVideoCodecType_JPEG: want = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        default: want = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }

        // Hình đọc thẳng từ CoreMediaIO khi được: qua AVCaptureSession thì macOS chạy thêm đường hiệu ứng video, tốn gấp ba
        // (xem CMIOVideoStream). Định dạng nén hay thiết bị CoreMediaIO không nhận thì quay về AVCaptureSession.
        let stream = Self.allowDirect ? CMIOVideoStream(video: s.video, format: s.format, deliver: videoQueue) { [weak self] pb, skipped, times in
            guard let self else { return }
            dropped += skipped; windowDropped += skipped
            cadence.add(times)
            handle(pb)
        } : nil
        if let stream {
            want = stream.subtype
        } else {
            let input = try AVCaptureDeviceInput(device: s.video)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw AppError(L("Không mở được \(s.video.localizedName). Có thể app khác đang dùng thiết bị này.",
                                 "Couldn't open \(s.video.localizedName). Another app may be using it."))
            }
            session.addInput(input)
            if !output.availableVideoPixelFormatTypes.contains(want) { want = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: want, kCVPixelBufferMetalCompatibilityKey as String: true]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        let baselineFull = want == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || want == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        renderQueue.sync { renderer.resetDetection(baselineFull: baselineFull) }
        videoQueue.sync {
            resetCounters()
            lastLog = Date(); lastFrameAt = Date()
        }

        var audioNote = L("không có tiếng", "no audio")
        if let a = s.audio {
            do {
                let ain = try AVCaptureDeviceInput(device: a)
                if session.canAddInput(ain) {
                    session.addInput(ain)
                    let ap = AVCaptureAudioPreviewOutput()
                    ap.outputDeviceUniqueID = s.outputUID
                    ap.volume = s.volume
                    if session.canAddOutput(ap) { session.addOutput(ap); audioOut = ap; audioNote = a.localizedName }
                }
            } catch {
                DebugLog.write("Màn hình chơi: không mở được nguồn tiếng \(a.localizedName): \(error.localizedDescription)")
            }
        }

        var fps = stream?.fps ?? 0
        if stream == nil {
            try s.video.lockForConfiguration()
            if let f = s.format {
                s.video.activeFormat = f
                if let r = f.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                    s.video.activeVideoMinFrameDuration = r.minFrameDuration
                    fps = r.maxFrameRate
                }
            }
        }
        session.commitConfiguration()
        if runtimeObserver == nil {
            runtimeObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
                let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                DebugLog.write("Màn hình chơi: phiên nhận hình báo lỗi: \(err?.localizedDescription ?? "?") (mã \(err?.code ?? 0))")
            }
        }
        // Đọc thẳng CoreMediaIO mà không có tiếng thì phiên không có gì để chạy.
        if !session.inputs.isEmpty { session.startRunning() }
        if let stream {
            guard stream.start() else {
                if session.isRunning { session.stopRunning() }
                throw AppError(L("Không mở được \(s.video.localizedName). Có thể app khác đang dùng thiết bị này.",
                                 "Couldn't open \(s.video.localizedName). Another app may be using it."))
            }
            direct = stream
        } else {
            s.video.unlockForConfiguration()
        }
        if fps > 0 { renderer.frameInterval = 1 / fps }
        let desc = s.format.map { CaptureCards.describe($0, fps: fps, codec: true) } ?? "?"
        DebugLog.write("Màn hình chơi: mở \(s.video.localizedName) \(desc), gốc \(CaptureCards.fourCC(native)), nhận \(CaptureCards.fourCC(want)); tiếng: \(audioNote)"
                       + (s.audio != nil ? ", loa: \(s.outputUID ?? "theo macOS"), âm lượng \(String(format: "%.2f", s.volume))" : "")
                       + "; hình qua \(stream != nil ? String(format: "CoreMediaIO (%.2f khung/giây)", fps) : "AVCaptureSession")")
        if stream == nil {
            // Hiệu ứng video của macOS (Trung tâm điều khiển › Hiệu ứng video) chạy nhận diện mặt, người, tay trên từng khung, rất tốn CPU.
            let f = s.format
            DebugLog.write("Màn hình chơi: cử chỉ Reactions \(AVCaptureDevice.reactionEffectGesturesEnabled ? "BẬT" : "tắt"); hiệu ứng video đang bật:"
                           + " chân dung \(AVCaptureDevice.isPortraitEffectEnabled)/\(f?.isPortraitEffectSupported ?? false),"
                           + " ánh sáng studio \(AVCaptureDevice.isStudioLightEnabled)/\(f?.isStudioLightSupported ?? false),"
                           + " Center Stage \(AVCaptureDevice.isCenterStageEnabled)/\(f?.isCenterStageSupported ?? false),"
                           + " Reactions \(AVCaptureDevice.reactionEffectsEnabled)/\(f?.reactionEffectsSupported ?? false),"
                           + " thay nền \(AVCaptureDevice.isBackgroundReplacementEnabled)/\(f?.isBackgroundReplacementSupported ?? false) (bật/định dạng hỗ trợ)")
        }
        return desc
    }

    /// Bản dev: OVERSUB_PLAY_PATH=avf ép hình đi qua AVCaptureSession như trước, để so CPU hai đường.
    private static var allowDirect: Bool {
        #if DEVTOOLS
        return ProcessInfo.processInfo.environment["OVERSUB_PLAY_PATH"] != "avf"
        #else
        return true
        #endif
    }

    func stop() {
        sessionQueue.sync {
            direct?.stop()
            direct = nil
            if session.isRunning { session.stopRunning() }
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            audioOut = nil
        }
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        runtimeObserver = nil
        let total = videoQueue.sync { (received, drawnCount, dropped) }
        DebugLog.write("Màn hình chơi: dừng nhận hình và tiếng (tổng \(total.0) khung nhận, \(total.1) khung vẽ, \(total.2) khung bỏ)")
    }

    var isRunning: Bool { sessionQueue.sync { session.isRunning || direct != nil } }

    /// Đặt âm lượng; `ramp`: chuyển dần trong khoảng 0,12 giây (giảm tiếng khi giọng đọc bắt đầu) để không nghe tiếng bụp.
    func setVolume(_ v: Float, ramp: Bool) {
        sessionQueue.async { [self] in
            guard let out = audioOut else { return }
            let from = out.volume
            guard ramp, abs(from - v) > 0.01 else { out.volume = v; return }
            for k in 1...6 {
                out.volume = from + (v - from) * Float(k) / 6
                if k < 6 { usleep(20_000) }
            }
        }
    }

    func setOutput(_ uid: String?) {
        sessionQueue.async { [self] in audioOut?.outputDeviceUniqueID = uid }
    }

    // MARK: Khung hình

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if t.isValid { cadence.add([t.seconds]) }
        handle(pb)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dropped += 1; windowDropped += 1
    }

    private var drawnCount: Int { boxLock.lock(); defer { boxLock.unlock() }; return drawnTotal }

    private func resetCounters() {
        received = 0; dropped = 0; windowReceived = 0; windowDropped = 0
        boxLock.lock(); drawnTotal = 0; replacedTotal = 0; boxLock.unlock()
        drawnAtLog = 0; replacedAtLog = 0
    }

    /// Một khung tới (từ card, hoặc từ nguồn thử trong bản dev). Chạy trên videoQueue: đếm, rồi đặt vào hộp chờ cho luồng vẽ.
    private func handle(_ pb: CVPixelBuffer) {
        received += 1; windowReceived += 1
        lastFrameAt = Date()
        if received == 1 {
            let info = Self.describe(pb)
            DebugLog.write("Màn hình chơi: khung đầu tiên \(info)")
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onFirstFrame?(info) } }
        }
        boxLock.lock()
        if boxFrame != nil { replacedTotal += 1 }
        boxFrame = pb
        let schedule = !boxScheduled
        boxScheduled = true
        let drawn = drawnTotal, replaced = replacedTotal
        boxLock.unlock()
        if schedule { renderQueue.async { [weak self] in self?.drawPending() } }

        let elapsed = Date().timeIntervalSince(lastLog)
        if elapsed >= 10 {
            // Phần của luồng nhận hình chụp ở đây; phần của bộ vẽ đọc trên luồng vẽ để khỏi tranh nhau trạng thái.
            let head = String(format: "Màn hình chơi: %.1f khung/giây nhận, %.1f vẽ, %d bỏ", Double(windowReceived) / elapsed,
                              Double(drawn - drawnAtLog) / elapsed, windowDropped)
            let late = replaced - replacedAtLog
            let tail = (late > 0 ? ", \(late) khung thay vì vẽ chậm" : "")
            let (cad, median) = cadence.take()
            // Nhịp đo thật lệch quá 3% so với nhịp đang dùng thì đổi theo (độ trễ Mượt, chèn khung, số trễ thêm).
            if let m = median, m > 0.008, m < 0.05, abs(m - renderer.frameInterval) / renderer.frameInterval > 0.03 {
                DebugLog.write(String(format: "Màn hình chơi: card gửi đều %.1f ms một khung (%.1f khung/giây), khác %.1f khung/giây đang dùng: dùng nhịp đo được",
                                      m * 1000, 1 / m, 1 / renderer.frameInterval))
                renderer.frameInterval = m
            }
            drawnAtLog = drawn; replacedAtLog = replaced
            windowReceived = 0; windowDropped = 0
            lastLog = Date()
            renderQueue.async { [renderer] in
                let y = renderer.takeStats().map { "độ sáng \($0.0)–\($0.1)" } ?? "chưa lấy mẫu"
                let i = renderer.current
                let skips = renderer.takeSkips()
                DebugLog.write(String(format: "%@%@%@; %@; hiểu là dải %@%@, BT.%@, %d bit%@%@%@", head, tail,
                                      skips.isEmpty ? "" : " (không vẽ: \(skips))", y,
                                      i.full ? "đầy đủ" : "giới hạn", i.auto ? " (tự động)" : "", i.matrix, i.bits,
                                      cad, renderer.takeTiming(), Self.gpuLoad()))
            }
        }
    }

    /// Luồng vẽ: vẽ khung mới nhất trong hộp chờ, lặp tới khi hộp trống (khung tới trong lúc đang vẽ thì vẽ tiếp khung mới nhất).
    private func drawPending() {
        while true {
            boxLock.lock()
            guard let pb = boxFrame else { boxScheduled = false; boxLock.unlock(); return }
            boxFrame = nil
            boxLock.unlock()
            let ok = renderer.render(pb)
            if ok { boxLock.lock(); drawnTotal += 1; boxLock.unlock() }
        }
    }

    /// Mức bận GPU của cả máy (mọi app cộng lại) theo IOAccelerator, kèm trạng thái nhiệt khi máy nóng. App khác chiếm GPU
    /// (iOS Simulator từng chiếm khoảng 27%) làm WindowServer vẽ trễ, khung hình bị dồn rồi bỏ.
    nonisolated static func gpuLoad() -> String {
        var text = ""
        var it: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS {
            var s = IOIteratorNext(it)
            while s != 0 {
                if let p = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                   let u = p["Device Utilization %"] as? Int {
                    text = "; GPU cả máy \(u)%"
                }
                IOObjectRelease(s)
                s = IOIteratorNext(it)
            }
            IOObjectRelease(it)
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious: text += ", máy nóng (serious)"
        case .critical: text += ", máy rất nóng (critical)"
        default: break
        }
        return text
    }

    /// Cỡ, kiểu điểm ảnh và thẻ màu card ghi trong khung (để biết card gửi gì khi người dùng báo lệch màu).
    private static func describe(_ pb: CVPixelBuffer) -> String {
        func tag(_ key: CFString) -> String { (CVBufferCopyAttachment(pb, key, nil) as? String) ?? "-" }
        return "\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) \(CaptureCards.fourCC(CVPixelBufferGetPixelFormatType(pb)))"
            + " ma trận \(tag(kCVImageBufferYCbCrMatrixKey)), truyền \(tag(kCVImageBufferTransferFunctionKey)), gam \(tag(kCVImageBufferColorPrimariesKey))"
    }

    #if DEVTOOLS
    // MARK: Nguồn thử

    private var testTimer: DispatchSourceTimer?

    /// Nguồn hình dựng sẵn thay cho card (OVERSUB_PLAY_TEST=pattern hoặc pattern-full): thang xám với độ sáng biết trước, dải
    /// màu và một dòng phụ đề, 60 khung/giây. `full`: giả lập card chuyển thẳng dải đầy đủ trong khung ghi dải giới hạn.
    func startPattern(full: Bool, text: String) {
        let name = ProcessInfo.processInfo.environment["OVERSUB_PLAY_PATTERN_FORMAT"] ?? "420v"
        let type: OSType = name == "2vuy" ? kCVPixelFormatType_422YpCbCr8 : name == "yuvs" ? kCVPixelFormatType_422YpCbCr8_yuvs : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard let pb = Self.pattern(full: full, text: text, type: type) else { DebugLog.write("Thử màn hình chơi: không dựng được khung thử"); return }
        renderQueue.sync { renderer.resetDetection(baselineFull: false) }
        videoQueue.sync {
            resetCounters()
            lastLog = Date(); lastFrameAt = Date()
        }
        // OVERSUB_PLAY_PATTERN_FPS=30: tín hiệu 30 khung/giây như chế độ 1440p30 của card (mặc định 60).
        let fps = Double(ProcessInfo.processInfo.environment["OVERSUB_PLAY_PATTERN_FPS"] ?? "") ?? 60
        renderer.frameInterval = 1.0 / fps
        // OVERSUB_PLAY_PATTERN_MOTION=60 hoặc 30: thêm hình vuông đỏ chạy ngang, đổi chỗ mỗi khung (60) hay mỗi hai khung (30, như
        // game 30 khung/giây qua card 60), để thử chèn khung. Chỉ với khung 420v.
        let motion = Int(ProcessInfo.processInfo.environment["OVERSUB_PLAY_PATTERN_MOTION"] ?? "") ?? 0
        let moving = motion > 0 && type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var tick = 0
        let t = DispatchSource.makeTimerSource(queue: videoQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / fps)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            tick += 1
            if moving, let f = Self.movingFrame(base: pb, step: motion >= Int(fps) ? tick : tick / 2) { self.handle(f) } else { self.handle(pb) }
        }
        t.resume()
        testTimer = t
        DebugLog.write("Thử màn hình chơi: nguồn thử \(full ? "dải đầy đủ" : "dải giới hạn"), 1920x1080 \(name), \(Int(fps)) khung/giây" + (moving ? ", vật chạy \(motion) khung/giây" : ""))
    }

    /// Chép khung nền rồi vẽ hình vuông đỏ 160×160 (BT.709 dải giới hạn) chạy ngang 24 điểm mỗi bước.
    private static func movingFrame(base: CVPixelBuffer, step: Int) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(base), h = CVPixelBufferGetHeight(base)
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(base, .readOnly); CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []); CVPixelBufferUnlockBaseAddress(base, .readOnly) }
        for p in 0..<2 {
            guard let s = CVPixelBufferGetBaseAddressOfPlane(base, p), let d = CVPixelBufferGetBaseAddressOfPlane(pb, p) else { return nil }
            let rows = CVPixelBufferGetHeightOfPlane(base, p), sr = CVPixelBufferGetBytesPerRowOfPlane(base, p), dr = CVPixelBufferGetBytesPerRowOfPlane(pb, p)
            for y in 0..<rows { memcpy(d.advanced(by: y * dr), s.advanced(by: y * sr), min(sr, dr)) }
        }
        let x0 = 120 + (step * 24) % 1600, y0 = 640
        guard let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cbuf = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        let yr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for y in y0..<(y0 + 160) { memset(yb.advanced(by: y * yr + x0), 63, 160) }
        for y in (y0 / 2)..<((y0 + 160) / 2) {
            let row = cbuf.advanced(by: y * cr).assumingMemoryBound(to: UInt8.self)
            for x in (x0 / 2)..<((x0 + 160) / 2) { row[2 * x] = 102; row[2 * x + 1] = 240 }
        }
        return pb
    }

    func stopPattern() {
        guard testTimer != nil else { return }
        testTimer?.cancel()
        testTimer = nil
        let total = videoQueue.sync { (received, drawnCount) }
        DebugLog.write("Thử màn hình chơi: dừng nguồn thử (\(total.0) khung nhận, \(total.1) khung vẽ)")
    }

    /// Độ sáng (thang 8 bit) của các ô thang xám ở nửa trên khung thử, trái sang phải. Khung dải giới hạn không có giá trị
    /// ngoài 16–235, để bộ dò dải sáng không nhận nhầm.
    static func patchLevels(full: Bool) -> [UInt8] {
        full ? [0, 8, 16, 64, 128, 192, 235, 245, 255] : [16, 24, 32, 64, 128, 192, 220, 230, 235]
    }

    /// Khung thử theo kiểu điểm ảnh `type` (420v, 2vuy hoặc yuvs), để thử cả đường đọc 4:2:2 đóng gói của capture card.
    private static func pattern(full: Bool, text: String, type: OSType) -> CVPixelBuffer? {
        let w = 1920, h = 1080, hw = w / 2
        // Vẽ cảnh bằng thang xám (0 đen, 255 trắng) rồi đổi sang độ sáng: dải giới hạn 16–235, hoặc giữ nguyên nếu `full`.
        var gray = [UInt8](repeating: 40, count: w * h)
        gray.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 40 / 255, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // Hộp thoại phụ đề ở một phần ba dưới.
            ctx.setFillColor(gray: 0.06, alpha: 1)
            ctx.fill(CGRect(x: 260, y: 90, width: 1400, height: 190))
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 64, weight: .semibold), .foregroundColor: NSColor.white]
            NSAttributedString(string: text, attributes: attr).draw(at: NSPoint(x: 320, y: 150))
            NSGraphicsContext.restoreGraphicsState()
        }
        // Độ sáng từng điểm, màu (Cb, Cr) theo cặp điểm ngang, đủ mọi dòng (4:2:2). CGContext gốc ở dưới nhưng dòng 0 của mảng
        // là dòng trên cùng của ảnh.
        var luma = gray.map { UInt8(full ? Int($0) : 16 + Int($0) * 219 / 255) }
        var cb = [UInt8](repeating: 128, count: hw * h), cr = [UInt8](repeating: 128, count: hw * h)
        // Thang xám: chín ô độ sáng biết trước, viết thẳng (không qua đổi dải).
        for (i, v) in patchLevels(full: full).enumerated() {
            let x0 = 240 + i * 160
            for y in 120..<360 { for x in x0..<(x0 + 152) { luma[y * w + x] = v } }
        }
        // Ba ô đỏ, xanh lá, xanh dương 100% (BT.709, dải giới hạn) ở giữa khung.
        let bars: [(UInt8, UInt8, UInt8)] = [(63, 102, 240), (173, 42, 26), (32, 240, 118)]   // Y, Cb, Cr
        for (i, bar) in bars.enumerated() {
            let x0 = 560 + i * 280
            for y in 440..<620 {
                for x in x0..<(x0 + 260) { luma[y * w + x] = bar.0 }
                for x in (x0 / 2)..<((x0 + 260) / 2) { cb[y * hw + x] = bar.1; cr[y * hw + x] = bar.2 }
            }
        }
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, w, h, type, attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        if type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
            let yRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            for y in 0..<h {
                let dst = yBase.advanced(by: y * yRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { dst[x] = luma[y * w + x] }
            }
            for y in 0..<(h / 2) {
                let dst = cBase.advanced(by: y * cRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<hw { dst[2 * x] = cb[2 * y * hw + x]; dst[2 * x + 1] = cr[2 * y * hw + x] }
            }
        } else {
            // 2vuy: Cb Y0 Cr Y1. yuvs: Y0 Cb Y1 Cr.
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
            let row = CVPixelBufferGetBytesPerRow(pb), uyvy = type == kCVPixelFormatType_422YpCbCr8
            for y in 0..<h {
                let dst = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
                for x in 0..<hw {
                    let y0 = luma[y * w + 2 * x], y1 = luma[y * w + 2 * x + 1], u = cb[y * hw + x], v = cr[y * hw + x]
                    if uyvy { dst[4 * x] = u; dst[4 * x + 1] = y0; dst[4 * x + 2] = v; dst[4 * x + 3] = y1 } else {
                        dst[4 * x] = y0; dst[4 * x + 1] = u; dst[4 * x + 2] = y1; dst[4 * x + 3] = v
                    }
                }
            }
        }
        return pb
    }
    #endif
}

/// Khoảng cách giữa các khung theo mốc thời gian card ghi, gom theo cửa sổ 10 giây: trung vị, dài nhất, số lần hở (dài hơn
/// 1,5 lần trung vị) và số lần dồn (ngắn hơn nửa trung vị). Chỉ dùng trên videoQueue.
struct Cadence {
    private var last: Double?
    private var gaps: [Double] = []

    mutating func add(_ times: [Double]) {
        for t in times {
            if let l = last, t > l { gaps.append(t - l) }
            last = t
        }
    }

    /// Chữ cho nhật ký và khoảng cách trung vị (giây; nil khi chưa đủ 50 khung để tin).
    mutating func take() -> (String, Double?) {
        defer { gaps.removeAll(keepingCapacity: true) }
        guard gaps.count >= 10 else { return ("", nil) }
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        let late = gaps.filter { $0 > median * 1.5 }.count
        let bunched = gaps.filter { $0 < median * 0.5 }.count
        return (String(format: "; nhịp card %.1f ms (dài nhất %.0f ms, %d lần hở, %d lần dồn)", median * 1000, sorted.last! * 1000, late, bunched),
                gaps.count >= 50 ? median : nil)
    }
}
