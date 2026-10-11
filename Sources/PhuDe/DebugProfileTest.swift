// Thử nhận diện game và tự chuyển hồ sơ bằng cảnh cửa sổ dựng sẵn, chỉ có trong bản dựng dành cho phát triển (OVERSUB_DEV=1 ./build.sh).
#if DEVTOOLS
import AppKit

extension DebugSnapshot {
    /// OVERSUB_PROFILE_TEST=1: chạy lại các tình huống đổi game của hồ sơ (chọn vùng, bấm sang app khác) trên cảnh cửa sổ dựng
    /// sẵn thay cho danh sách cửa sổ thật, ghi kết quả từng tình huống vào nhật ký. Không mở cửa sổ nào, không đụng card.
    /// Dùng ba hồ sơ thử riêng trong lúc chạy; hồ sơ, game và các tuỳ chọn liên quan được trả lại khi xong.
    static func profileTestIfRequested(engine: Engine) {
        guard ProcessInfo.processInfo.environment["OVERSUB_PROFILE_TEST"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let s = engine.settings
            let saved = (presets: s.presets, active: s.activePresetID, auto: s.autoSwitchProfile)
            DebugLog.write("=== Thử hồ sơ game === (đang dùng hồ sơ \(s.activePreset?.name ?? "?"), game \(s.gameAppName ?? "chưa có"))")
            await ProfileTest(engine: engine).run()
            engine.windowScene = { Engine.WindowScene.live() }
            s.presets = saved.presets
            if let p = saved.presets.first(where: { $0.id == saved.active }) { engine.applyPreset(p) }
            s.presets = saved.presets
            s.autoSwitchProfile = saved.auto
            try? await Task.sleep(for: .seconds(1))   // để hồ sơ tự lưu lại đúng giá trị cũ
            DebugLog.write("=== Hết thử hồ sơ game === (đã trả lại hồ sơ \(s.activePreset?.name ?? "?"), game \(s.gameAppName ?? "chưa có"))")
        }
    }
}

@MainActor
private struct ProfileTest {
    let engine: Engine
    var s: AppSettings { engine.settings }

    // App giả: mã tiến trình không trùng app thật nào.
    static let apps: [pid_t: (name: String, bundle: String)] = [
        990_001: ("Comet", "ai.perplexity.comet"),
        990_002: ("VisionRelay", "com.jiang.ConsoleLinkMac"),
        990_003: ("Claude", "com.anthropic.claudefordesktop"),
    ]
    static let comet: pid_t = 990_001, visionRelay: pid_t = 990_002, claude: pid_t = 990_003
    static let playNumber = 4242, mainWindowNumber = 4241

    var screen: CGRect { NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982) }
    /// Vùng phụ đề thử: dải dưới giữa màn hình chính, như vùng của người dùng.
    var region: CaptureRegion {
        let f = screen
        let id = NSScreen.screens.first.flatMap(displayIDOf) ?? 0
        return CaptureRegion(displayID: id, x: f.width * 0.27, y: f.height * 0.76, w: f.width * 0.45, h: f.height * 0.18,
                             sw: f.width, sh: f.height)
    }

    func window(_ pid: pid_t, _ number: Int, _ rect: CGRect) -> [String: Any] {
        [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: number,
         kCGWindowBounds as String: rect.dictionaryRepresentation, kCGWindowAlpha as String: 1.0,
         kCGWindowOwnerName as String: Self.apps[pid]?.name ?? "OverSub"]
    }
    var full: CGRect { CGRect(origin: .zero, size: screen.size) }
    var me: pid_t { ProcessInfo.processInfo.processIdentifier }

    /// Đặt cảnh: cửa sổ trên màn hình (từ trên xuống), Màn hình chơi game có mở không, app đang được chọn, app đang chạy.
    func scene(_ windows: [[String: Any]], playOpen: Bool, front: pid_t?, running: Set<pid_t>) {
        let me = me
        let front: (String?, String?) = front.flatMap { Self.apps[$0] }.map { ($0.name, $0.bundle) } ?? ("OverSub", Bundle.main.bundleIdentifier)
        let runningBundles = Set(running.compactMap { Self.apps[$0]?.bundle })
        engine.windowScene = {
            Engine.WindowScene(windows: windows, playOpen: playOpen, playWindowID: playOpen ? Self.playNumber : nil, frontmost: front,
                               app: { pid in pid == me ? ("OverSub", Bundle.main.bundleIdentifier) : (Self.apps[pid]?.name, Self.apps[pid]?.bundle) },
                               isRunning: { runningBundles.contains($0) })
        }
    }

    func preset(_ name: String, game: String?, gameName: String?) -> Preset {
        var snap = s.snapshot()
        snap.region = region
        snap.gameBundleID = game
        snap.gameAppName = gameName
        snap.pauseWhenGameHidden = true
        return Preset(name: name, snapshot: snap, lastUsedAt: Date(timeIntervalSinceNow: -3600))
    }

    func run() async {
        let dd2 = preset("Thử · Dragon Dogma 2", game: PlayScreen.gameID, gameName: PlayScreen.gameName)
        let mhs = preset("Thử · Monster Hunter Story 3", game: "ai.perplexity.comet", gameName: "Comet")   // gắn nhầm như máy người dùng
        let vr = preset("Thử · VisionRelay", game: "com.jiang.ConsoleLinkMac", gameName: "VisionRelay")
        let tests = [dd2, mhs, vr]
        var passed = 0, total = 0

        /// Dùng hồ sơ thử `p` như vừa chọn tay, rồi đặt lại cả ba hồ sơ thử về đúng game ban đầu.
        func start(_ n: Int, _ title: String, _ p: Preset) {
            engine.applyPreset(p)
            s.presets = tests
            s.autoSwitchProfile = true
            DebugLog.write("-- Tình huống \(n): \(title) (hồ sơ \(p.name), game \(p.snapshot.gameAppName ?? "chưa có"))")
        }
        func expect(_ ok: Bool, _ what: String) {
            total += 1
            if ok { passed += 1 }
            DebugLog.write("   \(ok ? "ĐÚNG" : "SAI"): \(what); thực tế: hồ sơ \(s.activePreset?.name ?? "?"), game \(s.gameAppName ?? "chưa có")")
        }
        func expectReading(_ want: Bool) {
            let reading = engine.isGameInFront()
            total += 1
            if reading == want { passed += 1 }
            DebugLog.write("   \(reading == want ? "ĐÚNG" : "SAI"): \(want ? "vẫn đọc" : "tạm ngưng đọc"); thực tế: \(reading ? "vẫn đọc" : "tạm ngưng đọc")")
        }
        let me = me
        let mainWindow = window(me, Self.mainWindowNumber, CGRect(x: 80, y: 60, width: 760, height: 520))
        let play = window(me, Self.playNumber, full)

        // Lỗi đã gặp (nhật ký 12/10/2026).
        start(1, "chọn lại vùng từ cửa sổ chính khi Màn hình chơi game toàn màn hình ở Space khác (01:16:40)", dd2)
        scene([mainWindow], playOpen: true, front: nil, running: [Self.comet, Self.claude])
        engine.detectGame(under: region)
        expect(s.gameBundleID == PlayScreen.gameID, "giữ game Màn hình chơi game")

        start(2, "hồ sơ chưa gắn game, bấm sang Comet đang che vùng phụ đề (01:29:00)", dd2)
        s.setGame(nil, name: nil, reason: "bài thử: hồ sơ chưa gắn game")
        scene([window(Self.comet, 1, full), window(Self.claude, 2, full)], playOpen: true, front: Self.comet, running: [Self.comet, Self.claude])
        engine.autoSwitchProfile(for: "ai.perplexity.comet")
        expect(s.activePresetID == dd2.id && s.gameBundleID == nil, "giữ hồ sơ, không gắn Comet")

        start(3, "bấm sang Comet che vùng phụ đề, Màn hình chơi game vẫn mở ở Space khác", dd2)
        scene([window(Self.comet, 1, full), window(Self.claude, 2, full)], playOpen: true, front: Self.comet, running: [Self.comet, Self.claude])
        engine.autoSwitchProfile(for: "ai.perplexity.comet")
        expect(s.activePresetID == dd2.id && s.gameBundleID == PlayScreen.gameID, "giữ hồ sơ và game, không chuyển sang hồ sơ gắn Comet")
        expectReading(false)   // vùng phụ đề đang là Comet: tạm ngưng là đúng

        start(4, "bấm sang cửa sổ Comet nhỏ, Màn hình chơi game vẫn hiện ở vùng phụ đề", dd2)
        let small = CGRect(x: 0, y: 0, width: full.width * 0.4, height: full.height * 0.4)
        scene([window(Self.comet, 1, small), play], playOpen: true, front: Self.comet, running: [Self.comet])
        engine.autoSwitchProfile(for: "ai.perplexity.comet")
        expect(s.activePresetID == dd2.id && s.gameBundleID == PlayScreen.gameID, "giữ hồ sơ và game")
        expectReading(true)

        // Việc tự nhận diện và tự chuyển vẫn phải làm như trước.
        start(5, "đang dùng hồ sơ VisionRelay, mở Màn hình chơi game nằm trên VisionRelay", vr)
        scene([play, window(Self.visionRelay, 1, full)], playOpen: true, front: nil, running: [Self.visionRelay])
        engine.autoSwitchProfile(for: PlayScreen.gameID)
        expect(s.activePresetID == dd2.id, "tự chuyển sang hồ sơ Dragon Dogma 2")

        start(6, "Màn hình chơi game đã đóng, chọn vùng trên cửa sổ VisionRelay", dd2)
        scene([window(Self.visionRelay, 1, full)], playOpen: false, front: Self.visionRelay, running: [Self.visionRelay])
        engine.detectGame(under: region)
        expect(s.gameBundleID == "com.jiang.ConsoleLinkMac", "nhận VisionRelay")

        start(7, "VisionRelay vẫn hiện ở nửa trái màn hình, kéo vùng ra chỗ trống", vr)
        scene([window(Self.visionRelay, 1, CGRect(x: 0, y: 0, width: full.width * 0.4, height: full.height))], playOpen: false, front: nil,
              running: [Self.visionRelay])
        engine.detectGame(under: region)
        expect(s.gameBundleID == nil, "bỏ game, vì vùng mới không nằm trên game nào")

        start(8, "VisionRelay đã đóng, chọn vùng ở chỗ trống", vr)
        scene([], playOpen: false, front: nil, running: [])
        engine.detectGame(under: region)
        expect(s.gameBundleID == nil, "bỏ game đã đóng")

        start(9, "hồ sơ VisionRelay, VisionRelay đã đóng, bấm sang Comet (hồ sơ khác gắn Comet)", vr)
        scene([window(Self.comet, 1, full)], playOpen: false, front: Self.comet, running: [Self.comet])
        engine.autoSwitchProfile(for: "ai.perplexity.comet")
        expect(s.activePresetID == mhs.id, "như cũ: game cũ không còn hiện thì chuyển sang hồ sơ của app vừa ra phía trước")

        start(10, "hồ sơ VisionRelay, bấm sang cửa sổ Comet nhỏ, VisionRelay vẫn nằm trên cùng ở vùng phụ đề", vr)
        scene([window(Self.comet, 1, small), window(Self.visionRelay, 2, full)], playOpen: false, front: Self.comet,
              running: [Self.comet, Self.visionRelay])
        engine.autoSwitchProfile(for: "ai.perplexity.comet")
        expect(s.activePresetID == vr.id && s.gameBundleID == "com.jiang.ConsoleLinkMac", "giữ hồ sơ và game VisionRelay")
        expectReading(true)

        DebugLog.write("Thử hồ sơ game: \(passed)/\(total) đúng")
    }
}
#endif
