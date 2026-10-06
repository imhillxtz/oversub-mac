// Vẽ hình nền cửa sổ cài đặt .dmg (660×400 điểm): nền sáng, lưới mảnh kiểu bản vẽ kỹ thuật, tiêu đề, mũi tên kéo thả và
// hướng dẫn mở lần đầu. Icon OverSub và thư mục Applications do Finder đặt lên (package.sh), không vẽ ở đây.
// Dùng: swift Tools/dmg_background.swift <ra@1x.png> <ra@2x.png>
import AppKit

let cw: CGFloat = 660, ch: CGFloat = 400
/// Dải giữa chứa hai icon (toạ độ gốc dưới trái). package.sh đặt icon theo đúng các số này.
let band = NSRect(x: 90, y: 70, width: cw - 180, height: 190)
let leftX = band.minX + band.width * 0.28, rightX = band.minX + band.width * 0.72
let iconY = band.midY + 18

func draw(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cw * scale), pixelsHigh: Int(ch * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: cw, height: ch)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let content = NSRect(x: 0, y: 0, width: cw, height: ch)
    NSColor(red: 0.985, green: 0.982, blue: 0.978, alpha: 1).setFill(); content.fill()
    NSColor(red: 0.955, green: 0.957, blue: 0.950, alpha: 1).setFill(); band.fill()
    NSColor(white: 0.82, alpha: 1).setStroke()
    let lines = NSBezierPath(); lines.lineWidth = 0.6
    for x in [band.minX, band.maxX] { lines.move(to: NSPoint(x: x, y: 0)); lines.line(to: NSPoint(x: x, y: ch)) }
    for y in [band.minY, band.maxY] { lines.move(to: NSPoint(x: 0, y: y)); lines.line(to: NSPoint(x: cw, y: y)) }
    lines.stroke()

    // Tiêu đề hai dòng: tên app đậm, phần còn lại xám.
    let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineSpacing = 2
    let head = NSMutableAttributedString(string: "OverSub", attributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold),
                                                                          .foregroundColor: NSColor(white: 0.12, alpha: 1), .paragraphStyle: para])
    head.append(NSAttributedString(string: ", phụ đề tiếng Việt\ncho mọi game trên Mac",
                                   attributes: [.font: NSFont.systemFont(ofSize: 30, weight: .medium), .foregroundColor: NSColor(white: 0.42, alpha: 1), .paragraphStyle: para]))
    head.draw(in: NSRect(x: 0, y: band.maxY + 22, width: cw, height: 90))

    // Mũi tên kéo thả mảnh giữa hai icon.
    NSColor(white: 0.62, alpha: 1).setStroke()
    let arrow = NSBezierPath(); arrow.lineWidth = 2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: leftX + 84, y: iconY)); arrow.line(to: NSPoint(x: rightX - 84, y: iconY))
    arrow.move(to: NSPoint(x: rightX - 96, y: iconY + 10)); arrow.line(to: NSPoint(x: rightX - 84, y: iconY)); arrow.line(to: NSPoint(x: rightX - 96, y: iconY - 10))
    arrow.stroke()

    // Hướng dẫn: kéo để cài, và cách mở lần đầu (app chưa được Apple công chứng nên macOS chặn).
    func line(_ s: String, size: CGFloat, gray: CGFloat, y: CGFloat) {
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(white: gray, alpha: 1)])
        a.draw(at: NSPoint(x: (cw - a.size().width) / 2, y: y))
    }
    line("Kéo OverSub vào Applications để cài đặt  ·  Drag OverSub to Applications to install", size: 12, gray: 0.42, y: 44)
    line("Lần đầu mở bị chặn? Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Vẫn mở", size: 11, gray: 0.55, y: 25)
    line("Blocked on first launch? System Settings → Privacy & Security → Open Anyway", size: 11, gray: 0.55, y: 10)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
draw(scale: 1, to: args[1])
draw(scale: 2, to: args[2])
// Toạ độ tâm icon theo kiểu Finder (gốc trên trái), để package.sh đọc.
print("\(Int(leftX.rounded())) \(Int(rightX.rounded())) \(Int((ch - iconY).rounded()))")
