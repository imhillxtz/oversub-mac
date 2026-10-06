import AppKit
import SwiftUI

/// Dấu vết của phụ đề gốc trong vùng quét, để đặt bản dịch đè đúng lên và trông giống chữ gốc.
struct TextFit: Equatable {
    var box: CGRect          // vùng chứa chữ gốc, toạ độ điểm trong vùng quét, gốc ở góc trên trái
    var cover: CGRect        // vùng cần che: hộp thoại/nền quanh chữ gốc, luôn chứa `box`
    var lineHeight: CGFloat  // chiều cao một dòng chữ gốc, tính bằng điểm
    var text: Color?         // màu chữ gốc
    var background: Color?   // màu nền của hộp chứa chữ gốc
    var alignment: TextAlignment = .center   // chữ gốc căn trái, giữa hay phải
    var linePitch: CGFloat?  // khoảng cách từ dòng này tới dòng kế (điểm), nil nếu chỉ có một dòng
    /// Cỡ chữ gốc ước từ bề ngang các dòng (ổn định hơn nhiều so với bề cao dòng Vision đo, vốn lệch tới 30%).
    var fontSize: CGFloat? = nil

    static func make(image: CGImage, region: CaptureRegion, lines: [OCRLine]) -> TextFit? {
        guard !lines.isEmpty else { return nil }
        let w = region.w, h = region.h
        let rects = lines.map { l in
            CGRect(x: l.box.minX * w, y: (1 - l.box.maxY) * h, width: l.box.width * w, height: l.box.height * h)
        }
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let heights = rects.map(\.height).sorted()
        let lh = heights[heights.count / 2]
        let pitches = zip(rects, rects.dropFirst()).map { $1.minY - $0.minY }.filter { $0 > 0 }
        let pitch: CGFloat? = pitches.isEmpty ? nil : pitches.reduce(0, +) / CGFloat(pitches.count)
        guard let s = ColorSampler.sample(image: image, boxes: lines.map(\.box)) else {
            let cover = union.insetBy(dx: -14, dy: -6)
            return TextFit(box: union, cover: cover, lineHeight: lh, text: nil, background: nil,
                           alignment: detectAlignment(rects: rects, box: union, cover: cover), linePitch: pitch,
                           fontSize: ScreenText.fontSize(lines, regionWidth: w, lineHeight: lh))
        }
        // Đổi từ điểm ảnh của ảnh mẫu sang điểm của vùng quét.
        let sx = w / CGFloat(s.size.width), sy = h / CGFloat(s.size.height)
        let cover = CGRect(x: s.cover.minX * sx, y: s.cover.minY * sy, width: s.cover.width * sx, height: s.cover.height * sy)
            .union(union.insetBy(dx: -14, dy: -6))
        return TextFit(box: union, cover: cover, lineHeight: lh, text: s.text, background: s.background,
                       alignment: detectAlignment(rects: rects, box: union, cover: cover), linePitch: pitch,
                       fontSize: ScreenText.fontSize(lines, regionWidth: w, lineHeight: lh))
    }

    /// Đoán chữ gốc căn lề nào: nhiều dòng thì xem lề nào của các dòng thẳng hàng nhất; không phân biệt được (một dòng,
    /// hoặc các dòng dài bằng nhau) thì xem chữ nằm gần mép trái hay mép phải hộp chứa nó.
    static func detectAlignment(rects: [CGRect], box: CGRect, cover: CGRect) -> TextAlignment {
        func spread(_ v: [CGFloat]) -> CGFloat { (v.max() ?? 0) - (v.min() ?? 0) }
        let lh = rects.map(\.height).sorted()[rects.count / 2]
        let tol = max(3, lh * 0.35)
        if rects.count >= 2 {
            let cands: [(TextAlignment, CGFloat)] = [(.leading, spread(rects.map(\.minX))),
                                                       (.trailing, spread(rects.map(\.maxX))),
                                                       (.center, spread(rects.map(\.midX)))]
            let within = cands.filter { $0.1 <= tol }
            if within.count == 1 { return within[0].0 }
            if within.isEmpty { return cands.min { $0.1 < $1.1 }!.0 }
        }
        let lm = box.minX - cover.minX, rm = cover.maxX - box.maxX
        if abs(lm - rm) <= max(tol, lh * 0.6) { return .center }   // chữ giữa thì hai lề gần như bằng nhau
        return lm < rm ? .leading : .trailing
    }
}

enum ColorSampler {
    struct Sample {
        var text: Color
        var background: Color
        var cover: CGRect   // điểm ảnh của ảnh mẫu, gốc ở góc trên trái
        var size: CGSize    // kích thước ảnh mẫu
    }

    /// Nền = màu trung vị trong hộp chữ (nét chữ chiếm ít hơn nửa diện tích nên không kéo lệch);
    /// chữ = trung bình các điểm lệch nền xa nhất; phạm vi che = mở rộng hộp ra ngoài chừng nào vùng bên ngoài còn cùng màu nền.
    static func sample(image: CGImage, boxes: [CGRect]) -> Sample? {
        // Lấy mẫu ở độ phân giải gần gốc: thu nhỏ mạnh sẽ trộn nét chữ mảnh vào nền và làm màu chữ nhạt đi.
        let w = min(2400, image.width)
        let h = max(1, image.height * w / max(1, image.width))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // Hộp chữ (bộ nhớ ảnh đi từ trên xuống nên đảo trục y của Vision).
        var ux0 = w, uy0 = h, ux1 = 0, uy1 = 0
        var mask = [Bool](repeating: false, count: w * h)
        var lineHeights: [Int] = []
        for b in boxes {
            let x0 = max(0, Int((Double(b.minX) * Double(w)).rounded(.down)) - 2)
            let x1 = min(w - 1, Int((Double(b.maxX) * Double(w)).rounded(.up)) + 2)
            let y0 = max(0, Int(((1 - Double(b.maxY)) * Double(h)).rounded(.down)) - 2)
            let y1 = min(h - 1, Int(((1 - Double(b.minY)) * Double(h)).rounded(.up)) + 2)
            guard x0 <= x1, y0 <= y1 else { continue }
            lineHeights.append(y1 - y0)
            ux0 = min(ux0, x0); uy0 = min(uy0, y0); ux1 = max(ux1, x1); uy1 = max(uy1, y1)
            for y in y0...y1 { for x in x0...x1 { mask[y * w + x] = true } }
        }
        guard ux0 <= ux1, uy0 <= uy1 else { return nil }

        func rgb(_ i: Int) -> (Double, Double, Double) { (Double(px[i * 4]), Double(px[i * 4 + 1]), Double(px[i * 4 + 2])) }

        // Màu nền: trung vị từng kênh trong hộp chữ, tính bằng biểu đồ 256 mức cho nhanh.
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var total = 0
        for y in uy0...uy1 { for x in ux0...ux1 {
            let i = (y * w + x) * 4
            hist[0][Int(px[i])] += 1; hist[1][Int(px[i + 1])] += 1; hist[2][Int(px[i + 2])] += 1
            total += 1
        } }
        func median(_ c: Int) -> Double {
            var run = 0
            for v in 0..<256 { run += hist[c][v]; if run * 2 >= total { return Double(v) } }
            return 0
        }
        let bg = (median(0), median(1), median(2))

        func dist(_ c: (Double, Double, Double)) -> Double {
            (c.0 - bg.0) * (c.0 - bg.0) + (c.1 - bg.1) * (c.1 - bg.1) + (c.2 - bg.2) * (c.2 - bg.2)
        }

        // Màu chữ: trong các điểm rõ ràng là nét chữ, lấy nhóm TƯƠNG PHẢN ĐỘ SÁNG mạnh nhất với nền (nền sáng thì lấy phần tối nhất,
        // nền tối thì lấy phần sáng nhất). Chữ thường của game luôn là phần tương phản nhất; chữ nhấn mạnh (đỏ, vàng) kém tương phản hơn,
        // nên không còn nhuộm cả câu dịch. Chọn theo màu sắc hay số đông đều thua chữ đỏ khi ảnh chụp thật bị nhoè.
        func luma(_ c: (Double, Double, Double)) -> Double { 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2 }
        var maxD = 0.0
        for i in 0..<(w * h) where mask[i] { maxD = max(maxD, dist(rgb(i))) }
        var strokes: [(l: Double, c: (Double, Double, Double))] = []
        for i in 0..<(w * h) where mask[i] {
            let c = rgb(i)
            if dist(c) >= maxD * 0.4 { strokes.append((luma(c), c)) }
        }
        let lightBackground = luma(bg) > 128
        strokes.sort { lightBackground ? $0.l < $1.l : $0.l > $1.l }
        let core = strokes.prefix(max(1, strokes.count / 4))
        var text = bg
        if !core.isEmpty {
            let sum = core.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.c.0, $0.1 + $1.c.1, $0.2 + $1.c.2) }
            let n = Double(core.count)
            text = (sum.0 / n, sum.1 / n, sum.2 / n)
        }

        func lum(_ c: (Double, Double, Double)) -> Double { (0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2) / 255 }
        if abs(lum(text) - lum(bg)) < 0.3 {   // chữ lấy được quá gần màu nền, chọn đen hoặc trắng cho dễ đọc
            text = lum(bg) > 0.5 ? (0, 0, 0) : (255, 255, 255)
        }

        // Phạm vi che: mở từng cạnh ra 2 điểm ảnh một lần khi dải bên ngoài vẫn chủ yếu cùng màu nền.
        let lh = max(8, lineHeights.sorted()[lineHeights.count / 2])
        let capH = lh * 8, capV = lh * 3 / 2   // ngang được mở rộng hơn dọc, vì hộp thoại thường rộng hơn cao
        var x0 = ux0, x1 = ux1, y0 = uy0, y1 = uy1
        let tol = 55.0 * 55.0
        func stripIsBackground(xs: ClosedRange<Int>, ys: ClosedRange<Int>) -> Bool {
            var near = 0, count = 0
            for y in ys { for x in xs {
                count += 1
                if dist(rgb(y * w + x)) < tol { near += 1 }
            } }
            return count > 0 && Double(near) / Double(count) >= 0.8
        }
        var gl = 0, gr = 0, gu = 0, gd = 0
        var grew = true
        while grew {
            grew = false
            if gl < capH, x0 >= 2, stripIsBackground(xs: (x0 - 2)...(x0 - 1), ys: y0...y1) { x0 -= 2; gl += 2; grew = true }
            if gr < capH, x1 <= w - 3, stripIsBackground(xs: (x1 + 1)...(x1 + 2), ys: y0...y1) { x1 += 2; gr += 2; grew = true }
            if gu < capV, y0 >= 2, stripIsBackground(xs: x0...x1, ys: (y0 - 2)...(y0 - 1)) { y0 -= 2; gu += 2; grew = true }
            if gd < capV, y1 <= h - 3, stripIsBackground(xs: x0...x1, ys: (y1 + 1)...(y1 + 2)) { y1 += 2; gd += 2; grew = true }
        }

        func color(_ c: (Double, Double, Double)) -> Color {
            Color(.sRGB, red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, opacity: 1)
        }
        return Sample(text: color(text), background: color(bg),
                      cover: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1),
                      size: CGSize(width: w, height: h))
    }
}
