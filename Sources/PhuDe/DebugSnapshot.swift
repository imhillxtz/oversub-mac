// Công cụ tự kiểm tra, chỉ có trong bản dựng dành cho phát triển (OVERSUB_DEV=1 ./build.sh).
#if DEVTOOLS
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Chụp cửa sổ của chính app để kiểm tra giao diện khi phát triển. Chỉ chạy khi mở app với biến môi trường
/// OVERSUB_SNAPSHOT_DIR (open --env OVERSUB_SNAPSHOT_DIR=/đường/dẫn OverSub.app); người dùng bình thường không bao giờ kích hoạt.
@MainActor
enum DebugSnapshot {
    /// Tự kiểm tra đường lồng tiếng: OVERSUB_DUB_TEST=1 đọc 3 câu ngắn bằng 3 cách phát khác nhau, ghi thời gian vào nhật ký.
    /// Thử dịch màn hình: OVERSUB_SCREEN_TEST="x,y,w,h" (điểm, gốc trên trái, màn hình chính) là chỗ có chữ của app khác.
    /// Đặt tạm vùng đó làm vùng dịch màn hình, bật dịch, rồi chụp cả lớp dịch đè lên. Chỉ dùng khi đã sao lưu cài đặt.
    static func screenTestIfRequested(engine: Engine) {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["OVERSUB_SCREEN_TEST"], let dir = env["OVERSUB_SNAPSHOT_DIR"] else { return }
        let n = spec.split(separator: ",").compactMap { Double($0) }
        guard n.count == 4, let screen = NSScreen.main, let id = displayIDOf(screen) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            let region = CaptureRegion(displayID: id, x: n[0], y: n[1], w: n[2], h: n[3], sw: screen.frame.width, sh: screen.frame.height)
            AppSettings.shared.pauseWhenGameHidden = false
            AppSettings.shared.secondaryRegions = [region]
            engine.setScreenTranslate(true)
            DebugLog.write("Thử dịch màn hình: bật=\(engine.screenTranslateOn) vùng \(Int(region.w))×\(Int(region.h))")
            try? await Task.sleep(for: .seconds(5))
            await shootScreen("screen-translate", dir: dir, display: id, rect: region.rect.insetBy(dx: -40, dy: -40))
            try? await Task.sleep(for: .seconds(6))   // cửa sổ mẫu đổi chữ ở giây thứ 12: xem bản dịch cũ có được gỡ và dịch lại không
            await shootScreen("screen-translate-2", dir: dir, display: id, rect: region.rect.insetBy(dx: -40, dy: -40))
            engine.setScreenTranslate(false)
            DebugLog.write("Thử dịch màn hình: đã tắt, bật=\(engine.screenTranslateOn)")
        }
    }

    /// Thử bố cục dịch màn hình không cần chụp màn hình: OVERSUB_LAYOUT_TEST=1 vẽ lớp dịch đè cho vài khung chữ mẫu ra ảnh
    /// (viền đỏ là khung chữ gốc), và đo thời gian Dịch máy Apple.
    static func layoutTestIfRequested(settings: AppSettings) {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSUB_LAYOUT_TEST"] != nil, let dir = env["OVERSUB_SNAPSHOT_DIR"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            let brown = Color(red: 0.22, green: 0.15, blue: 0.10), cream = Color(red: 0.98, green: 0.92, blue: 0.80)
            let cases: [(String, CGSize, TextFit, String)] = [
                ("button", CGSize(width: 220, height: 50),
                 TextFit(box: CGRect(x: 30, y: 12, width: 160, height: 26), cover: CGRect(x: 0, y: 0, width: 220, height: 50), lineHeight: 26,
                         text: .white, background: Color(red: 0.15, green: 0.25, blue: 0.45), alignment: .center, linePitch: nil),
                 "Tiếp tục cuộc phiêu lưu"),
                ("paragraph", CGSize(width: 640, height: 150),
                 TextFit(box: CGRect(x: 24, y: 22, width: 590, height: 104), cover: CGRect(x: 0, y: 0, width: 640, height: 150), lineHeight: 26,
                         text: cream, background: brown, alignment: .leading, linePitch: 36),
                 "Nhiệm vụ: Tìm chiếc dây chuyền bị mất. Nói chuyện với thương nhân gần cây cầu cũ, sau đó tìm kiếm bờ sông trước khi hoàng hôn buông xuống."),
                ("item", CGSize(width: 360, height: 90),
                 TextFit(box: CGRect(x: 16, y: 14, width: 320, height: 60), cover: CGRect(x: 0, y: 0, width: 360, height: 90), lineHeight: 24,
                         text: cream, background: brown, alignment: .leading, linePitch: 34),
                 "Kiếm Sắt: Lưỡi kiếm chắc chắn được rèn ở các mỏ phương bắc. Tấn công +12. Có thể nâng cấp ở lò rèn làng."),
            ]
            for (name, size, fit, vi) in cases {
                let model = OverlayModel()
                model.pieces = [ScreenPiece(id: 0, vi: vi, fit: fit)]; model.visible = true
                let total = NSSize(width: size.width, height: size.height + 300)   // cửa sổ lớp đè chừa 150 điểm trên và dưới
                let host = NSHostingView(rootView: OverlayView(model: model, settings: settings, screenTranslation: true)
                    .frame(width: total.width, height: total.height).background(Color(white: 0.35)))
                host.frame = NSRect(origin: .zero, size: total)
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .seconds(0.4))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let img = NSImage(size: total); img.addRepresentation(rep)
                let out = NSImage(size: total)
                out.lockFocusFlipped(true)
                img.draw(in: NSRect(origin: .zero, size: total), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
                NSColor.red.setStroke()
                let box = NSBezierPath(rect: fit.box.offsetBy(dx: 0, dy: 150)); box.lineWidth = 1; box.stroke()
                out.unlockFocus()
                if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("layout-\(name).png"))
                }
            }
            for text in ["Continue your adventure", "Iron Sword: A sturdy blade forged in the northern mines. Attack +12."] {
                let t0 = Date()
                let r: String
                do { r = try await Providers.appleTranslate(text, source: "en", target: settings.target.code) } catch { r = "(lỗi: \(error))" }
                DebugLog.write(String(format: "Thử Dịch máy Apple: %.2f s \"%@\" → \"%@\"", Date().timeIntervalSince(t0), text, r))
            }
            DebugLog.write("Thử bố cục dịch màn hình xong")
        }
    }

    /// Thử trọn quy trình dịch màn hình trên cảnh vẽ sẵn (không cần chụp màn hình): OVERSUB_SCENE_TEST=1.
    /// Vẽ menu kiểu game → OCR thật → chia cụm → AI dịch một lần → vẽ mảng tô lên cảnh, lưu ảnh trước/sau.
    static func sceneTestIfRequested(engine: Engine, hub: TranslationHub, settings: AppSettings) {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSUB_SCENE_TEST"] != nil, let dir = env["OVERSUB_SNAPSHOT_DIR"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for (name, scene) in [("chest", chestScene()), ("armor", armorScene()), ("item", itemScene())] {
                guard let (image, size) = scene else { continue }
                let region = CaptureRegion(displayID: 0, x: 0, y: 0, w: size.width, h: size.height, sw: nil, sh: nil)
                guard let res = try? await OCR.recognize(image, language: "en-US", keepAll: true) else { continue }
                let blocks = ScreenText.blocks(res.lines, size: size)
                DebugLog.write("Thử cảnh \(name): \(res.lines.count) dòng → \(blocks.count) cụm: " + blocks.map(\.text).joined(separator: " | "))
                let t0 = Date()
                let out = await hub.translateUI(blocks.map(\.text), source: SourceLanguage.find("en-US"), fast: true)
                DebugLog.write(String(format: "Thử cảnh %@: AI %.2f s [%@] ", name, Date().timeIntervalSince(t0), out?.label ?? "lỗi") + (out?.texts.joined(separator: " | ") ?? ""))
                let texts = out?.texts ?? blocks.map(\.text)
                let fits = blocks.indices.compactMap { k in
                    TextFit.make(image: image, region: region, lines: blocks[k].lines).map { (k, $0, ScreenText.fontSize(blocks[k].lines, regionWidth: size.width, lineHeight: $0.lineHeight)) }
                }
                let t1 = Date()
                let cleaned = Inpaint.clean(image, size: size, zones: fits.map { ScreenText.zone($0.1, size: $0.2) }, boxes: fits.map { $0.1.box })
                DebugLog.write(String(format: "Thử cảnh %@: dựng nền %.0f ms, nét chữ %@", name, Date().timeIntervalSince(t1) * 1000,
                                      (cleaned?.stem ?? []).map { String(format: "%.1f", $0) }.joined(separator: " ")))
                DebugLog.write("Thử cảnh \(name): cỡ chữ gốc ước " + fits.map { String(format: "%.1f", $0.2) }.joined(separator: " "))
                // Như app thật: bỏ cụm không cần dịch (bản dịch trùng chữ gốc).
                let pieces = fits.enumerated().compactMap { n, f -> ScreenPiece? in
                    guard TextUtil.normalize(texts[f.0]) != TextUtil.normalize(blocks[f.0].text) else { return nil }
                    return ScreenPiece(id: f.0, vi: texts[f.0], fit: f.1, stem: cleaned?.stem[n] ?? 0, size: f.2)
                }
                DebugLog.write("Thử cảnh \(name) khung: " + pieces.map { String(format: "%@ lh=%.1f box=(%.0f,%.0f %.0f×%.0f) cover=(%.0f,%.0f %.0f×%.0f) pitch=%@", String(texts[$0.id].prefix(16)), $0.fit.lineHeight, $0.fit.box.minX, $0.fit.box.minY, $0.fit.box.width, $0.fit.box.height, $0.fit.cover.minX, $0.fit.cover.minY, $0.fit.cover.width, $0.fit.cover.height, $0.fit.linePitch.map { String(format: "%.0f", $0) } ?? "-") }.joined(separator: " | "))
                let model = OverlayModel()
                model.pieces = pieces; model.visible = true
                model.screenBackground = cleaned.map { NSImage(cgImage: $0.image, size: size) }
                let total = NSSize(width: size.width, height: size.height + 300)
                let host = NSHostingView(rootView: OverlayView(model: model, settings: settings, screenTranslation: true).frame(width: total.width, height: total.height))
                host.frame = NSRect(origin: .zero, size: total)
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .seconds(0.4))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let overlay = NSImage(size: total); overlay.addRepresentation(rep)
                for (suffix, withOverlay) in [("before", false), ("after", true)] {
                    let out = NSImage(size: size)
                    out.lockFocusFlipped(true)
                    NSImage(cgImage: image, size: size).draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
                    if withOverlay {
                        overlay.draw(in: NSRect(origin: .zero, size: size), from: NSRect(x: 0, y: 150, width: size.width, height: size.height),
                                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    }
                    out.unlockFocus()
                    if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("scene-\(name)-\(suffix).png"))
                    }
                }
            }
            // Chữ nổi trên nền đá lát đang chạy (nhân vật di chuyển): ba khung, nền lệch nhau; chữ đọc nhanh phải y nhau.
            var reads: [String] = [], masked: [String] = [], accurate: [String] = []
            for k in 0..<3 {
                guard let (img, _) = movingScene(offset: CGFloat(k) * 37) else { continue }
                reads.append(await OCR.screenSignature(img, language: "en-US"))
                if let m = OCR.brightTextMask(img) { masked.append(await OCR.quickText(m, language: "en-US")) }
                let t0 = Date()
                let acc = (try? await OCR.recognize(img, language: "en-US", keepAll: true))?.text ?? ""
                accurate.append(String(format: "%.0fms %@", Date().timeIntervalSince(t0) * 1000, acc))
            }
            DebugLog.write("Thử nền chạy, tách chữ sáng: " + masked.joined(separator: " | "))
            DebugLog.write("Thử nền chạy, đọc kỹ: " + accurate.joined(separator: " | "))
            let same = reads.count == 3 && reads.dropFirst().allSatisfy { $0 == reads[0] || (TextUtil.dice($0, reads[0]) >= 0.92 && abs($0.count - reads[0].count) <= 2) }
            DebugLog.write("Thử nền chạy: " + (same ? "ổn định" : "KHÔNG ổn định") + " · " + reads.joined(separator: " | "))
            if let (img, size) = movingScene(offset: 37) {
                let out = NSImage(cgImage: img, size: size)
                if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("scene-moving.png"))
                }
            }
            DebugLog.write("Thử cảnh xong")
        }
    }

    /// Vẽ một cảnh (gốc trên trái) ra CGImage gấp đôi điểm ảnh, như ảnh chụp màn hình Retina.
    private static func drawScene(_ size: CGSize, _ draw: () -> Void) -> (CGImage, CGSize)? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        ctx?.cgContext.translateBy(x: 0, y: size.height)
        ctx?.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx!.cgContext, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage.map { ($0, size) }
    }

    private static func text(_ s: String, at p: CGPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .semibold) {
        (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }

    private static func menuScene() -> (CGImage, CGSize)? {
        drawScene(CGSize(width: 640, height: 430)) {
            NSColor(calibratedRed: 0.95, green: 0.89, blue: 0.75, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 430)).fill()
            let ink = NSColor(calibratedRed: 0.30, green: 0.22, blue: 0.14, alpha: 1)
            text("Options", at: CGPoint(x: 272, y: 26), size: 26, color: ink)
            NSColor(calibratedRed: 0.0, green: 0.72, blue: 0.75, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 40, y: 90, width: 560, height: 60), xRadius: 8, yRadius: 8).fill()
            text("Option Settings", at: CGPoint(x: 72, y: 105), size: 24, color: .white)
            for (k, label) in ["Controller Settings", "Return to Title Screen"].enumerated() {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: 40, y: 168 + CGFloat(k) * 78, width: 560, height: 60), xRadius: 8, yRadius: 8).fill()
                text(label, at: CGPoint(x: 72, y: 183 + CGFloat(k) * 78), size: 24, color: ink)
            }
            text("A Confirm", at: CGPoint(x: 360, y: 380), size: 18, color: ink, weight: .medium)
            text("B Back", at: CGPoint(x: 500, y: 380), size: 18, color: ink, weight: .medium)
        }
    }

    /// Nền đá lát có vân (lệch theo `offset` như camera đang chạy) và hai dòng thoại chữ trắng viền đen nổi trên nền.
    private static func movingScene(offset: CGFloat) -> (CGImage, CGSize)? {
        drawScene(CGSize(width: 720, height: 150)) {
            var rng = UInt64(12345)
            func rand() -> CGFloat { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((rng >> 33) % 10000) / 10000 }
            NSColor(calibratedRed: 0.62, green: 0.55, blue: 0.45, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 720, height: 150)).fill()
            for _ in 0..<420 {
                let x = rand() * 900 - offset * 2, y = rand() * 170 - 10, w = 14 + rand() * 40, h = 8 + rand() * 18
                NSColor(calibratedRed: 0.45 + rand() * 0.35, green: 0.40 + rand() * 0.3, blue: 0.32 + rand() * 0.25, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: 3, yRadius: 3).fill()
                NSColor(white: 0.2, alpha: 0.5).setStroke()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: 3, yRadius: 3).stroke()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.white,
                                                        .strokeColor: NSColor.black, .strokeWidth: -3.5]
            ("His Majesty's commands are absolute!" as NSString).draw(at: CGPoint(x: 40, y: 34), withAttributes: attrs)
            ("Let's go check the situation at the border!" as NSString).draw(at: CGPoint(x: 40, y: 82), withAttributes: attrs)
        }
    }

    /// Cảnh giống menu Rương: tiêu đề "Menu" kiểu chữ trang trí (không cần dịch), ký tự rác ":Q:" như Vision đọc nhầm biểu tượng.
    private static func chestScene() -> (CGImage, CGSize)? {
        drawScene(CGSize(width: 480, height: 470)) {
            NSColor(calibratedRed: 0.93, green: 0.86, blue: 0.70, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 480, height: 470)).fill()
            NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.32, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 480, height: 50)).fill()
            text("Chest", at: CGPoint(x: 20, y: 12), size: 22, color: NSColor(white: 0.95, alpha: 1), weight: .medium)
            let ink = NSColor(calibratedRed: 0.28, green: 0.22, blue: 0.15, alpha: 1)
            ("Menu" as NSString).draw(at: CGPoint(x: 185, y: 70), withAttributes: [.font: NSFont(name: "Copperplate-Bold", size: 34) ?? NSFont.boldSystemFont(ofSize: 34), .foregroundColor: ink])
            @MainActor func button(_ y: CGFloat, _ label: String, selected: Bool) {
                let r = NSRect(x: 50, y: y, width: 380, height: 54)
                (selected ? NSColor(calibratedRed: 0.0, green: 0.62, blue: 0.62, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
                text(label, at: CGPoint(x: 80, y: y + 15), size: 20, color: selected ? .white : ink)
            }
            button(140, "Change Appearance", selected: false)
            button(210, "Change Clothes", selected: false)
            button(280, "Gallery", selected: true)
            button(350, ":Q: Scan amiibo", selected: false)
        }
    }

    /// Cảnh giống menu game có vân: nền xanh ngọc chuyển màu, băng tiêu đề có vân, nút tối có hoa văn, nút đang chọn phát sáng.
    private static func armorScene() -> (CGImage, CGSize)? {
        drawScene(CGSize(width: 520, height: 470)) {
            NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.72, blue: 0.74, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.85, alpha: 1)])?
                .draw(in: NSRect(x: 0, y: 0, width: 520, height: 470), angle: 90)
            // Băng tiêu đề nâu đỏ có vân sọc.
            NSGradient(colors: [NSColor(calibratedRed: 0.45, green: 0.25, blue: 0.22, alpha: 1), NSColor(calibratedRed: 0.62, green: 0.38, blue: 0.33, alpha: 1)])?
                .draw(in: NSRect(x: 0, y: 14, width: 520, height: 62), angle: 0)
            NSColor(white: 1, alpha: 0.06).setStroke()
            for k in stride(from: 0, to: 520, by: 9) { let p = NSBezierPath(); p.move(to: NSPoint(x: k, y: 14)); p.line(to: NSPoint(x: k + 30, y: 76)); p.stroke() }
            text("Change Color/Layer", at: CGPoint(x: 30, y: 30), size: 24, color: NSColor(white: 0.95, alpha: 1))
            text("Armor Color", at: CGPoint(x: 205, y: 104), size: 15, color: NSColor(calibratedRed: 0.2, green: 0.33, blue: 0.35, alpha: 1), weight: .medium)
            @MainActor func button(_ y: CGFloat, _ label: String, selected: Bool) {
                let r = NSRect(x: 40, y: y, width: 420, height: 56)
                if selected {
                    NSGradient(colors: [NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.27, alpha: 1), NSColor(calibratedRed: 0.2, green: 0.75, blue: 0.78, alpha: 1)])?
                        .draw(in: NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6), angle: 0)
                } else {
                    NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.08, alpha: 1).setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                    NSColor(calibratedRed: 0.25, green: 0.22, blue: 0.16, alpha: 1).setStroke()
                    for k in 0..<7 { NSBezierPath(ovalIn: NSRect(x: 250 + CGFloat(k) * 28, y: y + 8, width: 26, height: 40)).stroke() }
                }
                NSColor(calibratedRed: 0.6, green: 0.5, blue: 0.3, alpha: 1).setStroke()
                let border = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6); border.lineWidth = 2; border.stroke()
                text(label, at: CGPoint(x: 70, y: y + 15), size: 21, color: NSColor(white: selected ? 0.95 : 0.85, alpha: 1), weight: .medium)
            }
            button(140, "Armor Main Color", selected: false)
            button(210, "Armor Sub Color", selected: false)
            button(300, "Layered Armor", selected: true)
            button(380, "Layered Main Color", selected: false)
        }
    }

    private static func itemScene() -> (CGImage, CGSize)? {
        drawScene(CGSize(width: 560, height: 200)) {
            NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.22, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 560, height: 200)).fill()
            let cream = NSColor(calibratedRed: 0.96, green: 0.92, blue: 0.82, alpha: 1)
            text("Iron Sword", at: CGPoint(x: 24, y: 18), size: 24, color: NSColor(calibratedRed: 1, green: 0.8, blue: 0.4, alpha: 1))
            text("A sturdy blade forged in the northern mines of the", at: CGPoint(x: 24, y: 70), size: 19, color: cream, weight: .regular)
            text("old kingdom. Attack +12, can be upgraded.", at: CGPoint(x: 24, y: 98), size: 19, color: cream, weight: .regular)
            text("Equip", at: CGPoint(x: 24, y: 158), size: 18, color: cream, weight: .medium)
            text("Sell", at: CGPoint(x: 120, y: 158), size: 18, color: cream, weight: .medium)
        }
    }

    /// Thử loại trừ cửa sổ của app khỏi ảnh chụp (OVERSUB_EXCLUDE_TEST=1): chụp lúc lớp đè đang ẩn (bộ chụp nhớ danh sách
    /// cửa sổ), rồi hiện lớp đè có chữ lạ và chụp lại. Đọc thấy chữ lạ nghĩa là app sẽ đọc lại chính bản dịch của mình.
    static func excludeTestIfRequested(settings: AppSettings) {
        guard ProcessInfo.processInfo.environment["OVERSUB_EXCLUDE_TEST"] != nil, let screen = NSScreen.main, let id = displayIDOf(screen) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let region = CaptureRegion(displayID: id, x: 120, y: 120, w: 520, h: 120, sw: screen.frame.width, sh: screen.frame.height)
            let grabber = ScreenGrabber()
            _ = try? await grabber.grab(region)
            let ov = OverlayController(settings: settings, applyOffsets: false)
            ov.region = region
            ov.show(vi: "ZEBRA KANGAROO OVERLAY", original: nil, fit: nil)
            try? await Task.sleep(for: .seconds(0.8))
            var seen = "(lỗi chụp)"
            if let img = try? await grabber.grab(region) { seen = await OCR.quickText(img, language: "en-US") }
            ov.hide()
            DebugLog.write("Thử loại trừ: " + (seen.contains("zebra") || seen.contains("kangaroo") ? "LỌT, đọc thấy lớp đè: \(seen.prefix(80))" : "ổn, không thấy lớp đè (đọc được: \(seen.prefix(60)))"))
        }
    }

    /// Thử bộ dẫn đổi giọng Siri (OVERSUB_SIRI_COACH=1): mở bộ dẫn, chờ nó nhận bước rồi chụp cả màn hình chính.
    static func siriCoachIfRequested() {
        guard ProcessInfo.processInfo.environment["OVERSUB_SIRI_COACH"] != nil, let dir = ProcessInfo.processInfo.environment["OVERSUB_SNAPSHOT_DIR"],
              let screen = NSScreen.screens.first, let id = displayIDOf(screen) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            SiriGuidePanel.shared.show()
            try? await Task.sleep(for: .seconds(8))
            await shootScreen("coach", dir: dir, display: id, rect: CGRect(origin: .zero, size: screen.frame.size))
            DebugLog.write("Thử bộ dẫn: bước \(SiriGuidePanel.shared.step.rawValue) thấy nút=\(SiriGuidePanel.shared.located) đọc được=\(SiriGuidePanel.shared.recognized)")
            SiriGuidePanel.shared.close()
        }
    }

    /// Đọc chữ vài ảnh có sẵn (OVERSUB_OCR_FILES=a.png:b.png) và ghi ra log kèm vị trí, để kiểm tra giả định về giao diện.
    static func ocrFilesIfRequested() {
        guard let spec = ProcessInfo.processInfo.environment["OVERSUB_OCR_FILES"] else { return }
        Task { @MainActor in
            for path in spec.split(separator: ":") {
                guard let img = NSImage(contentsOfFile: String(path))?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let r = try? await OCR.recognize(img, language: "en-US", keepAll: true) else { continue }
                DebugLog.write("OCR tệp \(path.suffix(8)): " + r.lines.map { String(format: "%@ @(%.2f,%.2f)", $0.text.lowercased(), $0.box.minX, $0.box.midY) }.joined(separator: " | "))
            }
            DebugLog.write("OCR tệp xong")
        }
    }

    /// Thử menu trên thanh menu khi một app khác đang toàn màn hình (OVERSUB_MENU_TEST=tên app): đưa app đó lên trước,
    /// bấm biểu tượng bằng mã, chụp cả màn hình lúc menu đang mở.
    static func menuTestIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["OVERSUB_MENU_TEST"], let dir = env["OVERSUB_SNAPSHOT_DIR"], let screen = NSScreen.screens.first, let id = displayIDOf(screen) else { return }
        let frame = CGRect(origin: .zero, size: screen.frame.size)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.activate()
            try? await Task.sleep(for: .seconds(3))
            Task.detached {
                try? await Task.sleep(for: .seconds(1.5))
                await shootScreen("menu", dir: dir, display: id, rect: frame)
            }
            let variant = env["OVERSUB_MENU_VARIANT"] ?? ""
            if variant.contains("accessory") { NSApp.setActivationPolicy(.accessory) }
            if variant.contains("nosub") { SubtitleWindowState.shared.close() }
            if variant.contains("nowin") { NSApp.windows.forEach { DebugLog.write("cửa sổ: \($0.className) level=\($0.level.rawValue) visible=\($0.isVisible) frame=\($0.frame)") } }
            try? await Task.sleep(for: .seconds(0.5))
            StatusMenu.shared.debugClick(closeAfter: 4)
        }
    }

    /// Thử dịch nhanh (OVERSUB_QUICK_TEST="x,y,w,h" trên màn hình chính): mở dịch nhanh, chọn sẵn vùng đó, chụp kết quả.
    /// Chụp một vùng màn hình của app khác (OVERSUB_SCREEN_RECT="x,y,w,h", điểm, gốc trên trái, màn hình chính), vd. cửa sổ
    /// cài đặt .dmg trong Finder. App tự ẩn trước khi chụp để không che vùng đó.
    static func screenRectIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["OVERSUB_SCREEN_RECT"], let dir = env["OVERSUB_SNAPSHOT_DIR"], let screen = NSScreen.screens.first, let id = displayIDOf(screen) else { return }
        let n = spec.split(separator: ",").compactMap { Double($0) }
        guard n.count == 4 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            NSApp.hide(nil)
            try? await Task.sleep(for: .seconds(1.5))
            await shootScreen("screen", dir: dir, display: id, rect: CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))
            DebugLog.write("snapshot xong: \(dir)")
        }
    }

    static func quickTestIfRequested(engine: Engine) {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["OVERSUB_QUICK_TEST"], let dir = env["OVERSUB_SNAPSHOT_DIR"], let screen = NSScreen.screens.first, let id = displayIDOf(screen) else { return }
        let n = spec.split(separator: ",").compactMap { Double($0) }
        guard n.count == 4 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            engine.quickTranslate()
            try? await Task.sleep(for: .seconds(1.5))
            let r = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
            engine.quick.debugSelect(r)
            try? await Task.sleep(for: .seconds(4))
            await shootScreen("quick", dir: dir, display: id, rect: r.insetBy(dx: -120, dy: -160))
            DebugLog.write("Thử dịch nhanh xong, đang mở=\(engine.quick.isOpen)")
            engine.quick.close()
        }
    }

    /// Nghiên cứu: mở System Settings theo URL (OVERSUB_SIRI_PROBE), chụp các cửa sổ của nó, đọc chữ và ghi ra log kèm vị trí.
    static func siriProbeIfRequested() {
        guard let spec = ProcessInfo.processInfo.environment["OVERSUB_SIRI_PROBE"], let dir = ProcessInfo.processInfo.environment["OVERSUB_SNAPSHOT_DIR"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if let url = URL(string: spec) { NSWorkspace.shared.open(url) }
            try? await Task.sleep(for: .seconds(4))
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            let all = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            DebugLog.write("Probe: app trước mặt=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"); cửa sổ Settings (mọi Space): " + (all?.windows.filter { ($0.owningApplication?.bundleIdentifier ?? "").contains("systempref") || ($0.owningApplication?.applicationName ?? "").contains("Settings") }.map { "\($0.owningApplication?.bundleIdentifier ?? "?") '\($0.title ?? "-")' onScreen=\($0.isOnScreen) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: "; ") ?? "nil"))
            let wins = (all ?? content).windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.systempreferences" && $0.frame.width > 200 && $0.frame.height > 200 }
            for (k, w) in wins.enumerated() {
                DebugLog.write("Probe cửa sổ \(k): title=\(w.title ?? "-") layer=\(w.windowLayer) frame=\(w.frame)")
                let cfg = SCStreamConfiguration()
                cfg.width = Int(w.frame.width * 2); cfg.height = Int(w.frame.height * 2)
                guard w.isOnScreen else { continue }
                let img: CGImage
                do { img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) }
                catch { DebugLog.write("Probe lỗi chụp: \(error)"); continue }
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("probe-\(k).png"))
                do {
                    let r = try await OCR.recognize(img, language: "en-US", keepAll: true)
                    DebugLog.write("Probe chữ \(k): " + r.lines.map { String(format: "%@ @(%.2f,%.2f)", $0.text, $0.box.midX, 1 - $0.box.midY) }.joined(separator: " | "))
                } catch { DebugLog.write("Probe lỗi đọc: \(error)") }
            }
            DebugLog.write("Probe xong")
        }
    }

    /// Chụp một phần màn hình, gồm cả cửa sổ của app (lớp dịch đè lên).
    nonisolated private static func shootScreen(_ name: String, dir: String, display: UInt32, rect: CGRect) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let d = content.displays.first(where: { $0.displayID == display }) else { return }
            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = Int(rect.width * 2); config.height = Int(rect.height * 2)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: config)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        } catch {
            DebugLog.write("snapshot lỗi \(name): \(error)")
        }
    }

    /// Thử chữ chạy + giọng đọc (OVERSUB_PROG_TEST=1): đoạn hội thoại Expert Farmer lấy từ nhật ký thật, nơi giọng đọc từng
    /// chờ tới câu sau mới đọc. Dịch thật (vài lượt API) và đọc thật; xem kết quả trong nhật ký.
    static func progressiveTestIfRequested(engine: Engine) {
        guard ProcessInfo.processInfo.environment["OVERSUB_PROG_TEST"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            DebugLog.write("=== Thử chữ chạy + giọng đọc ===")
            if ProcessInfo.processInfo.environment["OVERSUB_PROG_TEST"] == "cutscene" {
                // Cắt cảnh (nhật ký thật 06/10 21:58): cả dòng hiện một lần, mỗi khung 2–3 giây, có câu bị cắt bằng dấu phẩy.
                let frames: [(String, Double)] = [
                    ("The pleasure is mine, Your Highness. I am known as Fiero,", 2.5),
                    ("And may I introduce Her Queen Majesty's younger sister.", 2.5),
                    ("I have come on Her Majesty's behalf. My name is Eleanor,", 2.0),
                    ("", 0.5),
                    ("Well met, young princess.", 2.0),
                    ("I'm delighted to make yours as well.", 2.0),
                    ("", 0.5),
                    ("Vermeil faces an unprecedented crisis. Within our borders,", 3.0),
                    ("In turn, countless citizens have lost their homes.", 3.0),
                    ("Our soil and food reserves are devastated.", 3.0),
                    ("", 14),
                ]
                for (text, wait) in frames {
                    await engine.debugRead(text.isEmpty ? [] : [text], speaker: nil, wait: wait)
                }
                DebugLog.write("=== Hết thử chữ chạy ===")
                return
            }
            if ProcessInfo.processInfo.environment["OVERSUB_PROG_TEST"] == "return" {
                // Nhật ký thật 07/10 02:30: đọc xong câu lính canh, chuyển sang app khác (chữ của app đó lọt vào một nhịp), quay lại
                // sau 16 giây thì câu cũ bị đọc lại. Kèm "Hill×" (OCR đọc lệch tên) và hai người cùng nói một câu ngắn.
                let guardLine = "The thought of my trainee brother joining in is more motivation than I'll ever need! Hmm, it wouldn't hurt to check in on him."
                await engine.debugRead([guardLine], speaker: "Brotherly Guard", wait: 9)
                await engine.debugRead(["thích kèm phím tắt. Mình đã chụp lại các cỡ cửa sổ ở cả lúc dừng lẫn lúc chạy."], speaker: nil, wait: 1)
                await engine.debugRead([], speaker: nil, wait: 7)
                await engine.debugRead([guardLine], speaker: "Brotherly Guard", wait: 4)
                let hill = "We conduct our activities beyond the walls. Will you venture into the unknown with us?"
                await engine.debugRead([hill], speaker: "Hillx", wait: 6)
                await engine.debugRead(["Hill×", hill], speaker: nil, wait: 3)
                await engine.debugRead([], speaker: nil, wait: 1)
                await engine.debugRead(["Thank you very much!"], speaker: "Eleanor", wait: 3)
                await engine.debugRead([], speaker: nil, wait: 0.3)
                await engine.debugRead([], speaker: nil, wait: 1)   // hai lần đọc trống: hộp thoại đã tắt, như giữa hai câu thật
                await engine.debugRead(["Thank you very much!"], speaker: "Fiero", wait: 4)
                DebugLog.write("=== Hết thử chữ chạy ===")
                return
            }
            if ProcessInfo.processInfo.environment["OVERSUB_PROG_TEST"] == "retalk" {
                // Nhật ký thật 07/10 16:29–16:31: nói chuyện với NPC hai lần liền. Lần hai câu đầu được đọc còn câu sau bị bỏ ("vừa
                // đọc rồi"). Giờ cả hai câu lần hai phải được đọc, vì game gõ lại chữ từ đầu.
                let name = "Kind-Hearted Farmer"
                let a = "Word of the border skirmish is making the rounds about town. I just hope it doesn't escalate into full-on war..."
                let b = "But if war does come, I'll do everything I can to keep my pal here"
                for round in 1...2 {
                    DebugLog.write("--- Lần nói chuyện \(round) ---")
                    await engine.debugRead(["Word of"], speaker: name, wait: 0.5)
                    await engine.debugRead(["Word of the border skirmish is making the rounds about town. I just hope it d"], speaker: name, wait: 0.5)
                    await engine.debugRead([a], speaker: name, wait: 8)
                    await engine.debugRead(["But if w"], speaker: name, wait: 0.5)
                    await engine.debugRead(["But if war does come, I'll do everything I c"], speaker: name, wait: 0.5)
                    await engine.debugRead([b], speaker: name, wait: 9)
                    await engine.debugRead([], speaker: nil, wait: 4)
                }
                // Chuyển app rồi quay lại: câu cũ hiện nguyên vẹn ngay thì vẫn không đọc lại.
                DebugLog.write("--- Quay lại game, câu cũ còn nằm đó ---")
                await engine.debugRead([b], speaker: name, wait: 6)
                DebugLog.write("=== Hết thử chữ chạy ===")
                return
            }
            if ProcessInfo.processInfo.environment["OVERSUB_PROG_TEST"] == "menu" {
                // Nhật ký thật 07/10 22:49 – 08/10 03:00 (Monster Hunter Stories): lướt menu trang bị, chiến đấu, rồi thoại, rồi lại menu.
                // Chữ giao diện, tên nhân vật đứng một mình, mẩu OCR rời đều bị đọc (69 câu ngắn trong 316 lần đọc). Mong đợi: chỉ đọc
                // mô tả vật phẩm (câu trọn vẹn, lớp luật không phân biệt được) và bốn câu thoại; mọi nhãn ghi "Bỏ qua (lý do)".
                let steps: [(lines: [String], speaker: String?, wait: Double)] = [
                    (["Wyvernfell Ab. Stat. Defense Decorations"], nil, 1.5),
                    (["Wyvernfell Ab. Stat."], nil, 1.5),
                    (["Armor Info"], "Decorations", 2.0),   // OCR tưởng mục menu bên trên là nhãn tên
                    (["Armor made from light materials using leather as a base. Responds flexibly to any situation."], nil, 6),
                    (["Set as Favorite"], nil, 2.5),
                    (["ng"], "Leather", 2.5),
                    (["o of o . ."], nil, 2.0),
                    ([": Off During Cutscenes"], nil, 2.0),
                    (["* Slash (BLNT)"], nil, 2.5),
                    (["They got us..."], nil, 2.0),
                    (["You've got this! Keep fighting!"], nil, 3.0),
                    (["That was a close"], nil, 0.5),
                    (["That was a close one... But it's OK, I'm fine."], nil, 4.0),
                    (["Decorations"], nil, 3.0),   // từng bị cắt thành "Decoratio" + "ns" rồi đọc "Decoratio ns"
                    (["Eleanor"], nil, 1.5),
                    (["ated state."], nil, 2.0),
                    (["Drowning Shaft Lv."], "Iron Katana", 2.0),
                    ([], nil, 2.0),
                ]
                for s in steps { await engine.debugRead(s.lines, speaker: s.speaker, wait: s.wait) }
                DebugLog.write("=== Hết thử chữ chạy ===")
                return
            }
            if ProcessInfo.processInfo.environment["OVERSUB_PROG_TEST"] == "emotion" {
                // Người dùng 08/10: "lâu lâu thoại đọc chậm rãi, câu đã chạy xong rồi mới đọc mà còn kéo dài thì tốn thời gian".
                // Ba câu: do dự ("..." ở đầu), buồn (sorry, gone), hét (!!). Xem hệ số ×  trong dòng "Lồng tiếng: đọc": không câu nào dưới ×1.00.
                for (text, wait) in [("...I don't know. Maybe we should turn back...", 5.0), ("I'm sorry. He's gone.", 4.0), ("Run! Now!!", 3.0)] {
                    await engine.debugRead([text], speaker: nil, wait: wait)
                }
                DebugLog.write("=== Hết thử chữ chạy ===")
                return
            }
            if ProcessInfo.processInfo.environment["OVERSUB_PROG_TEST"] == "label" {
                // Tên người nói lúc tách lúc dính vào đầu câu (nhật ký thật 06/10 21:05–21:06): câu chỉ được đọc một lần.
                let name = "Experienced Farmer"
                let full = "These vineyards are managed by Thea's father. Used to wrangle all sorts of Poogies, too."
                await engine.debugRead(["These vineyards are managed by"], speaker: name, wait: 0.5)
                await engine.debugRead(["These vineyards are managed by Thea's father. Used to wrangle"], speaker: name, wait: 0.5)
                await engine.debugRead([full], speaker: name, wait: 3)
                await engine.debugRead([name, full], speaker: nil, wait: 2)
                await engine.debugRead([full], speaker: name, wait: 2)
                await engine.debugRead([name, full], speaker: nil, wait: 2)
                // Lớp chặn cuối: cùng câu mà tên dính kiểu lạ (không tách được) vẫn không được đọc lại.
                await engine.debugRead(["Experienced Farmer: " + full], speaker: nil, wait: 6)
                DebugLog.write("=== Hết thử chữ chạy ===")
                return
            }
            await engine.debugProgressive([
                ("Back in the day, ther", 0.5),
                ("Back in the day, there used to be 100 Poogies around the vines. The grapes and the Poogies grew side-by-s", 0.5),
                ("Back in the day, there used to be 100 Poogies around the vines. The grapes and the Poogies grew side-by-side.", 9),
                ("We", 0.5),
                ("We called it Poogiecology! It was a", 0.5),
                ("We called it Poogiecology! It was a wonderfully practical solution... Ah, but listen to me prattle on about the past.", 12),
            ])
            DebugLog.write("=== Hết thử chữ chạy ===")
        }
    }

    /// Thử tự cập nhật không cần phát hành thật (OVERSUB_UPDATE_TEST=1, kèm OVERSUB_UPDATE_FEED và OVERSUB_UPDATE_TARGET):
    /// kiểm tra, tải, kiểm chữ ký, cài vào bản sao app; ghi kết quả vào nhật ký.
    static func updateTestIfRequested() {
        guard ProcessInfo.processInfo.environment["OVERSUB_UPDATE_TEST"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let u = Updater.shared
            DebugLog.write("=== Thử cập nhật ===")
            await u.check(manual: true)
            DebugLog.write("Thử cập nhật: sau kiểm tra = \(u.state)")
            u.updateNow()
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(0.5))
                if case .downloading = u.state { continue }
                if case .ready = u.state { u.installNow() }
                if case .installing = u.state { break }
                if case .failed = u.state { break }
            }
            DebugLog.write("Thử cập nhật: kết thúc = \(u.state)")
            DebugLog.write("=== Hết thử cập nhật ===")
        }
    }

    static func dubTestIfRequested(engine: Engine) {
        guard ProcessInfo.processInfo.environment["OVERSUB_DUB_TEST"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            DebugLog.write("=== Tự kiểm tra lồng tiếng ===")
            if ProcessInfo.processInfo.environment["OVERSUB_DUB_TEST"] == "karaoke", let dir = ProcessInfo.processInfo.environment["OVERSUB_SNAPSHOT_DIR"] {
                engine.lastSource = "My lord, the gates have fallen! We must retreat to the keep before nightfall."
                engine.lastTranslation = "Thưa ngài, cổng thành đã thất thủ! Chúng ta phải rút về thành nội trước khi trời tối."
                engine.replay(TranscriptItem(speaker: nil, source: engine.lastSource, translation: engine.lastTranslation))
                try? await Task.sleep(for: .seconds(2.2))
                await shoot("karaoke", dir: dir, window: mainWindow())
                return
            }
            if ProcessInfo.processInfo.environment["OVERSUB_DUB_TEST"] == "stream" {
                // Đúng đường đã làm app bị huỷ: bản dịch theo luồng tạo cửa sổ phụ đề đè lên game.
                await engine.debugConfirm("The Riders have been unusually active since this morning. Tenser than usual, if you ask me.")
                DebugLog.write("=== Tự kiểm tra dịch theo luồng xong, app vẫn chạy ===")
                if let dir = ProcessInfo.processInfo.environment["OVERSUB_SNAPSHOT_DIR"] {
                    try? await Task.sleep(for: .seconds(1.2))
                    await shoot("stream", dir: dir, window: mainWindow())
                }
                return
            }
            if ProcessInfo.processInfo.environment["OVERSUB_DUB_TEST"] == "pitch" {
                // Đo độ trễ giọng nhân vật (Siri đổi cao độ, phải dựng ra tệp) với một câu dài.
                let text = "Ta được biết các Riders của chúng ta đã đi phòng thủ từ sáng nay, căng thẳng hơn bình thường. Hầu hết dân thường chẳng hề hay biết chúng ta đã cận kề nguy hiểm đến mức nào."
                DebugLog.write("Thử chia đoạn: " + Speaker.renderPieces(text).map { "[\($0.count)] \($0.prefix(28))…" }.joined(separator: " | "))
                try? await Task.sleep(for: .seconds(4))   // chờ khởi động sẵn giọng xong, như lúc đang chơi
                engine.speaker.speak(DubLine(text: text, language: engine.settings.target.speech, speaker: "Kiri", force: true), plan: VoicePlan(route: .siri, pitch: 2))
                try? await Task.sleep(for: .seconds(14))
                engine.speaker.speak(DubLine(text: "Rõ ràng là có chuyện gì đang xảy ra rồi.", language: engine.settings.target.speech, speaker: "Kiri", force: true), plan: VoicePlan(route: .siri, pitch: 2))
                return
            }
            if ProcessInfo.processInfo.environment["OVERSUB_DUB_TEST"] == "ratetest" {
                let text = "Hầu hết dân thường chẳng hề hay biết chúng ta đã cận kề nguy hiểm đến mức nào, và ta cũng không định nói cho họ biết lúc này."
                let lang = engine.settings.target.speech
                try? await Task.sleep(for: .seconds(4))
                DebugLog.write("Thử tốc độ: lượt 1, giữ nguyên")
                engine.speaker.speak(DubLine(text: text, language: lang), plan: VoicePlan(route: .siri))
                try? await Task.sleep(for: .seconds(13))
                DebugLog.write("Thử tốc độ: lượt 2, tăng 1,6 lần sau 1,5 giây")
                engine.speaker.speak(DubLine(text: text, language: lang), plan: VoicePlan(route: .siri))
                try? await Task.sleep(for: .seconds(1.5))
                engine.speaker.speak(DubLine(text: "Rõ ràng là có chuyện gì đang xảy ra rồi.", language: lang), plan: VoicePlan(route: .siri))
                return
            }
            if ProcessInfo.processInfo.environment["OVERSUB_DUB_TEST"] == "voiceover" {
                engine.previewVoice()
                return
            }
            if ProcessInfo.processInfo.environment["OVERSUB_DUB_TEST"] == "gemini" {
                engine.testGemini()
                try? await Task.sleep(for: .seconds(20))
                let t = engine.tts.samples.last
                DebugLog.write("=== Gemini: ok=\(t?.ok ?? false) ra tiếng sau \(t?.firstAudio ?? -1) s, tổng \(t?.total ?? -1) s, âm thanh \(t?.audioSeconds ?? -1) s, token \(t?.outputTokens ?? -1), lỗi \(t?.error ?? "-") ===")
                return
            }
            let lang = engine.settings.target.speech
            engine.speaker.speak(DubLine(text: "Câu một, giọng Siri phát thẳng.", language: lang, force: true), plan: VoicePlan(route: .siri))
            engine.speaker.speak(DubLine(text: "Câu hai, giọng Siri đổi cao độ.", language: lang, speaker: "Kiri", force: true),
                                 plan: VoicePlan(route: .siri, pitch: 4))
            let linh = VoiceCatalog.apple(language: engine.settings.target.base, siriGender: .unknown).first { $0.id != VoiceCatalog.siriID }
            engine.speaker.speak(DubLine(text: "Câu ba, giọng \(linh?.name ?? "Apple").", language: lang, speaker: "Elena", force: true),
                                 plan: VoicePlan(route: linh.map { .apple($0.id) } ?? .siri))
            try? await Task.sleep(for: .seconds(25))
            DebugLog.write("=== Hết tự kiểm tra, còn \(engine.speaker.pendingCount) câu trong hàng đợi ===")
        }
    }

    /// Đo CPU lúc app bị ẩn (OVERSUB_HIDE_TEST=giây): ẩn app sau số giây đó, ghi trạng thái vào nhật ký.
    static func hideTestIfRequested() {
        guard let s = ProcessInfo.processInfo.environment["OVERSUB_HIDE_TEST"], let secs = Double(s) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(secs))
            NSApp.hide(nil)
            DebugLog.write("Thử ẩn app: đã ẩn")
        }
    }

    /// Thử tạo gói báo lỗi (OVERSUB_REPORT_TEST=1): chỉ tạo tệp .zip và ghi đường dẫn vào nhật ký, không mở Mail.
    static func reportTestIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["OVERSUB_REPORT_TEST"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let t = Date()
            let zip = await ErrorReport.makeArchive()
            DebugLog.write("Thử gói báo lỗi: \(zip?.path ?? "không tạo được") sau \(Int(Date().timeIntervalSince(t) * 1000)) ms")
            // OVERSUB_REPORT_TEST=show: hiện cửa sổ Gửi báo lỗi, chụp lại (OVERSUB_SHOT_DIR, không kéo theo lượt chụp toàn bộ như OVERSUB_SNAPSHOT_DIR), ghi độ dài liên kết Issue.
            // OVERSUB_REPORT_TEST=issue: thêm bước mở trang Issue điền sẵn trong trình duyệt mặc định (không bấm gửi).
            guard mode == "show" || mode == "issue", let zip else { return }
            ErrorReport.send(reason: mode == "issue" ? L("Thử báo lỗi", "Test report") : nil)
            try? await Task.sleep(for: .seconds(1.5))
            if let url = ErrorReport.issueURL(zip: zip, reason: nil) { DebugLog.write("Thử báo lỗi: liên kết Issue \(url.absoluteString.count) ký tự") }
            if let dir = env["OVERSUB_SHOT_DIR"] { await shoot("report-window", dir: dir, window: ErrorReport.debugWindow) }
            if mode == "issue" {
                ErrorReport.debugOpenIssue(zip: zip)
                try? await Task.sleep(for: .seconds(1))
                if let dir = env["OVERSUB_SHOT_DIR"] { await shoot("report-dock", dir: dir, window: ErrorReport.debugDock) }
            }
        }
    }

    /// Chụp các thông báo mới (OVERSUB_SNAPSHOT_NOTICES=1): đang chuẩn bị bộ nhận chữ, đã sẵn sàng, Vision treo lần nữa và hướng
    /// dẫn cấp quyền Ghi màn hình. Không khởi động lại, không mở Cài đặt hệ thống.
    static func noticesTestIfRequested(engine: Engine) {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSUB_SNAPSHOT_NOTICES"] != nil, let dir = env["OVERSUB_SNAPSHOT_DIR"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            PreparingNotice.shared.show(on: NSScreen.main)
            try? await Task.sleep(for: .seconds(2.2))
            await shoot("notice-preparing", dir: dir, window: PreparingNotice.shared.debugPanel)
            PreparingNotice.shared.finish()
            try? await Task.sleep(for: .seconds(0.5))
            await shoot("notice-ready", dir: dir, window: PreparingNotice.shared.debugPanel)
            try? await Task.sleep(for: .seconds(2))
            RestartNotice.shared.showStuckAgain(on: NSScreen.main) { DebugLog.write("Thử thông báo: bấm khởi động lại") }
            try? await Task.sleep(for: .seconds(0.6))
            await shoot("notice-stuck-again", dir: dir, window: RestartNotice.shared.debugPanel)
            RestartNotice.shared.hide()
            PermissionGuide.shared.show { DebugLog.write("Thử thông báo: bấm mở lại") }
            try? await Task.sleep(for: .seconds(0.6))
            await shoot("notice-permission", dir: dir, window: PermissionGuide.shared.debugPanel)
            PermissionGuide.shared.hide()
            DebugLog.write("snapshot thông báo xong: \(dir)")
        }
    }

    /// Thử thu gọn hướng dẫn cấp quyền (OVERSUB_PERMISSION_DOCK_TEST=1, nên kèm OVERSUB_FAKE_NO_SCREEN_PERMISSION=1): hiện
    /// hướng dẫn, bấm Mở Cài đặt hệ thống (chỉ mở trang xem, không đổi gì), ghi khung thẻ và khung Cài đặt, rồi ghi chỗ đặt thẻ
    /// với vài kiểu màn hình giả (Cài đặt nằm giữa, sát phải, chiếm gần hết màn hình).
    static func permissionDockTestIfRequested(engine: Engine) {
        guard ProcessInfo.processInfo.environment["OVERSUB_PERMISSION_DOCK_TEST"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            engine.showPermissionGuide()
            try? await Task.sleep(for: .seconds(1.5))
            PermissionGuide.shared.openSettings()
            try? await Task.sleep(for: .seconds(5))
            let card = PermissionGuide.shared.debugPanel?.frame ?? .zero
            let settings = PermissionGuide.settingsWindowFrame() ?? .zero
            DebugLog.write("Thử thu gọn: thẻ \(card), Cài đặt \(settings), mép thẻ đè Cài đặt: \(card.insetBy(dx: 12, dy: 12).intersects(settings)), tầng \(PermissionGuide.shared.debugPanel?.level.rawValue ?? -1)")
            if let dir = ProcessInfo.processInfo.environment["OVERSUB_SHOT_DIR"] {
                await shoot("permission-compact", dir: dir, window: PermissionGuide.shared.debugPanel)
            }
            let v = NSRect(x: 0, y: 0, width: 1470, height: 919)
            let s = card.size
            for (name, f) in [("giữa", NSRect(x: 320, y: 150, width: 830, height: 700)),
                              ("sát phải", NSRect(x: 600, y: 150, width: 830, height: 700)),
                              ("gần kín", NSRect(x: 40, y: 40, width: 1400, height: 860))] {
                let o = PermissionGuide.dockOrigin(card: s, settings: f, visible: v)
                DebugLog.write("Thử thu gọn (\(name)): đặt ở \(o), mép thẻ đè Cài đặt: \(NSRect(origin: o, size: s).insetBy(dx: 12, dy: 12).intersection(f).width)pt")
            }
        }
    }

    /// Thử hộp thoại cập nhật (OVERSUB_UPDATE_PROMPT_TEST=1, kèm OVERSUB_UPDATE_FEED, có thể kèm OVERSUB_UPDATE_LIST và
    /// OVERSUB_SHOT_DIR): bấm Kiểm tra cập nhật như ở menu, chụp hộp thoại sau khi có kết quả. Không tải, không cài.
    static func updatePromptTestIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSUB_UPDATE_PROMPT_TEST"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            UpdatePrompt.shared.checkNow()
            // Ghi cỡ cửa sổ mỗi 0,1 giây trong 5 giây để bắt cửa sổ co giãn liên tục.
            var sizes: [String] = []
            for _ in 0..<50 {
                try? await Task.sleep(for: .seconds(0.1))
                let w = UpdatePrompt.shared.debugWindow
                sizes.append(w.map { $0.isVisible ? "\(Int($0.frame.height))" : "ẩn" } ?? "-")
            }
            DebugLog.write("Thử hộp thoại cập nhật: chiều cao theo thời gian \(sizes.joined(separator: " "))")
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(0.25))
                if case .checking = Updater.shared.state { continue }
                break
            }
            try? await Task.sleep(for: .seconds(0.8))
            let w = UpdatePrompt.shared.debugWindow
            DebugLog.write("Thử hộp thoại cập nhật: \(Updater.shared.state), cửa sổ \(w.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "không có")")
            if let dir = env["OVERSUB_SHOT_DIR"] { await shoot("update-prompt", dir: dir, window: w) }
        }
    }

    /// Chụp hộp thoại báo tự khởi động lại (OVERSUB_RESTART_NOTICE=1): hiện hộp thoại, chụp lúc đang đếm ngược, hết giờ chỉ ghi nhật ký.
    static func restartNoticeTestIfRequested() {
        guard ProcessInfo.processInfo.environment["OVERSUB_RESTART_NOTICE"] != nil else { return }
        let dir = ProcessInfo.processInfo.environment["OVERSUB_SNAPSHOT_DIR"]
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            RestartNotice.shared.show(on: NSScreen.main, seconds: 5) {
                DebugLog.write("Thử bảng báo: hết đếm ngược, bản thật sẽ khởi động lại lúc này")
                RestartNotice.shared.hide()
            }
            try? await Task.sleep(for: .seconds(0.6))
            if let w = RestartNotice.shared.debugPanel {
                DebugLog.write("Thử bảng báo: level=\(w.level.rawValue) allSpaces=\(w.collectionBehavior.contains(.canJoinAllSpaces)) fullScreenAux=\(w.collectionBehavior.contains(.fullScreenAuxiliary)) nonactivating=\(w.styleMask.contains(.nonactivatingPanel)) onActiveSpace=\(w.isOnActiveSpace)")
            }
            if let dir { await shoot("restart-notice", dir: dir, window: RestartNotice.shared.debugPanel) }
        }
    }

    static func runIfRequested(engine: Engine) {
        guard let dir = ProcessInfo.processInfo.environment["OVERSUB_SNAPSHOT_DIR"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            // Có nguồn cập nhật thử: kiểm tra trước để ảnh chụp có thông báo bản mới và mục Cập nhật.
            if ProcessInfo.processInfo.environment["OVERSUB_UPDATE_FEED"] != nil { await Updater.shared.check(manual: true) }
            // Đưa cửa sổ lên trước: dùng Stage Manager mà cửa sổ đang nằm ở dải bên thì ảnh chụp bị méo phối cảnh.
            NSApp.activate()
            mainWindow()?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1.2))
            await shoot("main", dir: dir, window: mainWindow())
            // Ảnh thứ hai sau 0,7 giây: so hai ảnh để biết hoạt ảnh (ống năng lượng, nền) có đang chạy.
            try? await Task.sleep(for: .seconds(0.7))
            await shoot("main-later", dir: dir, window: mainWindow())
            if let sheet = mainWindow()?.attachedSheet {   // hướng dẫn lần đầu đang mở: chụp rồi thôi
                await shoot("onboarding-\(UserDefaults.standard.integer(forKey: "onboardStep"))", dir: dir, window: sheet)
                return
            }
            // Màn hình chính lúc phiên đang chạy (nền rực hơn, linh vật đang nghe) và lúc đang đọc (miệng mấp máy, sóng loang).
            // Chỉ đổi cờ để chụp, không chạy vòng quét hay phát tiếng thật.
            do {
                let wasRunning = engine.running
                let saved = (engine.lastSource, engine.lastTranslation, engine.lastSpeaker)
                let savedStatus = engine.status
                engine.running = true
                engine.status = L("Đang nhận phụ đề…", "Watching for subtitles…")
                try? await Task.sleep(for: .seconds(1.8))
                await shoot("main-running", dir: dir, window: mainWindow())
                engine.lastSpeaker = "Expert Farmer"
                engine.lastSource = "Back in the day, there used to be 100 Poogies around the vines."
                engine.lastTranslation = "Ngày trước, có tới cả trăm chú Poogie quanh mấy giàn nho ấy chứ."
                engine.speaker.debugSetSpeaking("")
                try? await Task.sleep(for: .seconds(0.9))
                await shoot("main-speaking", dir: dir, window: mainWindow())
                engine.speaker.debugSetSpeaking(nil)
                (engine.lastSource, engine.lastTranslation, engine.lastSpeaker) = saved
                engine.running = wasRunning
                engine.status = savedStatus
                try? await Task.sleep(for: .seconds(0.3))
            }
            if ProcessInfo.processInfo.environment["OVERSUB_SNAPSHOT_DONATE"] != nil {
                StatusMenu.openDonate?()
                try? await Task.sleep(for: .seconds(1.5))
                let w = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("donate") == true && $0.isVisible }
                w?.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(0.5))
                await shoot("donate", dir: dir, window: w)
                w?.close()
            }
            if ProcessInfo.processInfo.environment["OVERSUB_SNAPSHOT_MAIN_ONLY"] != nil { DebugLog.write("snapshot xong: \(dir)"); return }
            // Lịch sử thoại nổi trên cửa sổ chính, có vài câu mẫu.
            let savedTranscript = engine.transcript
            engine.transcript = [
                TranscriptItem(speaker: "Expert Farmer", source: "Back in the day, there used to be 100 Poogies around the vines.", translation: "Ngày trước, có tới cả trăm chú Poogie quanh mấy giàn nho ấy chứ."),
                TranscriptItem(speaker: "Expert Farmer", source: "We called it Poogiecology!", translation: "Bọn ta gọi đó là Sinh thái học Poogie!"),
                TranscriptItem(speaker: "Rudy", source: "It's a fairly potent Brute Wyvern egg.", translation: "Đó là một quả trứng Brute Wyvern khá mạnh đấy."),
            ]
            engine.showHistory = true
            try? await Task.sleep(for: .seconds(0.8))
            await shoot("history", dir: dir, window: mainWindow())
            engine.showHistory = false
            engine.transcript = []
            engine.showHistory = true
            try? await Task.sleep(for: .seconds(0.6))
            await shoot("history-empty", dir: dir, window: mainWindow())
            engine.showHistory = false
            engine.transcript = savedTranscript
            let subs = SubtitleWindowState.shared
            let wasOpen = subs.isOpen
            subs.show()
            try? await Task.sleep(for: .seconds(1.2))
            if let w = subs.window {
                DebugLog.write("Cửa sổ phụ đề: lớp=\(w.className) ghim=\(subs.onTop) level=\(w.level.rawValue) allSpaces=\(w.collectionBehavior.contains(.canJoinAllSpaces)) fullScreenAux=\(w.collectionBehavior.contains(.fullScreenAuxiliary)) nonactivating=\(w.styleMask.contains(.nonactivatingPanel))")
                let original = w.frame
                let saved = (engine.lastSource, engine.lastTranslation, engine.lastSpeaker)
                engine.lastSpeaker = "Flower Fan"
                engine.lastSource = "Aren't these the most gorgeous flowers you've ever seen? Azuria's soil is so rich, it's perfect for growing flowers!"
                engine.lastTranslation = "Đấy có phải là những bông hoa rực rỡ nhất mà cậu từng thấy không? Đất của Azuria tràn ngập dưỡng chất, hoàn hảo để trồng hoa đấy!"
                func frame(_ width: CGFloat, _ height: CGFloat) {
                    w.setFrame(NSRect(x: original.minX, y: original.minY, width: width, height: height), display: true)
                }
                frame(760, 220)
                subs.hovering = true   // hiện nút điều khiển để chụp
                try? await Task.sleep(for: .seconds(0.6))
                await shoot("subtitles", dir: dir, window: w)
                // Một dòng: chụp lúc rê chuột (nút đè lên chữ), lúc không rê, và lúc cửa sổ hẹp.
                frame(760, SubtitleWindowState.singleLineHeight(AppSettings.shared.windowFontSize))
                try? await Task.sleep(for: .seconds(0.6))
                DebugLog.write("Cửa sổ phụ đề một dòng: cao \(Int(w.frame.height)) compact=\(subs.compact)")
                await shoot("subtitles-1line-hover", dir: dir, window: w)
                // Nút Bắt đầu / Dừng lúc đang chạy (chỉ đổi cờ để chụp, không chạy vòng quét thật).
                let wasRunning = engine.running
                engine.running = true
                try? await Task.sleep(for: .seconds(0.4))
                await shoot("subtitles-1line-running", dir: dir, window: w)
                engine.running = wasRunning
                subs.hovering = false
                try? await Task.sleep(for: .seconds(0.5))
                await shoot("subtitles-1line", dir: dir, window: w)
                frame(1100, 40)
                try? await Task.sleep(for: .seconds(0.5))
                await shoot("subtitles-1line-wide", dir: dir, window: w)
                frame(420, 220)
                subs.hovering = true
                try? await Task.sleep(for: .seconds(0.5))
                await shoot("subtitles-narrow", dir: dir, window: w)
                subs.hovering = false
                w.setFrame(original, display: true)
                (engine.lastSource, engine.lastTranslation, engine.lastSpeaker) = saved
            }
            if !wasOpen { subs.close() }
            if ProcessInfo.processInfo.environment["OVERSUB_SNAPSHOT_SELECT"] != nil {
                engine.selectRegion()
                try? await Task.sleep(for: .seconds(2))
                await shoot("select", dir: dir, window: NSApp.windows.filter { $0.isVisible }.max { $0.level.rawValue < $1.level.rawValue })
                engine.editor.debugReview()
                try? await Task.sleep(for: .seconds(2.5))
                await shoot("select-review", dir: dir, window: NSApp.windows.filter { $0.isVisible }.max { $0.level.rawValue < $1.level.rawValue })
                NSApp.windows.filter { $0.level.rawValue > NSWindow.Level.normal.rawValue && $0.isVisible }.forEach { $0.orderOut(nil) }
                return
            }
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            try? await Task.sleep(for: .seconds(1.5))
            for page in SettingsPage.allCases {
                engine.requestedSettingsPage = page
                try? await Task.sleep(for: .seconds(1.6))
                await shoot("settings-\(page.rawValue)", dir: dir, window: settingsWindow())
            }
            engine.requestedPresetDetail = engine.settings.activePresetID ?? Preset.defaultID
            try? await Task.sleep(for: .seconds(1.6))
            await shoot("settings-preset-detail", dir: dir, window: settingsWindow())
            settingsWindow()?.close()
            DebugLog.write("snapshot xong: \(dir)")
        }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0.frame.width > 600 && $0.toolbar != nil }
    }
    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }
            ?? NSApp.windows.first { $0.isVisible && $0.frame.width > 700 && $0.identifier?.rawValue.hasPrefix("main") != true && $0.identifier?.rawValue.hasPrefix("subtitles") != true }
    }

    static func shoot(_ name: String, dir: String, window target: NSWindow? = nil) async {
        guard let window = target ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 }) else {
            DebugLog.write("snapshot: không thấy cửa sổ cho \(name)"); return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let sc = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
            let config = SCStreamConfiguration()
            config.width = Int(sc.frame.width * 2); config.height = Int(sc.frame.height * 2)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sc), configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        } catch {
            DebugLog.write("snapshot lỗi \(name): \(error)")
        }
    }
}

#endif
