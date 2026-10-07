import AppKit
import Combine
import SwiftUI

@MainActor
final class Engine: ObservableObject {
    let settings: AppSettings
    let hub: TranslationHub
    @Published var running = false
    @Published var status = L("Bấm Chọn vùng phụ đề để bắt đầu.", "Click Select subtitle region to get started.")
    @Published var lastSource = ""
    @Published var lastTranslation = ""
    // Dùng @Published thay cho @State: SDK mới biến @State thành macro, mà Command Line Tools không có plugin SwiftUIMacros.
    @Published var showHistory = false   // bảng lịch sử thoại bên phải cửa sổ
    @Published var transcript: [TranscriptItem] = []   // các câu đã dịch gần đây, để xem lại khi lỡ đọc không kịp
    @Published var problem: String?      // lỗi cần người dùng xử lý (quyền, key...)
    @Published var demoActive = false    // đang hiện phụ đề mẫu
    @Published var showTermPicker = false   // cửa sổ gợi ý tên riêng từ câu đang hiện
    @Published var requestedSettingsPage: SettingsPage?   // mở Cài đặt ở đúng trang (vd. Quản lý preset)
    @Published var requestedPresetDetail: UUID?            // mở thẳng trang chi tiết một preset
    @Published var gameInFront = true      // game có đang ở phía trước không (chuyển sang app khác thì tạm ngưng đọc)
    @Published var contextCount = 0      // số câu đang nhớ làm ngữ cảnh xưng hô
    @Published var lastSpeaker: String?  // tên người nói đọc được từ nhãn tên trên hộp thoại
    @Published private(set) var recentNames: [Bool] = []   // 12 câu gần nhất có nhãn tên người nói không (cho hướng dẫn lồng tiếng)

    private let grabber = ScreenGrabber()
    let tts: GeminiTTS
    let speaker: Speaker
    let editor = RegionEditor()
    private let overlay: OverlayController
    // Dịch màn hình: tính năng riêng, tách khỏi phụ đề lời thoại. Mỗi vùng một trạng thái và một lớp dịch đè tại chỗ.
    // (Vùng lưu ở settings.secondaryRegions, giữ tên cũ để không mất vùng đã lưu.)
    @Published private(set) var screenTranslateOn = false
    /// Trạng thái một vùng dịch màn hình. Nhận biết chữ đổi bằng chữ đọc nhanh (không theo điểm ảnh), vì menu game hay có
    /// hiệu ứng động (lấp lánh, nền sau chuyển động) làm khung hình đổi liên tục dù chữ vẫn y nguyên.
    private struct ScreenRegionState {
        var lastQuick = ""        // chữ đọc nhanh ở lần quét trước
        var sameCount = 0         // số lần quét liên tiếp chữ gần như không đổi
        var offCount = 0          // số lần quét liên tiếp chữ khác hẳn bản đang hiện (đủ 2 mới gỡ, để khỏi chớp)
        var emptyCount = 0        // số lần quét liên tiếp không thấy chữ
        var shownQuick = ""       // chữ đọc nhanh ứng với bản dịch đang hiện (hoặc đang dịch)
        var shownSig: [UInt8]?    // dấu vân tay khung hình lúc hiện bản dịch, để phân biệt Vision đọc trượt với menu đã đóng
        var shown = ""            // chữ gốc (chuẩn hoá) đang được dịch hoặc đang hiện
        var lastScan = Date.distantPast
        var token = 0             // lần dịch mới nhất; bản dịch về muộn của chữ cũ thì bỏ
        var blocks: [ScreenBlock] = []   // các cụm chữ đang hiện, để dựng lại nền khi vệt chọn di chuyển
        var vis: [String?] = []          // bản dịch từng cụm đang hiện
        var rings: [[Double]] = []       // màu viền quanh từng cụm lúc dựng nền
        var zones: [CGRect] = []         // vùng xoá chữ của từng cụm (để đo lại màu viền, không phải tính lại bố cục)
        var failedAt: Date?              // lần dịch AI lỗi gần nhất, để thử lại sau vài giây
        var refObs: [OCR.QuickObs] = []  // vị trí các mẩu chữ (đọc nhanh) lúc đặt bản dịch, để biết chữ có di chuyển không
        var prevObs: [OCR.QuickObs] = [] // vị trí ở lần quét trước, để biết chữ đã dừng chưa
        var moving = false               // chữ đang di chuyển (cuộn danh sách, bảng trượt): bản dịch tạm ẩn, dừng thì đặt lại
    }
    private var secStates: [ScreenRegionState] = []
    private var secOverlays: [OverlayController] = []
    private var secCursor = 0
    private var secBusy = false
    private var screenLoop: Task<Void, Never>?
    /// Chữ giao diện rất ngắn ("Yes", "No", "Map") không vào trí nhớ dịch lâu dài (dễ nhầm với lời thoại): nhớ trong phiên.
    private var uiShortCache: [String: String] = [:]
    private var screenGameInFront = true
    private var lastScreenError = Date.distantPast
    private var mainBusy = false
    let memory: TranslationMemory
    let gamepad = GamepadControl()
    private var loop: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    // Các câu gần nhất làm ngữ cảnh; tự lưu theo preset đang dùng (ContextStore), dùng lại preset nào thì nối tiếp ngữ cảnh đó.
    private var history: [ContextLine] = [] {
        didSet {
            contextCount = history.count
            if let id = settings.activePresetID { ContextStore.set(history, for: id, target: settings.targetLanguage) }
        }
    }
    private var classifying: Set<String> = []   // nhân vật đang được hỏi AI giới tính, tuổi
    private var lastDialogueAt: Date?       // lần dịch lời thoại gần nhất; im lặng quá lâu thì quên ngữ cảnh cũ
    private var lastLineTexts: [String] = []   // các dòng OCR của lời thoại, để nhận ra danh sách menu
    private var cache: [String: String] = [:]      // câu đã dịch, gặp lại thì dùng luôn
    private var shown = ""          // câu (đã chuẩn hoá) đang hiển thị
    private var pending = ""        // câu mới (đã chuẩn hoá), chờ khung hình đứng yên để xác nhận
    private var pendingRaw = ""
    private var speakerMisses = 0         // số lần đọc liên tiếp không thấy nhãn tên
    private var knownSpeakers: [String] = []   // tên người nói đã nhận được gần đây (để nhận ra khi tên bị dính vào câu)
    private var awakeToken: NSObjectProtocol?   // đang giữ màn hình sáng (bỏ khi dừng hay tắt tuỳ chọn)
    private var behindNote: String?   // trạng thái game sau app khác đã ghi nhật ký gần nhất (để chỉ ghi khi đổi)
    private var recentDubs: [SpokenLine] = []   // các câu vừa đọc, để không đọc lại cùng một câu
    private struct SpokenLine { var norm: String; var source: String; var speaker: String; var at: Date }
    private var quickSawNothing = false   // lần quét này bộ đọc nhanh cũng không thấy chữ
    private var pendingSame = 0     // chế độ đợi đủ câu: số lần đọc liên tiếp ra cùng chữ
    private var progSame = 0        // chữ chạy: số lần đọc liên tiếp chữ không dài thêm
    private var progLastNorm = ""
    private var lastSignature: [UInt8]?
    private var lastOCREmpty = false
    // Chế độ "Dịch dần": phần chữ gốc đã dịch, bản dịch đã ghép, và lần OCR mới nhất.
    private var progNorm = ""
    private var progRaw = ""
    private var progLatestRaw = ""
    private var progLine = ProgLine()     // câu đang dịch dần: bản dịch đã ghép, các cụm đang dịch, phần chờ đọc
    private var progInFlight = 0          // số cụm đang chờ AI dịch
    private var emptyReads = 0      // số lần đọc liên tiếp không thấy phụ đề, đủ 2 thì ẩn bản dịch
    private var presentSignature: [UInt8]?   // dấu vân tay khung hình lúc phụ đề còn hiện, để biết khi nào cảnh đã đổi hẳn
    private var fastRecheck = false          // vừa thấy trống một lần: kiểm tra lại ngay thay vì chờ hết nhịp quét
    private var lastFit: TextFit?   // vị trí, cỡ chữ, màu của phụ đề gốc ở lần OCR gần nhất
    private var fontSamples: [CGFloat] = []   // cỡ chữ thoại ước được ở các câu gần đây
    private var lastQuick: String?      // chữ đọc nhanh ứng với lần đọc kỹ gần nhất
    private var lastAccurate: OCRResult?
    private(set) var ocrSaved = 0       // số lần bỏ qua đọc kỹ nhờ đọc nhanh thấy chữ không đổi
    private var idleTicks = 0
    private var stableTicks = 0

    // Để tự cân tốc độ đọc theo nhịp thoại.
    private var lastConfirmAt: Date?
    private var gapEMA = 4.0
    private var demoToken = 0

    init(settings: AppSettings, hub: TranslationHub) {
        self.settings = settings
        self.hub = hub
        self.overlay = OverlayController(settings: settings)
        self.memory = TranslationMemory(settings: settings)
        let tts = GeminiTTS(hub: hub, settings: settings)
        self.tts = tts
        self.speaker = Speaker(settings: settings, tts: tts)
        if settings.region != nil { status = L("Sẵn sàng. Bấm Bắt đầu.", "Ready. Click Start.") }
        if let id = settings.activePresetID { history = ContextStore.lines(for: id, target: settings.targetLanguage) }
        speaker.probeSiriGender(language: settings.target.speech)
        speaker.warmUp(language: settings.target.speech)
        speaker.$siriGender.removeDuplicates().sink { [weak self] _ in self?.reassignCast() }.store(in: &bag)
        settings.$outputMode.dropFirst().removeDuplicates().sink { [weak self] mode in
            guard let self else { return }
            if !mode.showsSubtitles { self.overlay.hide(); self.grabber.invalidate() }
            if !mode.speaks { self.speaker.stop() }
        }.store(in: &bag)
        settings.$duckEnabled.dropFirst().sink { [weak self] on in if !on { self?.speaker.releaseGameAudio() } }.store(in: &bag)
        // Tự lưu: mọi thay đổi cài đặt (kể cả dàn diễn viên, thuật ngữ) ghi vào hồ sơ đang dùng sau nửa giây.
        settings.objectWillChange.debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.settings.syncActiveProfile() }.store(in: &bag)
        // Tự chuyển hồ sơ theo game vừa được đưa ra phía trước.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier }
            .sink { [weak self] bundle in self?.autoSwitchProfile(for: bundle) }.store(in: &bag)
        settings.$overlayEnabled.sink { [weak self] on in
            if !on { self?.overlay.hide(); self?.grabber.invalidate() }
        }.store(in: &bag)
        Publishers.CombineLatest4(settings.$overlayDX, settings.$overlayDY, settings.$overlayWidthPct, settings.$overlayFit)
            .dropFirst()
            .sink { [weak self] _ in self?.overlay.reposition() }
            .store(in: &bag)
        // Đổi ngôn ngữ đích: đặt lại ngôn ngữ tiến trình cho giọng Siri, quên bản dịch cũ, khởi động sẵn engine Apple cho ngôn ngữ mới.
        settings.$targetLanguage.dropFirst().removeDuplicates().sink { [weak self] code in
            guard let self else { return }
            Speaker.setProcessLanguage(TargetLanguage.find(code).base)
            self.speaker.resetSystemVoice()
            self.speaker.probeSiriGender(language: TargetLanguage.find(code).speech)
            self.speaker.warmUp(language: TargetLanguage.find(code).speech)
            self.resetState()
            // Ngữ cảnh lưu kèm ngôn ngữ dịch: đổi ngôn ngữ thì nối tiếp ngữ cảnh của ngôn ngữ đó (thường là trống).
            if let id = self.settings.activePresetID { self.history = ContextStore.lines(for: id, target: code) }
            self.hub.warmUp()
            DebugLog.write("Đổi ngôn ngữ đích sang \(code)")
        }.store(in: &bag)
        hub.warmUp()
        settings.$globalHotkeys.removeDuplicates().sink { [weak self] on in self?.setHotkeys(on) }.store(in: &bag)
        // Giữ màn hình sáng trong lúc chạy: chơi bằng tay cầm thì Mac không nhận thao tác, tự tắt màn hình hay khoá máy giữa chừng.
        Publishers.CombineLatest3(settings.$keepScreenAwake, $running, $screenTranslateOn)
            .map { keep, running, screen in keep && (running || screen) }
            .removeDuplicates()
            .sink { [weak self] want in self?.setKeepAwake(want) }
            .store(in: &bag)
        gamepad.onReplay = { [weak self] in self?.replayLast() }
        gamepad.onToggleVoice = { [weak self] in self?.toggleDub() }
        gamepad.onToggleSubtitles = { [weak self] in self?.toggleOverlay() }
        settings.$gamepadControls.removeDuplicates().sink { [weak self] on in self?.gamepad.setEnabled(on) }.store(in: &bag)
        settings.$screenTranslateEnabled.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyScreenTranslateSetting() }
        }.store(in: &bag)
    }

    /// Phím tắt dùng được cả khi đang chơi game toàn màn hình, không cần chuyển sang app.
    private func setHotkeys(_ on: Bool) {
        HotkeyCenter.shared.unregisterAll()
        guard on else { return }
        HotkeyCenter.shared.register(.toggleRunning) { [weak self] in self?.toggleRunning() }
        HotkeyCenter.shared.register(.toggleOverlay) { [weak self] in self?.toggleOverlay() }
        HotkeyCenter.shared.register(.selectRegion) { [weak self] in self?.selectRegion() }
        HotkeyCenter.shared.register(.toggleDub) { [weak self] in self?.toggleDub() }
        HotkeyCenter.shared.register(.replayLast) { [weak self] in self?.replayLast() }
        HotkeyCenter.shared.register(.screenTranslate) { [weak self] in self?.toggleScreenTranslate() }
        HotkeyCenter.shared.register(.quickTranslate) { [weak self] in self?.quickTranslate() }
        HotkeyCenter.shared.register(.history) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.showHistory.toggle()
        }
    }

    // MARK: Điều khiển

    /// Mở trình chọn vùng gộp (khung phụ đề và các vùng dịch màn hình, dừng hình, xem lại một lần).
    /// `screen`: mở từ "Thêm dịch màn hình", kéo chỗ trống là thêm vùng dịch màn hình; Lưu & bắt đầu thì bật dịch màn hình.
    func selectRegion(screen: Bool = false) {
        guard !editor.isOpen else { return }
        status = screen ? L("Đang chọn vùng dịch màn hình…", "Selecting screen region…") : L("Đang chọn vùng phụ đề…", "Selecting subtitle region…")
        prepareEditor()
        // Ẩn cửa sổ chính trong lúc chọn để không vướng, nhất là khi game đang toàn màn hình.
        let hidden = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
        hidden.forEach { $0.orderOut(nil) }
        editor.begin(main: settings.region, secondaries: settings.secondaryRegions, running: running,
                     screenTranslating: screenTranslateOn, screenMode: screen) { [weak self] result in
            guard let self else { return }
            hidden.forEach { $0.orderFront(nil) }   // orderFront không kích hoạt app, không kéo người dùng về Space của app
            self.grabber.invalidate()
            guard let result else { self.status = L("Đã huỷ chọn vùng.", "Region selection canceled."); return }
            self.applyRegions(result, screen: screen)
        }
    }

    /// Chỉnh vùng của một hồ sơ (từ trang hồ sơ). Hồ sơ đang dùng thì như Chọn vùng; hồ sơ khác thì chỉ sửa hồ sơ đó.
    func editRegions(forProfile id: UUID) {
        if id == settings.activePresetID { selectRegion(); return }
        guard !editor.isOpen, let p = settings.presets.first(where: { $0.id == id }) else { return }
        prepareEditor()
        let hidden = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
        hidden.forEach { $0.orderOut(nil) }
        let secs = p.snapshot.secondaryRegions ?? p.snapshot.secondaryRegion.map { [$0] } ?? []
        editor.begin(main: p.snapshot.region, secondaries: secs, running: true) { [weak self] result in
            guard let self else { return }
            hidden.forEach { $0.orderFront(nil) }
            guard let result else { return }
            self.settings.updatePreset(id) { $0.region = result.main; $0.secondaryRegions = result.secondaries }
            if let t = result.thumbnail { RegionThumbs.save(t, for: id) }
            self.status = L("Đã lưu vùng cho hồ sơ \(p.name).", "Saved regions for profile \(p.name).")
        }
    }

    private func prepareEditor() {
        editor.grabScreen = { [weak self] r in try? await self?.grabber.grab(r, fullResolution: true) }
        editor.readText = { [weak self] r, img in await self?.regionText(r, from: img) }
        editor.autoFind = { [weak self] screen in await self?.autoFindRegion(screen) }
    }

    private func applyRegions(_ result: RegionEditor.Result, screen: Bool) {
        if let main = result.main {
            detectGame(under: main)
            if main != settings.region {
                settings.region = main
                resetState()
                overlay.region = main
            }
        }
        if result.secondaries != settings.secondaryRegions {
            settings.secondaryRegions = result.secondaries
            resetSecondary()
        }
        if let t = result.thumbnail, let id = settings.activePresetID { RegionThumbs.save(t, for: id) }
        let n = result.secondaries.count
        if let first = result.secondaries.first, result.main == nil, settings.region == nil { detectGame(under: first) }
        let parts = [result.main != nil ? L("vùng phụ đề", "the subtitle region") : nil, n > 0 ? L("\(n) vùng dịch màn hình", "\(n) screen \(n == 1 ? "region" : "regions")") : nil].compactMap { $0 }
        status = L("Đã lưu ", "Saved ") + (parts.isEmpty ? L("vùng", "regions") : parts.joined(separator: L(" và ", " and "))) + "."
        if result.start {
            if screen, n > 0 { settings.screenTranslateEnabled = true }
            if anyRunning { applyScreenTranslateSetting(); if result.main != nil, !running { start() } } else { startAll() }
        }
    }

    /// Chữ trong một vùng: cắt từ ảnh đã dừng hình nếu có (đúng cái người dùng đang thấy), không thì chụp trực tiếp.
    private func regionText(_ region: CaptureRegion, from frozen: CGImage?) async -> String? {
        guard CGPreflightScreenCaptureAccess() else { return L("Chưa có quyền Ghi màn hình", "Screen Recording permission not granted") }
        var image: CGImage?
        if let frozen, let sw = region.sw, sw > 0 {
            let scale = CGFloat(frozen.width) / sw
            image = frozen.cropping(to: CGRect(x: region.x * scale, y: region.y * scale, width: region.w * scale, height: region.h * scale).integral)
        } else {
            grabber.invalidate()
            image = try? await grabber.grab(region)
        }
        guard let image, let r = try? await OCR.recognize(image, language: settings.sourceLanguage, keepAll: true) else { return nil }
        return r.text
    }

    private func resetSecondary() {
        secOverlays.forEach { $0.hide() }
        let n = settings.secondaryRegions.count
        secStates = Array(repeating: ScreenRegionState(), count: n)
        while secOverlays.count < n { secOverlays.append(OverlayController(settings: settings, applyOffsets: false, screenTranslation: true)) }
        if n == 0, screenTranslateOn { setScreenTranslate(false) }
    }

    // MARK: Dịch màn hình

    /// Bật/tắt tính năng dịch màn hình (nút tròn, ⌃⌥T, thanh menu), như Phụ đề và Voice-over: đang chạy thì có tác dụng ngay,
    /// chưa chạy thì chờ bấm Bắt đầu. Bật mà chưa có vùng thì mở trình chọn vùng để thêm.
    func toggleScreenTranslate() {
        if settings.secondaryRegions.isEmpty {
            settings.screenTranslateEnabled = true
            status = L("Kéo khung quanh chữ cần dịch tại chỗ (bảng nhiệm vụ, menu, mô tả vật phẩm).", "Drag a box around the text to translate in place (quest log, menus, item descriptions).")
            selectRegion(screen: true)
            return
        }
        settings.screenTranslateEnabled.toggle()
        status = settings.screenTranslateEnabled ? L("Đã bật dịch màn hình.", "Screen translation on.") : L("Đã tắt dịch màn hình.", "Screen translation off.")
    }

    /// Áp trạng thái bật/tắt dịch màn hình khi phiên đang chạy.
    private func applyScreenTranslateSetting() {
        guard running || screenTranslateOn else { return }
        setScreenTranslate(settings.screenTranslateEnabled && !settings.secondaryRegions.isEmpty)
    }

    /// Chạy riêng, không cần khung phụ đề: không đọc to, không vào lịch sử hay Cửa sổ phụ đề,
    /// bản dịch hiện đè ngay tại chỗ trên chữ gốc.
    func setScreenTranslate(_ on: Bool) {
        guard on != screenTranslateOn else { return }
        if on {
            guard !settings.secondaryRegions.isEmpty, ensurePermission() else { return }
            screenTranslateOn = true
            resetSecondary()
            screenGameInFront = true
            status = L("Đang dịch màn hình (\(settings.secondaryRegions.count) vùng).", "Translating the screen (\(settings.secondaryRegions.count) \(settings.secondaryRegions.count == 1 ? "region" : "regions")).")
            screenLoop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.screenTick()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        } else {
            screenTranslateOn = false
            screenLoop?.cancel()
            screenLoop = nil
            resetSecondary()
            status = L("Đã tắt dịch màn hình.", "Screen translation off.")
        }
    }

    /// Quét lần lượt từng vùng, mỗi vùng khoảng 0,45 giây một lần. Khung hình đứng yên thì đọc kỹ rồi dịch; chữ đổi thì gỡ
    /// bản dịch cũ ngay (đọc nhanh để biết chữ có thật sự đổi không, con trỏ nhấp nháy thì thôi). Dịch chạy tách riêng nên
    /// trong lúc chờ AI vẫn quét tiếp được.
    private func screenTick() {
        let regions = settings.secondaryRegions
        guard screenTranslateOn, !regions.isEmpty, !secBusy else { return }
        let front = isGameInFront()
        if front != screenGameInFront {
            screenGameInFront = front
            if !front {
                secOverlays.forEach { $0.hide() }
                secStates.indices.forEach { secStates[$0] = ScreenRegionState() }
            }
        }
        guard front else { return }
        if secStates.count != regions.count { resetSecondary() }
        let i = secCursor % regions.count
        secCursor += 1
        // Quét dày (0,2 giây): chữ mới hiện là dịch sớm, tắt menu là gỡ ngay, không đọng bản dịch cũ.
        let interval = 0.2
        guard Date().timeIntervalSince(secStates[i].lastScan) >= interval else { return }
        secStates[i].lastScan = Date()
        let r2 = regions[i]
        let lang = settings.sourceLanguage
        secBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.secBusy = false }
            let image: CGImage
            do { image = try await self.grabber.grab(r2) } catch {
                // Mất quyền ghi màn hình hay màn hình bị rút: báo lên như phụ đề, không im lặng.
                if !self.running, Date().timeIntervalSince(self.lastScreenError) > 5 { self.lastScreenError = Date(); self.report(error) }
                return
            }
            guard self.isScreenRegion(i, r2) else { return }
            let scan = await OCR.screenScan(image, language: lang)
            let q = scan.sig
            guard self.isScreenRegion(i, r2) else { return }
            let sig = FrameSignature.make(image)
            let st = self.secStates[i]
            defer { if self.isScreenRegion(i, r2) { self.secStates[i].lastQuick = q; self.secStates[i].prevObs = scan.obs } }
            let showing = !st.shownQuick.isEmpty
            let bigChange = st.shownSig.map { FrameSignature.bigChange($0, sig) } ?? false

            if q.isEmpty {
                // Hết chữ. Cảnh đổi hẳn (menu đóng) thì gỡ ngay; cảnh gần như y nguyên thì có thể Vision đọc trượt một khung,
                // chờ thêm một lần quét (0,2 giây) cho chắc.
                self.secStates[i].emptyCount = st.emptyCount + 1
                self.secStates[i].sameCount = 0
                if showing, bigChange || st.emptyCount >= 1 { self.clearScreen(i, reason: "hết chữ") }
                return
            }
            self.secStates[i].emptyCount = 0
            // Chữ đứng yên: y hệt lần quét trước (cho lệch một ký tự). Chữ chạy từng ký tự thì chưa đứng yên, chưa dịch.
            let stable = q == st.lastQuick || (TextUtil.dice(q, st.lastQuick) >= 0.92 && abs(q.count - st.lastQuick.count) <= 2)
            self.secStates[i].sameCount = stable ? st.sameCount + 1 : 0

            if showing {
                let sim = TextUtil.dice(q, st.shownQuick)
                // Chữ đang chạy tiếp (thoại hiện từng ký tự): phần đầu vẫn là chữ đang hiện, giữ bản dịch, đợi chữ dừng rồi thay.
                let growing = q.count > st.shownQuick.count && TextUtil.dice(String(q.prefix(st.shownQuick.count)), st.shownQuick) >= 0.75
                // Chữ như cũ nhưng con số đã đổi (số tiền, số lượng) và đã đứng yên: đọc lại để cập nhật số (lấy mẫu câu từ
                // trí nhớ, không gọi AI). Số đang nhảy liên tục (đồng hồ) thì chờ nó dừng.
                let digitsChanged = q.filter(\.isNumber) != st.shownQuick.filter(\.isNumber)
                // Lần dịch AI trước bị lỗi: thử lại sau 3 giây.
                let retry = st.failedAt.map { Date().timeIntervalSince($0) > 3 } ?? false
                if retry { self.secStates[i].failedAt = nil; self.secStates[i].shown = "" }
                // Chữ di chuyển (cuộn danh sách, bảng trượt, cửa sổ game bị kéo): so vị trí các mẩu chữ với lúc đặt bản dịch.
                // Lệch quá 3 điểm thì ẩn bản dịch ngay (không để nó nằm sai chỗ); chữ dừng lại thì đặt bản dịch vào chỗ mới.
                let total = OCR.shift(from: st.refObs, to: scan.obs)
                let step = OCR.shift(from: st.prevObs, to: scan.obs)
                func points(_ v: CGVector?) -> CGFloat { v.map { max(abs($0.dx) * r2.w, abs($0.dy) * r2.h) } ?? 0 }
                let displaced = points(total) > 3
                if sim >= 0.6 || growing {
                    self.secStates[i].offCount = 0
                    if sim >= 0.9, !retry, !(digitsChanged && stable) {
                        if displaced || st.moving, let total {
                            if !st.moving { self.secOverlays[i].hide(); self.secStates[i].moving = true }
                            // Đã dừng (gần như không nhích so với lần quét trước): dời các cụm theo độ lệch rồi hiện lại,
                            // không đọc kỹ lại và không gọi AI.
                            if points(step) <= 1.5 {
                                await self.repositionScreen(i, region: r2, image: image, by: total, obs: scan.obs, sig: sig)
                            }
                            return
                        }
                        // Vẫn đúng chữ đang hiện: vệt chọn hay nền dưới chữ đổi thì dựng lại nền, không tắt bản dịch.
                        await self.refreshScreenBackground(i, region: r2, image: image)
                        return
                    }
                    // Chữ vừa đổi một phần vừa di chuyển (đang cuộn): gỡ bản cũ, chữ dừng thì dịch lại (đã gặp thì lấy từ trí nhớ).
                    if displaced { self.clearScreen(i, reason: "chữ di chuyển") }
                } else {
                    // Chữ khác hẳn hoặc cảnh đổi hẳn: gỡ ngay. Hơi khác (có thể đọc lệch): chờ thêm một lần quét cho khỏi chớp.
                    self.secStates[i].offCount = st.offCount + 1
                    guard sim < 0.3 || bigChange || self.secStates[i].offCount >= 2 else { return }
                    self.clearScreen(i, reason: "chữ đổi")
                }
            }
            // Chữ đứng yên qua hai lần quét mới đọc kỹ và dịch; đang hiện bản cũ thì thay tại chỗ, không tắt trước.
            guard self.secStates[i].sameCount >= 1 else { return }
            guard let res = try? await OCR.recognize(image, language: lang, keepAll: true), self.isScreenRegion(i, r2) else { return }
            // Chia thành cụm (mục menu, nút, đoạn mô tả); bỏ cụm đã đặt "luôn bỏ qua" hoặc đã là ngôn ngữ đích.
            let srcCode = SourceLanguage.find(lang).code, tgt = self.settings.target.base
            // Phụ đề đang chạy thì bỏ cụm nằm trong khung phụ đề: chỗ đó phụ đề lo, không để hai lớp bản dịch đè nhau.
            let sub = self.running ? self.settings.region : nil
            let size = CGSize(width: r2.w, height: r2.h)
            let blocks = ScreenText.blocks(res.lines, size: size).filter { b in
                if let sub, sub.displayID == r2.displayID, let l = b.lines.first {
                    let c = CGPoint(x: r2.x + l.box.midX * r2.w, y: r2.y + (1 - l.box.midY) * r2.h)
                    if sub.rect.contains(c) { return false }
                }
                return !self.settings.isIgnored(b.text) && !TextUtil.isAlreadyTarget(b.text, target: tgt, source: srcCode)
            }
            let norm = TextUtil.normalize(blocks.map(\.text).joined(separator: "\n"))
            guard !norm.isEmpty, norm != self.secStates[i].shown else { return }
            guard let prepared = await self.prepareScreen(blocks, region: r2, image: image), self.isScreenRegion(i, r2) else { return }
            self.secStates[i].blocks = prepared.blocks
            self.secStates[i].rings = prepared.rings
            self.secStates[i].zones = prepared.zones
            self.secStates[i].refObs = scan.obs
            self.secStates[i].moving = false
            self.secStates[i].shownSig = sig
            self.translateScreen(i, region: r2, parts: prepared.parts, stem: prepared.stem, background: prepared.background, norm: norm, quick: q)
        }
    }

    /// Gỡ bản dịch của một vùng và quên chữ đang hiện.
    private func clearScreen(_ i: Int, reason: String = "") {
        guard i < secStates.count else { return }
        if !secStates[i].shownQuick.isEmpty, !reason.isEmpty { DebugLog.write("Dịch màn hình, vùng \(i + 1): gỡ (\(reason))") }
        secOverlays[i].hide()
        secStates[i].shownQuick = ""
        secStates[i].shown = ""
        secStates[i].offCount = 0
        secStates[i].token += 1
        secStates[i].blocks = []
        secStates[i].vis = []
        secStates[i].rings = []
        secStates[i].zones = []
        secStates[i].failedAt = nil
        secStates[i].refObs = []
        secStates[i].moving = false
        secStates[i].shownSig = nil
    }

    private struct PreparedScreen {
        var blocks: [ScreenBlock]
        var parts: [(text: String, fit: TextFit, size: CGFloat)]
        var stem: [Double]
        var rings: [[Double]]
        var zones: [CGRect]
        var background: NSImage?
    }

    /// Vị trí, màu, cỡ chữ của từng cụm; nền game dựng lại ở chỗ chữ gốc (chạy nền, khoảng 10 ms); màu viền quanh từng cụm.
    private func prepareScreen(_ blocks: [ScreenBlock], region r2: CaptureRegion, image: CGImage) async -> PreparedScreen? {
        // Toàn bộ là xử lý ảnh (lấy màu, dựng nền): chạy ngoài luồng chính để giao diện và phụ đề không khựng.
        await Task.detached(priority: .userInitiated) { () -> PreparedScreen? in
            var kept: [ScreenBlock] = []
            var parts: [(text: String, fit: TextFit, size: CGFloat)] = []
            for b in blocks {
                guard let fit = TextFit.make(image: image, region: r2, lines: b.lines) else { continue }
                kept.append(b)
                parts.append((b.text, fit, ScreenText.fontSize(b.lines, regionWidth: r2.w, lineHeight: fit.lineHeight)))
            }
            guard !parts.isEmpty else { return nil }
            let size = CGSize(width: r2.w, height: r2.h)
            let zones = parts.map { ScreenText.zone($0.fit, size: $0.size) }, boxes = parts.map(\.fit.box)
            let cleaned = Inpaint.clean(image, size: size, zones: zones, boxes: boxes)
            return PreparedScreen(blocks: kept, parts: parts, stem: cleaned?.stem ?? [], rings: cleaned?.rings ?? [], zones: zones,
                                  background: cleaned.map { NSImage(cgImage: $0.image, size: size) })
        }.value
    }

    /// Chữ không đổi nhưng nền quanh chữ đổi (vệt chọn chuyển sang mục khác): dựng lại nền và màu chữ, giữ nguyên bản dịch.
    private func refreshScreenBackground(_ i: Int, region r2: CaptureRegion, image: CGImage) async {
        let st = secStates[i]
        guard !st.blocks.isEmpty, st.vis.count == st.blocks.count, st.rings.count == st.blocks.count, st.zones.count == st.blocks.count else { return }
        // Đo màu viền quanh các vùng đã lưu (rất nhẹ, ngoài luồng chính); chỉ khi màu đổi mới tính lại bố cục và dựng nền.
        let size = CGSize(width: r2.w, height: r2.h), zones = st.zones
        let now = await Task.detached(priority: .utility) { Inpaint.rings(image, size: size, zones: zones) }.value
        let moved = zip(now, st.rings).contains { a, b in zip(a, b).map { abs($0 - $1) }.reduce(0, +) > 40 }
        guard moved, let prepared = await prepareScreen(st.blocks, region: r2, image: image), isScreenRegion(i, r2),
              prepared.parts.count == st.vis.count, secStates[i].token == st.token else { return }
        secStates[i].rings = prepared.rings
        secStates[i].zones = prepared.zones
        let pieces = screenPieces(prepared.parts, vis: st.vis, stem: prepared.stem)
        if !pieces.isEmpty { secOverlays[i].show(pieces: pieces, background: prepared.background) }
    }

    /// Chữ đã di chuyển rồi dừng: dời các cụm theo độ lệch, dựng lại nền ở chỗ mới và hiện lại bản dịch đang có.
    private func repositionScreen(_ i: Int, region r2: CaptureRegion, image: CGImage, by v: CGVector, obs: [OCR.QuickObs], sig: [UInt8]) async {
        let st = secStates[i]
        guard !st.blocks.isEmpty, st.vis.count == st.blocks.count else { return }
        let moved = st.blocks.map { b in
            ScreenBlock(lines: b.lines.map { OCRLine(text: $0.text, box: $0.box.offsetBy(dx: v.dx, dy: v.dy)) }, text: b.text)
        }
        // Cụm nào trôi ra ngoài vùng thì thôi, không hiện.
        let inside = moved.indices.filter { k in moved[k].lines.allSatisfy { $0.box.minX >= -0.01 && $0.box.maxX <= 1.01 && $0.box.minY >= -0.01 && $0.box.maxY <= 1.01 } }
        guard !inside.isEmpty else { clearScreen(i, reason: "chữ trôi ra ngoài vùng"); return }
        let keptBlocks = inside.map { moved[$0] }, keptVis = inside.map { st.vis[$0] }
        guard let prepared = await prepareScreen(keptBlocks, region: r2, image: image), isScreenRegion(i, r2),
              secStates[i].token == st.token, prepared.parts.count == keptVis.count else { return }
        secStates[i].blocks = prepared.blocks
        secStates[i].vis = keptVis
        secStates[i].rings = prepared.rings
        secStates[i].zones = prepared.zones
        secStates[i].refObs = obs
        secStates[i].shownSig = sig
        secStates[i].moving = false
        let pieces = screenPieces(prepared.parts, vis: keptVis, stem: prepared.stem)
        secOverlays[i].region = r2
        if !pieces.isEmpty { secOverlays[i].show(pieces: pieces, background: prepared.background) }
        DebugLog.write(String(format: "Dịch màn hình, vùng %d: chữ di chuyển (%.0f, %.0f) điểm, đặt lại %d cụm", i + 1, v.dx * r2.w, -v.dy * r2.h, pieces.count))
    }

    /// Mảng thay chữ cho các cụm đã có bản dịch. Bỏ cụm không cần dịch (AI trả "=", hoặc bản dịch trùng chữ gốc như "Menu").
    private func screenPieces(_ parts: [(text: String, fit: TextFit, size: CGFloat)], vis: [String?], stem: [Double]) -> [ScreenPiece] {
        parts.indices.compactMap { k in
            guard k < vis.count, let vi = vis[k], !vi.isEmpty, TextUtil.normalize(vi) != TextUtil.normalize(parts[k].text) else { return nil }
            return ScreenPiece(id: k, vi: vi, fit: parts[k].fit, stem: stem.indices.contains(k) ? stem[k] : 0, size: parts[k].size)
        }
    }

    private func isScreenRegion(_ i: Int, _ r: CaptureRegion) -> Bool {
        screenTranslateOn && i < secStates.count && settings.secondaryRegions.indices.contains(i) && settings.secondaryRegions[i] == r
    }

    /// Dịch các cụm chữ của một vùng theo chế độ tốc độ: trí nhớ (tức thì) → Dịch máy Apple (trên máy, dưới nửa giây) → AI.
    /// Cụm nào có bản dịch trước thì thay trước; AI dịch mọi cụm còn thiếu trong một lần gọi.
    private func translateScreen(_ i: Int, region r2: CaptureRegion, parts: [(text: String, fit: TextFit, size: CGFloat)], stem: [Double],
                                 background: NSImage?, norm: String, quick: String) {
        secStates[i].token += 1
        let token = secStates[i].token
        secStates[i].shown = norm
        secStates[i].shownQuick = quick
        secStates[i].offCount = 0
        let started = Date()
        final class Box { var vi: [String?] = [] }
        let box = Box()
        box.vi = parts.map { screenLookup($0.text) }
        let present: (String) -> Void = { [weak self] how in
            guard let self, self.isScreenRegion(i, r2), self.secStates[i].token == token, self.screenGameInFront else { return }
            self.secStates[i].vis = box.vi
            let pieces = self.screenPieces(parts, vis: box.vi, stem: stem)
            guard !pieces.isEmpty else { return }
            self.secOverlays[i].region = r2
            self.secOverlays[i].show(pieces: pieces, background: background)
            DebugLog.write(String(format: "Dịch màn hình, vùng %d (%@, %.2f s): %d/%d cụm · %@", i + 1, how, Date().timeIntervalSince(started),
                                  pieces.count, parts.count, pieces.map { "\(parts[$0.id].text.prefix(30)) → \($0.vi.prefix(30))" }.joined(separator: " | ")))
        }
        if box.vi.contains(where: { $0 != nil }) { present("trí nhớ") }
        let missing = parts.indices.filter { box.vi[$0] == nil }
        guard !missing.isEmpty else { return }
        let speed = settings.screenSpeed
        let source = SourceLanguage.find(settings.sourceLanguage), target = settings.target.code
        let apple = speed != .quality && !settings.disabledEngines.contains(.appleTranslation)
        Task { [weak self] in
            if apple {
                // Dịch máy Apple từng cụm song song, ngay trên máy; không lưu vào trí nhớ (để bản AI thay sau).
                await withTaskGroup(of: (Int, String?).self) { group in
                    for k in missing {
                        let t = parts[k].text
                        group.addTask { (k, try? await Providers.appleTranslate(t, source: source.code, target: target)) }
                    }
                    for await (k, r) in group { if let r, !r.isEmpty { box.vi[k] = Providers.clean(r) } }
                }
                if missing.contains(where: { box.vi[$0] != nil }) { present("Apple") }
                if speed == .instant, missing.allSatisfy({ box.vi[$0] != nil }) { return }
            }
            guard let self else { return }
            // Bản AI: nhường lời thoại một chút. Đã có bản Apple đang hiện thì không vội, chờ lâu hơn được.
            var waited = 0
            let maxWait = speed == .quality ? 5 : 30
            while self.mainBusy, waited < maxWait { try? await Task.sleep(nanoseconds: 200_000_000); waited += 1 }
            guard self.isScreenRegion(i, r2), self.secStates[i].token == token else { return }
            let texts = missing.map { parts[$0].text }
            guard let out = await self.hub.translateUI(texts, source: source, fast: speed != .quality) else {
                DebugLog.write("Dịch màn hình, vùng \(i + 1): AI chưa dịch được \(texts.count) cụm, thử lại sau 3 giây")
                if self.isScreenRegion(i, r2), self.secStates[i].token == token { self.secStates[i].failedAt = Date() }
                return
            }
            // Đã đổi hồ sơ, ngôn ngữ hoặc chữ trên màn hình trong lúc chờ: bỏ, không ghi nhầm vào trí nhớ.
            guard self.isScreenRegion(i, r2), self.secStates[i].token == token else { return }
            for (n, k) in missing.enumerated() {
                box.vi[k] = out.texts[n]
                self.screenStore(parts[k].text, out.texts[n])   // "không cần dịch" lưu bằng chính chữ gốc
            }
            present(out.label)
        }
    }

    // Trí nhớ cho chữ giao diện. Câu có số ("Gold 1,234") lưu thành mẫu ("Gold {0}" → "Vàng {0}"): số đổi thì điền số mới
    // vào mẫu, không gọi AI lại và không làm đầy trí nhớ bằng hàng trăm biến thể.
    private static let numberRx = try! NSRegularExpression(pattern: #"\d+(?:[.,:]\d+)*"#)

    private func numberTemplate(_ text: String) -> (masked: String, nums: [String]) {
        let ns = text as NSString
        var nums: [String] = [], out = "", last = 0
        for m in Self.numberRx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + "{\(nums.count)}"
            nums.append(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        return (out + ns.substring(from: last), nums)
    }

    private func screenLookup(_ text: String) -> String? {
        let key = TextUtil.normalize(text)
        if key.count <= 3 { return uiShortCache[settings.targetLanguage + "|" + key] }
        let t = numberTemplate(text)
        if !t.nums.isEmpty, var hit = memory.lookup("#mẫu# " + t.masked) {
            for (k, n) in t.nums.enumerated() { hit = hit.replacingOccurrences(of: "{\(k)}", with: n) }
            return hit
        }
        return memory.lookup(text)
    }

    private func screenStore(_ text: String, _ vi: String) {
        let key = TextUtil.normalize(text)
        if key.count <= 3 { uiShortCache[settings.targetLanguage + "|" + key] = vi; return }
        let t = numberTemplate(text)
        if !t.nums.isEmpty, Set(t.nums).count == t.nums.count {
            // Mỗi số phải xuất hiện đúng một lần trong bản dịch thì mới lập được mẫu.
            var masked = vi, ok = true
            for (k, n) in t.nums.enumerated() {
                guard masked.components(separatedBy: n).count == 2 else { ok = false; break }
                masked = masked.replacingOccurrences(of: n, with: "{\(k)}")
            }
            if ok { memory.store("#mẫu# " + t.masked, masked); return }
        }
        memory.store(text, vi)
    }

    // MARK: Dịch nhanh

    let quick = QuickTranslator()

    /// Dịch nhanh (⌃⌥Q): kéo một khung quanh chữ bất kỳ, thả chuột là dịch ngay tại chỗ. Vùng dùng một lần, không lưu.
    /// Bấm lại phím tắt khi đang mở thì tắt.
    func quickTranslate() {
        if quick.isOpen { quick.close(); return }
        guard !editor.isOpen, ensurePermission() else { return }
        quick.grabScreen = { [weak self] r in try? await self?.grabber.grab(r, fullResolution: true) }
        quick.translate = { [weak self] region, image in await self?.quickResult(region, image: image) }
        quick.begin(freeze: settings.quickFreeze)
    }

    /// Đọc chữ trong ảnh của vùng vừa kéo, chia cụm, dịch (trí nhớ → AI một lần gọi → Dịch máy Apple) và dựng nền thay chữ.
    private func quickResult(_ region: CaptureRegion, image: CGImage) async -> QuickTranslator.Output? {
        let lang = settings.sourceLanguage, source = SourceLanguage.find(lang)
        guard let res = try? await OCR.recognize(image, language: lang, keepAll: true) else { return nil }
        let blocks = ScreenText.blocks(res.lines, size: CGSize(width: region.w, height: region.h)).filter {
            !TextUtil.isAlreadyTarget($0.text, target: settings.target.base, source: source.code)
        }
        guard !blocks.isEmpty, let prepared = await prepareScreen(blocks, region: region, image: image) else {
            return QuickTranslator.Output(pieces: [], background: nil, plain: "")
        }
        var vis: [String?] = prepared.parts.map { screenLookup($0.text) }
        let missing = vis.indices.filter { vis[$0] == nil }
        if !missing.isEmpty {
            let t0 = Date()
            if let out = await hub.translateUI(missing.map { prepared.parts[$0].text }, source: source, fast: true) {
                for (n, k) in missing.enumerated() { vis[k] = out.texts[n]; screenStore(prepared.parts[k].text, out.texts[n]) }
                DebugLog.write(String(format: "Dịch nhanh: %d cụm, %@ %.2f s", missing.count, out.label, Date().timeIntervalSince(t0)))
            } else {
                // AI không dùng được: Dịch máy Apple từng cụm.
                for k in missing {
                    if let a = try? await Providers.appleTranslate(prepared.parts[k].text, source: source.code, target: settings.target.code) { vis[k] = Providers.clean(a) }
                }
            }
        }
        let plain = prepared.parts.indices.map { vis[$0] ?? prepared.parts[$0].text }.joined(separator: "\n")
        return QuickTranslator.Output(pieces: screenPieces(prepared.parts, vis: vis, stem: prepared.stem), background: prepared.background, plain: plain,
                                      original: prepared.parts.map(\.text).joined(separator: "\n"))
    }

    func removeSecondaryRegion(at i: Int) {
        guard settings.secondaryRegions.indices.contains(i) else { return }
        settings.secondaryRegions.remove(at: i)
        resetSecondary()
    }

    /// Tìm khung phụ đề trên cả màn hình (nút "Tự tìm khung" khi chọn khung).
    private func autoFindRegion(_ screen: CaptureRegion) async -> CGRect? {
        grabber.invalidate()
        guard let image = try? await grabber.grab(screen),
              let r = await OCR.detectSubtitleArea(image, language: settings.sourceLanguage) else { return nil }
        DebugLog.write(String(format: "Tự tìm khung: (%.0f, %.0f) %.0f×%.0f", r.minX * screen.w, r.minY * screen.h, r.width * screen.w, r.height * screen.h))
        return CGRect(x: r.minX * screen.w, y: r.minY * screen.h, width: r.width * screen.w, height: r.height * screen.h)
    }

    // MARK: Hồ sơ game

    /// Game được đưa ra phía trước có hồ sơ riêng (khác hồ sơ đang dùng) thì chuyển sang; nhiều hồ sơ cùng game thì lấy hồ sơ dùng gần nhất.
    /// App hệ thống (Cài đặt hệ thống, Finder…) và chính OverSub không phải game: không gắn hồ sơ vào chúng.
    private static func isPlausibleGame(_ bundle: String?) -> Bool {
        guard let bundle, bundle != Bundle.main.bundleIdentifier else { return false }
        return !bundle.hasPrefix("com.apple.")
    }

    /// Tự chuyển hồ sơ khi một game khác được đưa ra phía trước. Hồ sơ bạn tự chọn luôn được tôn trọng:
    /// - Hồ sơ đang dùng chưa gắn với game nào: gắn nó với game vừa ra phía trước, không chuyển.
    /// - Hồ sơ đang dùng đã gắn đúng game này: giữ nguyên (nhiều hồ sơ cùng một app xem capture card thì bạn chọn tay).
    /// - Chỉ khi hồ sơ đang dùng gắn với một game KHÁC thì mới chuyển, sang hồ sơ dùng gần nhất của game này.
    private func autoSwitchProfile(for bundle: String) {
        guard settings.autoSwitchProfile, Self.isPlausibleGame(bundle) else { return }
        let matches = settings.presets.filter { $0.snapshot.gameBundleID == bundle }
        guard !matches.isEmpty else { return }   // app này chưa từng là game của hồ sơ nào
        let current = Self.isPlausibleGame(settings.gameBundleID) ? settings.gameBundleID : nil
        if current == bundle { return }
        if current == nil {
            settings.gameBundleID = bundle
            settings.gameAppName = matches.first?.snapshot.gameAppName
            DebugLog.write("Hồ sơ \(settings.activePreset?.name ?? "?") gắn với game \(settings.gameAppName ?? bundle)")
            return
        }
        guard let best = matches.max(by: { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }) else { return }
        applyPreset(best)
        status = L("Đã tự chuyển sang hồ sơ \(best.name) (\(best.snapshot.gameAppName ?? "game")).", "Automatically switched to profile \(best.name) (\(best.snapshot.gameAppName ?? "game")).")
    }

    /// Tạo hồ sơ mới cho game khác: cài đặt hiện tại, trí nhớ game trống.
    @discardableResult
    func createProfile(named name: String) -> Preset {
        settings.syncActiveProfile()
        let p = settings.createProfile(named: name)
        memory.load(profile: p.id)
        history = []
        cache.removeAll()
        status = L("Đã tạo hồ sơ \(p.name).", "Created profile \(p.name).")
        return p
    }

    /// Nhân bản: mang theo mọi thứ, cả ngữ cảnh và bộ nhớ dịch.
    func duplicateProfile(_ id: UUID) {
        settings.syncActiveProfile()
        let before = Set(settings.presets.map(\.id))
        settings.duplicatePreset(id)
        if let copy = settings.presets.first(where: { !before.contains($0.id) }) {
            memory.copy(from: id, to: copy.id)
            RegionThumbs.copy(from: id, to: copy.id)
        }
    }

    func deleteProfile(_ id: UUID) {
        memory.clear(id)
        RegionThumbs.remove(id)
        if let next = settings.deletePreset(id) { applyPreset(next) }
    }

    /// Xoá trí nhớ game: ngữ cảnh, dàn diễn viên, thuật ngữ, danh sách bỏ qua, bộ nhớ dịch. Giữ cài đặt.
    func clearProfileMemory(_ id: UUID) {
        settings.clearProfileMemory(id)
        memory.clear(id)
        if id == settings.activePresetID { history = []; cache.removeAll() }
    }

    /// Chuyển sang preset: khôi phục toàn bộ cài đặt (cả vùng chọn) và nối tiếp ngữ cảnh hội thoại đã lưu của preset đó.
    func applyPreset(_ p: Preset) {
        settings.syncActiveProfile()   // lưu nốt hồ sơ đang dùng trước khi rời
        endDemo()
        speaker.stop()
        settings.apply(p.snapshot)
        settings.activePresetID = p.id
        // Hồ sơ lỡ gắn với app hệ thống (chọn vùng lúc Cài đặt hệ thống nằm dưới): bỏ, để không bị "tạm ngưng vì game không ở phía trước".
        if settings.gameBundleID != nil, !Self.isPlausibleGame(settings.gameBundleID) { settings.gameBundleID = nil; settings.gameAppName = nil }
        if let i = settings.presets.firstIndex(where: { $0.id == p.id }) { settings.presets[i].lastUsedAt = Date() }
        resetState()
        resetSecondary()
        memory.load(profile: p.id)
        history = ContextStore.lines(for: p.id, target: settings.targetLanguage)
        overlay.region = settings.region
        gameInFront = true
        DebugLog.write("Dùng hồ sơ \(p.name)")
        status = running ? L("Đã chuyển sang hồ sơ \(p.name).", "Switched to profile \(p.name).") : L("Đã chuyển sang hồ sơ \(p.name). Bấm Bắt đầu.", "Switched to profile \(p.name). Click Start.")
    }

    /// Yêu cầu mở Cài đặt ở một trang; giao diện thấy yêu cầu này sẽ mở cửa sổ Cài đặt.
    func openSettings(_ page: SettingsPage) {
        requestedSettingsPage = page
    }

    /// Ghi nhận app có cửa sổ nằm trên cùng tại giữa vùng chọn: đó là game. Sau này chỉ đọc khi app đó ở phía trước.
    private func detectGame(under region: CaptureRegion) {
        guard let screen = resolveScreen(for: region) else { return }
        let f = screen.frame
        let mainH = NSScreen.screens.first?.frame.height ?? f.height
        // Toạ độ toàn cục gốc trên trái, như CGWindowList dùng.
        let center = CGPoint(x: f.minX + region.x + region.w / 2, y: mainH - (f.maxY - region.y - region.h / 2))
        let pid = ProcessInfo.processInfo.processIdentifier
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for info in windows {   // xếp từ trên xuống dưới
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID != pid,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict as CFDictionary), b.contains(center) else { continue }
            let app = NSRunningApplication(processIdentifier: ownerPID)
            guard Self.isPlausibleGame(app?.bundleIdentifier) else { continue }   // bỏ qua cửa sổ app hệ thống nằm đè lên game
            settings.gameAppName = app?.localizedName ?? (info[kCGWindowOwnerName as String] as? String)
            settings.gameBundleID = app?.bundleIdentifier
            DebugLog.write("Nhận diện game dưới vùng chọn: \(settings.gameAppName ?? "?") (\(settings.gameBundleID ?? "?"))")
            return
        }
        settings.gameAppName = nil
        settings.gameBundleID = nil
    }

    /// Game có đang hiện ở vùng phụ đề không. Chưa nhận diện được game hoặc đã tắt tuỳ chọn thì luôn coi là có.
    /// Trước đây chỉ xét app đang được chọn: chơi console qua app xem capture (VisionRelay) bằng tay cầm, bấm sang app khác để
    /// gõ việc gì đó là OverSub ngừng hẳn dù game vẫn chạy và thoại vẫn hiện (nhật ký 07/10: 224 lần tạm ngưng, nhiều lần lỡ thoại).
    /// Giờ game không được chọn mà cửa sổ game vẫn nằm trên cùng ở vùng phụ đề thì vẫn đọc; chỉ tạm ngưng khi game bị ẩn hoặc
    /// cửa sổ app khác che vùng phụ đề (lúc đó vùng chọn chứa chữ của app khác).
    private func isGameInFront() -> Bool {
        // Máy đang khoá, đang chạy bảo vệ màn hình hay màn hình tắt: không đọc được màn hình, tạm ngưng êm, không phải lỗi.
        // (Khoá máy thì cửa sổ game vẫn được liệt kê là đang hiện, nếu không xét riêng thì app cố chụp mỗi nhịp và báo sai là
        // "macOS từ chối chụp màn hình".) Không phụ thuộc tuỳ chọn tạm ngưng: lúc đó không chụp được gì cả.
        if let away = screenAway() {
            if behindNote != away { behindNote = away; DebugLog.write("Tạm ngưng vì \(away)") }
            return false
        }
        guard settings.pauseWhenGameHidden, let bundle = settings.gameBundleID else { return true }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle {
            behindNote = nil
            return true
        }
        let (visible, cover) = gameVisibleInRegion(bundle: bundle)
        // Ghi nhật ký khi đổi trạng thái: đang chọn app nào, game còn hiện ở vùng phụ đề không, nếu bị che thì do app nào.
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let note = visible ? "Đang chọn \(front), game vẫn hiện ở vùng phụ đề: vẫn đọc" : "Đang chọn \(front), vùng phụ đề \(cover.map { "bị \($0) che" } ?? "không thấy game")"
        if note != behindNote { behindNote = note; DebugLog.write(note) }
        return visible
    }

    /// Giữ (hoặc thôi giữ) màn hình sáng: không tắt màn hình, không chạy bảo vệ màn hình nên cũng không tự khoá máy.
    /// Dùng cơ chế chuẩn của macOS như trình xem phim; app thoát thì hệ thống tự bỏ.
    private func setKeepAwake(_ on: Bool) {
        if on, awakeToken == nil {
            awakeToken = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                                                               reason: "OverSub đang đọc phụ đề trên màn hình")
            DebugLog.write("Giữ màn hình luôn sáng trong lúc chạy")
        } else if !on, let token = awakeToken {
            ProcessInfo.processInfo.endActivity(token)
            awakeToken = nil
            DebugLog.write("Thôi giữ màn hình sáng")
        }
    }

    /// Màn hình không dùng được lúc này (khoá máy, bảo vệ màn hình, màn hình tắt, đang ở phiên người dùng khác): trả lý do.
    private func screenAway() -> String? {
        if let s = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if s["CGSSessionScreenIsLocked"] as? Bool == true { return "màn hình đang khoá" }
            if s[kCGSessionOnConsoleKey as String] as? Bool == false { return "đang ở phiên người dùng khác" }
        }
        switch NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
        case "com.apple.loginwindow": return "màn hình đang khoá"
        case "com.apple.ScreenSaver.Engine": return "đang chạy bảo vệ màn hình"
        default: break
        }
        if let region = settings.region, let screen = resolveScreen(for: region), let id = displayIDOf(screen), CGDisplayIsAsleep(id) != 0 {
            return "màn hình đang tắt"
        }
        return nil
    }

    /// Cửa sổ trên cùng chiếm vùng phụ đề có phải của game không. Xét các cửa sổ thường (từ trên xuống), bỏ qua cửa sổ của
    /// chính OverSub (ảnh chụp đã loại trừ chúng): gặp cửa sổ game trước thì game đang hiện; gặp cửa sổ app khác che từ một
    /// phần tư vùng trở lên thì coi là bị che. Trả kèm tên app che (để ghi nhật ký).
    private func gameVisibleInRegion(bundle: String) -> (Bool, String?) {
        guard let region = settings.region, let screen = resolveScreen(for: region) else { return (false, nil) }
        let f = screen.frame
        let mainH = NSScreen.screens.first?.frame.height ?? f.height
        // Toạ độ toàn cục gốc trên trái, như CGWindowList dùng.
        let rect = CGRect(x: f.minX + region.x, y: mainH - (f.maxY - region.y), width: region.w, height: region.h)
        let area = max(1, rect.width * rect.height)
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for info in windows {   // xếp từ trên xuống dưới
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            let overlap = b.intersection(rect)
            guard !overlap.isNull, overlap.width * overlap.height > 0 else { continue }
            let app = NSRunningApplication(processIdentifier: ownerPID)
            if app?.bundleIdentifier == bundle { return (true, nil) }
            if overlap.width * overlap.height >= area * 0.25 {
                return (false, app?.localizedName ?? info[kCGWindowOwnerName as String] as? String)
            }
        }
        return (false, nil)
    }

    /// Chụp vùng đã chọn. Trả về ảnh và vùng (để đặt lớp phủ).
    private func capture() async throws -> (CGImage, CaptureRegion) {
        guard let r = settings.region else { throw AppError(L("Chưa chọn vùng phụ đề.", "No subtitle region selected.")) }
        return (try await grabber.grab(r), r)
    }

    /// Cập nhật vùng của lớp phủ.
    private func useRegion(_ region: CaptureRegion) {
        if overlay.region != region {
            overlay.region = region
            overlay.reposition()
        }
    }

    func start() {
        guard settings.region != nil else { status = L("Chưa chọn vùng phụ đề.", "No subtitle region selected."); return }
        guard ensurePermission() else { return }
        overlay.region = settings.region
        running = true
        resetState()
        status = L("Đang nhận phụ đề…", "Watching for subtitles…")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                // Khung hình đứng yên lâu thì quét thưa hơn cho đỡ nóng máy.
                // Đang hiện bản dịch thì không quét thưa, để phát hiện hộp thoại tắt kịp thời.
                // Khung đứng yên thì mỗi lần quét chỉ là chụp và so dấu vân tay (rất nhẹ), nên không quét thưa nữa:
                // câu đầu tiên sau quãng im lặng được thấy sớm hơn tới 1 giây.
                var base = self.settings.captureMode.interval
                if self.settings.overlayFollow || self.idleTicks > 0 { base = min(base, 0.4) }
                // Đang hiện phụ đề thì quét dày hơn, để hộp thoại vừa tắt là gỡ bản dịch ngay.
                if self.overlay.model.visible { base = min(base, 0.25) }
                let wait = self.fastRecheck ? 0.08 : base
                self.fastRecheck = false
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    func stop() {
        demoActive = false
        demoToken += 1
        loop?.cancel()
        loop = nil
        running = false
        hideOverlay()
        speaker.stop()
        speaker.releaseGameAudio()
        status = L("Đã dừng.", "Stopped.")
    }

    /// Đang chạy phần nào đó: phụ đề lời thoại hoặc dịch màn hình. Nút Bắt đầu/Dừng chính (⌘R, ⌃⌥S) điều khiển cả hai.
    var anyRunning: Bool { running || screenTranslateOn }

    func toggleRunning() { anyRunning ? stopAll() : startAll() }

    /// Bắt đầu: phụ đề (có khung phụ đề) và dịch màn hình (đang bật và có vùng).
    func startAll() {
        let hasMain = settings.region != nil
        let hasScreen = settings.screenTranslateEnabled && !settings.secondaryRegions.isEmpty
        guard hasMain || hasScreen else {
            status = settings.secondaryRegions.isEmpty ? L("Chưa có vùng nào. Bấm Chọn vùng phụ đề hoặc Thêm dịch màn hình.", "No regions yet. Click Select subtitle region or Add screen translation.")
                                                       : L("Dịch màn hình đang tắt và chưa có vùng phụ đề. Bật nút Dịch màn hình hoặc chọn vùng phụ đề.", "Screen translation is off and there's no subtitle region. Turn on Screen translation or select a subtitle region.")
            return
        }
        if hasMain { start() }
        if hasScreen { setScreenTranslate(true) }
        if hasMain && hasScreen { status = L("Đang đọc phụ đề và dịch màn hình…", "Reading subtitles and translating the screen…") }
    }

    func stopAll() {
        if running { stop() }
        if screenTranslateOn { setScreenTranslate(false) }
        status = L("Đã dừng.", "Stopped.")
    }

    /// Ẩn hoặc hiện phụ đề đè lên (phím tắt ⌃⌥H, thanh menu).
    func toggleOverlay() {
        settings.overlayEnabled.toggle()
        status = settings.overlayEnabled ? L("Đã bật phụ đề đè lên.", "Subtitle overlay on.") : L("Đã ẩn phụ đề đè lên.", "Subtitle overlay hidden.")
    }

    /// Bật hoặc tắt thuyết minh (phím tắt ⌃⌥D, nút loa): đang đọc thì về chỉ phụ đề, đang tắt thì bật phụ đề + thuyết minh.
    func toggleDub() {
        settings.speakEnabled.toggle()
        status = settings.speakEnabled ? L("Đã bật giọng đọc.", "Voice on.") : L("Đã tắt giọng đọc.", "Voice off.")
    }

    /// Đọc lại câu vừa rồi (⌃⌥R hoặc tay cầm), khi lỡ nghe không kịp.
    func replayLast() {
        guard let last = transcript.last else { status = L("Chưa có câu nào để đọc lại.", "Nothing to replay yet."); return }
        replay(last)
        status = L("Đọc lại câu vừa rồi.", "Replaying the last line.")
    }

    /// Đọc lại một câu trong Lịch sử, bằng giọng của đúng nhân vật đó.
    func replay(_ item: TranscriptItem) {
        dub(item.translation, source: item.source, speakerName: item.speaker ?? "", boost: 1, force: true)
    }

    /// Nghe thử giọng của một nhân vật trong dàn diễn viên.
    func previewCast(_ m: CastMember) {
        let samples = ["vi": "Xin chào, ta là \(m.isNarrator ? "người dẫn chuyện" : m.name). Hành trình của chúng ta bắt đầu từ đây!",
                       "en": "Hello, I am \(m.isNarrator ? "the narrator" : m.name). Our journey begins here!"]
        let text = samples[settings.target.base] ?? samples["en"]!
        // Nghe thử trong Dàn diễn viên luôn dùng giọng của nhân vật, kể cả khi chưa bật lồng tiếng theo nhân vật.
        let plan = CastDirector.plan(for: m, line: text, source: "Our journey begins here!", voiceSource: .apple, emotion: false,
                                     genre: settings.genre, appleAvailable: appleVoices(for: settings.target.speech))
        speaker.playNow(DubLine(text: text, language: settings.target.speech, speaker: m.isNarrator ? nil : m.name), plan: plan)
    }

    /// Đọc một câu mẫu bằng Gemini TTS (tốn 1 lượt) để đo độ trễ thật trên máy này.
    func testGemini() {
        let m = settings.cast.first { $0.isNarrator } ?? .narrator
        let source = "My lord, the gates have fallen! We must retreat now!"
        let text = settings.target.isVietnamese ? "Thưa ngài, cổng thành đã thất thủ! Chúng ta phải rút lui ngay!" : source
        let p = CastDirector.plan(for: m, line: text, source: source, voiceSource: .gemini, emotion: true,
                                  genre: settings.genre, appleAvailable: appleVoices(for: settings.target.speech))
        speaker.playNow(DubLine(text: text, language: settings.target.speech), plan: p)
    }

    func clearTranscript() { transcript.removeAll() }

    /// Ghi một câu vào lịch sử thoại; với Dịch dần thì cập nhật câu đang ghép thay vì thêm dòng mới.
    private func record(source: String, translation: String, updating id: UUID? = nil) -> UUID {
        if let id, let i = transcript.firstIndex(where: { $0.id == id }) {
            transcript[i].source = source
            transcript[i].translation = translation
            return id
        }
        recentNames.append(lastSpeaker != nil)
        if recentNames.count > 12 { recentNames.removeFirst(recentNames.count - 12) }
        let item = TranscriptItem(speaker: lastSpeaker, source: source, translation: translation)
        transcript.append(item)
        Donation.countLine()
        if transcript.count > 300 { transcript.removeFirst(transcript.count - 300) }
        return item.id
    }

    func adjustWindowFont(_ delta: Double) {
        settings.windowFontSize = min(120, max(12, settings.windowFontSize + delta))
    }

    /// Nghe thử giọng thuyết minh.
    func previewVoice() {
        let samples = ["vi": "Xin chào, đây là giọng đọc phụ đề của OverSub.", "en": "Hello, this is the OverSub voice-over."]
        let text = samples[settings.target.base] ?? samples["en"]!
        speaker.playNow(DubLine(text: text, language: settings.target.speech), plan: voiceOverPlan)
    }

    /// Hiện phụ đề mẫu vài giây để chỉnh vị trí, cỡ chữ, kiểu nền. Bấm lần nữa, đóng Cài đặt hoặc bấm Dừng thì tắt ngay.
    func toggleDemo() { demoActive ? endDemo() : demoOverlay() }

    private func demoOverlay() {
        guard let region = overlay.region ?? settings.region else { status = L("Chưa chọn vùng phụ đề.", "No subtitle region selected."); return }
        overlay.region = region
        demoActive = true
        demoToken += 1
        let token = demoToken
        // Giả lập một dòng chữ gốc cỡ vừa phải nằm giữa vùng quét để xem bản dịch khớp ra sao.
        let lineH = min(region.h * 0.5, 32)
        let box = CGRect(x: region.w / 2 - region.w * 0.2, y: region.h / 2 - lineH * 0.6, width: region.w * 0.4, height: lineH * 1.2)
        let sample = TextFit(box: box, cover: box.insetBy(dx: -14, dy: -6), lineHeight: lineH, text: nil, background: nil)
        overlay.show(vi: L("Đây là phụ đề mẫu để chỉnh vị trí và cỡ chữ.", "This is a sample subtitle for adjusting position and text size."), original: "This is a sample subtitle.", fit: sample)
        grabber.invalidate()
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if demoToken == token { endDemo() }
        }
    }

    func endDemo() {
        guard demoActive else { return }
        demoActive = false
        demoToken += 1
        if running, !shown.isEmpty, !lastTranslation.isEmpty {
            // Đang có phụ đề thật trên màn hình: trả lại thay vì ẩn.
            overlay.show(vi: lastTranslation, original: settings.mode == .viAndEn ? lastSource : nil, fit: lastFit)
        } else {
            hideOverlay()
        }
    }

    private func resetState() {
        lastQuick = nil; lastAccurate = nil
        shown = ""; pending = ""; pendingRaw = ""; lastSignature = nil; lastOCREmpty = false; emptyReads = 0; presentSignature = nil; fastRecheck = false; lastFit = nil; fontSamples = []
        resetProgressive()
        idleTicks = 0; stableTicks = 0
        cache.removeAll()
        lastDialogueAt = nil
        lastConfirmAt = nil; gapEMA = 4.0
        hideOverlay()
    }

    /// Chữ gốc đã biến mất: ẩn bản dịch và quên phần đã dịch dần của câu đó (phần đã dịch mà chưa đọc thì đọc nốt).
    private func dismissOverlay() {
        shown = ""
        finishLineDub(progLine)
        resetProgressive()
        hideOverlay()
    }

    private func resetProgressive() {
        progNorm = ""; progRaw = ""; progLatestRaw = ""
        progLine = ProgLine()   // câu cũ còn cụm đang dịch thì vẫn được ghép và đọc nốt (các tác vụ dịch giữ tham chiếu tới nó)
    }

    private func hideOverlay() {
        overlay.hide()   // ảnh chụp loại trừ cả ứng dụng OverSub nên không cần lấy lại danh sách cửa sổ
    }

    // MARK: Quét thử

    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { problem = nil; return true }
        CGRequestScreenCaptureAccess()
        problem = L("Chưa có quyền Ghi màn hình cho OverSub. Bật trong System Settings → Privacy & Security → Screen & System Audio Recording, rồi thoát hẳn và mở lại app.", "OverSub doesn't have Screen Recording permission. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app.")
        status = L("Thiếu quyền Ghi màn hình.", "Screen Recording permission missing.")
        return false
    }

    private func report(_ error: Error) {
        DebugLog.write("Lỗi: \((error as? AppError)?.message ?? error.localizedDescription)")
        let ns = error as NSError
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" || ns.code == -3801 {
            problem = L("macOS từ chối chụp màn hình: \(error.localizedDescription). Kiểm tra quyền Ghi màn hình của OverSub, rồi thoát hẳn và mở lại app.", "macOS refused the screen capture: \(error.localizedDescription). Check OverSub's Screen Recording permission, then quit and reopen the app.")
        } else {
            problem = error.localizedDescription
        }
        status = L("Lỗi: \(error.localizedDescription)", "Error: \(error.localizedDescription)")
    }

    // MARK: Vòng lặp

    private func tick() async {
        guard settings.region != nil else { return }
        // Chuyển sang app khác (Claude, trình duyệt...) thì vùng chọn đang chứa chữ của app đó: tạm ngưng đọc và ẩn lớp phủ.
        let front = isGameInFront()
        if front != gameInFront {
            gameInFront = front
            DebugLog.write(front ? "Game hiện lại ở vùng phụ đề, đọc tiếp" : "Game bị ẩn hoặc bị che ở vùng phụ đề, tạm ngưng đọc")
            if !front { hideOverlay(); lastSignature = nil }
            status = front ? L("Đang nhận phụ đề…", "Watching for subtitles…") : L("Tạm ngưng: \(settings.gameAppName ?? "game") đang bị ẩn hoặc bị cửa sổ khác che.", "Paused: \(settings.gameAppName ?? "the game") is hidden or covered by another window.")
        }
        guard front else { return }
        do {
            let (image, region) = try await capture()
            useRegion(region)
            let sig = FrameSignature.make(image)
            let mode = settings.captureMode

            // Khung hình không đổi thì không cần OCR lại, đây là chỗ tiết kiệm nhiều nhất.
            if let last = lastSignature, FrameSignature.unchanged(last, sig) {
                idleTicks += 1
                stableTicks += 1
                if lastOCREmpty, !shown.isEmpty {   // phụ đề gốc đã biến mất và khung đã ổn định
                    emptyReads += 1
                    if emptyReads >= 2 { dismissOverlay() }
                }
                // Chế độ "đợi đủ câu" cần chữ đứng yên hai nhịp liên tiếp; các chế độ khác chỉ cần một nhịp.
                if !pending.isEmpty, stableTicks >= (mode == .complete ? 2 : 1) {
                    let raw = pendingRaw
                    pending = ""; pendingRaw = ""
                    try await confirm(raw)
                }
                // Dịch dần: chữ đã đứng yên nghĩa là không dài thêm nữa, dịch nốt phần còn lại.
                // Game hay ngừng gõ chữ một nhịp ở chỗ đổi màu: dịch luôn lúc đó sẽ ra câu cụt ("Bnahabra thường sử").
                // Chỉ dịch nốt khi câu đã có dấu kết thúc, hoặc chữ đứng yên khoảng 2,5 giây.
                if mode == .progressive, !progLatestRaw.isEmpty, progressiveSettled(stableTicks) {
                    try await progressiveCommit(stable: true)
                }
                return
            }
            lastSignature = sig
            idleTicks = 0
            stableTicks = 0

            // Đang hiện bản dịch mà khung đổi: đọc riêng chỗ chữ gốc cũ (ảnh nhỏ, rất nhanh) để biết nó còn đó không.
            // Cách này không phụ thuộc OCR toàn vùng có ra chữ rác từ hoạ tiết cảnh nền hay không.
            if !shown.isEmpty, overlay.model.visible, !settings.overlayFollow, mode != .progressive, let fit = lastFit,
               !(await textStillPresent(image, region: region, fit: fit, tolerance: mode == .progressive ? 0.65 : 0.4)) {
                pending = ""; pendingRaw = ""; emptyReads = 0
                DebugLog.write("Ẩn bản dịch: chữ gốc cũ không còn ở chỗ cũ")
                dismissOverlay()
            }

            // Đọc nhanh trước: chữ vẫn y như lần trước (chỉ cảnh nền chuyển động) thì dùng lại kết quả đọc kỹ, đỡ nóng máy.
            // Chữ chạy cần thấy từng ký tự và dấu câu mới nên phải giống hệt; các chế độ khác cho lệch chút vì nền làm nhiễu.
            let result: OCRResult
            let quick = settings.overlayFollow ? nil : await OCR.quickText(image, language: settings.sourceLanguage)
            quickSawNothing = quick?.isEmpty ?? false
            if let q = quick, let pq = lastQuick, let prev = lastAccurate,
               q == pq || (mode != .progressive && abs(q.count - pq.count) <= 3 && TextUtil.similar(q, pq, tolerance: 0.08)) {
                result = prev
                ocrSaved += 1
            } else {
                result = try await OCR.recognize(image, language: settings.sourceLanguage)
                lastAccurate = result
                lastQuick = quick
            }
            problem = nil
            let newLines = result.lines.map(\.text)
            if newLines != lastLineTexts || lastSpeaker != result.speaker {
                DebugLog.write("OCR [\(mode.rawValue)] người nói=\(result.speaker ?? "-") | \(result.text)")
            }
            lastLineTexts = newLines
            // Nhãn tên có lúc không tách được (khác màu, khác cỡ chưa rõ khi hộp thoại đang hiện dần) nên dính vào đầu câu:
            // "Experienced Farmer These vineyards...". Dòng đầu trùng tên vừa gặp thì vẫn là nhãn tên. Không bỏ thì app tưởng
            // là câu mới, dịch và đọc lại cả câu mỗi lần tên lúc tách lúc dính (đo thực: một câu bị đọc 5 lần).
            let (body, speakerName) = Self.splitKnownLabel(result.lines, speaker: result.speaker, known: knownSpeakers)
            rememberSpeaker(speakerName)
            let bodyText = body.map(\.text).joined(separator: " ")
            // Nhãn tên đôi lúc bị đọc trượt một khung (nền chuyển động, hiệu ứng): giữ tên đang có, chỉ coi là "không có tên"
            // sau ba lần đọc liên tiếp không thấy. Không thì giữa câu giọng nhân vật bị đổi sang giọng dẫn chuyện.
            if let s = speakerName {
                speakerMisses = 0
                if lastSpeaker != s { lastSpeaker = s }
            } else if lastSpeaker != nil {
                speakerMisses += 1
                if speakerMisses >= 3 || bodyText.isEmpty { lastSpeaker = nil; speakerMisses = 0 }
            }
            if !body.isEmpty {
                lastFit = TextFit.make(image: image, region: region, lines: body)
                // Chữ thoại của game luôn cùng cỡ: lấy trung vị cỡ chữ ước được ở các câu gần đây, để phụ đề không lúc to lúc nhỏ.
                if var f = lastFit, let fs = f.fontSize {
                    fontSamples.append(fs)
                    if fontSamples.count > 9 { fontSamples.removeFirst() }
                    f.fontSize = fontSamples.sorted()[fontSamples.count / 2]
                    lastFit = f
                }
            }
            try await handle(bodyText, mode: mode)
        } catch {
            // Máy vừa khoá (hay màn hình vừa tắt) đúng lúc đang chụp: không phải lỗi, nhịp sau sẽ tạm ngưng êm.
            if let away = screenAway() { DebugLog.write("Không chụp được vì \(away), bỏ qua"); return }
            report(error)
        }
    }

    /// Chữ này có nên bỏ qua không dịch: đã đặt "luôn bỏ qua", hoặc lớp luật nhận ra là chữ giao diện.
    private func skipReason(_ text: String) -> String? {
        if settings.isIgnored(text) { return L("đã đặt luôn bỏ qua", "set to always ignore") }
        if TextUtil.isAlreadyTarget(text, target: settings.target.base, source: SourceLanguage.find(settings.sourceLanguage).code) {
            return L("chữ đã là \(settings.target.displayName)", "text is already in \(settings.target.displayName)")
        }
        guard settings.smartSubtitleOnly else { return nil }
        return SubtitleFilter.nonSubtitleReason(lines: lastLineTexts, joined: text).map(SubtitleFilter.displayReason)
    }

    /// Các câu trước gửi kèm khi dịch: tối đa 10 câu và khoảng 1.400 ký tự, để không vượt giới hạn token mỗi phút của Groq.
    private func contextWindow() -> [ContextLine] {
        var out: [ContextLine] = [], chars = 0
        for l in history.reversed() {
            chars += l.source.count + l.vi.count + 8
            if out.count >= 10 || chars > 1400 { break }
            out.append(l)
        }
        return out.reversed()
    }

    /// Tuỳ chọn: im lặng quá lâu thì quên ngữ cảnh cũ để cuộc hội thoại mới không bị ảnh hưởng.
    private func refreshContext() {
        let now = Date()
        if settings.contextAutoForget, let last = lastDialogueAt, now.timeIntervalSince(last) > settings.contextResetSeconds,
           !history.isEmpty || !cache.isEmpty {
            history.removeAll()
            cache.removeAll()
            hub.logEvent(L("Đã quên ngữ cảnh hội thoại cũ sau \(Int(now.timeIntervalSince(last))) giây im lặng.", "Cleared the old conversation context after \(Int(now.timeIntervalSince(last))) seconds of silence."))
        }
        lastDialogueAt = now
    }

    /// Các cụm viết hoa trong câu đang hiện nhiều khả năng là tên riêng, chưa có trong từ điển.
    func termCandidates() -> [String] {
        Glossary.candidates(in: lastSource).filter { c in
            !settings.glossary.contains { $0.term.caseInsensitiveCompare(c) == .orderedSame }
        }
    }

    /// Tên riêng có thể giữ nguyên trong một câu bất kỳ (dùng ở Lịch sử).
    func termCandidates(in source: String) -> [String] {
        Glossary.candidates(in: source).filter { c in
            !settings.glossary.contains { $0.term.caseInsensitiveCompare(c) == .orderedSame }
        }
    }

    /// Bỏ qua một câu trong Lịch sử: từ nay gặp lại không dịch, không đọc. Đang hiện đúng câu đó thì gỡ luôn.
    func ignore(_ item: TranscriptItem) {
        settings.addIgnored(item.source)
        transcript.removeAll { $0.id == item.id }
        if lastSource == item.source { lastSource = ""; lastTranslation = ""; hideOverlay() }
        status = L("Đã thêm vào danh sách luôn bỏ qua.", "Added to the always-ignore list.")
    }

    func addTermToGlossary(_ term: String) {
        settings.addTerm(term)
        status = L("Đã thêm \"\(term)\" vào danh sách thuật ngữ, các câu sau sẽ giữ nguyên.", "Added \"\(term)\" to the glossary; it will be kept as is from now on.")
    }

    func clearContext() {
        history.removeAll()
        cache.removeAll()
        lastDialogueAt = nil
        hub.logEvent(L("Đã quên ngữ cảnh theo yêu cầu.", "Context cleared on request."))
    }

    /// Đặt câu đang hiện (logo, chữ HUD cố định...) vào danh sách luôn bỏ qua.
    func ignoreCurrentSentence() {
        guard !lastSource.isEmpty else { return }
        settings.addIgnored(lastSource)
        status = L("Đã thêm vào danh sách luôn bỏ qua.", "Added to the always-ignore list.")
        lastSource = ""; lastTranslation = ""
        hideOverlay()
    }

    private func textStillPresent(_ image: CGImage, region: CaptureRegion, fit: TextFit, tolerance: Double) async -> Bool {
        let sx = CGFloat(image.width) / region.w, sy = CGFloat(image.height) / region.h
        let pad = fit.lineHeight * 0.3
        let r = fit.box.insetBy(dx: -pad, dy: -pad)
        let px = CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard px.width > 8, px.height > 8, let crop = image.cropping(to: px),
              let result = try? await OCR.recognize(crop, language: settings.sourceLanguage) else { return true }
        let now = TextUtil.normalize(result.text)
        if now.isEmpty { return false }
        return TextUtil.similar(now, shown, tolerance: tolerance)   // nới ngưỡng: ảnh cắt có thể làm OCR sai vài ký tự
    }

    private func handle(_ text: String, mode: CaptureMode) async throws {
        let norm = TextUtil.normalize(text)

        if norm.isEmpty {
            lastOCREmpty = true
            pending = ""; pendingRaw = ""
            // Khung hình đổi liên tục (cảnh nền chuyển động) thì nhánh "khung đứng yên" không bao giờ chạy tới,
            // nên phải đếm cả ở đây: hai lần đọc liên tiếp không thấy chữ là phụ đề đã hết.
            emptyReads += 1
            if !shown.isEmpty {
                // Cảnh đã đổi nhiều so với lúc còn phụ đề mà OCR không thấy chữ: hộp thoại đã tắt, ẩn ngay không cần đọc lần hai.
                let sceneChanged = presentSignature.flatMap { p in lastSignature.map { FrameSignature.changedFraction(p, $0) > 0.08 } } ?? false
                // Dịch dần ghép bản dịch qua nhiều cụm: một lần đọc trống thoáng qua không được xoá mất phần đã ghép.
                // Chữ chạy: chỉ gỡ ngay khi cả bộ đọc nhanh lẫn đọc kỹ đều không thấy chữ và cảnh đã đổi (hộp thoại tắt hẳn).
                if emptyReads >= 2 || (sceneChanged && (settings.captureMode != .progressive || quickSawNothing)) {
                    DebugLog.write("Ẩn bản dịch: OCR trống \(emptyReads) lần\(sceneChanged ? ", cảnh đã đổi" : "")")
                    dismissOverlay()
                } else {
                    fastRecheck = true   // chưa chắc: đọc lại sau 0.12 giây
                }
            }
            return
        }
        lastOCREmpty = false
        emptyReads = 0
        if mode == .progressive {
            if settings.overlayFollow { overlay.updateFit(lastFit) }
            progSame = norm == progLastNorm ? progSame + 1 : 0
            progLastNorm = norm
            try await progressive(text, norm: norm)
            // Chữ không dài thêm qua vài lần đọc (dù nền phía sau vẫn chuyển động): dịch nốt phần còn lại.
            if !progLatestRaw.isEmpty, progressiveSettled(progSame) { progSame = 0; try await progressiveCommit(stable: true) }
            return
        }
        if TextUtil.similar(norm, shown) {
            pending = ""; pendingRaw = ""
            if settings.overlayFollow { overlay.updateFit(lastFit) }   // cùng câu nhưng chữ gốc có thể đã nhích đi
            return
        }

        switch mode {
        case .balanced:
            if TextUtil.similar(norm, pending) {   // hai lần đọc giống nhau
                pending = ""; pendingRaw = ""
                try await confirm(text)
            } else {
                pending = norm; pendingRaw = text
                fastRecheck = true   // vừa thấy chữ mới: đọc lại ngay để chốt câu, không chờ hết nhịp quét
            }
        case .complete:
            // Chờ chữ đứng yên. Nhánh "khung không đổi" chốt khi hình đứng yên; còn ở đây chốt theo chữ (ba lần đọc giống
            // nhau), để nền chuyển động hay mũi tên nhấp nháy không làm câu kẹt mãi không được dịch.
            if TextUtil.similar(norm, pending) {
                pendingSame += 1
                if pendingSame >= 2 {
                    pending = ""; pendingRaw = ""; pendingSame = 0
                    try await confirm(text)
                }
            } else {
                pending = norm; pendingRaw = text; pendingSame = 0
            }
        case .progressive:
            break   // đã xử lý ở trên
        }
    }

    /// Dòng đầu trùng một tên người nói đã gặp (bỏ dấu hai chấm cuối) mà OCR chưa tách ra: coi là nhãn tên. Cho lệch một ký tự
    /// với tên từ 4 chữ trở lên, vì OCR hay đọc nhầm chữ cuối ("Hill×" thay cho "Hillx").
    static func splitKnownLabel(_ lines: [OCRLine], speaker: String?, known: [String]) -> (body: [OCRLine], speaker: String?) {
        guard speaker == nil, let first = lines.first else { return (lines, speaker) }
        var label = first.text.trimmingCharacters(in: .whitespaces)
        while let last = label.last, ":-—".contains(last) { label.removeLast() }
        let l = TextUtil.normalize(label)
        guard !l.isEmpty, let name = known.first(where: { k in
            let n = TextUtil.normalize(k)
            if l == n { return true }
            return n.count >= 4 && abs(l.count - n.count) <= 1 && TextUtil.similar(l, n, tolerance: 0.25)
        }) else { return (lines, speaker) }
        return (Array(lines.dropFirst()), name)
    }

    private func rememberSpeaker(_ name: String?) {
        guard let name, !knownSpeakers.contains(name) else { return }
        knownSpeakers.append(name)
        if knownSpeakers.count > 8 { knownSpeakers.removeFirst() }
    }

    // MARK: Dịch dần

    #if DEVTOOLS
    /// Thử chế độ chữ chạy không cần game: đưa lần lượt từng lần "đọc chữ" vào đúng đường xử lý. Sau mỗi lần đọc, nghỉ `wait`
    /// giây; trong lúc nghỉ thì giả lập khung hình đứng yên như vòng quét thật (mỗi nhịp 0,25 giây).
    /// Như vòng quét thật sau bước OCR: tách nhãn tên đã biết, giữ tên người nói, rồi xử lý chữ theo chế độ chữ chạy.
    /// Thử nhận biết game có đang hiện ở vùng phụ đề (OVERSUB_FRONT_TEST=giây): ghi kết quả mỗi giây vào nhật ký.
    func debugFrontCheck(seconds: Int) async {
        for _ in 0..<seconds {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            DebugLog.write("Thử game ở vùng phụ đề: đang chọn \(front) → \(isGameInFront() ? "đọc" : "tạm ngưng")")
            try? await Task.sleep(for: .seconds(1))
        }
        DebugLog.write("=== Hết thử game ở vùng phụ đề ===")
    }

    func debugRead(_ lines: [String], speaker: String?, wait: Double) async {
        let ocr = lines.map { OCRLine(text: $0, box: .zero) }
        let (body, name) = Self.splitKnownLabel(ocr, speaker: speaker, known: knownSpeakers)
        rememberSpeaker(name)
        if let name { lastSpeaker = name }
        let text = body.map(\.text).joined(separator: " ")
        DebugLog.write("Thử OCR người nói=\(speaker ?? "-") | \(lines.joined(separator: " ")) → chữ thoại: \(text)")
        try? await handle(text, mode: .progressive)
        await debugProgressive([], idle: wait)
    }

    func debugProgressive(_ steps: [(text: String, wait: Double)], idle: Double = 0) async {
        if idle > 0 {
            for k in 1...max(1, Int(idle / 0.25)) {
                try? await Task.sleep(for: .seconds(0.25))
                if !progLatestRaw.isEmpty, progressiveSettled(k) { try? await progressiveCommit(stable: true) }
            }
        }
        for step in steps {
            try? await progressive(step.text, norm: TextUtil.normalize(step.text))
            let ticks = Int(step.wait / 0.25)
            guard ticks > 0 else { continue }
            for k in 1...ticks {
                try? await Task.sleep(for: .seconds(0.25))
                if !progLatestRaw.isEmpty, progressiveSettled(k) { try? await progressiveCommit(stable: true) }
            }
        }
    }
    #endif

    /// Chữ đang hiện từng ký tự: giữ lại phần đã dịch, mỗi lần chữ dài thêm thì chỉ dịch cụm mới hiện xong.
    private func progressive(_ text: String, norm: String) async throws {
        // OCR thỉnh thoảng đọc sót vài chữ ("make" thành "ma"): gần giống phần đã dịch và không dài hơn thì là cùng một câu,
        // không xoá rồi dịch lại (tốn lượt API, phụ đề nháy).
        if !progNorm.isEmpty, norm.count <= progNorm.count + 2, TextUtil.similar(norm, progNorm, tolerance: 0.12) {
            shown = norm
            return
        }
        if !progNorm.isEmpty, !Progressive.continues(norm: norm, committedNorm: progNorm) {
            DebugLog.write("Dịch dần: câu mới thay vào, bỏ phần đã ghép \"\(progRaw)\"")
            finishLineDub(progLine)   // phần đã dịch mà chưa đọc (chưa có dấu kết thúc câu) thì đọc nốt, không bỏ mất
            resetProgressive()   // câu khác thay vào, không phải câu cũ dài ra
        }
        shown = norm
        if progNorm.isEmpty, let why = skipReason(text) {   // câu mới bắt đầu mà là chữ giao diện: không dịch
            progLatestRaw = ""
            status = L("Bỏ qua (\(why)).", "Skipped (\(why)).")
            return
        }
        progLatestRaw = text
        // Câu hiện ra nguyên vẹn ngay (chuyển app rồi quay lại, OCR đọc chập chờn) là câu cũ còn nằm đó; câu dài dần từ đầu là game
        // vừa gõ ra một lần nói mới (vd. nói chuyện lại với NPC), được đọc dù vừa đọc cách đây chưa tới 45 giây.
        if progLine.firstSeen == 0 { progLine.firstSeen = text.count }
        else if !progLine.typedIn, text.count >= progLine.firstSeen + 12 { progLine.typedIn = true }
        try await progressiveCommit(stable: false)
    }

    /// Một câu đang dịch dần. Việc dịch chạy riêng, vòng quét không phải chờ: cắt cảnh đổi phụ đề nhanh, chờ dịch xong mới quét
    /// tiếp thì lỡ mất nguyên khung phụ đề (đo thực 06/10/2026: có lần vòng quét bị chặn 7 giây). Các cụm của cùng một câu vẫn
    /// dịch nối tiếp nhau, cụm sau có bản dịch của cụm trước làm ngữ cảnh (dịch song song thì AI lặp ý hoặc mất nghĩa: "Ngày
    /// trước, trước đây..."); câu khác thì không phải chờ. Câu bị thay giữa chừng vẫn được dịch và đọc nốt.
    private final class ProgLine {
        var raw = ""                 // chữ gốc đã gửi dịch
        var vi = ""                  // bản dịch đã ghép theo thứ tự
        var transcriptID: UUID?
        var speaker: String?         // người nói lúc câu bắt đầu
        var language: String?        // giọng đọc; nil = ngôn ngữ đích
        var nextSeq = 0              // số thứ tự của cụm gửi dịch kế tiếp
        var applied = 0              // số cụm đã ghép
        var results: [Int: (chunk: String, text: String, label: String, stable: Bool)] = [:]
        var dub = "", dubSource = ""
        var finishWhenDone = false   // chữ đã đứng yên hoặc câu đã bị thay: ghép xong các cụm đang dịch thì đọc nốt
        var boost: Double?           // tốc độ đọc tính một lần cho cả câu, các cụm đọc cùng một nhịp
        var lastTask: Task<Void, Never>?   // cụm gửi dịch gần nhất: cụm sau chờ cụm trước để có bản dịch của nó làm ngữ cảnh
        var earlyFlush: Task<Void, Never>?   // hẹn đọc trước phần đã dịch khi phần sau của câu tới chậm
        var firstSeen = 0            // số ký tự lần đầu thấy câu này
        var typedIn = false          // câu được game gõ ra dần trên màn hình (chữ dài thêm hẳn so với lần đầu thấy)
        var pending: Int { nextSeq - applied }
    }

    private func progressiveCommit(stable: Bool) async throws {
        guard let chunk = Progressive.nextChunk(latest: progLatestRaw, committedNorm: progNorm, stable: stable) else {
            // Chữ đã đứng yên mà mọi cụm đều đã gửi dịch: phần còn chờ đủ câu (bản dịch thiếu dấu chấm cuối, câu bị cắt sang
            // khung phụ đề sau) thì đọc luôn, không đợi tới khi câu kế tiếp hiện ra.
            if stable { finishLineDub(progLine) }
            return
        }
        presentSignature = lastSignature
        let source = SourceLanguage.find(settings.sourceLanguage)
        let line = progLine
        if line.nextSeq == 0 { line.speaker = lastSpeaker }

        if settings.mode == .audioOnly {
            commitProgressive(chunk: chunk)
            line.nextSeq += 1; line.applied += 1
            line.language = source.speech
            hideOverlay()
            if settings.speakEnabled { queueLineDub(line, text: chunk, source: chunk, stable: stable) }
            status = L("Đã đọc.", "Read aloud.")
            return
        }

        // Cả câu hiện ra một lần (người chơi bấm bỏ hiệu ứng chạy chữ) mà đã từng dịch: dùng bộ nhớ, không gọi API.
        if progNorm.isEmpty, chunk.count == progLatestRaw.count, let hit = memory.lookup(chunk) {
            commitProgressive(chunk: chunk)
            line.nextSeq += 1; line.applied += 1
            line.vi = hit
            lastTranslation = hit
            line.transcriptID = record(source: line.raw, translation: hit, updating: line.transcriptID)
            appendHistory(ContextLine(speaker: line.speaker, source: chunk, vi: hit))
            showLine(hit, original: line.raw)
            if settings.speakEnabled { queueLineDub(line, text: hit, source: chunk, stable: true) }
            status = L("Đang nhận phụ đề…", "Watching for subtitles…")
            return
        }

        status = L("Đang dịch…", "Translating…")
        refreshContext()
        // Không cho AI phân loại các cụm của Dịch dần: một cụm đứng riêng (như "Technical Attacks.") dễ bị coi là tên mục và bỏ qua,
        // làm mất một đoạn của câu. Chữ giao diện đã được lớp luật lọc khi câu bắt đầu.
        // Chỉ cụm nối tiếp mới kèm lời dặn "đây là một đoạn nối tiếp"; cụm đầu dịch như câu bình thường.
        let fragment = !progNorm.isEmpty
        let speakerName = lastSpeaker
        commitProgressive(chunk: chunk)
        let seq = line.nextSeq
        line.nextSeq += 1
        progInFlight += 1
        mainBusy = true
        let previous = line.lastTask
        line.lastTask = Task { [weak self] in
            await previous?.value   // cụm trước của cùng câu dịch xong và đã ghép, để lấy làm ngữ cảnh
            guard let self else { return }
            let context = self.contextWindow()
            var text = "", label = ""
            for attempt in 1...2 {   // lỗi hay rỗng thì thử lại một lần; vẫn không được thì bỏ cụm này
                do {
                    let o = try await self.hub.translate(chunk, context: context, source: source, speaker: speakerName,
                                                         fragment: fragment, classify: false)
                    label = o.label
                    if !o.text.isEmpty { text = o.text; break }
                    DebugLog.write("Dịch dần: cụm \"\(chunk)\" dịch ra rỗng (lần \(attempt), \(o.label))")
                } catch {
                    DebugLog.write("Dịch dần: cụm \"\(chunk)\" lỗi (lần \(attempt)): \(error.localizedDescription)")
                    if attempt == 2 { self.report(error) }
                }
            }
            self.progInFlight -= 1
            self.mainBusy = self.progInFlight > 0
            self.deliver(line, seq: seq, chunk: chunk, text: text, label: label, stable: stable)
        }
    }

    /// Nhận bản dịch của một cụm; ghép theo thứ tự (cụm sau dịch xong trước thì chờ cụm trước).
    private func deliver(_ line: ProgLine, seq: Int, chunk: String, text: String, label: String, stable: Bool) {
        line.results[seq] = (chunk, text, label, stable)
        while let r = line.results.removeValue(forKey: line.applied) {
            line.applied += 1
            guard !r.text.isEmpty else {
                DebugLog.write("Dịch dần: bỏ cụm không dịch được \"\(r.chunk)\"")
                continue
            }
            DebugLog.write("Dịch dần: \"\(r.chunk)\" → \"\(r.text)\" [\(r.label)]")
            line.vi += (line.vi.isEmpty ? "" : " ") + r.text
            line.transcriptID = record(source: line.raw, translation: line.vi, updating: line.transcriptID)
            appendHistory(ContextLine(speaker: line.speaker, source: r.chunk, vi: r.text))
            // Câu đã bị câu khác thay thì không hiện lại lên màn hình, chỉ đọc nốt.
            if line === progLine {
                lastTranslation = line.vi
                if settings.overlayActive {
                    let wasHidden = !overlay.model.visible
                    overlay.show(vi: line.vi, original: settings.mode == .viAndEn ? line.raw : nil, fit: lastFit)
                    if wasHidden { grabber.invalidate() }
                }
                status = L("Đang nhận phụ đề…", "Watching for subtitles…")
            }
            if settings.speakEnabled { queueLineDub(line, text: r.text, source: r.chunk, stable: r.stable) }
        }
        if line.finishWhenDone, line.pending == 0 { finishLineDub(line) }
    }

    private func appendHistory(_ c: ContextLine) {
        history.append(c)
        if history.count > ContextStore.limit { history.removeFirst(history.count - ContextStore.limit) }
    }

    /// Chữ chạy: chỉ lồng tiếng khi đã đủ một câu (có dấu kết thúc, hoặc chữ đã đứng yên), không đọc từng mẩu rời rạc.
    /// Xét dấu kết thúc ở cả chữ gốc lẫn bản dịch: với cụm nối tiếp, AI hay bỏ dấu chấm cuối bản dịch dù câu gốc đã hết
    /// ("...grew side-by-side." → "...lớn lên cùng nhau"), nếu chỉ xét bản dịch thì câu nằm chờ tới khi câu sau hiện ra.
    private func queueLineDub(_ line: ProgLine, text: String, source: String, stable: Bool) {
        line.earlyFlush?.cancel()
        line.earlyFlush = nil
        line.dub += (line.dub.isEmpty ? "" : " ") + text
        line.dubSource += (line.dubSource.isEmpty ? "" : " ") + source
        func ends(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).last.map { ".!?…。！？\"”".contains($0) } ?? false }
        if ends(text) || ends(source) || stable { flushLineDub(line); return }
        // Phần đầu câu đã dịch mà phần sau chưa tới (AI chậm, hoặc game còn đang gõ): chờ một chút, chưa có thì đọc trước phần
        // đã có, phần sau đọc nối khi dịch xong. Trước đây giọng chờ đủ cả câu: phụ đề hiện nửa đầu rồi 5–6 giây sau mới nghe đọc
        // (nhật ký 07/10 21:32, cả Gemini lẫn Groq cùng chậm). Ngắt ở dấu phẩy nghe tự nhiên nên chờ ngắn; ngắt giữa cụm từ thì
        // chờ lâu hơn và chỉ khi phần sau đang dịch dở (còn chờ game gõ tiếp thì để cơ chế chữ đứng yên lo).
        func pause(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).last.map { ",;:—–".contains($0) } ?? false }
        // Cụm sau thường dịch xong sau 1–1,7 giây (Gemini, hoặc Groq khi Gemini quá 1 giây): chờ quá mức đó mới tách, không thì
        // câu bị đọc thành hai đoạn rời mà chẳng nhanh hơn bao nhiêu (đo thử: chờ 0,8 giây thì "Ngày trước," bị đọc riêng, cụm sau
        // tới chỉ chậm hơn 0,15 giây). Những lần chậm thật (4–6 giây) thì vẫn đọc sớm được vài giây.
        let wait: Double? = pause(text) || pause(source) ? 1.8 : (line.pending > 0 ? 2.5 : nil)
        guard let wait else { return }
        line.earlyFlush = Task { [weak self, weak line] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, let line, !line.dub.isEmpty else { return }
            DebugLog.write(String(format: "Lồng tiếng: phần sau của câu chưa tới sau %.1f s, đọc trước phần đã dịch", wait))
            self.flushLineDub(line)
        }
    }

    private func flushLineDub(_ line: ProgLine) {
        guard !line.dub.isEmpty else { return }
        defer { line.dub = ""; line.dubSource = "" }
        guard settings.speakEnabled else { return }
        // Tốc độ tính một lần cho cả câu: trước đây mỗi cụm tính riêng nên câu này đọc chậm, câu sau đọc vội, nghe lệch nhịp.
        let boost = line.boost ?? speechBoost(for: line.dub)
        line.boost = boost
        dub(line.dub, source: line.dubSource, language: line.language, speakerName: line.speaker ?? "", boost: boost,
            group: ObjectIdentifier(line), dedupSource: true, fresh: line.typedIn)
    }

    /// Chữ đã đứng yên, hộp thoại tắt, hoặc câu bị thay: đọc nốt phần đã dịch; cụm còn đang dịch thì đọc khi dịch xong.
    private func finishLineDub(_ line: ProgLine) {
        if line.pending > 0 { line.finishWhenDone = true; return }
        line.finishWhenDone = false
        flushLineDub(line)
        if !line.raw.isEmpty, !line.vi.isEmpty { memory.store(line.raw, line.vi) }
    }

    /// Chữ đã đứng yên đủ lâu để dịch nốt phần cuối: có dấu kết thúc câu thì 2 nhịp; dấu phẩy, hai chấm (câu bị cắt sang khung
    /// phụ đề sau, hay gặp ở cắt cảnh) thì 3 nhịp; không có dấu gì thì 6 nhịp, vì game hay ngừng gõ chữ một nhịp ở chỗ đổi màu.
    private func progressiveSettled(_ n: Int) -> Bool {
        guard let last = progLatestRaw.trimmingCharacters(in: .whitespaces).last else { return false }
        if ".!?…。！？\"”'".contains(last) { return n >= 2 }
        if ",;:—–、，；：".contains(last) { return n >= 3 }
        return n >= 6
    }

    // MARK: Lồng tiếng

    private func appleVoices(for language: String) -> [VoiceOption] {
        let base = String(language.split(separator: "-").first ?? "vi")
        return VoiceCatalog.apple(language: base, siriGender: speaker.siriGender[base] ?? .unknown)
    }

    /// Giọng thuyết minh: một giọng Siri, đọc thẳng (không dựng trước), nhanh và đồng nhất.
    private var voiceOverPlan: VoicePlan { VoicePlan(route: .siri) }

    private func plan(for m: CastMember, text: String, source: String, language: String) -> VoicePlan {
        guard settings.dubCharacters else { return voiceOverPlan }
        // Gemini TTS đang phát triển (chậm 4–8 giây mỗi câu): tạm chỉ dùng giọng Apple.
        var p = CastDirector.plan(for: m, line: text, source: source, voiceSource: .apple, emotion: settings.dubEmotion,
                                  genre: settings.genre, appleAvailable: appleVoices(for: language))
        if case .gemini = p.route, tts.usableKeyCount == 0 {
            p.route = p.fallback; p.style = nil   // chưa có key Gemini dùng được: đọc bằng giọng Apple
        }
        return p
    }

    /// Lồng tiếng một câu bằng giọng của nhân vật đang nói.
    /// Câu đã đọc gần đây chưa. Câu ngắn ("Cảm ơn ngài!") hai nhân vật nói giống nhau là chuyện thường: chỉ tính là lặp khi cùng
    /// người nói và giống cả câu. Câu dài thì so với chuỗi ghép các câu vừa đọc, vì một câu có thể đã được đọc thành nhiều cụm.
    private static func alreadySpoken(_ n: String, speaker: String, in recent: [SpokenLine], key: KeyPath<SpokenLine, String>) -> Bool {
        guard n.count >= 6 else { return false }
        if n.count < 20 {
            return recent.contains { $0.speaker == speaker && ($0[keyPath: key] == n || TextUtil.similar(n, $0[keyPath: key], tolerance: 0.1)) }
        }
        let items = recent.map { $0[keyPath: key] }.filter { !$0.isEmpty }
        if items.contains(where: { TextUtil.similar(n, $0, tolerance: 0.15) }) { return true }
        let joined = items.joined()
        return joined.contains(n) || TextUtil.similar(n, String(joined.suffix(n.count)), tolerance: 0.15)
    }

    private func dub(_ text: String, source: String, language: String? = nil, speakerName: String? = nil, boost: Double, force: Bool = false,
                     group: ObjectIdentifier? = nil, dedupSource: Bool = false, fresh: Bool = false) {
        let lang = language ?? settings.target.speech
        // speakerName "" = câu không có tên (người dẫn chuyện); nil = dùng tên người nói đang hiện.
        let raw = speakerName ?? lastSpeaker
        let name = (raw?.isEmpty ?? true) ? nil : raw
        // Lớp chặn cuối: câu vừa đọc trong 45 giây qua thì không đọc lại. Gặp thực tế: chuyển sang app khác rồi quay lại game,
        // câu thoại vẫn nằm đó nên app tưởng câu mới và đọc lại sau 16 giây; OCR đọc chập chờn làm cùng một câu hiện lại.
        // So cả bản dịch lẫn câu gốc (`dedupSource`): cùng một câu gốc mà AI dịch ra hai cách khác nhau thì bản dịch không trùng.
        // Đọc lại bằng tay (force) thì luôn đọc. Câu game vừa gõ ra lại từ đầu (`fresh`, vd. nói chuyện lại với NPC) cũng đọc:
        // gặp thực tế 07/10 16:31, nói lại với một NPC thì câu đầu được đọc (đã quá 45 giây) còn câu sau bị bỏ, đọc nửa chừng rồi im.
        if !force {
            let now = Date()
            recentDubs.removeAll { now.timeIntervalSince($0.at) > 45 }
            let n = TextUtil.normalize(text), ns = dedupSource ? TextUtil.normalize(source) : ""
            let repeated = Self.alreadySpoken(n, speaker: name ?? "", in: recentDubs, key: \.norm)
                || (!ns.isEmpty && Self.alreadySpoken(ns, speaker: name ?? "", in: recentDubs, key: \.source))
            if repeated, !fresh {
                DebugLog.write("Lồng tiếng: bỏ, câu này vừa đọc rồi: \(text.prefix(40))")
                return
            }
            if repeated { DebugLog.write("Lồng tiếng: câu vừa đọc nhưng game gõ lại từ đầu (nói lại), đọc lại: \(text.prefix(40))") }
            recentDubs.append(SpokenLine(norm: n, source: ns, speaker: name ?? "", at: now))
        }
        guard settings.dubCharacters else {   // Voice-over: không dựng dàn diễn viên, không hỏi AI, không tốn lượt
            // Một giọng Siri đọc thẳng: cảm xúc của câu chỉ đổi tốc độ và âm lượng (đổi cao độ buộc phải dựng trước, trễ thêm).
            var p = voiceOverPlan
            if settings.dubEmotion {
                let e = Emotion.detect(source: source)
                if e != .neutral { p.rate = e.appleAdjust.rate; p.volume = e.appleAdjust.volume }
            }
            speaker.speak(DubLine(text: text, language: lang, speaker: name, boost: boost, force: force, group: group), plan: p)
            return
        }
        let member = castMember(for: name, source: source, translation: text, language: lang)
        let p = plan(for: member, text: text, source: source, language: lang)
        speaker.speak(DubLine(text: text, language: lang, speaker: name, boost: boost, force: force, group: group), plan: p)
    }

    /// Nhân vật trong dàn diễn viên; gặp tên mới thì thêm vào, tự chọn giọng, và hỏi AI giới tính, tuổi để chọn lại cho đúng.
    private func castMember(for name: String?, source: String, translation: String, language: String) -> CastMember {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            if let n = settings.cast.first(where: { $0.isNarrator }) { return n }
            settings.cast.insert(.narrator, at: 0)
            return .narrator
        }
        let key = CastMember.key(for: name)
        if let m = settings.cast.first(where: { $0.id == key }) {
            if !m.classified { classify(key, name: name, source: source, translation: translation, language: language) }
            return m
        }
        var m = CastMember(id: key, name: name)
        CastDirector.autoAssign(&m, cast: settings.cast, apple: appleVoices(for: language))
        if !settings.cast.contains(where: { $0.isNarrator }) { settings.cast.insert(.narrator, at: 0) }
        settings.cast.append(m)
        DebugLog.write("Dàn diễn viên: thêm \(name)")
        classify(key, name: name, source: source, translation: translation, language: language)
        return m
    }

    /// Chọn lại giọng cho các nhân vật app tự chọn, theo thứ tự trong danh sách (mỗi nhân vật chỉ xét những người đứng trước),
    /// để kết quả ổn định giữa các lần mở app. Nhân vật bạn đã chỉnh tay giữ nguyên.
    private func reassignCast() {
        guard settings.dubCharacters, speaker.siriGender[settings.target.base] != nil else { return }
        let apple = appleVoices(for: settings.target.speech)
        var done: [CastMember] = []
        for var m in settings.cast {
            if !m.isNarrator, !m.manual { CastDirector.autoAssign(&m, cast: done, apple: apple) }
            done.append(m)
        }
        if done != settings.cast { settings.cast = done }
    }

    private func classify(_ key: String, name: String, source: String, translation: String, language: String) {
        guard !classifying.contains(key) else { return }
        classifying.insert(key)
        let system = "You classify video game characters for voice casting. Reply with ONLY compact JSON like {\"gender\":\"male\",\"age\":\"adult\",\"kind\":\"human\"}. gender: male, female or unknown. age: child, young, adult, elder or unknown. kind: human (also elves, dwarves and other humanoids who talk like people), monster (beasts, demons, creatures) or robot (machines, AIs, synthetic voices). Use the name, the genre and how the character speaks."
        let user = "Game genre: \(settings.genre.englishHint)\nCharacter name: \(name)\nA line they said: \(source)\nTranslation: \(translation)"
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.hub.ask(system: system, user: user)
            self.classifying.remove(key)
            guard let i = self.settings.cast.firstIndex(where: { $0.id == key }) else { return }
            var m = self.settings.cast[i]
            m.classified = true
            if let reply, let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
               let obj = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any] {
                if !m.manual {
                    m.gender = Gender(rawValue: (obj["gender"] as? String ?? "").lowercased()) ?? .unknown
                    m.age = AgeGroup(rawValue: (obj["age"] as? String ?? "").lowercased()) ?? .unknown
                    let kind = (obj["kind"] as? String ?? "").lowercased()
                    m.creature = kind == "monster" || kind == "robot"
                    CastDirector.autoAssign(&m, cast: self.settings.cast, apple: self.appleVoices(for: language))
                }
                DebugLog.write("Dàn diễn viên: \(name) → \(m.gender.title), \(m.age.title)")
            } else if reply == nil {
                m.classified = false   // chưa hỏi được (hết lượt, mất mạng): lần sau thử lại
            }
            self.settings.cast[i] = m
        }
    }

    private func commitProgressive(chunk: String) {
        progNorm += TextUtil.normalize(chunk)
        progRaw += (progRaw.isEmpty ? "" : " ") + chunk
        progLine.raw = progRaw
        lastSource = progRaw
    }

    private func confirm(_ text: String) async throws {
        let norm = TextUtil.normalize(text)
        shown = norm
        presentSignature = lastSignature
        if let why = skipReason(text) {   // không phải lời thoại: không dịch, không đọc, không hiện
            DebugLog.write("Bỏ qua (\(why)): \(text)")
            status = L("Bỏ qua (\(why)).", "Skipped (\(why)).")
            hideOverlay()
            return
        }
        lastSource = text
        refreshContext()

        if settings.mode == .audioOnly {
            lastTranslation = ""
            hideOverlay()
            if settings.speakEnabled {
                dub(text, source: text, language: SourceLanguage.find(settings.sourceLanguage).speech, boost: speechBoost(for: text))
            }
            status = L("Đã đọc.", "Read aloud.")
            return
        }

        let vi: String
        var spoken = ""   // phần đã đọc trong lúc bản dịch còn đang về theo luồng
        let boost = speechBoost(for: text)   // một lần cho cả câu, kể cả khi đọc từng câu nhỏ
        if let hit = cache[norm] ?? memory.lookup(text) {
            vi = hit
        } else {
            status = L("Đang dịch…", "Translating…")
            mainBusy = true
            var streamed = false
            // Dịch máy Apple chạy song song trên máy: AI chưa trả lời sau 0,4 giây thì hiện tạm bản của Apple, có bản AI thì thay.
            let quick = startQuickTranslation(text, norm: norm) { streamed }
            defer { mainBusy = false; quick?.cancel() }
            let outcome: TranslationOutcome
            do {
                outcome = try await hub.translate(text, context: contextWindow(), source: SourceLanguage.find(settings.sourceLanguage),
                                                  speaker: lastSpeaker) { [weak self] partial in
                    guard let self, self.shown == norm else { return }
                    streamed = true
                    quick?.cancel()
                    self.showLine(partial, original: text)
                    // Đọc ngay các câu đã trọn vẹn trong phần đã về, không chờ cả đoạn.
                    if self.settings.speakEnabled, let cut = TextUtil.completedSentences(partial, after: spoken.count) {
                        let piece = String(partial.prefix(cut).dropFirst(spoken.count)).trimmingCharacters(in: .whitespaces)
                        spoken = String(partial.prefix(cut))
                        if !piece.isEmpty { self.dub(piece, source: text, boost: boost) }
                    }
                }
            } catch {
                shown = ""   // để lần đọc sau thử dịch lại câu này
                lastSignature = nil   // hộp thoại đứng yên cũng phải đọc lại, không thì câu này không bao giờ được dịch
                throw error
            }
            // Trong lúc chờ AI, người dùng đã đổi hồ sơ hoặc ngôn ngữ: bỏ kết quả, không ghi nhầm vào trí nhớ của hồ sơ mới.
            guard shown == norm else { return }
            DebugLog.write("Dịch: \"\(text)\" → \"\(outcome.text)\" [\(outcome.label)]\(spoken.isEmpty ? "" : " (đọc sớm \(spoken.count) ký tự)")")
            if outcome.text.isEmpty {
                status = L("Bỏ qua: không phải phụ đề.", "Skipped: not a subtitle.")
                hideOverlay()
                return
            }
            vi = outcome.text
            cache[norm] = vi
            if cache.count > 300 { cache.removeAll() }
            memory.store(text, vi)
        }

        _ = record(source: text, translation: vi)
        history.append(ContextLine(speaker: lastSpeaker, source: text, vi: vi))
        if history.count > ContextStore.limit { history.removeFirst(history.count - ContextStore.limit) }
        showLine(vi, original: text)
        status = L("Đang nhận phụ đề…", "Watching for subtitles…")
        if settings.speakEnabled {
            let rest = TextUtil.remainder(of: vi, afterSpoken: spoken)
            if !rest.isEmpty { dub(rest, source: text, boost: boost) }
        }
    }

    /// Chỉ dùng cho tự kiểm tra: chạy một câu qua đúng đường chốt câu (dịch theo luồng, hiện phụ đề đè lên game, đọc).
    func debugConfirm(_ text: String) async {
        overlay.region = settings.region
        do { try await confirm(text) } catch { DebugLog.write("Tự kiểm tra: \(error.localizedDescription)") }
    }

    /// Hiện một câu (đang dịch dần theo luồng, bản tạm, hoặc bản cuối) ở cửa sổ app và phụ đề đè lên game.
    private func showLine(_ vi: String, original: String) {
        lastTranslation = vi
        if settings.overlayActive {
            let wasHidden = !overlay.model.visible
            overlay.show(vi: vi, original: settings.mode == .viAndEn ? original : nil, fit: lastFit)
            _ = wasHidden   // ảnh chụp loại trừ cả ứng dụng OverSub nên không cần lấy lại danh sách cửa sổ
        }
    }

    /// Bản dịch tạm bằng Dịch máy Apple (trên máy, thường dưới 0,3 giây). Chỉ hiện nếu AI chưa trả lời, chưa ra chữ theo luồng,
    /// và vẫn đang là câu đó. Không đọc bản tạm: giọng đọc chờ bản AI hay hơn.
    private func startQuickTranslation(_ text: String, norm: String, streamed: @escaping () -> Bool) -> Task<Void, Never>? {
        guard settings.quickAppleTranslation, !settings.disabledEngines.contains(.appleTranslation),
              hub.currentOrder().first != .appleTranslation else { return nil }
        let src = SourceLanguage.find(settings.sourceLanguage).code, tgt = settings.target.code
        return Task { [weak self] in
            let started = Date()
            guard let quick = try? await Providers.appleTranslate(text, source: src, target: tgt) else { return }
            let wait = 0.25 - Date().timeIntervalSince(started)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled, let self, self.shown == norm, !streamed() else { return }
            self.showLine(Providers.clean(quick), original: text)
            DebugLog.write("Hiện tạm bản Dịch máy Apple trong lúc chờ AI: \"\(quick.prefix(60))\"")
        }
    }

    /// Tự cân tốc độ đọc: ước lượng khoảng cách giữa các câu thoại, câu dài mà thoại dồn dập thì đọc nhanh hơn để kịp.
    private func speechBoost(for vi: String) -> Double {
        let now = Date()
        if let last = lastConfirmAt {
            let gap = min(max(now.timeIntervalSince(last), 0.8), 12)
            gapEMA = 0.6 * gapEMA + 0.4 * gap
        }
        lastConfirmAt = now
        guard settings.autoSpeechRate else { return 1 }
        let charsPerSecond = 13.0   // ước lượng tốc độ đọc tiếng Việt ở tốc độ gốc
        var factor = (Double(vi.count) / charsPerSecond) / (gapEMA * 0.9)
        // Câu trước chưa đọc xong mà câu mới đã tới: không cắt, xếp hàng, và đọc nhanh hơn theo độ dài hàng đợi để đuổi kịp.
        let backlog = speaker.pendingCount
        if backlog > 0 { factor = max(factor, 1.3 + 0.2 * Double(backlog - 1)) }
        return min(2.0, max(1.0, factor))
    }
}
