import CoreGraphics
import Foundation

/// Xoá chữ gốc trên ảnh vùng dịch màn hình bằng cách dựng lại nền từ các điểm ảnh quanh chữ, để bản dịch nằm trên nền
/// game thật (dải sáng, màu chuyển trên nút) thay vì một mảng màu phẳng.
enum Inpaint {
    /// Giữ đúng không gian màu của ảnh chụp (thường là của màn hình): đổi sang không gian khác thì nền dựng lại lệch màu
    /// chút ít so với game và lộ viền mảng thay chữ.
    private static func colorSpace(of image: CGImage) -> CGColorSpace {
        if let cs = image.colorSpace, cs.model == .rgb { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Màu viền quanh từng vùng trên ảnh mới, để so với lúc dựng nền.
    static func rings(_ image: CGImage, size: CGSize, zones: [CGRect]) -> [[Double]] {
        let W = image.width, H = image.height
        guard W > 4, H > 4, size.width > 0 else { return [] }
        var px = [UInt8](repeating: 0, count: W * 4 * H)
        guard let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: colorSpace(of: image), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        let sx = Double(W) / size.width, sy = Double(H) / size.height
        return zones.map { ringColor(px, W: W, H: H, rect: $0, sx: sx, sy: sy) }
    }

    /// Trung bình màu dải rộng 2 điểm ảnh ngay ngoài `rect` (lấy thưa, đủ để biết nền quanh chữ đổi màu).
    private static func ringColor(_ px: [UInt8], W: Int, H: Int, rect: CGRect, sx: Double, sy: Double) -> [Double] {
        let x0 = max(0, Int(rect.minX * sx) - 3), x1 = min(W - 1, Int(rect.maxX * sx) + 3)
        let y0 = max(0, Int(rect.minY * sy) - 3), y1 = min(H - 1, Int(rect.maxY * sy) + 3)
        guard x1 > x0, y1 > y0 else { return [0, 0, 0] }
        var c = [0.0, 0.0, 0.0], n = 0.0
        func add(_ x: Int, _ y: Int) {
            let o = y * W * 4 + x * 4
            for ch in 0..<3 { c[ch] += Double(px[o + ch]) }
            n += 1
        }
        for x in stride(from: x0, through: x1, by: 3) { add(x, y0); add(x, y0 + 1); add(x, y1); add(x, y1 - 1) }
        for y in stride(from: y0, through: y1, by: 3) { add(x0, y); add(x0 + 1, y); add(x1, y); add(x1 - 1, y) }
        return n > 0 ? c.map { $0 / n } : [0, 0, 0]
    }

    struct Result {
        var image: CGImage
        var stem: [Double]   // độ dày nét chữ gốc (điểm) trong từng khung chữ, để đoán độ đậm của chữ
        var rings: [[Double]]  // màu trung bình của dải viền ngay ngoài từng vùng xoá (để biết nền quanh chữ có đổi không)
    }

    /// `zones`: vùng cần xoá (điểm, gốc trên trái, trong vùng quét kích thước `size`). `boxes`: khung chữ gốc tương ứng.
    /// Mỗi điểm trong vùng xoá lấy màu nội suy từ bốn phía (trên, dưới, trái, phải), phía nào gần thì nặng hơn; viền lấy
    /// mẫu được làm mượt để vân nền không thành sọc, rồi làm mờ nhẹ bên trong cho liền.
    static func clean(_ image: CGImage, size: CGSize, zones: [CGRect], boxes: [CGRect]) -> Result? {
        let W = image.width, H = image.height
        guard W > 4, H > 4, size.width > 0 else { return nil }
        let bpr = W * 4
        var px = [UInt8](repeating: 0, count: bpr * H)
        guard let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: colorSpace(of: image), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        let original = px
        let sx = Double(W) / size.width, sy = Double(H) / size.height
        let rings = zones.map { ringColor(px, W: W, H: H, rect: $0, sx: sx, sy: sy) }

        func pixelRect(_ r: CGRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
            (max(1, Int((r.minX * sx).rounded(.down)) - 1), max(1, Int((r.minY * sy).rounded(.down)) - 1),
             min(W - 2, Int((r.maxX * sx).rounded(.up)) + 1), min(H - 2, Int((r.maxY * sy).rounded(.up)) + 1))
        }

        // Thứ tự từ trên xuống: vùng dưới lấy mẫu viền từ phần vùng trên đã xoá chữ.
        for zone in zones.sorted(by: { $0.minY < $1.minY }) {
            let (x0, y0, x1, y1) = pixelRect(zone)
            guard x1 - x0 >= 2, y1 - y0 >= 2 else { continue }
            let w = x1 - x0 + 1, h = y1 - y0 + 1
            // Viền: trung bình 3 hàng (cột) ngay ngoài vùng, rồi làm mượt dọc theo viền.
            func edgeRow(_ y: Int, _ dir: Int) -> [[Double]] {
                (0..<w).map { i in
                    var c = [0.0, 0.0, 0.0], n = 0.0
                    for k in 1...3 {
                        let yy = y + dir * k
                        guard yy >= 0, yy < H else { continue }
                        let o = yy * bpr + (x0 + i) * 4
                        for ch in 0..<3 { c[ch] += Double(px[o + ch]) }
                        n += 1
                    }
                    return n > 0 ? c.map { $0 / n } : [0, 0, 0]
                }
            }
            func edgeCol(_ x: Int, _ dir: Int) -> [[Double]] {
                (0..<h).map { j in
                    var c = [0.0, 0.0, 0.0], n = 0.0
                    for k in 1...3 {
                        let xx = x + dir * k
                        guard xx >= 0, xx < W else { continue }
                        let o = (y0 + j) * bpr + xx * 4
                        for ch in 0..<3 { c[ch] += Double(px[o + ch]) }
                        n += 1
                    }
                    return n > 0 ? c.map { $0 / n } : [0, 0, 0]
                }
            }
            func smooth(_ a: [[Double]], radius: Int) -> [[Double]] {
                guard a.count > 2 else { return a }
                return a.indices.map { i in
                    let lo = max(0, i - radius), hi = min(a.count - 1, i + radius)
                    var c = [0.0, 0.0, 0.0]
                    for k in lo...hi { for ch in 0..<3 { c[ch] += a[k][ch] } }
                    return c.map { $0 / Double(hi - lo + 1) }
                }
            }
            let r = max(2, h / 4)
            let top = smooth(edgeRow(y0, -1), radius: r), bottom = smooth(edgeRow(y1, 1), radius: r)
            let left = smooth(edgeCol(x0, -1), radius: 2), right = smooth(edgeCol(x1, 1), radius: 2)
            let hasTop = y0 > 3, hasBottom = y1 < H - 4, hasLeft = x0 > 3, hasRight = x1 < W - 4

            for j in 0..<h {
                for i in 0..<w {
                    let dT = Double(j + 1), dB = Double(h - j), dL = Double(i + 1), dR = Double(w - i)
                    var c = [0.0, 0.0, 0.0], wsum = 0.0
                    func add(_ v: [Double], _ d: Double, _ ok: Bool) {
                        guard ok else { return }
                        let wt = 1 / (d * d)
                        for ch in 0..<3 { c[ch] += v[ch] * wt }
                        wsum += wt
                    }
                    add(top[i], dT, hasTop); add(bottom[i], dB, hasBottom)
                    add(left[j], dL, hasLeft); add(right[j], dR, hasRight)
                    guard wsum > 0 else { continue }
                    let o = (y0 + j) * bpr + (x0 + i) * 4
                    for ch in 0..<3 { px[o + ch] = UInt8(max(0, min(255, c[ch] / wsum))) }
                    px[o + 3] = 255
                }
            }
            // Làm mờ nhẹ bên trong (hộp 3×3, hai lượt) cho liền mạch.
            for _ in 0..<2 {
                let copy = px
                for y in (y0 + 1)..<y1 {
                    for x in (x0 + 1)..<x1 {
                        for ch in 0..<3 {
                            var sum = 0
                            for dy in -1...1 { for dx in -1...1 { sum += Int(copy[(y + dy) * bpr + (x + dx) * 4 + ch]) } }
                            px[y * bpr + x * 4 + ch] = UInt8(sum / 9)
                        }
                    }
                }
            }
        }

        // Độ dày nét: điểm ảnh khác hẳn nền đã dựng lại là nét chữ; theo từng hàng, các đoạn nét liền nhau cắt qua nét dọc của
        // chữ, trung vị độ dài các đoạn chính là độ dày nét.
        let stem: [Double] = boxes.map { b in
            let (x0, y0, x1, y1) = pixelRect(b)
            let maxRun = max(2, (y1 - y0) / 2)
            var runs: [Int] = []
            for y in y0...y1 {
                var run = 0
                for x in x0...(x1 + 1) {
                    var ink = false
                    if x <= x1 {
                        let o = y * bpr + x * 4
                        let d = abs(Int(original[o]) - Int(px[o])) + abs(Int(original[o + 1]) - Int(px[o + 1])) + abs(Int(original[o + 2]) - Int(px[o + 2]))
                        ink = d > 90
                    }
                    if ink { run += 1 } else if run > 0 { if run <= maxRun { runs.append(run) }; run = 0 }
                }
            }
            guard !runs.isEmpty else { return 0 }
            runs.sort()
            return Double(runs[runs.count / 2]) / sx
        }

        guard let out = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: colorSpace(of: image), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        else { return nil }
        return Result(image: out, stem: stem, rings: rings)
    }
}
