import CoreVideo
import Metal

/// Tăng FPS cho màn hình chơi game bằng cách chèn khung dựng từ hai khung thật (không có dữ liệu chuyển động của game, nên
/// tự dò chuyển động trên hình, như Lossless Scaling hay AMD Fluid Motion Frames).
///
/// Dò chuyển động: hình độ sáng thu 1/4 mỗi chiều, chia khối 8×8 (32×32 điểm ảnh gốc), tìm vectơ đối xứng v sao cho khối của
/// khung trước dời −v khớp nhất khối của khung sau dời +v (tìm hết ±12 điểm ở cỡ 1/4, tức dời tới ±96 điểm ảnh mỗi khung),
/// ưu tiên vectơ 0 để chữ, thanh máu, bản đồ đứng yên giữ nguyên nét; lọc trung vị 3×3. Rồi mỗi điểm ở cỡ 1/4 chọn lại vectơ
/// khớp nhất trong số vectơ của 9 khối quanh nó, vectơ 0 và vectơ chung của cả cảnh (vectơ nhiều khối có nhất, thường là
/// chuyển động máy quay; vùng nền trơn không tự dò được nên cần nó), nên mép vật đang chạy không bị kéo theo nền. Khung giữa lấy trung
/// bình hai khung đã dời theo vectơ; chỗ hai bên không khớp (vật che, đổi cảnh) thì lấy khung sau.
///
/// Hai cách:
/// - `double`: mỗi khung thật chèn một khung giữa, hiện khung giữa ngay rồi khung thật sau nửa nhịp: 60 thành 120 khung/giây
///   trên màn 120 Hz. Khung thật trễ thêm nửa nhịp (8,3 ms ở 60 khung/giây).
/// - `thirty`: game 30 khung/giây qua card 60 khung/giây (mỗi khung lặp hai lần): thay khung lặp bằng khung giữa của khung
///   trước và khung sau. Phải chờ khung sau nên mọi khung trễ thêm một nhịp (16,7 ms). Không thấy khung lặp trong 2 giây thì
///   thôi chờ, hiện thẳng.
final class PlayInterpolator {
    enum Mode: String, CaseIterable, Sendable { case off, double, thirty }

    struct Output {
        let texture: MTLTexture
        /// Hiện sau khung trước ít nhất bấy nhiêu giây (0 là ngay).
        let after: Double
        let synthetic: Bool
    }

    private let device: MTLDevice
    private let log: (String) -> Void
    private var library: MTLLibrary?
    private var kernels: [String: MTLComputePipelineState] = [:]
    private var ring: [MTLTexture] = []
    private var lumas: [MTLTexture] = []
    private var field: MTLTexture?
    private var smooth: MTLTexture?
    private var fine: MTLTexture?
    private var global: MTLTexture?
    private var mids: [MTLTexture] = []
    private var midIndex = 0
    private var index = -1
    private var filled = 0
    private var size = (0, 0)
    // Cách `thirty`: khung trước có phải khung lặp không, và số khung liền không thấy khung lặp.
    private var prevDuplicate = false
    private var sinceDuplicate = 1000
    private var waiting = false
    private var lastSignature: [UInt8] = []
    private(set) var duplicateFrames = 0
    private(set) var syntheticFrames = 0

    init(device: MTLDevice, log: @escaping (String) -> Void) {
        self.device = device
        self.log = log
    }

    private func kernel(_ name: String) -> MTLComputePipelineState? {
        if let k = kernels[name] { return k }
        if library == nil {
            do { library = try device.makeLibrary(source: Self.shader, options: nil) } catch {
                log("Chèn khung: không dựng được shader: \(error)")
                return nil
            }
        }
        guard let fn = library?.makeFunction(name: name), let k = try? device.makeComputePipelineState(function: fn) else {
            log("Chèn khung: không dựng được \(name)")
            return nil
        }
        kernels[name] = k
        return k
    }

    private func makeTexture(_ w: Int, _ h: Int, _ f: MTLPixelFormat) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(1, w), height: max(1, h), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// Texture để bước đổi màu ghi khung mới vào (vòng 3 khung). Đổi cỡ thì xoá lịch sử.
    func nextSlot(width w: Int, height h: Int) -> MTLTexture? {
        if size != (w, h) || ring.count != 3 {
            size = (w, h)
            ring = (0..<3).compactMap { _ in makeTexture(w, h, .rgba16Float) }
            lumas = (0..<3).compactMap { _ in makeTexture((w + 3) / 4, (h + 3) / 4, .r16Float) }
            field = makeTexture(((w + 3) / 4 + 7) / 8, ((h + 3) / 4 + 7) / 8, .rgba16Float)
            smooth = makeTexture(((w + 3) / 4 + 7) / 8, ((h + 3) / 4 + 7) / 8, .rgba16Float)
            fine = makeTexture((w + 3) / 4, (h + 3) / 4, .rgba16Float)
            global = makeTexture(1, 1, .rgba16Float)
            mids = (0..<2).compactMap { _ in makeTexture(w, h, .rgba16Float) }
            filled = 0
            index = -1
            waiting = false
            guard ring.count == 3, lumas.count == 3, field != nil, smooth != nil, fine != nil, global != nil, mids.count == 2 else { return nil }
        }
        index = (index + 1) % 3
        return ring[index]
    }

    /// Đã ghi khung mới vào texture của `nextSlot`. `duplicate`: khung này giống hệt khung trước (xem `signature`).
    /// Trả về các khung cần hiện theo thứ tự.
    func push(_ cb: MTLCommandBuffer, mode: Mode, interval: Double, duplicate: Bool) -> [Output] {
        let cur = ring[index]
        filled = min(filled + 1, 3)
        encode(cb, "fi_luma", [cur, lumas[index]], grid: lumas[index])
        if duplicate { duplicateFrames += 1 }
        defer { prevDuplicate = duplicate }
        guard filled >= 2, mode != .off else { waiting = false; return [Output(texture: cur, after: 0, synthetic: false)] }
        let p = (index + 2) % 3
        let prev = ring[p]

        switch mode {
        case .off:
            return [Output(texture: cur, after: 0, synthetic: false)]
        case .double:
            guard let mid = synthesize(cb, prev: prev, prevLuma: lumas[p], cur: cur, curLuma: lumas[index]) else {
                return [Output(texture: cur, after: 0, synthetic: false)]
            }
            return [Output(texture: mid, after: 0, synthetic: true), Output(texture: cur, after: interval / 2, synthetic: false)]
        case .thirty:
            sinceDuplicate = duplicate ? 0 : sinceDuplicate + 1
            let shouldWait = sinceDuplicate < Int((2.0 / max(interval, 0.001)).rounded())
            if shouldWait != waiting {
                waiting = shouldWait
                log(waiting ? "Chèn khung: thấy khung lặp (game khoảng 30 khung/giây), hiện trễ một nhịp để chèn khung giữa"
                            : "Chèn khung: 2 giây không thấy khung lặp, hiện thẳng không trễ")
                if !waiting { return [Output(texture: cur, after: 0, synthetic: false)] }
                return [Output(texture: prev, after: 0, synthetic: false)]
            }
            guard waiting else { return [Output(texture: cur, after: 0, synthetic: false)] }
            // Hiện trễ một nhịp: khung trước, hoặc nếu khung trước chỉ là bản lặp và khung này mới thì khung giữa của hai khung.
            if prevDuplicate, !duplicate, let mid = synthesize(cb, prev: prev, prevLuma: lumas[p], cur: cur, curLuma: lumas[index]) {
                return [Output(texture: mid, after: 0, synthetic: true)]
            }
            return [Output(texture: prev, after: 0, synthetic: false)]
        }
    }

    private func synthesize(_ cb: MTLCommandBuffer, prev: MTLTexture, prevLuma: MTLTexture, cur: MTLTexture, curLuma: MTLTexture) -> MTLTexture? {
        guard let field, let smooth, let fine, let global, mids.count == 2, let search = kernel("fi_search"), let enc = cb.makeComputeCommandEncoder() else { return nil }
        enc.label = "fi_search"
        enc.setComputePipelineState(search)
        enc.setTexture(prevLuma, index: 0)
        enc.setTexture(curLuma, index: 1)
        enc.setTexture(field, index: 2)
        enc.dispatchThreadgroups(MTLSize(width: field.width, height: field.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 25, height: 25, depth: 1))
        enc.endEncoding()
        encode(cb, "fi_median", [field, smooth], grid: smooth)
        if let k = kernel("fi_global"), let e = cb.makeComputeCommandEncoder() {
            e.label = "fi_global"
            e.setComputePipelineState(k)
            e.setTexture(smooth, index: 0)
            e.setTexture(global, index: 1)
            e.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(1024, k.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            e.endEncoding()
        }
        encode(cb, "fi_refine", [prevLuma, curLuma, smooth, fine, global], grid: fine)
        midIndex = (midIndex + 1) % 2
        let mid = mids[midIndex]
        encode(cb, "fi_warp", [prev, cur, fine, mid], grid: mid)
        syntheticFrames += 1
        return mid
    }

    private func encode(_ cb: MTLCommandBuffer, _ name: String, _ tex: [MTLTexture], grid: MTLTexture) {
        guard let k = kernel(name), let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = name
        enc.setComputePipelineState(k)
        for (i, t) in tex.enumerated() { enc.setTexture(t, index: i) }
        enc.dispatchThreads(MTLSize(width: grid.width, height: grid.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
    }

    // MARK: Nhận ra khung lặp

    /// Lấy mẫu 64×36 điểm độ sáng của khung (8 bit) trên CPU để biết khung có lặp lại khung trước không. `yOffset`: khung 4:2:2
    /// đóng gói thì byte độ sáng đứng thứ mấy trong mỗi cặp hai byte; nil là khung hai mặt phẳng (mặt phẳng 0 là độ sáng).
    static func signature(_ pb: CVPixelBuffer, packedYOffset: Int?, tenBit: Bool) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let planar = packedYOffset == nil
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb) else { return [] }
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let row = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt8]()
        out.reserveCapacity(64 * 36)
        for j in 0..<36 {
            let y = (j * 2 + 1) * h / 72
            for i in 0..<64 {
                let x = (i * 2 + 1) * w / 128
                if let off = packedYOffset {
                    out.append(base.advanced(by: y * row + x * 2 + off).assumingMemoryBound(to: UInt8.self).pointee)
                } else if tenBit {
                    out.append(UInt8(base.advanced(by: y * row + x * 2).assumingMemoryBound(to: UInt16.self).pointee >> 8))
                } else {
                    out.append(base.advanced(by: y * row + x).assumingMemoryBound(to: UInt8.self).pointee)
                }
            }
        }
        return out
    }

    /// Khung giống khung trước (khác trung bình dưới 0,5 và không điểm nào khác quá 6 trên thang 255).
    func isDuplicate(_ sig: [UInt8]) -> Bool {
        defer { lastSignature = sig }
        guard sig.count == lastSignature.count, !sig.isEmpty else { return false }
        var sum = 0, worst = 0
        for i in 0..<sig.count {
            let d = abs(Int(sig[i]) - Int(lastSignature[i]))
            sum += d
            worst = max(worst, d)
        }
        return Double(sum) / Double(sig.count) < 0.5 && worst <= 6
    }

    // MARK: Shader

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    constexpr sampler fiLin(filter::linear, address::clamp_to_edge);

    float fiLuma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

    // Độ sáng thu 1/4 mỗi chiều: trung bình 4×4 điểm bằng 4 lần lấy mẫu song tuyến.
    kernel void fi_luma(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 rs = 1.0 / float2(src.get_width(), src.get_height());
        float2 c = (float2(gid) * 4.0 + 2.0) * rs;
        float3 s = src.sample(fiLin, c + float2(-rs.x, -rs.y)).rgb + src.sample(fiLin, c + float2(rs.x, -rs.y)).rgb
                 + src.sample(fiLin, c + float2(-rs.x, rs.y)).rgb + src.sample(fiLin, c + float2(rs.x, rs.y)).rgb;
        dst.write(float4(fiLuma(s * 0.25), 0.0, 0.0, 0.0), gid);
    }

    // Tìm vectơ đối xứng cho mỗi khối 8×8 (ở cỡ 1/4): mỗi luồng thử một vectơ trong ±12, giữ tổng sai khác nhỏ nhất.
    kernel void fi_search(texture2d<float, access::read> lp [[texture(0)]], texture2d<float, access::read> lc [[texture(1)]],
                          texture2d<float, access::write> field [[texture(2)]],
                          uint2 tg [[threadgroup_position_in_grid]], uint2 lid [[thread_position_in_threadgroup]],
                          uint tid [[thread_index_in_threadgroup]], uint lane [[thread_index_in_simdgroup]],
                          uint sg [[simdgroup_index_in_threadgroup]]) {
        const int B = 8, R = 12, S = B + 2 * R, N = (2 * R + 1) * (2 * R + 1);
        threadgroup half cp[S * S];
        threadgroup half cc[S * S];
        threadgroup uint best[32];
        int2 origin = int2(tg) * B - R;
        int2 mx = int2(lp.get_width() - 1, lp.get_height() - 1);
        for (uint k = tid; k < uint(S * S); k += uint(N)) {
            int2 q = clamp(origin + int2(int(k) % S, int(k) / S), int2(0), mx);
            cp[k] = half(lp.read(uint2(q)).r);
            cc[k] = half(lc.read(uint2(q)).r);
        }
        if (tid < 32) best[tid] = 0xFFFFFFFF;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        int vx = int(lid.x) - R, vy = int(lid.y) - R;
        float sad = 0.0;
        for (int by = 0; by < B; by++) {
            int rp = (R + by - vy) * S + R - vx, rc = (R + by + vy) * S + R + vx;
            for (int bx = 0; bx < B; bx++) sad += abs(float(cp[rp + bx]) - float(cc[rc + bx]));
        }
        sad += 0.02 * float(abs(vx) + abs(vy));
        if (vx == 0 && vy == 0) sad *= 0.9;
        uint key = (min(uint(sad * 4096.0), 0x3FFFFFu) << 10) | tid;
        uint m = simd_min(key);
        if (lane == 0) best[sg] = m;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tid == 0) {
            uint b = best[0];
            for (int i = 1; i < 32; i++) b = min(b, best[i]);
            int idx = int(b & 1023u);
            float2 v = float2(idx % (2 * R + 1) - R, idx / (2 * R + 1) - R) * 4.0;
            field.write(float4(v, float(b >> 10) / 4096.0 / float(B * B), 0.0), tg);
        }
    }

    // Trung vị 3×3 từng thành phần của trường vectơ, bỏ vectơ lạc.
    kernel void fi_median(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        int2 mx = int2(src.get_width() - 1, src.get_height() - 1);
        float xs[9], ys[9];
        float conf = 0.0;
        for (int k = 0; k < 9; k++) {
            float4 f = src.read(uint2(clamp(int2(gid) + int2(k % 3 - 1, k / 3 - 1), int2(0), mx)));
            xs[k] = f.x; ys[k] = f.y;
            if (k == 4) conf = f.z;
        }
        for (int i = 0; i < 9; i++) for (int j = i + 1; j < 9; j++) {
            if (xs[j] < xs[i]) { float t = xs[i]; xs[i] = xs[j]; xs[j] = t; }
            if (ys[j] < ys[i]) { float t = ys[i]; ys[i] = ys[j]; ys[j] = t; }
        }
        dst.write(float4(xs[4], ys[4], conf, 0.0), gid);
    }

    // Vectơ chung của cả cảnh: vectơ có nhiều khối nhất (đếm trên lưới vectơ đã lọc).
    kernel void fi_global(texture2d<float, access::read> blocks [[texture(0)]], texture2d<float, access::write> out [[texture(1)]],
                          uint tid [[thread_index_in_threadgroup]], uint n [[threads_per_threadgroup]]) {
        threadgroup atomic_uint hist[625];
        for (uint i = tid; i < 625; i += n) atomic_store_explicit(&hist[i], 0u, memory_order_relaxed);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        uint w = blocks.get_width(), h = blocks.get_height();
        for (uint i = tid; i < w * h; i += n) {
            int2 q = int2(round(blocks.read(uint2(i % w, i / w)).xy * 0.25)) + 12;
            if (all(q >= 0) && all(q <= 24)) atomic_fetch_add_explicit(&hist[q.y * 25 + q.x], 1u, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tid == 0) {
            uint best = 0, at = 12 * 25 + 12;
            for (uint i = 0; i < 625; i++) { uint c = atomic_load_explicit(&hist[i], memory_order_relaxed); if (c > best) { best = c; at = i; } }
            out.write(float4(float(int(at % 25) - 12) * 4.0, float(int(at / 25) - 12) * 4.0, 0.0, 0.0), uint2(0));
        }
    }

    // Chọn vectơ cho từng điểm ở cỡ 1/4: thử vectơ 0, vectơ chung và vectơ của 9 khối quanh, giữ cái làm hai khung khớp nhất
    // trong ô 3×3.
    kernel void fi_refine(texture2d<float, access::sample> lp [[texture(0)]], texture2d<float, access::sample> lc [[texture(1)]],
                          texture2d<float, access::read> blocks [[texture(2)]], texture2d<float, access::write> dst [[texture(3)]],
                          texture2d<float, access::read> global [[texture(4)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 rs = 1.0 / float2(lp.get_width(), lp.get_height());
        int2 b = int2(gid) / 8, bm = int2(blocks.get_width() - 1, blocks.get_height() - 1);
        float2 own = blocks.read(uint2(b)).xy;
        float2 best = own;
        float bestCost = 1e9;
        float2 g = global.read(uint2(0)).xy;
        for (int k = -2; k < 9; k++) {
            float2 v = k == -2 ? g : k == -1 ? float2(0.0) : blocks.read(uint2(clamp(b + int2(k % 3 - 1, k / 3 - 1), int2(0), bm))).xy;
            float2 vq = v * 0.25;
            float cost = 0.0;
            for (int w = 0; w < 9; w++) {
                float2 q = float2(gid) + 0.5 + float2(w % 3 - 1, w / 3 - 1);
                cost += abs(lp.sample(fiLin, (q - vq) * rs).r - lc.sample(fiLin, (q + vq) * rs).r);
            }
            if (all(v == own)) cost *= 0.95;
            if (cost < bestCost) { bestCost = cost; best = v; }
        }
        dst.write(float4(best, bestCost / 9.0, 0.0), gid);
    }

    // Khung giữa: trung bình khung trước dời −v và khung sau dời +v; không khớp thì lấy khung sau.
    kernel void fi_warp(texture2d<float, access::sample> prev [[texture(0)]], texture2d<float, access::sample> cur [[texture(1)]],
                        texture2d<float, access::sample> field [[texture(2)]], texture2d<float, access::write> dst [[texture(3)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        constexpr sampler near(filter::nearest, address::clamp_to_edge);
        float2 size = float2(dst.get_width(), dst.get_height());
        float2 px = float2(gid) + 0.5;
        float4 f = field.sample(near, px / (float2(field.get_width(), field.get_height()) * 4.0));
        float3 a = prev.sample(fiLin, (px - f.xy) / size).rgb;
        float3 b = cur.sample(fiLin, (px + f.xy) / size).rgb;
        float3 c = cur.sample(fiLin, px / size).rgb;
        // Điểm hai bên không khớp (vùng bị che hay vừa lộ ra): lấy khung sau đã dời về giữa. Cả khối không khớp (đổi cảnh,
        // chuyển động quá nhanh): lấy khung sau nguyên vẹn.
        float pixelMiss = smoothstep(0.06, 0.18, abs(fiLuma(a) - fiLuma(b)));
        float blockMiss = smoothstep(0.06, 0.16, f.z);
        dst.write(float4(mix(mix(0.5 * (a + b), b, pixelMiss), c, blockMiss), 1.0), gid);
    }
    """
}
