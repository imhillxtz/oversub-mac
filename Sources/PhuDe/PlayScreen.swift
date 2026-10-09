import AVFoundation
import AppKit
import Combine
import SwiftUI

/// Màn hình chơi game: hình và tiếng từ capture card trong một cửa sổ thường của OverSub, để chơi máy console trên Mac mà không
/// cần app xem capture card riêng. Phụ đề, giọng đọc và dịch màn hình chạy trên cửa sổ này như với mọi game khác: ảnh chụp
/// màn hình của OverSub loại mọi cửa sổ của chính app, trừ cửa sổ này (xem ScreenGrabber).
@MainActor
final class PlayScreen: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = PlayScreen()
    /// Mã "game" của cửa sổ này trong hồ sơ game. Không phải bundle id thật, chỉ để hồ sơ gắn và tự chuyển theo cửa sổ.
    static let gameID = "vn.imhillxtz.phude.playscreen"
    static var gameName: String { L("Màn hình chơi game", "Game screen") }

    enum Phase: Equatable { case closed, starting, live, waiting, unplugged, noPermission, failed(String) }
    @Published private(set) var phase: Phase = .closed
    @Published private(set) var isOpen = false
    @Published private(set) var isFullScreen = false
    @Published private(set) var deviceName = ""
    /// Cho số trễ thêm trong menu và Cài đặt: tín hiệu, cỡ khung hình và hệ số GPU của máy (lần dùng gần nhất khi chưa mở),
    /// cùng độ trễ thêm đo được của cách đang dùng. Cập nhật 2 giây một lần khi có hình.
    @Published private(set) var cost = PlayCost.saved
    @Published private(set) var measuredLag: Double?

    /// Hồ sơ game tự chuyển khi cửa sổ này được chọn (Engine đặt).
    var onBecameKey: (() -> Void)?
    let settings = PlaySettings.shared

    private(set) var window: NSWindow?
    private var view: PlayView?
    private var statusHost: NSView?
    private var controls: NSPanel?
    private var renderer: PlayRenderer?
    private var capture: PlayCapture?
    private var device: AVCaptureDevice?
    private var signal = ""
    /// Định dạng và nguồn tiếng (theo PlaySettings) của phiên đang chạy, để biết khi nào Cài đặt hay menu đổi thì phải mở lại.
    private var runningFormat: String?
    private var runningAudio: String?
    private var duckLevel = 1.0
    private var hoveringControls = false
    private var hideTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var costTask: Task<Void, Never>?
    private var moveLogTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private var sessionBag = Set<AnyCancellable>()

    /// Số hiệu cửa sổ cho ScreenCaptureKit; nil khi chưa mở.
    var windowID: CGWindowID? {
        guard let w = window, w.windowNumber > 0 else { return nil }
        return CGWindowID(w.windowNumber)
    }

    private override init() {
        super.init()
    }

    // MARK: Mở, đóng

    func open() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        // Thiết bị đã chọn lần trước, không có thì capture card đang cắm. Không tự bật camera FaceTime hay webcam khi chưa cắm card.
        let devices = CaptureCards.shared.devices
        let dev = devices.first { $0.uniqueID == settings.deviceID } ?? devices.first { $0.uniqueID == CaptureCards.shared.card?.id }
        guard makeWindow() else { return }
        start(dev)
    }

    func close() { window?.performClose(nil) }

    private func makeWindow() -> Bool {
        guard let r = PlayRenderer() else {
            DebugLog.write("Màn hình chơi: máy không dựng được bộ vẽ Metal")
            return false
        }
        renderer = r
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = Self.gameName
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenPrimary]
        w.minSize = NSSize(width: 480, height: 270)
        w.appearance = NSAppearance(named: .darkAqua)
        w.delegate = self
        let v = PlayView(renderer: r)
        v.onPointer = { [weak self] in self?.pointerMoved() }
        v.onExit = { [weak self] in self?.scheduleHide(after: 0.6) }
        v.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        w.contentView = v
        view = v
        var autosave = "OverSubPlayScreen"
        #if DEVTOOLS
        if ProcessInfo.processInfo.environment["OVERSUB_PLAY_TEST"] != nil { autosave = "OverSubPlayScreenTest" }
        #endif
        if !w.setFrameUsingName(autosave) { w.center() }
        w.setFrameAutosaveName(autosave)
        w.level = settings.onTop ? .floating : .normal
        window = w
        controls = makeControls(for: w)
        observeSettings()
        // Mở từ menu thanh menu hay khi app khác đang ở trước thì macOS có thể không cho kích hoạt app: vẫn đưa cửa sổ lên trên.
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        NSApp.activate()
        isOpen = true
        DebugLog.write("Màn hình chơi: mở cửa sổ \(Self.frameText(w))")
        return true
    }

    /// Bắt đầu nhận từ một thiết bị (hoặc báo chưa có thiết bị). Hỏi quyền Camera trước, rồi quyền Micrô nếu card có tiếng.
    private func start(_ dev: AVCaptureDevice?) {
        stopCapture()
        guard let dev else {
            device = nil
            deviceName = ""
            setPhase(.unplugged)
            return
        }
        device = dev
        deviceName = dev.localizedName
        runningFormat = settings.formats[dev.uniqueID]
        runningAudio = settings.audioSources[dev.uniqueID]
        settings.deviceID = dev.uniqueID
        window?.title = "\(Self.gameName) · \(dev.localizedName)"
        setPhase(.starting)
        Task { @MainActor in
            guard await CaptureCards.authorize(.video) else {
                DebugLog.write("Màn hình chơi: chưa có quyền Camera (trạng thái \(AVCaptureDevice.authorizationStatus(for: .video).rawValue))")
                self.setPhase(.noPermission)
                PlayPermissionGuide.shared.show(.camera, near: self.window)
                return
            }
            let audio = self.audioSource(for: dev)
            var audioOK = false
            if let audio {
                audioOK = await CaptureCards.authorize(.audio)
                if !audioOK {
                    DebugLog.write("Màn hình chơi: chưa có quyền Micrô, mở hình không có tiếng (\(audio.localizedName))")
                    PlayPermissionGuide.shared.show(.microphone, near: self.window)
                }
            }
            guard self.device === dev, let renderer = self.renderer else { return }
            let cap = PlayCapture(renderer: renderer)
            cap.onFirstFrame = { _ in self.setPhase(.live) }
            self.capture = cap
            let format = self.chosenFormat(dev)
            cap.start(.init(video: dev, format: format?.format, audio: audioOK ? audio : nil, outputUID: self.settings.outputUID,
                            volume: Float(self.effectiveVolume))) { result in
                guard self.capture === cap else { return }
                switch result {
                case .success(let desc):
                    self.signal = desc
                    self.watchFrames()
                case .failure(let error):
                    DebugLog.write("Màn hình chơi: không mở được \(dev.localizedName): \(error.localizedDescription)")
                    self.setPhase(.failed(error.localizedDescription))
                }
            }
        }
    }

    private func stopCapture() {
        watchTask?.cancel()
        watchTask = nil
        guard let cap = capture else { return }
        capture = nil
        #if DEVTOOLS
        cap.stopPattern()
        #endif
        // Dừng phiên có thể mất vài trăm mili giây: làm ở nền để cửa sổ đóng ngay.
        Task.detached { cap.stop() }
    }

    /// Theo dõi khung hình: card cắm nhưng máy console tắt hay rút dây HDMI thì báo chưa có hình, có lại thì ẩn báo.
    private func watchFrames() {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            var seconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let cap = self.capture else { return }
                seconds += 1
                let gap = cap.secondsSinceLastFrame
                if gap > 2.5, self.phase == .live || (self.phase == .starting && seconds >= 3) { self.setPhase(.waiting) }
                if gap < 1, self.phase == .waiting { self.setPhase(.live) }
                self.updateHeadroom()
            }
        }
    }

    private func teardown() {
        hideTask?.cancel()
        stopCapture()
        sessionBag.removeAll()
        if let controls { window?.removeChildWindow(controls); controls.orderOut(nil) }
        controls = nil
        statusHost = nil
        view = nil
        renderer = nil
        costTask?.cancel()
        costTask = nil
        measuredLag = nil
        device = nil
        window = nil
        isOpen = false
        isFullScreen = false
        phase = .closed
        NSCursor.setHiddenUntilMouseMoves(false)
        DebugLog.write("Màn hình chơi: đã đóng cửa sổ")
    }

    // MARK: Thiết bị, định dạng, tiếng

    private func chosenFormat(_ dev: AVCaptureDevice) -> CaptureCards.Choice? {
        if let key = settings.formats[dev.uniqueID], let f = dev.formats.first(where: { CaptureCards.key($0) == key }) {
            return CaptureCards.Choice(format: f, fps: CaptureCards.fps(f))
        }
        return CaptureCards.bestFormat(dev)
    }

    private func audioSource(for dev: AVCaptureDevice) -> AVCaptureDevice? {
        #if DEVTOOLS
        if ProcessInfo.processInfo.environment["OVERSUB_PLAY_NO_AUDIO"] != nil { return nil }
        #endif
        switch settings.audioSources[dev.uniqueID] {
        case "none": return nil
        case let id?: return CaptureCards.audioDevices().first { $0.uniqueID == id } ?? CaptureCards.audioDevice(for: dev)
        case nil: return CaptureCards.audioDevice(for: dev)
        }
    }

    /// Card cắm hay rút khi cửa sổ đang mở: rút thì dừng và báo, cắm lại (hoặc cắm card khác khi đang chờ) thì nhận tiếp.
    private func devicesChanged(_ list: [AVCaptureDevice]) {
        guard window != nil else { return }
        if let d = device, !list.contains(where: { $0.uniqueID == d.uniqueID }) {
            DebugLog.write("Màn hình chơi: \(d.localizedName) đã bị rút ra")
            stopCapture()
            device = nil
            setPhase(.unplugged)
        } else if device == nil, let next = list.first(where: { $0.uniqueID == settings.deviceID }) ?? list.first(where: CaptureCards.looksLikeCaptureCard) {
            DebugLog.write("Màn hình chơi: thấy \(next.localizedName), nhận hình tiếp")
            start(next)
        }
    }

    // MARK: Âm lượng

    private var effectiveVolume: Double {
        if settings.muted || (settings.muteWhenInactive && !NSApp.isActive) { return 0 }
        return settings.volume * duckLevel
    }

    /// Giảm tiếng game khi giọng đọc đang đọc (Speaker gọi); 1 là trả về bình thường.
    func duck(_ level: Double) {
        guard abs(level - duckLevel) > 0.001 else { return }
        duckLevel = level
        capture?.setVolume(Float(effectiveVolume), ramp: true)
    }

    // MARK: Tuỳ chọn

    private func observeSettings() {
        sessionBag.removeAll()
        settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.applySettings() }.store(in: &sessionBag)
        // Đổi thiết bị, định dạng hay nguồn tiếng (ở menu hay ở Cài đặt) thì mở lại phiên với lựa chọn mới.
        settings.$deviceID.dropFirst().removeDuplicates().receive(on: RunLoop.main).sink { [weak self] id in
            guard let self, self.window != nil, let id, id != self.device?.uniqueID,
                  let d = CaptureCards.shared.devices.first(where: { $0.uniqueID == id }) else { return }
            self.start(d)
        }.store(in: &sessionBag)
        Publishers.CombineLatest(settings.$formats, settings.$audioSources).dropFirst().receive(on: RunLoop.main).sink { [weak self] f, a in
            guard let self, self.window != nil, let d = self.device else { return }
            if f[d.uniqueID] != self.runningFormat || a[d.uniqueID] != self.runningAudio { self.start(d) }
        }.store(in: &sessionBag)
        CaptureCards.shared.$devices.dropFirst().sink { [weak self] list in self?.devicesChanged(list) }.store(in: &sessionBag)
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            nc.publisher(for: name).sink { [weak self] _ in
                guard let self, self.settings.muteWhenInactive else { return }
                self.capture?.setVolume(Float(self.effectiveVolume), ramp: true)
            }.store(in: &sessionBag)
        }
        applySettings()
    }

    private func applySettings() {
        let s = settings
        renderer?.update {
            $0.range = s.range; $0.matrix = s.matrix; $0.gamut = s.gamut; $0.hdr = s.hdr
            $0.upscaler = s.upscaler; $0.sharpen = s.sharpen; $0.antiAlias = s.antiAlias; $0.frameGen = s.frameGen
            $0.fill = s.fill; $0.latency = s.latency
        }
        updateHeadroom()
        capture?.setVolume(Float(effectiveVolume), ramp: false)
        capture?.setOutput(s.outputUID)
        window?.level = s.onTop ? .floating : .normal
    }

    private func updateHeadroom() {
        let h = Double(window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        renderer?.update { $0.headroom = h }
    }

    // MARK: Trạng thái trong cửa sổ

    private func setPhase(_ p: Phase) {
        guard phase != p else { return }
        phase = p
        DebugLog.write("Màn hình chơi: trạng thái \(p)")
        // Lời báo chỉ nằm trong cửa sổ khi chưa có hình; có hình thì gỡ hẳn để không lọt vào ảnh chụp phụ đề.
        costTask?.cancel()
        costTask = nil
        if p == .live {
            costTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, let info = self.renderer?.costInfo() else { return }
                    // Chỉ đăng khi chữ hiển thị có thể đổi, khỏi vẽ lại trang Cài đặt mỗi lần hệ số nhích một chút.
                    if !info.cost.similar(to: self.cost) { self.cost = info.cost }
                    if info.measured.map({ ($0 * 2).rounded() }) != self.measuredLag.map({ ($0 * 2).rounded() }) { self.measuredLag = info.measured }
                }
            }
        } else {
            measuredLag = nil
        }
        if p == .live {
            statusHost?.removeFromSuperview()
            statusHost = nil
        } else if statusHost == nil, let v = view {
            let host = NSHostingView(rootView: PlayStatusView(screen: self))
            host.sizingOptions = []
            host.frame = v.bounds
            host.autoresizingMask = [.width, .height]
            v.addSubview(host)
            statusHost = host
        }
    }

    func retry() {
        let devices = CaptureCards.shared.devices
        start(device ?? devices.first { $0.uniqueID == settings.deviceID } ?? devices.first { $0.uniqueID == CaptureCards.shared.card?.id })
    }

    // MARK: Thanh điều khiển

    private func makeControls(for w: NSWindow) -> NSPanel {
        let host = NSHostingView(rootView: PlayControlsView(screen: self, settings: settings))
        host.sizingOptions = []
        let size = PlayControlsView.size
        host.frame = NSRect(origin: .zero, size: size)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.contentView = host
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        p.alphaValue = 0
        p.ignoresMouseEvents = true
        w.addChildWindow(p, ordered: .above)
        placeControls(p, in: w)
        return p
    }

    private func placeControls(_ p: NSPanel, in w: NSWindow) {
        let f = w.frame
        p.setFrameOrigin(NSPoint(x: (f.midX - p.frame.width / 2).rounded(), y: f.minY + 8))
    }

    func hoverControls(_ on: Bool) {
        hoveringControls = on
        if on { hideTask?.cancel() } else { scheduleHide(after: 1.5) }
    }

    private func pointerMoved() {
        setChrome(visible: true)
        scheduleHide(after: 2.2)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.hoveringControls else { return }
            self.setChrome(visible: false)
        }
    }

    /// Hiện hoặc ẩn thanh điều khiển và ba nút cửa sổ; ẩn thì giấu cả con trỏ khi đang ở trên hình.
    private func setChrome(visible: Bool) {
        guard let w = window else { return }
        controls?.ignoresMouseEvents = !visible
        let buttons = w.standardWindowButton(.closeButton)?.superview
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.12 : 0.3
            controls?.animator().alphaValue = visible ? 1 : 0
            if !isFullScreen { buttons?.animator().alphaValue = visible ? 1 : 0 }
        }
        if !visible, w.isKeyWindow, let v = view, v.bounds.contains(v.convert(w.mouseLocationOutsideOfEventStream, from: nil)) {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    /// Menu tuỳ chọn mở lên phía trên thanh điều khiển (thanh nằm sát chân cửa sổ, mở xuống thì hay bị cắt ở chân màn hình).
    func showMenu() {
        guard let host = controls?.contentView else { return }
        let menu = buildMenu()
        menu.popUp(positioning: nil, at: Self.menuPoint(menu, in: host), in: host)
    }

    static func menuPoint(_ menu: NSMenu, in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.width - 60, y: host.bounds.midY + 24 + menu.size.height)
    }

    // MARK: Menu tuỳ chọn

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let s = settings

        let devices = CaptureCards.shared.devices
        m.addItem(submenu(L("Thiết bị hình", "Video device"), items: devices.isEmpty
            ? [PlayMenuItem(L("Chưa thấy thiết bị nào", "No device found"), enabled: false) {}]
            : devices.map { d in PlayMenuItem(d.localizedName, on: d.uniqueID == device?.uniqueID) { [weak self] in
                self?.settings.deviceID = d.uniqueID
            } }))

        if let dev = device {
            let best = CaptureCards.bestFormat(dev)
            let stored = s.formats[dev.uniqueID]
            var items = [PlayMenuItem(L("Tự động", "Automatic") + (best.map { " (\(CaptureCards.describe($0.format, fps: $0.fps)))" } ?? ""),
                                      on: stored == nil) { [weak self] in
                self?.settings.formats[dev.uniqueID] = nil
            }]
            var seen = Set<String>()
            let formats = dev.formats.sorted { a, b in
                let sa = CaptureCards.size(a), sb = CaptureCards.size(b)
                return (Int(sa.width) * Int(sa.height), CaptureCards.fps(a)) > (Int(sb.width) * Int(sb.height), CaptureCards.fps(b))
            }
            for f in formats where seen.insert(CaptureCards.key(f)).inserted {
                let key = CaptureCards.key(f)
                items.append(PlayMenuItem(PlayLabels.format(f), on: stored == key) { [weak self] in
                    self?.settings.formats[dev.uniqueID] = key
                })
            }
            m.addItem(submenu(L("Định dạng hình", "Video format"), items: items + [.separator()] + PlayLabels.formatNotes.map { PlayMenuItem.note($0) }))

            let auto = CaptureCards.audioDevice(for: dev)
            let source = s.audioSources[dev.uniqueID]
            var audio: [NSMenuItem] = [
                PlayMenuItem(L("Tự động", "Automatic") + " (\(auto?.localizedName ?? L("không thấy", "none found")))", on: source == nil) { [weak self] in
                    self?.settings.audioSources[dev.uniqueID] = nil
                },
                PlayMenuItem(L("Không dùng tiếng", "No audio"), on: source == "none") { [weak self] in
                    self?.settings.audioSources[dev.uniqueID] = "none"
                },
            ]
            audio.append(.separator())
            for a in CaptureCards.audioDevices() {
                audio.append(PlayMenuItem(a.localizedName, on: source == a.uniqueID) { [weak self] in
                    self?.settings.audioSources[dev.uniqueID] = a.uniqueID
                })
            }
            m.addItem(submenu(L("Nguồn tiếng", "Audio source"), items: audio))
        }

        var outputs: [NSMenuItem] = [PlayMenuItem(L("Theo loa của macOS", "Same as macOS"), on: s.outputUID == nil) { s.outputUID = nil }]
        for o in AudioDevices.outputs() {
            outputs.append(PlayMenuItem(PlayLabels.output(o), on: s.outputUID == o.uid) { s.outputUID = o.uid })
        }
        outputs += [.separator(),
                    PlayMenuItem.note(L("Loa, tai nghe Bluetooth thường trễ tiếng hơn 0,1 giây.", "Bluetooth speakers and headphones usually lag over 0.1 s.")),
                    PlayMenuItem.note(L("Chơi game nên dùng loa máy hoặc tai nghe cắm dây.", "For games, use built-in speakers or wired headphones."))]
        m.addItem(submenu(L("Phát tiếng ra", "Audio output"), items: outputs))
        m.addItem(.separator())

        let using = renderer?.current
        let rangeNow = using.map { $0.full ? L("đang dùng Đầy đủ", "using Full") : L("đang dùng Giới hạn", "using Limited") }
        m.addItem(submenu(L("Dải màu", "Color range"), items: [
            PlayMenuItem(L("Tự động", "Automatic") + (rangeNow.map { " (\($0))" } ?? ""), on: s.range == .auto) { s.range = .auto },
            PlayMenuItem(L("Đầy đủ (0–255)", "Full (0–255)"), on: s.range == .full) { s.range = .full },
            PlayMenuItem(L("Giới hạn (16–235)", "Limited (16–235)"), on: s.range == .limited) { s.range = .limited },
            .separator(),
            PlayMenuItem.note(L("Hình nhạt, màu đen ngả xám: chọn Giới hạn.", "Washed out, grey blacks: choose Limited.")),
            PlayMenuItem.note(L("Hình gắt, vùng tối mất chi tiết: chọn Đầy đủ.", "Harsh, crushed shadows: choose Full.")),
            PlayMenuItem.note(L("Vẫn nhạt: trên Switch 2, đặt RGB Range là Full Range.", "Still washed out: on Switch 2, set RGB Range to Full Range.")),
        ]))
        m.addItem(submenu(L("Chuẩn màu", "Color matrix"), items: [
            PlayMenuItem(L("Tự động", "Automatic") + (using.map { " (BT.\($0.matrix))" } ?? ""), on: s.matrix == .auto) { s.matrix = .auto },
            PlayMenuItem("BT.709 (HD)", on: s.matrix == .bt709) { s.matrix = .bt709 },
            PlayMenuItem("BT.601 (SD)", on: s.matrix == .bt601) { s.matrix = .bt601 },
            .separator(),
            PlayMenuItem.note(L("Đỏ ngả cam, xanh lá ngả vàng: thử chuẩn còn lại.", "Reds look orange or greens look yellow: try the other one.")),
        ]))
        m.addItem(submenu(L("Không gian màu", "Color space"), items: [
            PlayMenuItem(L("sRGB (đúng màu)", "sRGB (accurate)"), on: s.gamut == .srgb) { s.gamut = .srgb },
            PlayMenuItem(L("Display P3 (rực hơn, lệch màu gốc)", "Display P3 (more vivid, less accurate)"), on: s.gamut == .p3) { s.gamut = .p3 },
        ]))
        m.addItem(submenu("HDR", items: [
            PlayMenuItem(L("Tắt (tín hiệu SDR)", "Off (SDR signal)"), on: s.hdr == .off) { s.hdr = .off },
            PlayMenuItem(L("Chuyển HDR về SDR", "Tone-map HDR to SDR"), on: s.hdr == .tone) { s.hdr = .tone },
            PlayMenuItem(L("Hiện HDR (EDR)", "Show HDR (EDR)"), on: s.hdr == .edr) { s.hdr = .edr },
            .separator(),
            PlayMenuItem.note(L("Switch 2 bật HDR mà hình xám, nhạt màu: chọn Chuyển HDR về SDR,", "If Switch 2 outputs HDR and the picture looks grey and dull,")),
            PlayMenuItem.note(L("hoặc tắt HDR Output trên Switch 2.", "choose Tone-map HDR to SDR, or turn off HDR Output on Switch 2.")),
            PlayMenuItem.note(L("Hiện HDR: bộ chỉnh hình chỉ còn phóng thường hoặc MetalFX.", "Show HDR: presets can only use standard upscaling or MetalFX.")),
        ]))
        m.addItem(.separator())

        // Bộ chỉnh hình và từng mục của nó, mỗi lựa chọn ghi độ trễ thêm (input lag) tính theo tín hiệu, cỡ khung hình và GPU
        // của máy này (PlayCost).
        let live = renderer?.costInfo()
        let cost = live?.cost ?? self.cost
        let current: PlayCost.Values = (s.upscaler, s.sharpen, s.antiAlias, s.frameGen)
        m.addItem(submenu(L("Bộ chỉnh hình", "Picture preset"), items: PlaySettings.Preset.allCases.filter { $0 != .custom || s.preset == .custom }.map { p in
            PlayMenuItem(PlayLabels.preset(p, current: current, cost: cost), on: s.preset == p, enabled: p != .custom) { s.preset = p }
        } + [
            .separator(),
            PlayMenuItem.note(L("Trễ thêm: hình phản hồi nút bấm chậm hơn chừng đó so với Gốc,", "Added lag: how much later the picture responds to a button")),
            PlayMenuItem.note(L("tính theo tín hiệu, cỡ khung hình và GPU của máy này.", "than with Original, for this signal, picture size and Mac.")),
        ] + (live?.measured.map { [PlayMenuItem.note(L("Cách đang dùng đo được: ", "Measured for the current setup: ") + PlayLabels.lag($0) + ".")] } ?? [])))
        let fx = renderer?.supportsSuperResolution ?? false
        m.addItem(submenu(L("Phóng to", "Upscaling"), items: PlayEffects.Upscaler.allCases.map { u in
            PlayMenuItem(PlayLabels.upscaler(u, current: current, cost: cost), on: s.upscaler == u, enabled: u != .metalFX || fx) { s.upscaler = u }
        } + (PlayLabels.upscaleNote(cost: cost).map { [.separator(), PlayMenuItem.note($0)] } ?? [])))
        m.addItem(submenu(L("Làm nét (RCAS)", "Sharpen (RCAS)"), items: PlaySettings.Sharpen.allCases.map { v in
            PlayMenuItem(PlayLabels.sharpen(v, current: current, cost: cost), on: s.sharpen == v) { s.sharpen = v }
        } + [.separator(),
             PlayMenuItem.note(L("Mạnh hơn thì rõ hơn nhưng dễ lộ viền sáng", "Stronger is crisper but can add bright halos")),
             PlayMenuItem.note(L("quanh nét và hạt nhiễu.", "and grain."))]))
        m.addItem(PlayMenuItem(PlayLabels.antiAlias(current: current, cost: cost), on: s.antiAlias) { s.antiAlias.toggle() })
        m.addItem(PlayMenuItem.note(PlayLabels.antiAliasNote))
        m.addItem(submenu(L("Tăng FPS", "Frame generation"), items: PlayInterpolator.Mode.allCases.map { v -> NSMenuItem in
            PlayMenuItem(PlayLabels.frameGen(v, current: current, cost: cost), on: s.frameGen == v) { s.frameGen = v }
        } + [.separator()] + PlayLabels.frameGenNotes(cost: cost).map { PlayMenuItem.note($0) }))
        m.addItem(submenu(L("Khung hình", "Picture size"), items: [
            PlayMenuItem(L("Vừa khung (giữ trọn hình)", "Fit (show the whole picture)"), on: !s.fill) { s.fill = false },
            PlayMenuItem(L("Lấp đầy (cắt bớt phần thừa)", "Fill (crop what doesn't fit)"), on: s.fill) { s.fill = true },
            .separator(),
            PlayMenuItem.note(L("Lấp đầy bỏ viền đen khi toàn màn hình trên MacBook (màn 16:10),", "Fill removes the black bars in full screen on a MacBook (16:10 display)")),
            PlayMenuItem.note(L("đổi lại hai bên hình mất một dải mỏng khoảng 5%.", "at the cost of a thin strip, about 5%, on each side.")),
        ]))
        m.addItem(submenu(L("Độ trễ", "Latency"), items: [
            PlayMenuItem(L("Thấp nhất", "Lowest"), on: s.latency == .lowest) { s.latency = .lowest },
            PlayMenuItem(L("Mượt (trễ thêm tối đa \(Int((1000 / cost.fps).rounded())) ms)", "Smooth (adds up to \(Int((1000 / cost.fps).rounded())) ms)"), on: s.latency == .smooth) { s.latency = .smooth },
        ]))
        m.addItem(.separator())

        // Reactions của macOS (bóng bay, pháo hoa khi giơ tay) bật sẵn cho mọi app: macOS dò mặt và tay trên từng khung hình game,
        // tốn thêm khoảng 10% một nhân CPU (đo với card Hagibis) và có thể chèn hiệu ứng vào hình. App không tự tắt được, chỉ mở
        // được bảng Hiệu ứng video để người dùng tắt.
        // Bảng Hiệu ứng video (Portrait, Studio Light, Reactions…) chỉ có khi app đang dùng camera, nên chỉ hiện mục này lúc
        // đang nhận hình từ card. Không ghi "Reactions đang bật": `reactionEffectsEnabled` chỉ nói app được phép dùng Reactions,
        // không phải người dùng đang bật (đã nhầm một lần).
        if capture != nil, device != nil, phase == .live {
            m.addItem(PlayMenuItem(L("Hiệu ứng video của macOS…", "macOS Video Effects…")) { AVCaptureDevice.showSystemUserInterface(.videoEffects) })
            m.addItem(PlayMenuItem.note(L("Hình game bị làm mờ nền, chiếu sáng hay có hiệu ứng lạ thì tắt các hiệu ứng ở đây.", "If the game picture gets a blurred background, extra lighting or odd effects, turn them off here.")))
            m.addItem(.separator())
        }

        m.addItem(PlayMenuItem(L("Tắt tiếng", "Mute"), on: s.muted) { s.muted.toggle() })
        m.addItem(PlayMenuItem(L("Tắt tiếng khi chuyển sang app khác", "Mute when another app is active"), on: s.muteWhenInactive) { s.muteWhenInactive.toggle() })
        m.addItem(PlayMenuItem(L("Luôn nằm trên cùng", "Always on top"), on: s.onTop) { s.onTop.toggle() })
        m.addItem(.separator())
        if !signal.isEmpty, phase == .live {
            m.addItem(PlayMenuItem.note(L("Tín hiệu: ", "Signal: ") + signal))
            if let info = renderer?.processingInfo(), info.stages != "vẽ thẳng" {
                m.addItem(PlayMenuItem.note(String(format: L("Xử lý hình: %@, %.1f ms GPU mỗi lần vẽ", "Processing: %@, %.1f ms GPU per draw"), info.stages, info.ms)))
            }
        }
        m.addItem(PlayMenuItem(L("Đóng màn hình chơi", "Close game screen")) { [weak self] in self?.close() })
        return m
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let sub = NSMenu()
        sub.autoenablesItems = false
        items.forEach(sub.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { onBecameKey?() }

    func windowDidResize(_ notification: Notification) {
        if let w = window, let c = controls { placeControls(c, in: w) }
    }

    /// Ghi chỗ mới một lần khi thôi kéo (windowDidMove đến liên tục trong lúc kéo).
    func windowDidMove(_ notification: Notification) {
        moveLogTask?.cancel()
        moveLogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard let self, !Task.isCancelled, let w = self.window, !self.isFullScreen else { return }
            DebugLog.write("Màn hình chơi: di chuyển xong \(Self.frameText(w))")
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let w = window { DebugLog.write("Màn hình chơi: đổi cỡ xong \(Self.frameText(w))") }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        if let w = window { DebugLog.write("Màn hình chơi: toàn màn hình \(Self.frameText(w))") }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        if let w = window { DebugLog.write("Màn hình chơi: thôi toàn màn hình \(Self.frameText(w))") }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let w = window else { return }
        let visible = w.occlusionState.contains(.visible) && !w.isMiniaturized
        renderer?.update { $0.visible = visible }
    }

    func windowDidChangeScreen(_ notification: Notification) { updateHeadroom() }

    func windowWillClose(_ notification: Notification) {
        if let w = window { DebugLog.write("Màn hình chơi: đóng cửa sổ \(Self.frameText(w))") }
        teardown()
    }

    static func frameText(_ w: NSWindow) -> String {
        let f = w.frame
        return "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
    }

    #if DEVTOOLS
    // MARK: Thử

    var debugControls: NSPanel? { controls }
    var debugRenderer: PlayRenderer? { renderer }

    /// Mở cửa sổ với nguồn hình dựng sẵn thay cho card.
    func debugOpenPattern(full: Bool, text: String) {
        guard window == nil, makeWindow(), let renderer else { return }
        deviceName = L("Nguồn thử", "Test source")
        let cap = PlayCapture(renderer: renderer)
        cap.onFirstFrame = { [weak self] _ in self?.setPhase(.live) }
        capture = cap
        signal = "1920×1080 · 60 fps · YUV 4:2:0"
        setPhase(.starting)
        cap.startPattern(full: full, text: text)
        watchFrames()
    }

    /// Giả lập rút card rồi cắm lại (gọi đúng đường xử lý khi danh sách thiết bị đổi).
    func debugUnplugReplug() async {
        let list = CaptureCards.shared.devices
        devicesChanged([])
        try? await Task.sleep(for: .seconds(2))
        devicesChanged(list)
    }

    func debugShowChrome() { hideTask?.cancel(); hoveringControls = true; setChrome(visible: true) }
    func debugHideChrome() { hoveringControls = false; setChrome(visible: false) }
    func debugSetPhase(_ p: Phase) { setPhase(p) }
    #endif
}

/// Mục menu chạy một hàm khi chọn.
final class PlayMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, on: Bool? = nil, enabled: Bool = true, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        if let on { state = on ? .on : .off }
    }

    required init(coder: NSCoder) { fatalError("không dùng") }

    @objc private func fire() { run() }

    /// Dòng ghi chú xám, không bấm được.
    static func note(_ text: String) -> PlayMenuItem {
        let i = PlayMenuItem(text, enabled: false) {}
        i.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                                                                          .foregroundColor: NSColor.secondaryLabelColor])
        return i
    }
}

// MARK: Vùng hình

/// Vùng vẽ hình: lớp CAMetalLayer của bộ vẽ, báo cỡ thật cho bộ vẽ, báo rê chuột để hiện thanh điều khiển, bấm phải mở menu,
/// bấm đúp vào hình để bật hoặc tắt toàn màn hình.
final class PlayView: NSView {
    private let renderer: PlayRenderer
    var onPointer: (() -> Void)?
    var onExit: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    private var area: NSTrackingArea?

    init(renderer: PlayRenderer) {
        self.renderer = renderer
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("không dùng") }

    override func makeBackingLayer() -> CALayer { renderer.layer }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawable()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawable()
    }

    private func updateDrawable() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        renderer.layer.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        renderer.update { $0.drawableSize = size }
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        renderer.update { $0.resizing = true }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        renderer.update { $0.resizing = false }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseMoved(with event: NSEvent) { onPointer?() }
    override func mouseEntered(with event: NSEvent) { onPointer?() }
    override func mouseExited(with event: NSEvent) { onExit?() }

    // Cửa sổ không có thanh tiêu đề thấy được và hình phủ kín (kể cả dải tiêu đề), nên nắm kéo ở đâu trên hình cũng di chuyển
    // cửa sổ. Không có dòng này thì không kéo được chỗ nào, vì view đục (isOpaque) chặn việc kéo cửa sổ của macOS.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
        } else {
            onPointer?()
            if window?.styleMask.contains(.fullScreen) == false { window?.performDrag(with: event) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

// MARK: Giao diện

/// Thanh điều khiển nổi ở chân cửa sổ, chỉ hiện khi rê chuột: tắt tiếng, âm lượng, toàn màn hình, tuỳ chọn.
/// Nằm ở cửa sổ con riêng nên không lọt vào ảnh chụp phụ đề.
private struct PlayControlsView: View {
    static let size = NSSize(width: 280, height: 60)
    let screen: PlayScreen
    @ObservedObject var settings: PlaySettings
    @ObservedObject private var state = PlayScreen.shared

    var body: some View {
        HStack(spacing: 6) {
            icon(settings.muted || settings.volume == 0 ? "speaker.slash.fill" : settings.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill",
                 label: settings.muted ? L("Bật tiếng", "Unmute") : L("Tắt tiếng", "Mute")) { settings.muted.toggle() }
            SlimSlider(value: Binding(get: { settings.volume }, set: { v in
                settings.volume = v
                if settings.muted, v > 0 { settings.muted = false }
            }))
            .frame(width: 104)
            .accessibilityLabel(L("Âm lượng", "Volume"))
            Divider().frame(height: 18).padding(.horizontal, 4)
            icon(state.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                 label: state.isFullScreen ? L("Thôi toàn màn hình", "Exit full screen") : L("Toàn màn hình", "Full screen")) { screen.toggleFullScreen() }
            icon("slider.horizontal.3", label: L("Tuỳ chọn hình và tiếng", "Picture and sound options")) { screen.showMenu() }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
        .frame(width: Self.size.width, height: Self.size.height)
        .onHover { screen.hoverControls($0) }
    }

    private func icon(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        PlayIconButton(name: name, action: action).accessibilityLabel(label)
    }
}

private struct PlayIconButton: View {
    let name: String
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hover.on ? 1 : 0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(hover.on ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

/// Lời báo giữa cửa sổ khi chưa có hình: đang mở, chưa có tín hiệu, card bị rút, thiếu quyền, lỗi.
private struct PlayStatusView: View {
    @ObservedObject var screen: PlayScreen

    var body: some View {
        VStack(spacing: 10) {
            switch screen.phase {
            case .starting:
                ProgressView().controlSize(.small)
                Text(L("Đang mở \(screen.deviceName)…", "Opening \(screen.deviceName)…")).font(.callout).foregroundStyle(.secondary)
            case .waiting:
                title("tv.slash", L("Chưa có hình từ \(screen.deviceName)", "No picture from \(screen.deviceName) yet"))
                note(L("Hãy bật máy chơi game và kiểm tra dây HDMI nối vào capture card.", "Turn on the console and check the HDMI cable to the capture card."))
            case .unplugged:
                title("cable.connector.slash", L("Chưa thấy capture card", "No capture card found"))
                note(L("Hãy cắm capture card vào Mac. Hình sẽ tự hiện khi card sẵn sàng.", "Connect a capture card to your Mac. The picture appears as soon as the card is ready."))
            case .noPermission:
                title("video.slash", L("OverSub chưa được dùng Camera", "OverSub can't use the camera yet"))
                note(L("macOS xếp capture card vào nhóm camera. Hãy bật OverSub ở mục Camera trong Cài đặt hệ thống, rồi bấm Thử lại.",
                       "macOS treats capture cards as cameras. Turn on OverSub under Camera in System Settings, then click Try Again."))
                HStack(spacing: 8) {
                    Button(L("Thử lại", "Try Again")) { screen.retry() }.buttonStyle(DialogButtonStyle())
                    Button(L("Mở Cài đặt hệ thống", "Open System Settings")) { NSWorkspace.shared.open(PlayPermissionGuide.Kind.camera.url) }
                        .buttonStyle(DialogButtonStyle(prominent: true))
                }
                .padding(.top, 4)
            case .failed(let message):
                title("exclamationmark.triangle", L("Không mở được \(screen.deviceName)", "Couldn't open \(screen.deviceName)"))
                note(message)
                Button(L("Thử lại", "Try Again")) { screen.retry() }.buttonStyle(DialogButtonStyle()).padding(.top, 4)
            case .live, .closed:
                EmptyView()
            }
        }
        .frame(maxWidth: 440)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private func title(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30, weight: .regular)).foregroundStyle(.secondary)
            Text(text).font(.title3.weight(.semibold)).foregroundStyle(.primary)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Hướng dẫn cấp quyền

/// Hướng dẫn bật quyền Camera (hình) hoặc Micrô (tiếng) cho màn hình chơi game. Bấm Mở Cài đặt hệ thống thì hướng dẫn tự đóng,
/// để không che danh sách quyền. Quyền Camera và Micrô có hiệu lực ngay, không cần mở lại app.
@MainActor
final class PlayPermissionGuide {
    static let shared = PlayPermissionGuide()

    enum Kind {
        case camera, microphone
        var url: URL {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?" + (self == .camera ? "Privacy_Camera" : "Privacy_Microphone"))!
        }
    }

    private var panel: NSPanel?
    private(set) var kind: Kind?

    func show(_ kind: Kind, near window: NSWindow?) {
        hide()
        self.kind = kind
        DebugLog.write("Màn hình chơi: hiện hướng dẫn cấp quyền \(kind == .camera ? "Camera" : "Micrô")")
        let view = PlayPermissionView(kind: kind,
                                      open: { [weak self] in NSWorkspace.shared.open(kind.url); self?.hide() },
                                      close: { [weak self] in self?.hide() })
        panel = NoticePanel.show(view, on: window?.screen ?? NSScreen.main, level: .floating)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        kind = nil
    }

    #if DEVTOOLS
    var debugPanel: NSPanel? { panel }
    #endif
}

private struct PlayPermissionView: View {
    let kind: PlayPermissionGuide.Kind
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        NoticeCard(width: 540) {
            HStack(alignment: .top, spacing: 16) {
                DialogAppIcon(badge: kind == .camera ? "video" : "mic")
                VStack(alignment: .leading, spacing: 12) {
                    if kind == .camera {
                        DialogHeader(title: L("OverSub cần quyền Camera", "OverSub needs camera access"),
                                     message: L("macOS xếp capture card vào nhóm camera, nên OverSub cần quyền Camera để nhận hình từ card. Hình chỉ hiện trên máy, không ghi lại và không gửi đi đâu.",
                                                "macOS treats capture cards as cameras, so OverSub needs camera access to show the picture from your card. The picture stays on your Mac and is never recorded or sent anywhere."))
                        VStack(alignment: .leading, spacing: 6) {
                            DialogStep(n: 1, text: L("Bấm Mở Cài đặt hệ thống.", "Click Open System Settings."))
                            DialogStep(n: 2, text: L("Ở mục Camera, bật OverSub.", "Under Camera, turn on OverSub."))
                            DialogStep(n: 3, text: L("Quay lại màn hình chơi và bấm Thử lại.", "Return to the game screen and click Try Again."))
                        }
                    } else {
                        DialogHeader(title: L("OverSub cần quyền Micrô để phát tiếng game", "OverSub needs microphone access for game sound"),
                                     message: L("Tiếng game từ capture card vào Mac theo đường micrô. Chưa có quyền này thì màn hình chơi vẫn có hình nhưng không có tiếng. Tiếng chỉ phát ra loa, không ghi lại.",
                                                "Game sound from a capture card reaches your Mac as a microphone input. Without this permission the game screen shows the picture but has no sound. Sound only plays through your speakers and is never recorded."))
                        VStack(alignment: .leading, spacing: 6) {
                            DialogStep(n: 1, text: L("Bấm Mở Cài đặt hệ thống.", "Click Open System Settings."))
                            DialogStep(n: 2, text: L("Ở mục Micrô (Microphone), bật OverSub.", "Under Microphone, turn on OverSub."))
                            DialogStep(n: 3, text: L("Đóng rồi mở lại màn hình chơi.", "Close the game screen and open it again."))
                        }
                    }
                    HStack(spacing: 8) {
                        Button(L("Để sau", "Later"), action: close)
                            .buttonStyle(.link)
                            .font(.callout)
                        Spacer(minLength: 8)
                        Button(L("Mở Cài đặt hệ thống", "Open System Settings"), action: open)
                            .buttonStyle(DialogButtonStyle(prominent: true))
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}
