// Công cụ tự kiểm tra màn hình chơi game, chỉ có trong bản dựng dành cho phát triển (OVERSUB_DEV=1 ./build.sh).
#if DEVTOOLS
import AppKit
import AVFoundation
import ScreenCaptureKit

extension DebugSnapshot {
    /// Thử màn hình chơi game (OVERSUB_PLAY_TEST, ảnh vào OVERSUB_SHOT_DIR, ghi số liệu vào nhật ký):
    /// - `pattern`, `pattern-full`: nguồn hình dựng sẵn (dải giới hạn, hoặc dải đầy đủ trong khung ghi dải giới hạn). Đo màu từng ô
    ///   xám theo từng cách hiểu dải sáng, đọc phụ đề qua đúng đường chụp của vòng quét (kể cả khi cửa sổ khác của OverSub che lên),
    ///   đổi cỡ cửa sổ và đo viền đen, bật các tuỳ chọn xử lý hình, rồi đóng. OVERSUB_PLAY_FULLSCREEN=1 thử thêm toàn màn hình.
    /// - `facetime` (kèm OVERSUB_PLAY_DEVICE=facetime): mở camera FaceTime như một capture card, chờ hình, đổi cỡ, giả lập rút
    ///   rồi cắm lại card, giữ mở 12 giây để đo CPU, đóng, chờ 12 giây nữa.
    /// - `hold`: chỉ mở card thật, chờ hình, giữ mở OVERSUB_PLAY_HOLD giây (mặc định 30) để đo CPU, rồi đóng. Kèm
    ///   OVERSUB_PLAY_PATH=avf để hình đi qua AVCaptureSession như trước khi có đường CoreMediaIO.
    /// - `ui` (kèm OVERSUB_PLAY_DEVICE=facetime): chụp dòng báo ở chân cửa sổ chính, lời báo trong cửa sổ, thanh điều khiển,
    ///   menu tuỳ chọn và hai hướng dẫn cấp quyền. Không mở camera.
    static func playTestIfRequested(engine: Engine) {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["OVERSUB_PLAY_TEST"] else { return }
        let dir = env["OVERSUB_SHOT_DIR"]
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            PlaySettings.shared.debugReset()
            // Stage Manager để cửa sổ mới của app ở nền vào dải bên (không hiện, không vẽ): chờ app được đưa lên trước.
            for _ in 0..<12 where !NSApp.isActive { try? await Task.sleep(for: .seconds(0.5)) }
            DebugLog.write("=== Thử màn hình chơi: \(mode) === (app ở trước: \(NSApp.isActive))")
            switch mode {
            case "pattern", "pattern-full": await patternTest(engine: engine, full: mode == "pattern-full", dir: dir)
            case "facetime", "device": await cameraTest(engine: engine, dir: dir)
            case "hold": await holdTest()
            case "motion": await motionTest(dir: dir)
            case "ui": await playUITest(engine: engine, dir: dir)
            default: DebugLog.write("Thử màn hình chơi: không biết kiểu thử \(mode)")
            }
            DebugLog.write("=== Hết thử màn hình chơi ===")
        }
    }

    private static let subtitle = "Where did you find this sword?"

    // MARK: Chèn khung

    /// OVERSUB_PLAY_TEST=motion kèm OVERSUB_PLAY_PATTERN_MOTION=60 hoặc 30: nguồn thử có vật chạy; lần lượt từng bộ chỉnh hình,
    /// mỗi bộ 11 giây, ghi CPU của tiến trình và (qua dòng nhật ký 10 giây của bộ vẽ) thời gian GPU, số khung hiện mỗi giây.
    private static func motionTest(dir: String?) async {
        let play = PlayScreen.shared
        play.debugOpenPattern(full: false, text: subtitle)
        try? await Task.sleep(for: .seconds(1.5))
        guard let w = play.window else { return }
        let s = PlaySettings.shared
        for preset in [PlaySettings.Preset.original, .sharp, .game3D, .cartoon, .fluid120, .fluid30] {
            s.preset = preset
            let c0 = cpuSeconds(), t0 = Date()
            try? await Task.sleep(for: .seconds(11))
            let cpu = (cpuSeconds() - c0) / Date().timeIntervalSince(t0) * 100
            let info = play.debugRenderer?.processingInfo()
            DebugLog.write(String(format: "Thử màn hình chơi: bộ %@: CPU %.1f%% một nhân; GPU %.2f ms mỗi lần vẽ (%@)", preset.rawValue, cpu, info?.ms ?? -1, info?.stages ?? "-"))
            if let dir { await shoot("motion-\(preset.rawValue)", dir: dir, window: w) }
        }
        s.preset = .original
        await closeTest()
    }

    private static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    // MARK: Nguồn dựng sẵn

    private static func patternTest(engine: Engine, full: Bool, dir: String?) async {
        let play = PlayScreen.shared
        play.debugOpenPattern(full: full, text: subtitle)
        await trace("mở cửa sổ", seconds: 1.5)
        guard let w = play.window else { DebugLog.write("Thử màn hình chơi: không mở được cửa sổ"); return }
        try? await Task.sleep(for: .seconds(2.5))   // bộ dò dải sáng bỏ qua 2 giây đầu, rồi cần ba lần lấy mẫu

        // Màu từng ô xám theo cách hiểu Tự động, rồi ép Giới hạn, ép Đầy đủ.
        await measurePatches("Tự động", full: full, window: w, dir: dir, shot: "play-pattern\(full ? "-full" : "")")
        for (range, name) in [(PlaySettings.Range.limited, "Giới hạn"), (.full, "Đầy đủ")] {
            PlaySettings.shared.range = range
            try? await Task.sleep(for: .seconds(0.4))
            await measurePatches(name, full: full, window: w, dir: nil, shot: nil)
        }
        PlaySettings.shared.range = .auto
        try? await Task.sleep(for: .seconds(0.3))

        await readSubtitle(engine: engine, window: w, dir: dir)

        // Thanh điều khiển hiện khi rê chuột.
        play.debugShowChrome()
        try? await Task.sleep(for: .seconds(0.5))
        if let dir, let c = play.debugControls {
            await shootWindows("play-controls", dir: dir, windows: [w, c])
            DebugLog.write("Thử màn hình chơi: thanh điều khiển \(PlayScreen.frameText(c)), alpha \(c.alphaValue), nhận chuột \(!c.ignoresMouseEvents)")
        }
        play.debugHideChrome()
        try? await Task.sleep(for: .seconds(0.6))
        DebugLog.write("Thử màn hình chơi: ẩn thanh điều khiển, alpha \(play.debugControls?.alphaValue ?? -1)")

        // Các tuỳ chọn xử lý hình: mỗi cái bật một lúc, đo lại màu ô giữa và chụp.
        let s = PlaySettings.shared
        let steps: [(String, () -> Void, () -> Void)] = [
            ("bộ Nét (FSR 1)", { s.preset = .sharp }, { s.preset = .original }),
            ("bộ Mịn cạnh", { s.preset = .smoothEdges }, { s.preset = .original }),
            ("bộ Game 3D (Anime4K)", { s.preset = .game3D }, { s.preset = .original }),
            ("bộ Hoạt hình (Anime4K)", { s.preset = .cartoon }, { s.preset = .original }),
            ("MetalFX", { s.upscaler = .metalFX }, { s.upscaler = .bilinear }),
            ("bộ Mượt 120", { s.preset = .fluid120 }, { s.preset = .original }),
            ("bộ Game 30 lên 60", { s.preset = .fluid30 }, { s.preset = .original }),
            ("lấp đầy", { s.fill = true }, { s.fill = false }),
            ("Display P3", { s.gamut = .p3 }, { s.gamut = .srgb }),
            ("HDR về SDR", { s.hdr = .tone }, { s.hdr = .off }),
            ("HDR EDR", { s.hdr = .edr }, { s.hdr = .off }),
            ("độ trễ Mượt", { s.latency = .smooth }, { s.latency = .lowest }),
        ]
        for (i, step) in steps.enumerated() {
            step.1()
            try? await Task.sleep(for: .seconds(1.2))
            await measurePatches(step.0, full: full, window: w, dir: dir, shot: "play-option-\(i)")
            step.2()
            try? await Task.sleep(for: .seconds(0.3))
        }

        await resizeTest(window: w, dir: dir)
        if ProcessInfo.processInfo.environment["OVERSUB_PLAY_FULLSCREEN"] != nil { await fullScreenTest(window: w, dir: dir) }

        DebugLog.write("Thử màn hình chơi: bắt đầu giữ mở 12 giây (đo CPU khi mở)")
        try? await Task.sleep(for: .seconds(12))
        DebugLog.write("Thử màn hình chơi: hết giữ mở")
        await closeTest()
    }

    // MARK: Camera FaceTime

    private static func cameraTest(engine: Engine, dir: String?) async {
        let cards = CaptureCards.shared
        cards.refresh()
        DebugLog.write("Thử màn hình chơi: thiết bị hình \(cards.devices.map(\.localizedName)), báo ở chân: \(cards.card?.name ?? "không")")
        for d in cards.devices {
            let fmts = d.formats.map { CaptureCards.describe($0, fps: CaptureCards.fps($0), codec: true) }
            DebugLog.write("Thử màn hình chơi: \(d.localizedName) có \(fmts.count) định dạng: \(fmts.joined(separator: "; "))")
            DebugLog.write("Thử màn hình chơi: tiếng đi cùng \(d.localizedName): \(CaptureCards.audioDevice(for: d)?.localizedName ?? "không có")")
        }
        let play = PlayScreen.shared
        play.open()
        // Lần đầu macOS hỏi quyền Camera: chờ người dùng bấm Cho phép (tối đa 90 giây).
        var waited = 0.0
        while play.phase != .live, waited < 90 {
            try? await Task.sleep(for: .seconds(0.5))
            waited += 0.5
            if Int(waited * 2) % 10 == 0 { DebugLog.write("Thử màn hình chơi: chờ hình, trạng thái \(play.phase), quyền Camera \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)") }
        }
        guard let w = play.window, play.phase == .live else {
            DebugLog.write("Thử màn hình chơi: không có hình sau \(Int(waited)) giây, trạng thái \(play.phase)")
            if let dir, let w = play.window { await shoot("play-camera-fail", dir: dir, window: w) }
            await closeTest()
            return
        }
        DebugLog.write("Thử màn hình chơi: có hình sau \(waited) giây")
        // Máy chơi game cần vài giây mới lên hình qua card (OVERSUB_PLAY_SETTLE=giây, mặc định 2).
        let settle = Double(ProcessInfo.processInfo.environment["OVERSUB_PLAY_SETTLE"] ?? "") ?? 2
        try? await Task.sleep(for: .seconds(settle))
        if let dir {
            await shoot("play-camera", dir: dir, window: w)
            for (range, name) in [(PlaySettings.Range.limited, "limited"), (.full, "full")] {
                PlaySettings.shared.range = range
                try? await Task.sleep(for: .seconds(0.4))
                await shoot("play-camera-\(name)", dir: dir, window: w)
            }
            PlaySettings.shared.range = .auto
        }
        await readSubtitle(engine: engine, window: w, dir: dir)
        await resizeTest(window: w, dir: dir)

        // OVERSUB_PLAY_EFFECTS_UI=1: mở bảng Hiệu ứng video của macOS, chờ người dùng tắt Reactions (tối đa 90 giây) rồi mới đo CPU.
        if ProcessInfo.processInfo.environment["OVERSUB_PLAY_EFFECTS_UI"] != nil {
            AVCaptureDevice.showSystemUserInterface(.videoEffects)
            DebugLog.write("Thử màn hình chơi: mở bảng Hiệu ứng video, Reactions \(AVCaptureDevice.reactionEffectsEnabled)")
            var t = 0.0
            while AVCaptureDevice.reactionEffectsEnabled, t < 90 { try? await Task.sleep(for: .seconds(0.5)); t += 0.5 }
            DebugLog.write("Thử màn hình chơi: sau \(t) giây, Reactions \(AVCaptureDevice.reactionEffectsEnabled)")
            try? await Task.sleep(for: .seconds(2))
        }
        DebugLog.write("Thử màn hình chơi: giả lập rút card rồi cắm lại")
        let unplug = Task { @MainActor in await play.debugUnplugReplug() }
        for _ in 0..<16 {
            try? await Task.sleep(for: .seconds(0.25))
            DebugLog.write("Thử màn hình chơi: rút/cắm, trạng thái \(play.phase)")
        }
        await unplug.value
        var back = 0.0
        while play.phase != .live, back < 10 { try? await Task.sleep(for: .seconds(0.5)); back += 0.5 }
        DebugLog.write("Thử màn hình chơi: sau khi cắm lại, trạng thái \(play.phase) (chờ \(back) giây)")

        DebugLog.write("Thử màn hình chơi: bắt đầu giữ mở 12 giây (đo CPU khi mở)")
        try? await Task.sleep(for: .seconds(12))
        DebugLog.write("Thử màn hình chơi: hết giữ mở")
        await closeTest()
    }

    /// Chỉ mở màn hình chơi với card thật và giữ mở để đo CPU (không đổi cỡ, không chụp, không đọc phụ đề).
    private static func holdTest() async {
        let play = PlayScreen.shared
        play.open()
        var waited = 0.0
        while play.phase != .live, waited < 90 {
            try? await Task.sleep(for: .seconds(0.5))
            waited += 0.5
        }
        guard play.phase == .live else {
            DebugLog.write("Thử màn hình chơi: không có hình sau \(Int(waited)) giây, trạng thái \(play.phase)")
            await closeTest()
            return
        }
        let hold = Double(ProcessInfo.processInfo.environment["OVERSUB_PLAY_HOLD"] ?? "") ?? 30
        DebugLog.write("Thử màn hình chơi: có hình sau \(waited) giây, bắt đầu giữ mở \(Int(hold)) giây (đo CPU khi mở)")
        try? await Task.sleep(for: .seconds(hold))
        DebugLog.write("Thử màn hình chơi: hết giữ mở")
        await closeTest()
    }

    // MARK: Giao diện

    private static func playUITest(engine: Engine, dir: String?) async {
        guard let dir else { DebugLog.write("Thử màn hình chơi: cần OVERSUB_SHOT_DIR"); return }
        let cards = CaptureCards.shared
        cards.refresh()
        try? await Task.sleep(for: .seconds(1))
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            main.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(0.6))
            await shoot("main-card", dir: dir, window: main)
            DebugLog.write("Thử màn hình chơi: chụp cửa sổ chính \(PlayScreen.frameText(main)), báo card: \(cards.card?.name ?? "không")")
            // Cỡ nhỏ nhất: hàng chân (trạng thái, Màn hình chơi game, Ủng hộ) không chồng lên nhau.
            let old = main.frame
            main.setFrame(NSRect(x: old.minX, y: old.maxY - 440, width: 660, height: 440), display: true)
            try? await Task.sleep(for: .seconds(0.8))
            await shoot("main-min", dir: dir, window: main)
            main.setFrame(old, display: true)
        }
        let play = PlayScreen.shared
        play.debugOpenPattern(full: false, text: subtitle)
        try? await Task.sleep(for: .seconds(1.5))
        guard let w = play.window else { return }
        for (phase, name) in [(PlayScreen.Phase.starting, "starting"), (.waiting, "waiting"), (.unplugged, "unplugged"), (.noPermission, "permission"),
                              (.failed(L("Có thể app khác đang dùng thiết bị này.", "Another app may be using this device.")), "failed")] {
            play.debugSetPhase(phase)
            try? await Task.sleep(for: .seconds(0.5))
            await shoot("play-status-\(name)", dir: dir, window: w)
        }
        play.debugSetPhase(.live)
        try? await Task.sleep(for: .seconds(0.5))
        play.debugShowChrome()
        try? await Task.sleep(for: .seconds(0.4))
        if let c = play.debugControls { await shootWindows("play-controls", dir: dir, windows: [w, c]) }

        play.debugHideChrome()

        for kind in [PlayPermissionGuide.Kind.camera, .microphone] {
            PlayPermissionGuide.shared.show(kind, near: w)
            try? await Task.sleep(for: .seconds(0.6))
            if let p = PlayPermissionGuide.shared.debugPanel { await shoot("play-permission-\(kind == .camera ? "camera" : "mic")", dir: dir, window: p) }
            PlayPermissionGuide.shared.hide()
        }
        play.close()
        try? await Task.sleep(for: .seconds(1))

        // Trang Cài đặt › Màn hình chơi game.
        engine.openSettings(.play)
        try? await Task.sleep(for: .seconds(1.5))
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true })
            ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 700 && $0.identifier?.rawValue.hasPrefix("main") != true }) {
            w.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(0.6))
            await shoot("settings-play", dir: dir, window: w)
            DebugLog.write("Thử màn hình chơi: chụp trang cài đặt \(PlayScreen.frameText(w))")
            // Cuộn trang (khung cuộn có nội dung cao nhất là trang chi tiết) để chụp nốt phần dưới.
            func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews) }
            if let content = w.contentView, let sv = scrollViews(content).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) {
                let total = (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height
                for (k, y) in [total * 0.45, total].enumerated() where total > 0 {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: y))
                    sv.reflectScrolledClipView(sv.contentView)
                    try? await Task.sleep(for: .seconds(0.5))
                    await shoot("settings-play-\(k + 2)", dir: dir, window: w)
                }
            }
            w.close()
        }
    }

    // MARK: Các bước dùng chung

    /// Ghi khung cửa sổ và trạng thái mỗi 0,1 giây.
    private static func trace(_ what: String, seconds: Double) async {
        var rows: [String] = []
        for _ in 0..<Int(seconds * 10) {
            try? await Task.sleep(for: .seconds(0.1))
            let w = PlayScreen.shared.window
            rows.append(w.map { "\(Int($0.frame.width))x\(Int($0.frame.height))/\(PlayScreen.shared.phase)" } ?? "đóng")
        }
        DebugLog.write("Thử màn hình chơi: \(what), theo thời gian: \(rows.joined(separator: " "))")
    }

    /// Đo màu (R,G,B) giữa từng ô xám trên ảnh chụp cửa sổ và so với giá trị đúng của cách hiểu đang dùng.
    private static func measurePatches(_ label: String, full: Bool, window w: NSWindow, dir: String?, shot: String?) async {
        guard let img = await captureWindow(w) else { DebugLog.write("Thử màn hình chơi: không chụp được cửa sổ"); return }
        if let dir, let shot { save(img, name: shot, dir: dir) }
        guard let px = rgba(img) else { return }
        let levels = PlayCapture.patchLevels(full: full)
        let fit = fitRect(imageW: img.width, imageH: img.height)
        let interp = PlayScreen.shared.debugRenderer?.current
        var out: [String] = []
        var worst = 0
        for (i, y) in levels.enumerated() {
            let sx = 240 + i * 160 + 76, sy = 240
            let p = sample(px, w: img.width, at: CGPoint(x: fit.minX + CGFloat(sx) * fit.width / 1920, y: fit.minY + CGFloat(sy) * fit.height / 1080))
            let limitedValue = Int((Double(y) - 16) * 255 / 219 + 0.5)
            let expect: Int = interp.map { $0.full ? Int(y) : max(0, min(255, limitedValue)) } ?? -1
            worst = max(worst, abs(p.0 - expect))
            out.append("Y\(y)→\(p.0),\(p.1),\(p.2) (đúng \(expect))")
        }
        let bars = [(560, "đỏ"), (840, "xanh lá"), (1120, "xanh dương")].map { x, name -> String in
            let p = sample(px, w: img.width, at: CGPoint(x: fit.minX + CGFloat(x + 130) * fit.width / 1920, y: fit.minY + 530 * fit.height / 1080))
            return "\(name) \(p.0),\(p.1),\(p.2)"
        }
        DebugLog.write("Thử màn hình chơi: màu [\(label)] hiểu là \(interp.map { $0.full ? "đầy đủ" : "giới hạn" } ?? "?")\(interp?.auto == true ? " (tự động)" : ""): "
                       + out.joined(separator: "; ") + " | " + bars.joined(separator: "; ") + " | lệch xám lớn nhất \(worst)")
    }

    /// Đọc phụ đề trên cửa sổ bằng đúng đường chụp của vòng quét; rồi để một cửa sổ khác của OverSub che lên và đọc lại.
    private static func readSubtitle(engine: Engine, window w: NSWindow, dir: String?) async {
        guard let screen = w.screen, let id = displayIDOf(screen) else { return }
        // Hộp phụ đề trong khung thử: x 260…1660, y 800…990 (gốc trên trái). Với camera thì lấy một phần ba dưới.
        let fit = fitRect(imageW: Int(w.frame.width), imageH: Int(w.frame.height))
        let box = CGRect(x: fit.minX + 260 * fit.width / 1920, y: fit.minY + 790 * fit.height / 1080,
                         width: 1400 * fit.width / 1920, height: 210 * fit.height / 1080)
        let region = CaptureRegion(displayID: id, x: w.frame.minX - screen.frame.minX + box.minX, y: screen.frame.maxY - w.frame.maxY + box.minY,
                                   w: box.width, h: box.height, sw: screen.frame.width, sh: screen.frame.height)
        let game = engine.gameUnder(region)
        let visible = engine.gameVisibleInRegion(bundle: PlayScreen.gameID, region: region)
        DebugLog.write("Thử màn hình chơi: game dưới vùng = \(game?.name ?? "không") (\(game?.bundle ?? "-")), còn hiện = \(visible.0)")
        await readRegion(engine: engine, region: region, label: "cửa sổ thoáng", dir: dir, shot: "play-grab")

        // Cửa sổ thường khác của OverSub che lên nửa vùng: ảnh chụp phải bỏ nó, vẫn thấy phụ đề bên dưới.
        let cover = NSWindow(contentRect: NSRect(x: w.frame.minX + box.minX, y: w.frame.maxY - box.maxY, width: box.width * 0.6, height: box.height),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: "OVERSUB WINDOW TEXT")
        label.font = .systemFont(ofSize: 30, weight: .bold)
        label.frame = NSRect(x: 12, y: 20, width: box.width * 0.6 - 24, height: 44)
        cover.contentView?.addSubview(label)
        cover.isReleasedWhenClosed = false
        cover.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(0.5))
        let covered = engine.gameVisibleInRegion(bundle: PlayScreen.gameID, region: region)
        DebugLog.write("Thử màn hình chơi: có cửa sổ OverSub khác che, còn hiện = \(covered.0)")
        await readRegion(engine: engine, region: region, label: "bị cửa sổ OverSub khác che", dir: dir, shot: "play-grab-covered")
        cover.orderOut(nil)

        // Thu nhỏ cửa sổ: vùng không còn game.
        w.miniaturize(nil)
        try? await Task.sleep(for: .seconds(1.2))
        DebugLog.write("Thử màn hình chơi: thu nhỏ cửa sổ, còn hiện = \(engine.gameVisibleInRegion(bundle: PlayScreen.gameID, region: region).0)")
        w.deminiaturize(nil)
        try? await Task.sleep(for: .seconds(1.2))
        DebugLog.write("Thử màn hình chơi: mở lại cửa sổ, còn hiện = \(engine.gameVisibleInRegion(bundle: PlayScreen.gameID, region: region).0)")
    }

    private static func readRegion(engine: Engine, region: CaptureRegion, label: String, dir: String?, shot: String) async {
        guard let img = await engine.debugGrab(region) else { DebugLog.write("Thử màn hình chơi: chụp vùng [\(label)] không được"); return }
        if let dir { save(img, name: shot, dir: dir) }
        let text = (try? await OCR.recognize(img, language: AppSettings.shared.sourceLanguage).text) ?? "(lỗi đọc)"
        DebugLog.write("Thử màn hình chơi: đọc vùng [\(label)] \(img.width)x\(img.height): \"\(text)\"")
    }

    /// Đổi cỡ cửa sổ (16:9, rất rộng, vuông), ghi cỡ mỗi 0,1 giây, đo viền đen trên ảnh chụp.
    private static func resizeTest(window w: NSWindow, dir: String?) async {
        let original = w.frame
        for (i, size) in [NSSize(width: 960, height: 540), NSSize(width: 1400, height: 600), NSSize(width: 760, height: 760)].enumerated() {
            w.setFrame(NSRect(x: original.minX, y: original.maxY - size.height, width: size.width, height: size.height), display: true)
            await trace("đổi cỡ \(Int(size.width))x\(Int(size.height))", seconds: 0.6)
            guard let img = await captureWindow(w), let px = rgba(img) else { continue }
            if let dir { save(img, name: "play-size-\(i)", dir: dir) }
            let midY = img.height / 2, midX = img.width / 2
            let left = (0..<img.width).first { x in let p = sample(px, w: img.width, at: CGPoint(x: x, y: midY)); return p.0 + p.1 + p.2 > 30 } ?? -1
            let top = (0..<img.height).first { y in let p = sample(px, w: img.width, at: CGPoint(x: midX, y: y)); return p.0 + p.1 + p.2 > 30 } ?? -1
            let fit = fitRect(imageW: img.width, imageH: img.height)
            DebugLog.write("Thử màn hình chơi: cỡ \(Int(size.width))x\(Int(size.height)) ảnh \(img.width)x\(img.height): viền trái \(left), viền trên \(top) (tính trước \(Int(fit.minX)), \(Int(fit.minY)))")
        }
        // Lấp đầy ở cửa sổ rất rộng: không còn viền đen.
        PlaySettings.shared.fill = true
        w.setFrame(NSRect(x: original.minX, y: original.maxY - 600, width: 1400, height: 600), display: true)
        try? await Task.sleep(for: .seconds(0.6))
        if let img = await captureWindow(w), let px = rgba(img) {
            if let dir { save(img, name: "play-size-fill", dir: dir) }
            let left = (0..<img.width).first { x in let p = sample(px, w: img.width, at: CGPoint(x: x, y: img.height / 2)); return p.0 + p.1 + p.2 > 30 } ?? -1
            DebugLog.write("Thử màn hình chơi: lấp đầy ở 1400x600: viền trái \(left) (đúng 0)")
        }
        PlaySettings.shared.fill = false
        w.setFrame(original, display: true)
        try? await Task.sleep(for: .seconds(0.3))
    }

    private static func fullScreenTest(window w: NSWindow, dir: String?) async {
        w.toggleFullScreen(nil)
        await trace("vào toàn màn hình", seconds: 2.5)
        PlayScreen.shared.debugShowChrome()
        try? await Task.sleep(for: .seconds(0.5))
        if let c = PlayScreen.shared.debugControls {
            DebugLog.write("Thử màn hình chơi: toàn màn hình \(PlayScreen.frameText(w)), thanh điều khiển \(PlayScreen.frameText(c)) cùng Space \(c.isOnActiveSpace)")
            if let dir { await shootWindows("play-fullscreen", dir: dir, windows: [w, c]) }
        }
        PlayScreen.shared.debugHideChrome()
        w.toggleFullScreen(nil)
        await trace("thoát toàn màn hình", seconds: 2.5)
    }

    private static func closeTest() async {
        let play = PlayScreen.shared
        play.close()
        await trace("đóng cửa sổ", seconds: 1)
        DebugLog.write("Thử màn hình chơi: sau khi đóng, còn mở = \(play.isOpen), số hiệu cửa sổ = \(play.windowID.map(String.init) ?? "không")")
        DebugLog.write("Thử màn hình chơi: bắt đầu chờ 12 giây sau khi đóng (đo CPU khi đóng)")
        try? await Task.sleep(for: .seconds(12))
        DebugLog.write("Thử màn hình chơi: hết chờ sau khi đóng")
    }

    // MARK: Ảnh

    /// Khung hình 16:9 trong ảnh cỡ `imageW`×`imageH` (gốc trên trái), như bộ vẽ đặt.
    private static func fitRect(imageW: Int, imageH: Int) -> CGRect {
        // Toạ độ trong ảnh của cả khung nguồn 1920×1080: Vừa khung thì nằm gọn giữa ảnh, Lấp đầy thì tràn ra ngoài ảnh.
        let W = Double(imageW), H = Double(imageH)
        let s = PlaySettings.shared.fill ? max(W / 1920, H / 1080) : min(W / 1920, H / 1080)
        return CGRect(x: (W - 1920 * s) / 2, y: (H - 1080 * s) / 2, width: 1920 * s, height: 1080 * s)
    }

    /// Ảnh riêng cửa sổ (không kèm thanh điều khiển, menu hay cửa sổ khác), đúng khung cửa sổ, gấp đôi điểm.
    private static func captureWindow(_ w: NSWindow) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let sc = content.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }), let screen = w.screen,
                  let id = displayIDOf(screen), let d = content.displays.first(where: { $0.displayID == id }) else { return nil }
            let f = w.frame
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = CGRect(x: f.minX - screen.frame.minX, y: screen.frame.maxY - f.maxY, width: f.width, height: f.height)
            cfg.width = Int(f.width * 2); cfg.height = Int(f.height * 2)
            cfg.showsCursor = false
            cfg.colorSpaceName = CGColorSpace.sRGB
            return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, including: [sc]), configuration: cfg)
        } catch {
            DebugLog.write("Thử màn hình chơi: chụp cửa sổ lỗi \(error)")
            return nil
        }
    }

    private static func shootWindows(_ name: String, dir: String, windows: [NSWindow]) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ids = Set(windows.map { CGWindowID($0.windowNumber) })
            let scw = content.windows.filter { ids.contains($0.windowID) }
            guard let screen = windows.first?.screen, let id = displayIDOf(screen), let d = content.displays.first(where: { $0.displayID == id }) else { return }
            let union = windows.dropFirst().reduce(windows[0].frame) { $0.union($1.frame) }
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = CGRect(x: union.minX - screen.frame.minX, y: screen.frame.maxY - union.maxY, width: union.width, height: union.height)
            cfg.width = Int(union.width * 2); cfg.height = Int(union.height * 2)
            cfg.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, including: scw), configuration: cfg)
            save(img, name: name, dir: dir)
        } catch {
            DebugLog.write("Thử màn hình chơi: chụp \(name) lỗi \(error)")
        }
    }

    private static func shootDisplay(_ name: String, dir: String, display: UInt32, rect: CGRect) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let d = content.displays.first(where: { $0.displayID == display }) else { return }
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = rect
            cfg.width = Int(rect.width * 2); cfg.height = Int(rect.height * 2)
            cfg.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg)
            save(img, name: name, dir: dir)
        } catch {
            DebugLog.write("Thử màn hình chơi: chụp \(name) lỗi \(error)")
        }
    }

    private static func save(_ img: CGImage, name: String, dir: String) {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        do { try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url) } catch {
            DebugLog.write("Thử màn hình chơi: lưu \(name) lỗi \(error)")
        }
    }

    private static func rgba(_ img: CGImage) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return true
        }
        return ok ? px : nil
    }

    /// Điểm ảnh tại (x, y), gốc trên trái.
    private static func sample(_ px: [UInt8], w: Int, at p: CGPoint) -> (Int, Int, Int) {
        let x = max(0, min(w - 1, Int(p.x))), h = px.count / 4 / w, y = max(0, min(h - 1, Int(p.y)))
        let i = (y * w + x) * 4
        return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
    }
}
#endif
