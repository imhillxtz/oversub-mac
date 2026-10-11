// Công cụ đo âm lượng thật của giọng đọc và tiếng game, chỉ có trong bản dựng dành cho phát triển (OVERSUB_DEV=1 ./build.sh).
#if DEVTOOLS
import AppKit
import AudioToolbox
import CoreAudio

/// Đo mức tiếng đang phát thật: một tap không chặn tiếng (vẫn nghe bình thường) lên một nhóm tiến trình hoặc cả hệ thống,
/// mỗi 50 ms ghi một mức RMS (dBFS). Cần quyền ghi âm thanh hệ thống như tính năng giảm tiếng game.
final class AudioMeter: @unchecked Sendable {
    let label: String
    private var tapID = AudioObjectID(0)
    private var aggID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "oversub.meter", qos: .userInitiated)
    private let lock = NSLock()
    private var squares = 0.0, count = 0, windowStart = Date()
    private var points: [(at: Date, db: Double)] = []

    /// `processes` nil: cả hệ thống.
    init?(label: String, processes: [AudioObjectID]?) {
        self.label = label
        let desc = processes.map { CATapDescription(stereoMixdownOfProcesses: $0) } ?? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        desc.name = "OverSub meter"
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr, let out = AudioDevices.defaultOutput(), let uid = AudioDevices.uid(of: out) else {
            DebugLog.write("Đo tiếng (\(label)): không tạo được tap (mã \(st))"); stop(); return nil
        }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OverSub Meter",
            kAudioAggregateDeviceUIDKey: "OverSub-Meter-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard st == noErr else { DebugLog.write("Đo tiếng (\(label)): không tạo được thiết bị (mã \(st))"); stop(); return nil }
        var p: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&p, aggID, queue) { [weak self] _, input, _, output, _ in self?.feed(input, output) }
        guard st == noErr, let p else { DebugLog.write("Đo tiếng (\(label)): không mở được luồng (mã \(st))"); stop(); return nil }
        procID = p
        st = AudioDeviceStart(aggID, p)
        guard st == noErr else { DebugLog.write("Đo tiếng (\(label)): không chạy được luồng (mã \(st))"); stop(); return nil }
    }

    private func feed(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        for b in UnsafeMutableAudioBufferListPointer(output) { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        var sq = 0.0, n = 0
        for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let k = Int(b.mDataByteSize) / 4
            for i in 0..<k { sq += Double(d[i] * d[i]) }
            n += k
        }
        lock.lock()
        squares += sq; count += n
        let now = Date()
        if now.timeIntervalSince(windowStart) >= 0.05 {
            points.append((now, count > 0 ? 10 * log10(max(squares / Double(count), 1e-12)) : -120))
            squares = 0; count = 0; windowStart = now
        }
        lock.unlock()
    }

    func levels(from a: Date, to b: Date) -> [(at: Date, db: Double)] {
        lock.lock(); defer { lock.unlock() }
        return points.filter { $0.at >= a && $0.at <= b }
    }

    /// Mức trung bình (theo năng lượng) của những đoạn 50 ms có tiếng (trên −60 dBFS); nil nếu im lặng cả đoạn.
    func mean(from a: Date, to b: Date) -> Double? {
        let voiced = levels(from: a, to: b).map(\.db).filter { $0 > -60 }
        guard !voiced.isEmpty else { return nil }
        return 10 * log10(voiced.map { pow(10, $0 / 10) }.reduce(0, +) / Double(voiced.count))
    }

    /// Lúc có tiếng đầu tiên (trên −45 dBFS) sau mốc `a`.
    func onset(after a: Date) -> Date? { levels(from: a, to: .distantFuture).first { $0.db > -45 }?.at }

    func stop() {
        if let procID, aggID != 0 { AudioDeviceStop(aggID, procID); AudioDeviceDestroyIOProcID(aggID, procID) }
        procID = nil
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }

    deinit { stop() }
}

extension DebugSnapshot {
    /// Thử âm lượng giọng đọc và giảm tiếng game bằng số đo thật (OVERSUB_AUDIO_TEST, ghi vào nhật ký). Cài đặt đổi trong lúc
    /// thử (âm lượng, giảm tiếng) được trả lại khi xong.
    /// - `voice`: đọc một câu thử ở nhiều mức âm lượng, qua cả đường đọc thẳng lẫn AVAudioEngine, giọng nhân vật (cao độ), cảm xúc,
    ///   kéo âm lượng giữa câu; đo mức tiếng của chính OverSub và lúc bắt đầu có tiếng. Có cả một lượt tái hiện lỗi cũ (ép đọc thẳng).
    /// - `duck-play`: mở Màn hình chơi game với card thật, đọc một câu câm (âm lượng giọng 0) và ghi âm lượng phát thật của cửa sổ
    ///   chơi cùng mức tiếng đo được mỗi 50 ms, trước, trong và sau câu.
    /// - `duck-app` (kèm OVERSUB_AUDIO_TEST_APP=<mã app>): app đó phải đang mở một cửa sổ và phát tiếng. Đặt vùng phụ đề tạm lên
    ///   cửa sổ của nó, kiểm app được chọn để giảm, rồi đo mức tiếng game OverSub phát lại và mức của cả hệ thống.
    static func audioTestIfRequested(engine: Engine) {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["OVERSUB_AUDIO_TEST"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let s = engine.settings
            let saved = (s.speechVolume, s.duckEnabled, s.duckLevel)
            DebugLog.write(String(format: "=== Thử âm lượng: %@ === (cài đặt trước khi thử: âm lượng %.2f, giảm tiếng %@, còn %.2f)",
                                  mode, saved.0, saved.1 ? "bật" : "tắt", saved.2))
            switch mode {
            case "voice": await voiceTest(engine)
            case "duck-play": await duckPlayTest(engine)
            case "duck-app": await duckAppTest(engine, bundle: env["OVERSUB_AUDIO_TEST_APP"] ?? "")
            default: DebugLog.write("Thử âm lượng: không biết kiểu thử \(mode)")
            }
            engine.speaker.stop()
            engine.speaker.releaseGameAudio()
            engine.speaker.debugForceLive = false
            engine.speaker.duckDecider = { [weak engine] in engine?.duckDecision() ?? DuckDecision(target: .none, reason: "Engine đã đóng") }
            s.speechVolume = saved.0; s.duckEnabled = saved.1; s.duckLevel = saved.2
            try? await Task.sleep(for: .seconds(1))   // để hồ sơ tự lưu lại đúng giá trị cũ
            DebugLog.write(String(format: "=== Hết thử âm lượng === (đã trả lại: âm lượng %.2f, giảm tiếng %@, còn %.2f)",
                                  s.speechVolume, s.duckEnabled ? "bật" : "tắt", s.duckLevel))
        }
    }

    private static let testLine = "Thử âm lượng giọng đọc: một, hai, ba, bốn, năm, sáu, bảy, tám, chín, mười."

    /// Tap lên chính OverSub. Tiến trình chỉ có đối tượng âm thanh sau khi đã dùng tới âm thanh, nên chờ một chút nếu chưa có.
    private static func selfMeter() async -> AudioMeter? {
        for _ in 0..<20 {
            let me = AudioDevices.processObject(pid: getpid())
            if me != 0 { return AudioMeter(label: "OverSub", processes: [me]) }
            try? await Task.sleep(for: .seconds(0.1))
        }
        DebugLog.write("Thử âm lượng: OverSub chưa có đối tượng âm thanh")
        return nil
    }

    private static func waitSpeech(_ sp: Speaker, limit: Double = 15) async {
        let t = Date()
        while !sp.isSpeaking, Date().timeIntervalSince(t) < 3 { try? await Task.sleep(for: .seconds(0.02)) }
        while sp.isSpeaking, Date().timeIntervalSince(t) < limit { try? await Task.sleep(for: .seconds(0.05)) }
    }

    private static func db(_ v: Double?) -> String { v.map { String(format: "%.1f dBFS", $0) } ?? "im lặng" }

    // MARK: Giọng đọc

    private static func voiceTest(_ engine: Engine) async {
        let sp = engine.speaker, s = engine.settings
        let lang = s.target.speech
        engine.speaker.warmUp(language: lang)
        try? await Task.sleep(for: .seconds(2))
        guard let meter = await selfMeter() else { return }
        var reference: Double?

        func run(_ label: String, volume: Double, plan: VoicePlan = VoicePlan(route: .siri), forceLive: Bool = false,
                 changeTo: Double? = nil) async -> Double? {
            sp.debugForceLive = forceLive
            s.speechVolume = volume
            try? await Task.sleep(for: .seconds(0.4))
            let t0 = Date()
            sp.playNow(DubLine(text: testLine, language: lang), plan: plan)
            try? await Task.sleep(for: .seconds(0.05))
            let path = sp.debugCurrentPath ?? "?"
            var tChange: Date?
            var playerBefore: Float = -1, playerAfter: Float = -1
            if let changeTo {
                // Đổi âm lượng giữa câu, như kéo thanh âm lượng lúc đang đọc.
                while sp.isSpeaking, meter.onset(after: t0) == nil, Date().timeIntervalSince(t0) < 4 { try? await Task.sleep(for: .seconds(0.05)) }
                try? await Task.sleep(for: .seconds(1.0))
                playerBefore = sp.debugPlayerVolume
                s.speechVolume = changeTo
                tChange = Date()
                try? await Task.sleep(for: .seconds(0.1))
                playerAfter = sp.debugPlayerVolume
            }
            await waitSpeech(sp)
            let tEnd = Date()
            try? await Task.sleep(for: .seconds(0.3))
            let onset = meter.onset(after: t0).map { $0.timeIntervalSince(t0) * 1000 }
            let onsetText = onset.map { String(format: "có tiếng sau %.0f ms", $0) } ?? "không có tiếng"
            if let tChange {
                let before = meter.mean(from: t0, to: tChange)
                let after = meter.mean(from: tChange.addingTimeInterval(0.25), to: tEnd)
                let delta = (before != nil && after != nil) ? String(format: ", chênh %+.1f dB (lý thuyết %+.1f dB)", after! - before!,
                                                                     20 * log10(max(0.001, changeTo! / volume))) : ""
                DebugLog.write(String(format: "Thử âm lượng: %@: đường %@, %@; trước khi kéo (%.2f, player %.2f) %@, sau khi kéo (%.2f, player %.2f) %@%@",
                                      label, path, onsetText, volume, playerBefore, db(before), changeTo!, playerAfter, db(after), delta))
                return after
            }
            let level = meter.mean(from: t0, to: tEnd)
            var rel = ""
            if let reference, let level {
                let want = 20 * log10(max(0.001, min(1, volume * plan.volume)))
                rel = String(format: ", so với 100%%: %+.1f dB (lý thuyết %+.1f dB)", level - reference, want)
            }
            DebugLog.write(String(format: "Thử âm lượng: %@: đường %@, âm lượng %.2f × câu %.2f, player %.2f, %@, mức %@%@",
                                  label, path, volume, plan.volume, sp.debugPlayerVolume, onsetText, db(level), rel))
            return level
        }

        reference = await run("Siri 100% (mốc)", volume: 1)
        _ = await run("Siri 100% lần hai", volume: 1)
        _ = await run("Tái hiện lỗi cũ: Siri 40% ép đọc thẳng", volume: 0.4, forceLive: true)
        _ = await run("Siri 40%", volume: 0.4)
        _ = await run("Siri 40% lần hai", volume: 0.4)
        _ = await run("Siri 70% (như máy người dùng)", volume: 0.7)
        _ = await run("Cảm xúc buồn (câu 0.85), âm lượng 60%", volume: 0.6, plan: VoicePlan(route: .siri, rate: 1, volume: 0.85))
        _ = await run("Kéo 80% xuống 30% giữa câu", volume: 0.8, changeTo: 0.3)
        _ = await run("Kéo 100% xuống 40% giữa câu (đang đọc thẳng)", volume: 1, changeTo: 0.4)
        let dub = VoicePlan(route: .siri, pitch: 3, rate: 1, volume: 1)
        reference = await run("Dub nhân vật cao độ +3, 100% (mốc)", volume: 1, plan: dub)
        _ = await run("Dub nhân vật cao độ +3, 50%", volume: 0.5, plan: dub)
        meter.stop()
    }

    // MARK: Giảm tiếng game

    /// Ghi diễn biến theo thời gian (mỗi 250 ms một mốc) của một câu câm: mức áp cho tiếng game và mức đo được.
    private static func duckRun(_ engine: Engine, label: String, decision: DuckDecision, meters: [AudioMeter],
                                applied: @escaping @MainActor () -> String) async {
        let sp = engine.speaker, s = engine.settings
        sp.duckDecider = { decision }
        s.duckEnabled = true
        s.duckLevel = 0.3
        s.speechVolume = 0   // câu câm: chỉ nghe (và đo) tiếng game
        try? await Task.sleep(for: .seconds(0.3))
        var marks: [String] = []
        let t0 = Date()
        var spoke: (Date, Date)?
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            let a = Date()
            sp.playNow(DubLine(text: testLine, language: s.target.speech), plan: VoicePlan(route: .siri))
            await waitSpeech(sp)
            spoke = (a, Date())
        }
        while Date().timeIntervalSince(t0) < 15, spoke == nil || Date().timeIntervalSince(spoke!.1) < 1.6 {
            let t = Date()
            try? await Task.sleep(for: .seconds(0.25))
            let levels = meters.map { "\($0.label) \(db($0.mean(from: t, to: Date())))" }.joined(separator: ", ")
            marks.append(String(format: "%.2fs%@ %@; %@", Date().timeIntervalSince(t0), sp.isSpeaking ? " (đang đọc)" : "", applied(), levels))
        }
        DebugLog.write("Thử giảm tiếng: \(label): chọn \(decision.label) vì \(decision.reason)")
        for m in marks { DebugLog.write("Thử giảm tiếng: \(label): \(m)") }
        if let (a, b) = spoke {
            for m in meters {
                let before = m.mean(from: t0, to: a), during = m.mean(from: a.addingTimeInterval(0.4), to: b), after = m.mean(from: b.addingTimeInterval(1.0), to: Date())
                let delta = (before != nil && during != nil) ? String(format: ", chênh %+.1f dB (lý thuyết %+.1f dB)", during! - before!, 20 * log10(0.3)) : ""
                DebugLog.write("Thử giảm tiếng: \(label), đo \(m.label): trước câu \(db(before)), trong câu \(db(during)), sau câu \(db(after))\(delta)")
            }
        }
    }

    private static func duckPlayTest(_ engine: Engine) async {
        let play = PlayScreen.shared
        if !play.isOpen { play.open() }
        var waited = 0.0
        while play.phase != .live, waited < 30 { try? await Task.sleep(for: .seconds(0.5)); waited += 0.5 }
        guard play.phase == .live, let w = play.window else {
            DebugLog.write("Thử giảm tiếng: Màn hình chơi game không có hình sau \(Int(waited)) giây (trạng thái \(play.phase))")
            return
        }
        try? await Task.sleep(for: .seconds(2))
        guard play.appliedVolume != nil else { DebugLog.write("Thử giảm tiếng: card không có tiếng, bỏ qua"); return }
        // Vùng phụ đề tạm ở phần ba dưới cửa sổ chơi; và lựa chọn theo vùng đã lưu của người dùng (chỉ đọc).
        let region = Self.region(over: w.frame, screen: w.screen)
        let decision = engine.duckDecision(region: region)
        DebugLog.write("Thử giảm tiếng: theo vùng đã lưu, chọn \(engine.duckDecision().label) vì \(engine.duckDecision().reason)")
        DebugLog.write("Thử giảm tiếng: tiến trình đang phát tiếng: \(playingProcesses())")
        guard let meter = await selfMeter() else { return }
        let global = AudioMeter(label: "cả hệ thống", processes: nil)
        await duckRun(engine, label: "Màn hình chơi game", decision: decision, meters: [meter] + [global].compactMap { $0 }) {
            String(format: "âm lượng phát %.2f", play.appliedVolume ?? -1)
        }
        meter.stop(); global?.stop()
    }

    private static func duckAppTest(_ engine: Engine, bundle: String) async {
        // Trình duyệt Chromium phát tiếng từ tiến trình con: ghi danh sách tiến trình có tiếng của Comet nếu đang mở (chỉ đọc).
        if let comet = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.perplexity.comet").first {
            let list = AudioDevices.processes(of: comet).map { "\($0.name) [\($0.pid)]\($0.playing ? " đang phát" : "")" }
            DebugLog.write("Thử giảm tiếng: Comet có \(list.count) tiến trình có tiếng: \(list.joined(separator: ", "))")
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            DebugLog.write("Thử giảm tiếng: không thấy app \(bundle) đang mở"); return
        }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        guard let info = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let dict = info[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: dict as CFDictionary),
              let screen = NSScreen.screens.first else {
            DebugLog.write("Thử giảm tiếng: không thấy cửa sổ của \(bundle)"); return
        }
        // Toạ độ CGWindowList gốc trên trái màn hình chính; đổi sang khung AppKit (gốc dưới trái).
        let frame = CGRect(x: b.minX, y: screen.frame.maxY - b.maxY, width: b.width, height: b.height)
        let region = Self.region(over: frame, screen: NSScreen.screens.first { $0.frame.intersects(frame) } ?? screen)
        let decision = engine.duckDecision(region: region)
        DebugLog.write("Thử giảm tiếng: hồ sơ đang ghi game \(engine.settings.gameAppName ?? "-"); vùng tạm đặt lên cửa sổ \(app.localizedName ?? bundle)")
        guard let meter = await selfMeter() else { return }
        let global = AudioMeter(label: "cả hệ thống", processes: nil)
        let ducker = engine.speaker.ducker
        await duckRun(engine, label: app.localizedName ?? bundle, decision: decision, meters: [meter] + [global].compactMap { $0 }) {
            String(format: "mức áp %.2f, OverSub phát lại %@", ducker.currentGain, db(ducker.takeOutputLevel()))
        }
        meter.stop(); global?.stop()
    }

    /// Tên các tiến trình đang phát tiếng (để biết tiếng card phát từ đâu).
    private static func playingProcesses() -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids.compactMap { obj -> String? in
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var on: UInt32 = 0, sz = UInt32(4)
            guard AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &on) == noErr, on != 0 else { return nil }
            a.mSelector = kAudioProcessPropertyPID
            var pid: pid_t = 0; sz = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &pid)
            return "\(AudioDevices.processName(pid)) [\(pid)]"
        }.joined(separator: ", ")
    }

    /// Vùng phụ đề tạm ở phần ba dưới một khung cửa sổ (toạ độ AppKit), như vùng người dùng hay chọn.
    private static func region(over f: CGRect, screen: NSScreen?) -> CaptureRegion? {
        guard let screen = screen ?? NSScreen.main, let id = displayIDOf(screen) else { return nil }
        let box = CGRect(x: f.minX + f.width * 0.15, y: f.minY + f.height * 0.05, width: f.width * 0.7, height: f.height * 0.2)
        return CaptureRegion(displayID: id, x: box.minX - screen.frame.minX, y: screen.frame.maxY - box.maxY,
                             w: box.width, h: box.height, sw: screen.frame.width, sh: screen.frame.height)
    }
}
#endif
