import AVFoundation
import AppKit
import AudioToolbox

/// Một câu cần lồng tiếng.
struct DubLine {
    var text: String
    var language: String          // mã giọng, vd. vi-VN
    var speaker: String?          // tên nhân vật hiện trên hộp thoại
    var boost: Double = 1         // đọc nhanh hơn để kịp thoại kế tiếp
    var created = Date()
    var force = false             // Đọc lại, Nghe thử: phát ngay, không bỏ vì cũ
    var group: ObjectIdentifier?  // các cụm của cùng một câu thoại (chữ chạy): đang chờ thì gộp lại đọc một lần cho liền mạch
}

/// Lồng tiếng theo hàng đợi: câu mới xếp sau câu đang đọc chứ không cắt ngang; câu kế tiếp được dựng sẵn trong lúc câu trước đang đọc.
/// Giọng Siri phát thẳng khi không cần hiệu ứng (nhanh nhất). Khi cần đổi cao độ, đổi loa, hoặc là giọng Apple khác hay Gemini,
/// âm thanh đi qua AVAudioEngine: đổi tốc độ không đổi cao độ, đổi cao độ không đổi tốc độ, chọn được loa riêng.
@MainActor
final class Speaker: NSObject, ObservableObject, NSSpeechSynthesizerDelegate {
    // MARK: Giọng Siri hệ thống

    nonisolated static let siriAutoID = "siri-auto"
    nonisolated static let defaultVoiceID = "com.apple.ttsbundle.gryphon-neural_vi-VN-A_vi-VN_premium"   // Siri Voice 1

    /// Giọng người dùng chọn cho một ngôn ngữ trong Read & Speak (kể cả giọng Siri), không phụ thuộc "System speech language".
    nonisolated static func selectedVoice(forLanguage base: String) -> String? {
        let domain = "com.apple.Accessibility" as CFString
        CFPreferencesAppSynchronize(domain)
        if let list = CFPreferencesCopyAppValue("SpokenContentDefaultVoiceSelectionsByLanguage" as CFString, domain) as? [Any] {
            for case let item as [String: Any] in list where (item["boundLanguage"] as? String) == base {
                if let id = item["voiceId"] as? String, !id.isEmpty { return id }
            }
        }
        return nil
    }

    nonisolated static func selectedVietnameseVoice() -> String { selectedVoice(forLanguage: "vi") ?? defaultVoiceID }

    /// Giọng Siri chỉ phát được khi tiến trình đang dùng đúng ngôn ngữ của giọng; nếu không macOS lặng lẽ đọc bằng giọng mặc định.
    /// Đặt ngôn ngữ riêng cho app (vùng argument domain, không ghi ra đĩa), không đụng cài đặt của cả máy.
    nonisolated static func setProcessLanguage(_ base: String) {
        var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        args["AppleLanguages"] = [base]
        UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    }

    nonisolated static func isNativeVoice(_ id: String) -> Bool { id == siriAutoID || id.hasPrefix("com.apple.ttsbundle.") }

    private func siriVoiceID(for language: String) -> String? {
        let base = String(language.split(separator: "-").first ?? "vi")
        return Speaker.selectedVoice(forLanguage: base) ?? (base == "vi" ? Speaker.defaultVoiceID : nil)
    }

    // MARK: Trạng thái cho giao diện

    @Published private(set) var isSpeaking = false
    @Published private(set) var speakingName: String?
    @Published private(set) var lastRoute: String = ""     // "Siri", "Gemini · Kore"... để hiện ở cửa sổ chính
    @Published private(set) var siriGender: [String: Gender] = [:]   // giới tính đo được của giọng Siri đang chọn, theo ngôn ngữ
    @Published private(set) var dubFallbacks = 0
    // Chữ sáng theo giọng đọc: câu đang đọc và số ký tự (UTF-16) đã đọc tới.
    // Đọc thẳng thì Siri báo từng từ; đọc qua AVAudioEngine thì ước theo thời lượng âm thanh.
    @Published private(set) var currentText: String?
    @Published private(set) var spokenEnd = 0
    private var karaokeTask: Task<Void, Never>?   // số câu lồng tiếng chưa kịp dựng, đã đọc bằng giọng thuyết minh

    var pendingCount: Int { queue.count + (current == nil ? 0 : 1) }

    // MARK: Hàng đợi

    private final class Job {
        let id = UUID()
        var line: DubLine
        var plan: VoicePlan
        var buffers: [AVAudioPCMBuffer] = []
        var rendered = false        // đã dựng xong toàn bộ âm thanh
        var failed = false
        var task: Task<Void, Never>?
        var scheduled = 0
        var played = 0
        var live = false            // Siri phát thẳng, không qua AVAudioEngine
        init(line: DubLine, plan: VoicePlan) { self.line = line; self.plan = plan }
        var needsEngine: Bool { !live }
    }

    private let settings: AppSettings
    private let tts: GeminiTTS
    let ducker = AudioDucker()
    private var queue: [Job] = []
    private var current: Job?
    private var live: NSSpeechSynthesizer?          // phát thẳng giọng Siri
    private var liveBaseRate: Float = 0
    private var renderer: NSSpeechSynthesizer?      // dựng giọng Siri ra tệp để đi qua AVAudioEngine
    private var rendererWaiter: CheckedContinuation<Void, Never>?
    private var renderBusy = false
    private var renderQueue: [CheckedContinuation<Void, Never>] = []
    private let avSynth = AVSpeechSynthesizer()
    private var token = 0                           // tăng mỗi lần dừng: kết quả của lượt cũ bị bỏ
    private var waitTimer: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: GeminiTTS.sampleRate, channels: 1)!
    private var engineDeviceUID: String?
    private var converters: [String: AVAudioConverter] = [:]

    init(settings: AppSettings, tts: GeminiTTS) {
        self.settings = settings
        self.tts = tts
        super.init()
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    }

    // MARK: API

    /// Xếp câu vào hàng đợi và bắt đầu dựng âm thanh ngay (dựng trước tối đa 2 câu).
    func speak(_ line: DubLine, plan: VoicePlan) {
        // Cụm sau của cùng một câu mà cụm trước còn đang chờ tới lượt (chưa đọc, chưa dựng): nối vào, đọc liền một lần.
        // Đọc từng cụm rời thì mỗi cụm ngắt giọng và có khoảng lặng khởi động ở đầu, nghe đứt quãng.
        if let g = line.group, let last = queue.last, last.line.group == g, last.task == nil, last.live, isLiveable(plan) {
            last.line.text += " " + line.text
            last.line.created = line.created   // tính độ trễ theo cụm mới nhất, không bị bỏ vì cụm đầu đã cũ
            return
        }
        let job = Job(line: line, plan: plan)
        job.live = isLiveable(plan)
        queue.append(job)
        prefetch()
        // Không dừng câu đang đọc để đọc nốt nhanh hơn: đo thực (06/10/2026), giọng Siri tiếng Việt báo vị trí từ không đáng tin
        // (có lúc báo trọn câu đầu ngay khi mới bắt đầu đọc) và dừng "ở cuối từ" hay "cuối câu" đều cắt ngay, nên đọc tiếp từ
        // vị trí được báo làm mất nguyên một đoạn. Câu chờ phía sau đã được đọc nhanh hơn theo độ dài hàng đợi (Engine.speechBoost).
        if current == nil { advance() }
    }

    /// Phát ngay (Nghe thử, Đọc lại): bỏ câu đang đọc và hàng đợi.
    func playNow(_ line: DubLine, plan: VoicePlan) {
        stop()
        var l = line; l.force = true
        speak(l, plan: plan)
    }

    func stop() {
        karaokeTask?.cancel()
        currentText = nil
        token += 1
        queue.forEach { $0.task?.cancel() }
        queue.removeAll()
        current?.task?.cancel()
        current = nil
        waitTimer?.cancel()
        if live?.isSpeaking == true { DebugLog.write("Giọng đọc: dừng giữa chừng") }
        live?.stopSpeaking()
        player.stop()
        setSpeaking(nil)
        scheduleRelease()
    }

    /// Sau khi đổi ngôn ngữ của tiến trình: tạo lại bộ đọc hệ thống để nó nhận ngôn ngữ mới.
    func resetSystemVoice() {
        stop()
        live = nil
        renderer = nil
    }

    // MARK: Dựng âm thanh

    private func prefetch() {
        let rendering = ([current].compactMap { $0 } + queue).filter { $0.task != nil && !$0.rendered && $0.needsEngine }.count
        var slots = max(0, 2 - rendering)
        for job in queue where slots > 0 && job.task == nil && job.needsEngine && !job.failed {
            startRender(job)
            slots -= 1
        }
    }

    private func startRender(_ job: Job) {
        let t = token
        job.task = Task { [weak self] in
            guard let self else { return }
            do {
                switch job.plan.route {
                case .siri:
                    // Dựng từng đoạn ngắn: đoạn đầu (một vế câu) xong sau khoảng nửa giây là phát ngay, các đoạn sau dựng tiếp
                    // trong lúc đang phát. Dựng cả câu dài một lần thì phải chờ 1,5 đến 2,5 giây mới có tiếng.
                    for piece in Self.renderPieces(job.line.text) {
                        var l = job.line
                        l.text = piece
                        let b = try await self.renderSiri(l)
                        guard t == self.token, !Task.isCancelled else { return }
                        self.append(b, to: job)
                    }
                case .apple(let id):
                    let bufs = try await self.renderApple(job.line, voiceID: id)
                    guard t == self.token, !Task.isCancelled else { return }
                    bufs.forEach { self.append($0, to: job) }
                case .gemini(let voice):
                    for try await chunk in self.tts.stream(text: job.line.text, voice: voice, style: job.plan.style) {
                        guard t == self.token, !Task.isCancelled else { return }
                        if let b = self.pcm16Buffer(chunk) { self.append(b, to: job) }
                    }
                }
                guard t == self.token, !Task.isCancelled else { return }
                job.rendered = true
                self.renderFinished(job)
            } catch {
                guard t == self.token, !Task.isCancelled else { return }
                DebugLog.write("Lồng tiếng: dựng giọng lỗi (\((error as? GeminiTTS.TTSError)?.message ?? error.localizedDescription)), đổi sang giọng dự phòng")
                self.fallback(job)
            }
        }
    }

    /// Chia câu thành đoạn để dựng dần: đoạn đầu ngắn (từ 24 ký tự, cắt ở dấu câu) để có tiếng sớm, các đoạn sau dài hơn
    /// (từ 70 ký tự, ưu tiên cắt ở cuối câu) để ngữ điệu liền mạch.
    static func renderPieces(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count > 60 else { return [text] }
        var out: [String] = [], start = 0, i = 0
        while i < chars.count {
            let c = chars[i]
            let len = i - start + 1
            let atSpace = i + 1 >= chars.count || chars[i + 1] == " "
            let strong = ".!?…".contains(c), weak = ",;:–—".contains(c)
            let minLen = out.isEmpty ? 24 : 70
            // Đoạn đầu: câu dài mà mãi không có dấu câu thì cắt ở khoảng trắng quanh ký tự thứ 40, để có tiếng sau khoảng
            // 0,7 giây thay vì hơn 1,2 giây.
            let forceFirst = out.isEmpty && len >= 40 && chars.count > 90
            if atSpace, len >= minLen, strong || (weak && (out.isEmpty || len >= 110)) || forceFirst {
                out.append(String(chars[start...i]).trimmingCharacters(in: .whitespaces))
                start = i + 1
            }
            i += 1
        }
        if start < chars.count {
            let rest = String(chars[start...]).trimmingCharacters(in: .whitespaces)
            // Đuôi quá ngắn thì gộp vào đoạn trước cho khỏi ngắt hơi vô lý.
            if rest.count < 12, let last = out.popLast() { out.append(last + " " + rest) } else if !rest.isEmpty { out.append(rest) }
        }
        return out.isEmpty ? [text] : out
    }

    /// Gemini lỗi, hết lượt hoặc chậm quá: đọc câu đó bằng giọng Apple.
    private func fallback(_ job: Job) {
        job.task?.cancel()
        let wasPlaying = current === job && job.scheduled > 0
        guard !wasPlaying else { job.rendered = true; renderFinished(job); return }   // đã đọc được một phần thì thôi
        job.buffers.removeAll()
        job.plan.route = job.plan.fallback
        job.plan.style = nil
        job.task = nil
        job.live = isLiveable(job.plan)
        if job.needsEngine {
            startRender(job)
        } else if current === job {
            playLive(job)
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, to job: Job) {
        guard let b = convert(buffer) else { return }
        job.buffers.append(b)
        if current === job, isEngineJobPlaying { schedule(b, for: job) }
        else if current === job { beginEnginePlayback(job) }
    }

    private func renderFinished(_ job: Job) {
        prefetch()
        if current === job { checkJobDone(job) }
    }

    private func renderSiri(_ line: DubLine) async throws -> AVAudioPCMBuffer {
        // Bộ dựng tệp chỉ chạy từng câu một.
        if renderBusy { await withCheckedContinuation { renderQueue.append($0) } }
        renderBusy = true
        defer {
            renderBusy = false
            if !renderQueue.isEmpty { renderQueue.removeFirst().resume() }
        }
        if renderer == nil { renderer = NSSpeechSynthesizer(voice: nil); renderer?.delegate = self }
        guard let r = renderer else { throw AppError(L("Không tạo được bộ đọc", "Couldn't create the speech synthesizer")) }
        if let id = siriVoiceID(for: line.language) { r.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: id)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oversub-\(UUID().uuidString).aiff")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            rendererWaiter = c
            if !r.startSpeaking(line.text, to: url) { rendererWaiter = nil; c.resume() }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AppError(L("Không đọc được âm thanh", "Couldn't read the audio"))
        }
        try file.read(into: buf)
        return buf
    }

    private func renderApple(_ line: DubLine, voiceID: String) async throws -> [AVAudioPCMBuffer] {
        let u = AVSpeechUtterance(string: line.text)
        u.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? AVSpeechSynthesisVoice(language: line.language)
        let synth = avSynth
        return await withCheckedContinuation { (c: CheckedContinuation<[AVAudioPCMBuffer], Never>) in
            final class Box: @unchecked Sendable { var list: [AVAudioPCMBuffer] = []; var done = false }
            let box = Box()
            synth.write(u) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, !box.done else { return }
                if pcm.frameLength == 0 { box.done = true; c.resume(returning: box.list) } else { box.list.append(pcm) }
            }
        }
    }

    private func pcm16Buffer(_ data: Data) -> AVAudioPCMBuffer? {
        let frames = data.count / 2
        guard frames > 0, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        b.frameLength = AVAudioFrameCount(frames)
        let out = b.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        return b
    }

    /// Đưa mọi âm thanh về một định dạng (24 kHz, mono, float) để dùng chung một đường phát.
    private func convert(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if b.format == format { return b }
        let key = "\(b.format.sampleRate)-\(b.format.channelCount)-\(b.format.commonFormat.rawValue)-\(b.format.isInterleaved)"
        let conv = converters[key] ?? AVAudioConverter(from: b.format, to: format)
        converters[key] = conv
        guard let conv else { return nil }
        let cap = AVAudioFrameCount(Double(b.frameLength) * format.sampleRate / b.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return b
        }
        conv.reset()
        return err == nil ? out : nil
    }

    // MARK: Phát

    private var isEngineJobPlaying = false
    private var lastGroup: ObjectIdentifier?   // nhóm (câu) của đoạn vừa đọc

    private func advance() {
        guard current == nil else { return }
        guard !queue.isEmpty else { setSpeaking(nil); currentText = nil; scheduleRelease(); scheduleIdleStop(); return }
        let job = queue.removeFirst()
        // Câu đã quá cũ mà còn câu mới hơn đang chờ: bỏ, để giọng không trễ xa so với màn hình. Phần nối tiếp của câu vừa đọc
        // (cùng nhóm, đọc trước phần đầu khi phần sau dịch chậm) thì không bỏ, không thì câu bị cụt giữa chừng.
        let continuing = job.line.group != nil && job.line.group == lastGroup
        if settings.dropStaleLines, !job.line.force, !continuing, !queue.isEmpty, Date().timeIntervalSince(job.line.created) > 6 {
            job.task?.cancel()
            DebugLog.write("Lồng tiếng: bỏ câu đã trễ \(Int(Date().timeIntervalSince(job.line.created))) giây: \(job.line.text.prefix(40))")
            advance()
            return
        }
        current = job
        lastGroup = job.line.group
        isEngineJobPlaying = false
        setSpeaking(job.line.speaker ?? "")
        duck(true)
        if job.live {
            playLive(job)
            return
        }
        if job.task == nil, !job.rendered { startRender(job) }
        if !job.buffers.isEmpty { beginEnginePlayback(job) }
        armRenderWait(job)
        prefetch()
    }

    /// Giọng Siri phát thẳng khi không cần đổi cao độ và không chọn loa riêng: nhanh hơn dựng ra tệp.
    private func isLiveable(_ plan: VoicePlan) -> Bool {
        guard case .siri = plan.route else { return false }
        return abs(plan.pitch) < 0.25 && settings.dubDeviceUID.isEmpty
    }

    private func playLive(_ job: Job) {
        if live == nil, let s = NSSpeechSynthesizer(voice: nil) {
            s.delegate = self
            liveBaseRate = s.rate
            live = s
        }
        guard let s = live else { finishCurrent(); return }
        if let id = siriVoiceID(for: job.line.language) { s.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: id)) }
        let rate = settings.autoSpeechRate ? 1 : settings.speechRate / 0.5
        s.rate = liveBaseRate * Float(rate * job.plan.rate * job.line.boost)
        s.volume = Float(min(1, settings.speechVolume * job.plan.volume))
        lastRoute = "Siri"
        currentText = job.line.text
        spokenEnd = 0
        karaokeTask?.cancel()
        if !s.startSpeaking(job.line.text) { finishCurrent(); return }
        logStart(job)
    }

    /// Giọng nhân vật (lồng tiếng) chưa dựng kịp khi tới lượt: đọc ngay bằng giọng thuyết minh, ưu tiên không để người chơi chờ.
    /// Gemini được chờ lâu hơn (theo cài đặt); giọng Apple chỉ chờ 1 giây.
    private func armRenderWait(_ job: Job) {
        waitTimer?.cancel()
        guard job.buffers.isEmpty else { return }
        let isGemini: Bool
        if case .gemini = job.plan.route { isGemini = true } else { isGemini = false }
        // Thuyết minh qua loa riêng (không phải giọng nhân vật) thì không đổi sang đọc thẳng, vì đọc thẳng không chọn được loa.
        let isCharacterVoice: Bool
        if case .siri = job.plan.route { isCharacterVoice = abs(job.plan.pitch) >= 0.25 } else { isCharacterVoice = true }
        guard isGemini || isCharacterVoice else { return }
        let limit = isGemini ? max(1, settings.geminiMaxWait - Date().timeIntervalSince(job.line.created)) : 1.6   // đoạn đầu thường dựng xong trong nửa giây; chờ thêm chút để giữ đúng giọng nhân vật
        waitTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard let self, !Task.isCancelled, self.current === job, job.scheduled == 0 else { return }
            DebugLog.write("Lồng tiếng: giọng nhân vật chưa kịp dựng sau \(String(format: "%.1f", limit)) giây, đọc bằng giọng thuyết minh")
            self.dubFallbacks += 1
            self.fallbackToVoiceOver(job)
        }
    }

    private func fallbackToVoiceOver(_ job: Job) {
        job.task?.cancel()
        job.task = nil
        job.buffers.removeAll()
        job.plan = VoicePlan(route: .siri, rate: job.plan.rate, volume: job.plan.volume)
        job.live = isLiveable(job.plan)
        if job.live { playLive(job) } else { startRender(job) }
    }

    private func beginEnginePlayback(_ job: Job) {
        guard current === job, !isEngineJobPlaying else { return }
        guard startEngine() else { finishCurrent(); return }
        let rate = settings.autoSpeechRate ? 1 : settings.speechRate / 0.5
        timePitch.rate = Float(max(0.5, min(2.2, rate * job.plan.rate * job.line.boost)))
        timePitch.pitch = Float(job.plan.pitch * 100)
        player.volume = Float(min(1, settings.speechVolume * job.plan.volume))
        isEngineJobPlaying = true
        switch job.plan.route {
        case .siri: lastRoute = job.plan.pitch == 0 ? "Siri" : String(format: "Siri %+.0f", job.plan.pitch)
        case .apple(let id): lastRoute = AVSpeechSynthesisVoice(identifier: id)?.name ?? "Apple"
        case .gemini(let v): lastRoute = "Gemini · \(v)"
        }
        job.buffers.forEach { schedule($0, for: job) }
        if !player.isPlaying { player.play() }
        logStart(job)
        startEstimatedKaraoke(job)
    }

    private func schedule(_ b: AVAudioPCMBuffer, for job: Job) {
        job.scheduled += 1
        let id = job.id
        player.scheduleBuffer(b, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(id) }
        }
    }

    private func bufferPlayed(_ id: UUID) {
        guard let job = current, job.id == id else { return }
        job.played += 1
        checkJobDone(job)
    }

    private func checkJobDone(_ job: Job) {
        guard current === job, job.rendered, job.played >= job.scheduled, isEngineJobPlaying || job.buffers.isEmpty else { return }
        finishCurrent()
    }

    /// Không có báo từng từ: ước vị trí đọc theo thời gian đã phát trên tổng thời lượng âm thanh đã dựng.
    private func startEstimatedKaraoke(_ job: Job) {
        currentText = job.line.text
        spokenEnd = 0
        karaokeTask?.cancel()
        let started = Date()
        let total = (job.line.text as NSString).length
        karaokeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.current === job else { return }
                let frames = job.buffers.reduce(0.0) { $0 + Double($1.frameLength) }
                let duration = frames / GeminiTTS.sampleRate / Double(max(0.1, self.timePitch.rate))
                guard duration > 0 else { continue }
                let progress = min(1, Date().timeIntervalSince(started) / duration)
                self.spokenEnd = Int(Double(total) * progress)
            }
        }
    }

    /// Thử nghiệm: đổi tốc độ khi giọng đọc thẳng đang nói dở.
    func debugScaleLiveRate(_ k: Float) { if let s = live { s.rate = s.rate * k } }

    private func logStart(_ job: Job) {
        // Ghi cả hệ số tốc độ (cảm xúc × đuổi kịp) để nhật ký cho thấy câu nào bị đọc chậm hay nhanh hơn bình thường.
        DebugLog.write(String(format: "Lồng tiếng: đọc [%@ ×%.2f] sau %.0f ms: %@", lastRoute, job.plan.rate * job.line.boost,
                              Date().timeIntervalSince(job.line.created) * 1000, String(job.line.text.prefix(50))))
    }

    private func finishCurrent() {
        karaokeTask?.cancel()
        if let t = currentText { spokenEnd = (t as NSString).length }
        if let job = current {
            DebugLog.write(String(format: "Lồng tiếng: xong sau %.1f s", Date().timeIntervalSince(job.line.created)))
        }
        waitTimer?.cancel()
        current = nil
        isEngineJobPlaying = false
        advance()
    }

    private func startEngine() -> Bool {
        let wanted = settings.dubDeviceUID
        if engine.isRunning, engineDeviceUID == wanted { return true }
        engine.stop()
        if let unit = engine.outputNode.audioUnit {
            var dev = wanted.isEmpty ? (AudioDevices.defaultOutput() ?? 0) : (AudioDevices.id(forUID: wanted) ?? AudioDevices.defaultOutput() ?? 0)
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioObjectID>.size))
        }
        do {
            try engine.start()
            engineDeviceUID = wanted
            return true
        } catch {
            DebugLog.write("Lồng tiếng: không mở được đường phát âm thanh: \(error.localizedDescription)")
            return false
        }
    }

    /// Tắt đường phát sau một lúc im lặng để loa được nghỉ.
    private func scheduleIdleStop() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled, self.current == nil, self.queue.isEmpty else { return }
            self.player.stop()
            self.engine.stop()
            self.engineDeviceUID = nil
        }
    }

    private func setSpeaking(_ name: String?) {
        isSpeaking = name != nil
        speakingName = (name?.isEmpty ?? true) ? nil : name
    }

    #if DEVTOOLS
    /// Chỉ để chụp giao diện lúc đang đọc mà không phát tiếng thật.
    func debugSetSpeaking(_ name: String?) { setSpeaking(name) }
    #endif

    // MARK: Giảm tiếng game

    private func duck(_ on: Bool) {
        releaseTask?.cancel()
        guard settings.duckEnabled else { if ducker.isActive { ducker.detach() }; return }
        if on {
            // Tiếng của màn hình chơi game do chính OverSub phát: giảm thẳng âm lượng của nó, không chặn tiếng bằng tap.
            PlayScreen.shared.duck(settings.duckLevel)
            guard settings.gameBundleID != PlayScreen.gameID else { return }
            if ducker.attach(bundleID: settings.gameBundleID) { ducker.setLevel(settings.duckLevel) }
        }
    }

    /// Đọc xong một lúc mới trả tiếng game, tránh tiếng game bật lên rồi lại nhỏ xuống giữa hai câu liền nhau.
    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled, self.current == nil else { return }
            self.ducker.setLevel(1)
            PlayScreen.shared.duck(1)
        }
    }

    /// Tắt hẳn việc chặn tiếng game (tắt tính năng, dừng dịch, thoát app).
    func releaseGameAudio() {
        ducker.detach()
        PlayScreen.shared.duck(1)
    }

    /// Khởi động sẵn bộ đọc Siri (dựng một chữ ra tệp, không phát ra loa): câu thuyết minh đầu tiên đọc ngay thay vì chậm gần 1 giây.
    func warmUp(language: String) {
        Task { [weak self] in
            guard let self else { return }
            let t = Date()
            _ = try? await self.renderSiri(DubLine(text: "Xin chào.", language: language))
            if self.live == nil, let s = NSSpeechSynthesizer(voice: nil) {
                s.delegate = self
                self.liveBaseRate = s.rate
                self.live = s
            }
            if let id = self.siriVoiceID(for: language) { self.live?.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: id)) }
            DebugLog.write(String(format: "Thuyết minh: khởi động sẵn giọng Siri mất %.0f ms", Date().timeIntervalSince(t) * 1000))
        }
    }

    // MARK: Giới tính giọng Siri

    /// Đo cao độ giọng Siri đang chọn cho một ngôn ngữ (một câu ngắn dựng ra tệp), để gán đúng giọng cho nhân vật nam hay nữ.
    func probeSiriGender(language: String) {
        let base = String(language.split(separator: "-").first ?? "vi")
        guard let id = siriVoiceID(for: language) else { siriGender[base] = .unknown; return }
        let key = "siriGender.\(id)"
        if let saved = UserDefaults.standard.string(forKey: key).flatMap(Gender.init(rawValue:)) { siriGender[base] = saved; return }
        Task { [weak self] in
            guard let self else { return }
            let sample = ["vi": "Xin chào, rất vui được gặp bạn.", "ja": "こんにちは、はじめまして。", "zh": "你好，很高兴认识你。"][base] ?? "Hello, nice to meet you."
            guard let b = try? await self.renderSiri(DubLine(text: sample, language: language)) else { return }
            let f0 = Self.medianPitch(b)
            let g: Gender = f0 == 0 ? .unknown : (f0 < 165 ? .male : .female)
            UserDefaults.standard.set(g.rawValue, forKey: key)
            self.siriGender[base] = g
            DebugLog.write(String(format: "Giọng Siri (%@): cao độ %.0f Hz → %@", base, f0, g.title))
        }
    }

    nonisolated private static func medianPitch(_ buf: AVAudioPCMBuffer) -> Double {
        guard let x = buf.floatChannelData?[0] else { return 0 }
        let sr = buf.format.sampleRate, n = Int(buf.frameLength), win = Int(sr * 0.04)
        var est: [Double] = []
        var i = 0
        while i + win * 2 < n {
            var energy: Float = 0
            for k in 0..<win { energy += x[i + k] * x[i + k] }
            if energy / Float(win) > 1e-4 {
                var best: Float = 0, lagBest = 0
                for lag in Int(sr / 400)...Int(sr / 70) {
                    var c: Float = 0
                    for k in 0..<win { c += x[i + k] * x[i + k + lag] }
                    if c > best { best = c; lagBest = lag }
                }
                if lagBest > 0 { est.append(sr / Double(lagBest)) }
            }
            i += win
        }
        est.sort()
        return est.isEmpty ? 0 : est[est.count / 2]
    }

    // MARK: Báo đọc xong

    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakWord characterRange: NSRange, of string: String) {
        let id = ObjectIdentifier(sender)
        let end = characterRange.location + characterRange.length
        Task { @MainActor in
            guard let l = self.live, ObjectIdentifier(l) == id else { return }
            self.spokenEnd = end
        }
    }

    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        let id = ObjectIdentifier(sender)
        Task { @MainActor in
            if let r = self.renderer, ObjectIdentifier(r) == id {
                let w = self.rendererWaiter; self.rendererWaiter = nil; w?.resume()
                return
            }
            guard finishedSpeaking, let job = self.current, !job.needsEngine, !self.isEngineJobPlaying else { return }
            self.finishCurrent()
        }
    }
}
