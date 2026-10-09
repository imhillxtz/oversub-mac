import Metal
import MetalFX

/// Xử lý hình sau bước đổi màu của màn hình chơi game: khử răng cưa, phóng to và làm nét, rồi đặt vào khung trên drawable.
/// Mọi bộ lọc làm việc trên hình đã vẽ xong (capture card không cho dữ liệu chuyển động hay chiều sâu của game), nên dùng được
/// FSR 1 (EASU, RCAS), FXAA, MetalFX Spatial và Anime4K; DLSS, FSR 2 trở lên, MetalFX Temporal thì không.
/// - FSR 1: chuyển từ `ffx_fsr1.h` của AMD (MIT), bản 32 bit.
/// - FXAA: theo FXAA 3.11 bản Quality của Timothy Lottes (NVIDIA), viết lại gọn.
/// - Anime4K: chuyển tự động từ `Anime4K_3DGraphics_AA_Upscale_x2_US` và `Anime4K_Upscale_CNN_x2_S` của bloc97 (MIT), xem
///   `PlayAnime4K.swift`.
/// Chạy trên luồng nhận hình; không dùng chung giữa nhiều luồng.
final class PlayEffects {
    enum Upscaler: String, CaseIterable, Sendable {
        case bilinear, metalFX, fsr, anime3D, animeCel
    }

    struct Options: Equatable, Sendable {
        var upscaler: Upscaler = .bilinear
        /// Độ làm nét RCAS theo "stop" của FSR (0 là mạnh nhất, mỗi 1 giảm một nửa); nil là không làm nét.
        var sharpenStops: Float?
        var antiAlias = false
        /// Hình EDR tuyến tính (giá trị vượt 1): chỉ phóng song tuyến hoặc MetalFX chế độ HDR.
        var hdr = false
    }

    /// Thời gian GPU của lần xử lý gần nhất (giây), cho nhật ký và menu.
    private(set) var lastStages: [String] = []

    private let device: MTLDevice
    private let log: (String) -> Void
    private var library: MTLLibrary?
    private var compute: [String: MTLComputePipelineState] = [:]
    private var render: [String: MTLRenderPipelineState] = [:]
    private var textures: [String: MTLTexture] = [:]
    private var scaler: MTLFXSpatialScaler?
    private var scalerKey = ""
    private var failed = Set<String>()

    init(device: MTLDevice, log: @escaping (String) -> Void) {
        self.device = device
        self.log = log
    }

    private func lib() -> MTLLibrary? {
        if let library { return library }
        do {
            library = try device.makeLibrary(source: Self.shader + PlayAnime4K.shader, options: nil)
        } catch {
            log("Bộ lọc hình: không dựng được shader: \(error)")
            failed.insert("library")
        }
        return library
    }

    private func kernel(_ name: String) -> MTLComputePipelineState? {
        if let k = compute[name] { return k }
        guard !failed.contains(name), let fn = lib()?.makeFunction(name: name) else { failed.insert(name); return nil }
        do {
            let k = try device.makeComputePipelineState(function: fn)
            compute[name] = k
            return k
        } catch {
            log("Bộ lọc hình: lỗi dựng \(name): \(error)")
            failed.insert(name)
            return nil
        }
    }

    private func pipeline(_ name: String, format: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = "\(name)-\(format.rawValue)"
        if let p = render[key] { return p }
        guard !failed.contains(key), let l = lib() else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = l.makeFunction(name: "fx_vquad")
        d.fragmentFunction = l.makeFunction(name: name)
        d.colorAttachments[0].pixelFormat = format
        do {
            let p = try device.makeRenderPipelineState(descriptor: d)
            render[key] = p
            return p
        } catch {
            log("Bộ lọc hình: lỗi dựng \(key): \(error)")
            failed.insert(key)
            return nil
        }
    }

    /// Texture trung gian theo tên và cỡ, dùng lại giữa các khung.
    func texture(_ name: String, _ w: Int, _ h: Int, format: MTLPixelFormat = .rgba16Float) -> MTLTexture? {
        let key = "\(name)-\(w)x\(h)-\(format.rawValue)"
        if let t = textures[key] { return t }
        textures = textures.filter { !$0.key.hasPrefix(name + "-") }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, w), height: max(1, h), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)
        textures[key] = t
        return t
    }

    private func dispatch(_ cb: MTLCommandBuffer, _ name: String, _ tex: [MTLTexture], size: MTLTexture, bytes: [Float]? = nil) -> Bool {
        guard let k = kernel(name), let enc = cb.makeComputeCommandEncoder() else { return false }
        enc.label = name
        enc.setComputePipelineState(k)
        for (i, t) in tex.enumerated() { enc.setTexture(t, index: i) }
        if var b = bytes { enc.setBytes(&b, length: b.count * 4, index: 0) }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreads(MTLSize(width: size.width, height: size.height, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        return true
    }

    // MARK: Xử lý

    /// Khung đặt hình trên drawable (điểm ảnh, gốc trên trái).
    struct Viewport: Equatable { var x: Int; var y: Int; var w: Int; var h: Int }

    /// Từ `source` (hình đã đổi màu, cỡ gốc, rgba16Float) tới `target` (drawable): xoá nền đen, đặt hình vào `vp`.
    /// Trả false nếu có bước không dựng được (nơi gọi vẽ theo cách thường).
    @discardableResult
    func encode(_ cb: MTLCommandBuffer, source: MTLTexture, target: MTLTexture, vp: Viewport, options o: Options) -> Bool {
        var stages: [String] = []
        var cur = source
        let upscaling = vp.w > source.width + 2 || vp.h > source.height + 2
        let plain = o.hdr   // EDR: các bộ lọc giả định giá trị 0...1, chỉ dùng song tuyến hoặc MetalFX

        // 1. Khử răng cưa ở độ phân giải gốc.
        if o.antiAlias, !plain, let a = texture("fxaa", source.width, source.height), dispatch(cb, "fx_fxaa", [cur, a], size: a) {
            cur = a; stages.append("FXAA")
        }

        // 2. Phóng tới cỡ khung (chỉ khi phải phóng to; thu nhỏ thì song tuyến là đủ).
        var out: MTLTexture? = nil   // hình đúng cỡ khung, nếu đã dựng
        if upscaling {
            switch o.upscaler {
            case .bilinear:
                break
            case .fsr where !plain:
                if let u = texture("easu", vp.w, vp.h) {
                    let c = Self.easuConstants(inW: cur.width, inH: cur.height, outW: vp.w, outH: vp.h)
                    if dispatch(cb, "fx_easu", [cur, u], size: u, bytes: c) { out = u; stages.append("EASU") }
                }
            case .anime3D where !plain, .animeCel where !plain:
                if let d = anime(cb, cur, cel: o.upscaler == .animeCel) {
                    stages.append(o.upscaler == .animeCel ? "Anime4K hoạt hình" : "Anime4K 3D")
                    if d.width == vp.w, d.height == vp.h {
                        out = d
                    } else if let r = texture("resample", vp.w, vp.h), dispatch(cb, "fx_resample", [d, r], size: r) {
                        out = r
                    }
                }
            case .metalFX:
                if let big = metalFX(cb, cur, w: min(vp.w, cur.width * 2), h: min(vp.h, cur.height * 2), hdr: plain) {
                    stages.append("MetalFX")
                    if big.width == vp.w, big.height == vp.h {
                        out = big
                    } else if let r = texture("resample", vp.w, vp.h), dispatch(cb, "fx_resample", [big, r], size: r) {
                        out = r
                    }
                }
            default:
                break
            }
        }

        // 3. Làm nét RCAS ở cỡ khung, rồi đặt vào drawable.
        let sharpen = o.sharpenStops != nil && !plain
        if sharpen, out == nil, let r = texture("resample", vp.w, vp.h), dispatch(cb, "fx_resample", [cur, r], size: r) {
            out = r
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let name = sharpen ? "fx_rcas" : (out != nil ? "fx_copy" : "fx_bilinear")
        guard let state = pipeline(name, format: target.pixelFormat), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
        enc.setViewport(MTLViewport(originX: Double(vp.x), originY: Double(vp.y), width: Double(vp.w), height: Double(vp.h), znear: 0, zfar: 1))
        enc.setRenderPipelineState(state)
        var params: [Float] = [Float(vp.x), Float(vp.y), exp2(-(o.sharpenStops ?? 0)), 0]
        enc.setFragmentBytes(&params, length: 16, index: 0)
        enc.setFragmentTexture(out ?? cur, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        if sharpen { stages.append("RCAS") }
        lastStages = stages
        return true
    }

    /// Anime4K x2 ở độ phân giải gốc: các lớp tích chập rồi Depth-to-Space cộng vào hình phóng song tuyến.
    private func anime(_ cb: MTLCommandBuffer, _ src: MTLTexture, cel: Bool) -> MTLTexture? {
        let p = cel ? "a4kcel" : "a4k3d"
        let layers = cel ? 4 : 3
        var input = src
        for i in 0..<layers {
            guard let t = texture("\(p)-l\(i % 2)", src.width, src.height), dispatch(cb, "\(p)_c\(i)", [input, t], size: t) else { return nil }
            input = t
        }
        guard let d = texture("\(p)-x2", src.width * 2, src.height * 2), dispatch(cb, "\(p)_d2s", [src, input, d], size: d) else { return nil }
        return d
    }

    private func metalFX(_ cb: MTLCommandBuffer, _ src: MTLTexture, w: Int, h: Int, hdr: Bool) -> MTLTexture? {
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device), !failed.contains("metalfx") else { return nil }
        let key = "\(src.width)x\(src.height)>\(w)x\(h)-\(hdr)"
        if key != scalerKey {
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = src.width; d.inputHeight = src.height
            d.outputWidth = w; d.outputHeight = h
            d.colorTextureFormat = src.pixelFormat; d.outputTextureFormat = .rgba16Float
            d.colorProcessingMode = hdr ? .hdr : .perceptual
            guard let s = d.makeSpatialScaler(device: device) else { failed.insert("metalfx"); log("Bộ lọc hình: không dựng được MetalFX \(key)"); return nil }
            scaler = s
            scalerKey = key
        }
        guard let s = scaler, let out = texture("metalfx", w, h) else { return nil }
        s.colorTexture = src
        s.outputTexture = out
        s.encode(commandBuffer: cb)
        return out
    }

    /// Hằng số của EASU theo `FsrEasuCon` (cả hình làm vùng nhìn).
    static func easuConstants(inW: Int, inH: Int, outW: Int, outH: Int) -> [Float] {
        let iw = Float(inW), ih = Float(inH), ow = Float(outW), oh = Float(outH)
        return [iw / ow, ih / oh, 0.5 * iw / ow - 0.5, 0.5 * ih / oh - 0.5,
                1 / iw, 1 / ih, 1 / iw, -1 / ih,
                -1 / iw, 2 / ih, 1 / iw, 2 / ih,
                0, 4 / ih, 0, 0]
    }

    // MARK: Shader

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct FxOut { float4 pos [[position]]; float2 uv; };
    vertex FxOut fx_vquad(uint vid [[vertex_id]]) {
        float2 c = float2(vid & 1, vid >> 1);
        FxOut o;
        o.pos = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0);
        o.uv = c;
        return o;
    }

    constexpr sampler fxLin(filter::linear, address::clamp_to_edge);

    // Đặt hình đã đúng cỡ khung: đọc đúng điểm ảnh.
    fragment float4 fx_copy(FxOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant float4& p [[buffer(0)]]) {
        uint2 ip = uint2(max(in.pos.xy - p.xy, 0.0));
        return float4(t.read(min(ip, uint2(t.get_width() - 1, t.get_height() - 1))).rgb, 1.0);
    }

    // Phóng song tuyến thẳng vào khung.
    fragment float4 fx_bilinear(FxOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
        return float4(t.sample(fxLin, in.uv).rgb, 1.0);
    }

    // Phóng hay thu song tuyến sang texture đích.
    kernel void fx_resample(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
        dst.write(src.sample(fxLin, uv), gid);
    }

    // ---- FSR 1 RCAS (ffx_fsr1.h, MIT) ----
    #define FSR_RCAS_LIMIT (0.25 - (1.0 / 16.0))
    fragment float4 fx_rcas(FxOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant float4& p [[buffer(0)]]) {
        int2 sp = int2(max(in.pos.xy - p.xy, 0.0));
        int2 mx = int2(t.get_width() - 1, t.get_height() - 1);
        float3 b = t.read(uint2(clamp(sp + int2(0, -1), int2(0), mx))).rgb;
        float3 d = t.read(uint2(clamp(sp + int2(-1, 0), int2(0), mx))).rgb;
        float3 e = t.read(uint2(clamp(sp, int2(0), mx))).rgb;
        float3 f = t.read(uint2(clamp(sp + int2(1, 0), int2(0), mx))).rgb;
        float3 h = t.read(uint2(clamp(sp + int2(0, 1), int2(0), mx))).rgb;
        float3 mn4 = min(min(min(b, d), f), h);
        float3 mx4 = max(max(max(b, d), f), h);
        float2 peakC = float2(1.0, -4.0);
        float3 hitMin = min(mn4, e) / (4.0 * mx4);
        float3 hitMax = (peakC.x - max(mx4, e)) / (4.0 * mn4 + peakC.y);
        float3 lobeRGB = max(-hitMin, hitMax);
        float lobe = max(-FSR_RCAS_LIMIT, min(max(max(lobeRGB.r, lobeRGB.g), lobeRGB.b), 0.0)) * p.z;
        float rcpL = 1.0 / (4.0 * lobe + 1.0);
        float3 c = (lobe * b + lobe * d + lobe * h + lobe * f + e) * rcpL;
        return float4(saturate(c), 1.0);
    }

    // ---- FSR 1 EASU (ffx_fsr1.h, MIT), bản 32 bit ----
    void easuTap(thread float3& aC, thread float& aW, float2 off, float2 dir, float2 len, float lob, float clp, float3 c) {
        float2 v;
        v.x = (off.x * ( dir.x)) + (off.y * dir.y);
        v.y = (off.x * (-dir.y)) + (off.y * dir.x);
        v *= len;
        float d2 = min(v.x * v.x + v.y * v.y, clp);
        float wB = (2.0 / 5.0) * d2 - 1.0;
        float wA = lob * d2 - 1.0;
        wB *= wB;
        wA *= wA;
        wB = (25.0 / 16.0) * wB - (25.0 / 16.0 - 1.0);
        float w = wB * wA;
        aC += c * w; aW += w;
    }

    void easuSet(thread float2& dir, thread float& len, float2 pp, int which, float lA, float lB, float lC, float lD, float lE) {
        float w = which == 0 ? (1.0 - pp.x) * (1.0 - pp.y) : which == 1 ? pp.x * (1.0 - pp.y) : which == 2 ? (1.0 - pp.x) * pp.y : pp.x * pp.y;
        float dc = lD - lC, cb = lC - lB;
        float lenX = max(abs(dc), abs(cb));
        lenX = 1.0 / max(lenX, 1e-8);
        float dirX = lD - lB;
        dir.x += dirX * w;
        lenX = saturate(abs(dirX) * lenX);
        lenX *= lenX;
        len += lenX * w;
        float ec = lE - lC, ca = lC - lA;
        float lenY = max(abs(ec), abs(ca));
        lenY = 1.0 / max(lenY, 1e-8);
        float dirY = lE - lA;
        dir.y += dirY * w;
        lenY = saturate(abs(dirY) * lenY);
        lenY *= lenY;
        len += lenY * w;
    }

    kernel void fx_easu(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                        constant float4* con [[buffer(0)]], uint2 ip [[thread_position_in_grid]]) {
        if (ip.x >= dst.get_width() || ip.y >= dst.get_height()) return;
        constexpr sampler g(filter::nearest, address::clamp_to_edge);
        float2 pp = float2(ip) * con[0].xy + con[0].zw;
        float2 fp = floor(pp);
        pp -= fp;
        float2 p0 = fp * con[1].xy + con[1].zw;
        float2 p1 = p0 + con[2].xy;
        float2 p2 = p0 + con[2].zw;
        float2 p3 = p0 + con[3].xy;
        float4 bczzR = src.gather(g, p0, int2(0), component::x), bczzG = src.gather(g, p0, int2(0), component::y), bczzB = src.gather(g, p0, int2(0), component::z);
        float4 ijfeR = src.gather(g, p1, int2(0), component::x), ijfeG = src.gather(g, p1, int2(0), component::y), ijfeB = src.gather(g, p1, int2(0), component::z);
        float4 klhgR = src.gather(g, p2, int2(0), component::x), klhgG = src.gather(g, p2, int2(0), component::y), klhgB = src.gather(g, p2, int2(0), component::z);
        float4 zzonR = src.gather(g, p3, int2(0), component::x), zzonG = src.gather(g, p3, int2(0), component::y), zzonB = src.gather(g, p3, int2(0), component::z);
        float4 bczzL = bczzB * 0.5 + (bczzR * 0.5 + bczzG);
        float4 ijfeL = ijfeB * 0.5 + (ijfeR * 0.5 + ijfeG);
        float4 klhgL = klhgB * 0.5 + (klhgR * 0.5 + klhgG);
        float4 zzonL = zzonB * 0.5 + (zzonR * 0.5 + zzonG);
        float bL = bczzL.x, cL = bczzL.y, iL = ijfeL.x, jL = ijfeL.y, fL = ijfeL.z, eL = ijfeL.w;
        float kL = klhgL.x, lL = klhgL.y, hL = klhgL.z, gL = klhgL.w, oL = zzonL.z, nL = zzonL.w;
        float2 dir = 0.0;
        float len = 0.0;
        easuSet(dir, len, pp, 0, bL, eL, fL, gL, jL);
        easuSet(dir, len, pp, 1, cL, fL, gL, hL, kL);
        easuSet(dir, len, pp, 2, fL, iL, jL, kL, nL);
        easuSet(dir, len, pp, 3, gL, jL, kL, lL, oL);
        float2 dir2 = dir * dir;
        float dirR = dir2.x + dir2.y;
        bool zro = dirR < (1.0 / 32768.0);
        dirR = rsqrt(max(dirR, 1e-12));
        dirR = zro ? 1.0 : dirR;
        dir.x = zro ? 1.0 : dir.x;
        dir *= dirR;
        len = len * 0.5;
        len *= len;
        float stretch = (dir.x * dir.x + dir.y * dir.y) / max(max(abs(dir.x), abs(dir.y)), 1e-8);
        float2 len2 = float2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
        float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
        float clp = 1.0 / lob;
        float3 fC = float3(ijfeR.z, ijfeG.z, ijfeB.z), gC = float3(klhgR.w, klhgG.w, klhgB.w);
        float3 jC = float3(ijfeR.y, ijfeG.y, ijfeB.y), kC = float3(klhgR.x, klhgG.x, klhgB.x);
        float3 min4 = min(min(min(fC, gC), jC), kC);
        float3 max4 = max(max(max(fC, gC), jC), kC);
        float3 aC = 0.0;
        float aW = 0.0;
        easuTap(aC, aW, float2( 0.0, -1.0) - pp, dir, len2, lob, clp, float3(bczzR.x, bczzG.x, bczzB.x));
        easuTap(aC, aW, float2( 1.0, -1.0) - pp, dir, len2, lob, clp, float3(bczzR.y, bczzG.y, bczzB.y));
        easuTap(aC, aW, float2(-1.0,  1.0) - pp, dir, len2, lob, clp, float3(ijfeR.x, ijfeG.x, ijfeB.x));
        easuTap(aC, aW, float2( 0.0,  1.0) - pp, dir, len2, lob, clp, jC);
        easuTap(aC, aW, float2( 0.0,  0.0) - pp, dir, len2, lob, clp, fC);
        easuTap(aC, aW, float2(-1.0,  0.0) - pp, dir, len2, lob, clp, float3(ijfeR.w, ijfeG.w, ijfeB.w));
        easuTap(aC, aW, float2( 1.0,  1.0) - pp, dir, len2, lob, clp, kC);
        easuTap(aC, aW, float2( 2.0,  1.0) - pp, dir, len2, lob, clp, float3(klhgR.y, klhgG.y, klhgB.y));
        easuTap(aC, aW, float2( 2.0,  0.0) - pp, dir, len2, lob, clp, float3(klhgR.z, klhgG.z, klhgB.z));
        easuTap(aC, aW, float2( 1.0,  0.0) - pp, dir, len2, lob, clp, gC);
        easuTap(aC, aW, float2( 1.0,  2.0) - pp, dir, len2, lob, clp, float3(zzonR.z, zzonG.z, zzonB.z));
        easuTap(aC, aW, float2( 0.0,  2.0) - pp, dir, len2, lob, clp, float3(zzonR.w, zzonG.w, zzonB.w));
        float3 pix = min(max4, max(min4, aC / aW));
        dst.write(float4(pix, 1.0), ip);
    }

    // ---- FXAA 3.11 Quality (Timothy Lottes, NVIDIA), viết lại gọn ----
    float fxLuma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

    kernel void fx_fxaa(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 rcp = 1.0 / float2(src.get_width(), src.get_height());
        float2 posM = (float2(gid) + 0.5) * rcp;
        float4 rgbM = src.sample(fxLin, posM);
        float lumaM = fxLuma(rgbM.rgb);
        float lumaS = fxLuma(src.sample(fxLin, posM, int2( 0,  1)).rgb);
        float lumaE = fxLuma(src.sample(fxLin, posM, int2( 1,  0)).rgb);
        float lumaN = fxLuma(src.sample(fxLin, posM, int2( 0, -1)).rgb);
        float lumaW = fxLuma(src.sample(fxLin, posM, int2(-1,  0)).rgb);
        float maxSM = max(lumaS, lumaM), minSM = min(lumaS, lumaM);
        float maxESM = max(lumaE, maxSM), minESM = min(lumaE, minSM);
        float maxWN = max(lumaN, lumaW), minWN = min(lumaN, lumaW);
        float rangeMax = max(maxWN, maxESM), rangeMin = min(minWN, minESM);
        float range = rangeMax - rangeMin;
        if (range < max(0.0312, rangeMax * 0.125)) { dst.write(float4(rgbM.rgb, 1.0), gid); return; }
        float lumaNW = fxLuma(src.sample(fxLin, posM, int2(-1, -1)).rgb);
        float lumaSE = fxLuma(src.sample(fxLin, posM, int2( 1,  1)).rgb);
        float lumaNE = fxLuma(src.sample(fxLin, posM, int2( 1, -1)).rgb);
        float lumaSW = fxLuma(src.sample(fxLin, posM, int2(-1,  1)).rgb);
        float lumaNS = lumaN + lumaS, lumaWE = lumaW + lumaE;
        float subpixRcpRange = 1.0 / range;
        float subpixNSWE = lumaNS + lumaWE;
        float edgeHorz1 = -2.0 * lumaM + lumaNS, edgeVert1 = -2.0 * lumaM + lumaWE;
        float lumaNESE = lumaNE + lumaSE, lumaNWNE = lumaNW + lumaNE;
        float edgeHorz2 = -2.0 * lumaE + lumaNESE, edgeVert2 = -2.0 * lumaN + lumaNWNE;
        float lumaNWSW = lumaNW + lumaSW, lumaSWSE = lumaSW + lumaSE;
        float edgeHorz4 = abs(edgeHorz1) * 2.0 + abs(edgeHorz2), edgeVert4 = abs(edgeVert1) * 2.0 + abs(edgeVert2);
        float edgeHorz3 = -2.0 * lumaW + lumaNWSW, edgeVert3 = -2.0 * lumaS + lumaSWSE;
        float edgeHorz = abs(edgeHorz3) + edgeHorz4, edgeVert = abs(edgeVert3) + edgeVert4;
        float subpixNWSWNESE = lumaNWSW + lumaNESE;
        float lengthSign = rcp.x;
        bool horzSpan = edgeHorz >= edgeVert;
        float subpixA = subpixNSWE * 2.0 + subpixNWSWNESE;
        if (!horzSpan) { lumaN = lumaW; lumaS = lumaE; }
        if (horzSpan) lengthSign = rcp.y;
        float subpixB = subpixA * (1.0 / 12.0) - lumaM;
        float gradientN = lumaN - lumaM, gradientS = lumaS - lumaM;
        float lumaNN = lumaN + lumaM, lumaSS = lumaS + lumaM;
        bool pairN = abs(gradientN) >= abs(gradientS);
        float gradient = max(abs(gradientN), abs(gradientS));
        if (pairN) lengthSign = -lengthSign;
        float subpixC = saturate(abs(subpixB) * subpixRcpRange);
        float2 posB = posM;
        float2 offNP = float2(horzSpan ? rcp.x : 0.0, horzSpan ? 0.0 : rcp.y);
        if (!horzSpan) posB.x += lengthSign * 0.5;
        if (horzSpan) posB.y += lengthSign * 0.5;
        float2 posN = posB - offNP;
        float2 posP = posB + offNP;
        float subpixD = -2.0 * subpixC + 3.0;
        float subpixE = subpixC * subpixC;
        float lumaEndN = fxLuma(src.sample(fxLin, posN).rgb);
        float lumaEndP = fxLuma(src.sample(fxLin, posP).rgb);
        if (!pairN) lumaNN = lumaSS;
        float gradientScaled = gradient * 0.25;
        float lumaMM = lumaM - lumaNN * 0.5;
        float subpixF = subpixD * subpixE;
        bool lumaMLTZero = lumaMM < 0.0;
        lumaEndN -= lumaNN * 0.5;
        lumaEndP -= lumaNN * 0.5;
        bool doneN = abs(lumaEndN) >= gradientScaled;
        bool doneP = abs(lumaEndP) >= gradientScaled;
        const float steps[11] = {1.0, 1.0, 1.0, 1.0, 1.5, 2.0, 2.0, 2.0, 2.0, 4.0, 8.0};
        for (int i = 0; i < 11 && !(doneN && doneP); i++) {
            if (!doneN) { posN -= offNP * steps[i]; lumaEndN = fxLuma(src.sample(fxLin, posN).rgb) - lumaNN * 0.5; doneN = abs(lumaEndN) >= gradientScaled; }
            if (!doneP) { posP += offNP * steps[i]; lumaEndP = fxLuma(src.sample(fxLin, posP).rgb) - lumaNN * 0.5; doneP = abs(lumaEndP) >= gradientScaled; }
        }
        float dstN = horzSpan ? posM.x - posN.x : posM.y - posN.y;
        float dstP = horzSpan ? posP.x - posM.x : posP.y - posM.y;
        bool goodSpanN = (lumaEndN < 0.0) != lumaMLTZero;
        bool goodSpanP = (lumaEndP < 0.0) != lumaMLTZero;
        float spanLength = dstP + dstN;
        bool directionN = dstN < dstP;
        float dist = min(dstN, dstP);
        bool goodSpan = directionN ? goodSpanN : goodSpanP;
        float subpixG = subpixF * subpixF;
        float pixelOffset = dist * (-1.0 / spanLength) + 0.5;
        float subpixH = subpixG * 0.75;
        float pixelOffsetSubpix = max(goodSpan ? pixelOffset : 0.0, subpixH);
        float2 posOut = posM;
        if (!horzSpan) posOut.x += pixelOffsetSubpix * lengthSign;
        if (horzSpan) posOut.y += pixelOffsetSubpix * lengthSign;
        dst.write(float4(src.sample(fxLin, posOut).rgb, 1.0), gid);
    }
    """
}
