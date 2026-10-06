// Vẽ icon OverSub bằng CoreGraphics rồi xuất bộ PNG cho iconutil. Chạy: swift Resources/make_icon.swift
import AppKit

func drawIcon(size: CGFloat) -> CGImage {
    let s = size / 1024
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    // Toạ độ gốc dưới trái; vẽ theo khung 1024, thân icon 824 theo lưới icon macOS.
    func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
    }
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Bóng đổ nhẹ của cả icon
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.28))
    ctx.addPath(squircle); ctx.setFillColor(rgb(0xE0602F)); ctx.fillPath()
    ctx.restoreGState()

    // Nền: chuyển màu cam từ sáng (trên) xuống đậm (dưới)
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [rgb(0xFF8A4C), rgb(0xE5582A), rgb(0xC9461F)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Ánh sáng kính phía trên: chuyển mờ dần, không có viền cứng
    let shine = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()
    // Viền sáng mảnh quanh icon
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.14)); ctx.setLineWidth(4); ctx.strokePath()

    // Tay cầm (thân bo tròn + hai tay nắm), căn giữa theo cả chiều ngang lẫn dọc
    let cx: CGFloat = 512
    // Một đường cong liền mạch đối xứng, không có góc nhọn ở chỗ nối thân và tay nắm.
    func m(_ x: CGFloat) -> CGFloat { 1024 - x }
    let ctrl = CGMutablePath()
    ctrl.move(to: CGPoint(x: 512, y: 712))
    ctrl.addLine(to: CGPoint(x: 690, y: 712))
    ctrl.addCurve(to: CGPoint(x: 840, y: 590), control1: CGPoint(x: 790, y: 712), control2: CGPoint(x: 840, y: 660))
    ctrl.addCurve(to: CGPoint(x: 770, y: 300), control1: CGPoint(x: 840, y: 450), control2: CGPoint(x: 830, y: 300))
    ctrl.addCurve(to: CGPoint(x: 660, y: 372), control1: CGPoint(x: 720, y: 300), control2: CGPoint(x: 692, y: 330))
    ctrl.addCurve(to: CGPoint(x: 512, y: 420), control1: CGPoint(x: 628, y: 412), control2: CGPoint(x: 572, y: 420))
    ctrl.addCurve(to: CGPoint(x: m(660), y: 372), control1: CGPoint(x: m(572), y: 420), control2: CGPoint(x: m(628), y: 412))
    ctrl.addCurve(to: CGPoint(x: m(770), y: 300), control1: CGPoint(x: m(692), y: 330), control2: CGPoint(x: m(720), y: 300))
    ctrl.addCurve(to: CGPoint(x: m(840), y: 590), control1: CGPoint(x: m(830), y: 300), control2: CGPoint(x: m(840), y: 450))
    ctrl.addCurve(to: CGPoint(x: m(690), y: 712), control1: CGPoint(x: m(840), y: 660), control2: CGPoint(x: m(790), y: 712))
    ctrl.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0x7A2A0E, 0.35))
    ctx.addPath(ctrl); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()

    // Bong bóng chat (bo tròn, đuôi là hai chấm tròn, không có góc nhọn) chứa "En/Vi"
    let bubble = CGRect(x: cx - 262, y: 498, width: 286, height: 168)
    ctx.addPath(CGPath(roundedRect: bubble, cornerWidth: 62, cornerHeight: 62, transform: nil))
    ctx.setFillColor(rgb(0x3C3489)); ctx.fillPath()
    ctx.setFillColor(rgb(0x3C3489))
    ctx.fillEllipse(in: CGRect(x: bubble.minX + 26, y: bubble.minY - 34, width: 50, height: 50))
    ctx.fillEllipse(in: CGRect(x: bubble.minX + 4, y: bubble.minY - 64, width: 26, height: 26))

    let font = NSFont.systemFont(ofSize: 92, weight: .heavy)
    let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 92) } ?? font
    let text = NSMutableAttributedString()
    text.append(NSAttributedString(string: "En", attributes: [.font: rounded, .foregroundColor: NSColor(cgColor: rgb(0xFAC775))!]))
    text.append(NSAttributedString(string: "/", attributes: [.font: rounded, .foregroundColor: NSColor(cgColor: rgb(0xAFA9EC))!]))
    text.append(NSAttributedString(string: "Vi", attributes: [.font: rounded, .foregroundColor: NSColor.white]))
    let ts = text.size()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    text.draw(at: CGPoint(x: bubble.midX - ts.width / 2, y: bubble.midY - ts.height / 2 + 4))
    NSGraphicsContext.restoreGraphicsState()

    // Bốn nút bấm bên phải, xếp hình thoi, căn giữa theo tâm bong bóng
    let bx = cx + 178, by = bubble.midY
    let buttons: [(CGFloat, CGFloat, UInt32)] = [(0, 58, 0xEF9F27), (-58, 0, 0x378ADD), (58, 0, 0x1D9E75), (0, -58, 0xE24B4A)]
    for (dx, dy, c) in buttons {
        ctx.setFillColor(rgb(c))
        ctx.fillEllipse(in: CGRect(x: bx + dx * 0.95 - 31, y: by + dy * 0.95 - 31, width: 62, height: 62))
    }
    return ctx.makeImage()!
}

let set = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let rep = NSBitmapImageRep(cgImage: drawIcon(size: CGFloat(px)))
    try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent("icon_\(name).png"))
}
try! NSBitmapImageRep(cgImage: drawIcon(size: 1024)).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/icon_preview.png"))
print("đã vẽ xong")
