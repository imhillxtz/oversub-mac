import AppKit

/// NSPanel không kích hoạt app: không kéo người dùng ra khỏi game toàn màn hình hay sang Space của app,
/// vẫn nhận chuột và bàn phím khi là cửa sổ key.
private final class SelectionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Nút nhận cú nhấp ngay cả khi cửa sổ chưa là key (nhiều màn hình, mỗi màn hình một cửa sổ chọn).
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Trình chọn vùng gộp: một lần chọn cho cả khung phụ đề và các vùng dịch màn hình (dịch tại chỗ, chạy riêng với phụ đề).
/// Dừng hình để chọn cho dễ, chỉnh từng vùng (di chuyển, kéo góc, xoá), rồi xem lại một lần trước khi lưu.
@MainActor
final class RegionEditor {
    enum Kind { case main, secondary }
    struct Item: Identifiable {
        let id = UUID()
        var kind: Kind
        var region: CaptureRegion
    }
    struct Result {
        var main: CaptureRegion?
        var secondaries: [CaptureRegion]
        var start: Bool
        var thumbnail: CGImage?     // ảnh màn hình (đã dừng) của vùng chính, để xem lại trong hồ sơ
    }
    enum Stage { case editing, review }

    static let maxSecondaries = 3

    // Do Engine cung cấp.
    var grabScreen: ((CaptureRegion) async -> CGImage?)?                    // chụp cả màn hình (dừng hình)
    var readText: ((CaptureRegion, CGImage?) async -> String?)?             // chữ trong một vùng (từ ảnh dừng nếu có)
    var autoFind: ((CaptureRegion) async -> CGRect?)?                       // tự tìm khung phụ đề trên một màn hình

    fileprivate(set) var items: [Item] = []
    fileprivate var selected: UUID?
    fileprivate var adding = false               // lần kéo tới tạo vùng dịch màn hình mới
    fileprivate(set) var stage: Stage = .editing
    /// Mỗi lần mở đều xem trực tiếp; bấm Dừng hình (hoặc Space) mới dừng.
    fileprivate(set) var frozen = false
    fileprivate var frozenImages: [UInt32: CGImage] = [:]
    /// Ảnh màn hình lúc bấm Xong: đọc thử chữ và làm ảnh xem lại ở trang hồ sơ (kể cả khi không dừng hình).
    private var reviewShots: [UInt32: CGImage] = [:]
    fileprivate var reviewTexts: [UUID: String] = [:]     // "" = không thấy chữ; thiếu = đang đọc
    fileprivate var running = false
    fileprivate var screenTranslating = false
    /// Mở từ "Thêm dịch màn hình": kéo chỗ trống luôn tạo vùng dịch màn hình mới (tối đa 3), không vẽ lại khung phụ đề.
    fileprivate(set) var screenMode = false
    /// App đang ở phía trước lúc mở (thường là game): đóng trình chọn thì trả phím về cho nó.
    private var previousApp: NSRunningApplication?
    fileprivate var activeDisplay: UInt32?
    fileprivate var finding = false

    private var windows: [NSWindow] = []
    private var views: [EditorView] = []
    private var completion: ((Result?) -> Void)?
    private var screens: [UInt32: CGSize] = [:]

    var isOpen: Bool { !windows.isEmpty }

    func begin(main: CaptureRegion?, secondaries: [CaptureRegion], running: Bool, screenTranslating: Bool = false,
               screenMode: Bool = false, completion: @escaping (Result?) -> Void) {
        guard windows.isEmpty else { return }
        self.completion = completion
        self.running = running
        self.screenTranslating = screenTranslating
        self.screenMode = screenMode
        stage = .editing
        reviewTexts = [:]
        frozen = false
        frozenImages = [:]
        reviewShots = [:]
        items = []
        if let main { items.append(Item(kind: .main, region: main)) }
        items += secondaries.prefix(Self.maxSecondaries).map { Item(kind: .secondary, region: $0) }
        adding = false
        selected = items.first { $0.kind == editableKind }?.id
        activeDisplay = nil   // màn hình đang có chuột (đặt lúc mở cửa sổ), rồi đi theo chuột
        screens = [:]
        for s in NSScreen.screens { if let id = displayIDOf(s) { screens[id] = s.frame.size } }
        openWindows()
    }

    private func fullScreen(_ id: UInt32) -> CaptureRegion? {
        guard let size = screens[id] else { return nil }
        return CaptureRegion(displayID: id, x: 0, y: 0, w: size.width, h: size.height, sw: size.width, sh: size.height)
    }

    private func captureFrozen() async {
        for id in screens.keys {
            if let r = fullScreen(id), let img = await grabScreen?(r) { frozenImages[id] = img }
        }
    }

    private func openWindows() {
        for screen in NSScreen.screens {
            guard let id = displayIDOf(screen) else { continue }
            let size = screen.frame.size
            let w = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false, screen: screen)
            // Có tham số `screen:` thì contentRect bị hiểu là tính từ gốc của màn hình đó, nên ở màn hình thứ hai cửa sổ bị
            // lệch (lớp phủ chỉ che một góc). Đặt lại khung theo toạ độ toàn cục.
            w.setFrame(screen.frame, display: false)
            w.hidesOnDeactivate = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = EditorView(frame: NSRect(origin: .zero, size: size), displayID: id, editor: self)
            w.contentView = view
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                w.animator().alphaValue = 1
            }
            windows.append(w)
            views.append(view)
        }
        if activeDisplay == nil { activeDisplay = mouseDisplay() }
        // Giành phím về trình chọn: không thì Esc, Enter, Space lọt sang app đang ở phía trước (game, trình duyệt...).
        // Cửa sổ chọn đã hiện ở Space hiện tại nên kích hoạt app không kéo người dùng sang Space khác.
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate(ignoringOtherApps: true)
        // Cửa sổ trên màn hình có vùng chính (hoặc màn hình chứa chuột) nhận phím.
        let target = windows.first { ($0.contentView as? EditorView)?.displayID == activeDisplay } ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        target?.makeFirstResponder(target?.contentView)
        refresh()
    }

    private func mouseDisplay() -> UInt32? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) }.flatMap(displayIDOf)
    }

    fileprivate func refresh() { views.forEach { $0.refresh() } }

    /// Chuột sang màn hình nào thì thanh hướng dẫn, nút và phím tắt theo sang màn hình đó.
    fileprivate func activate(display: UInt32) {
        guard activeDisplay != display else { return }
        activeDisplay = display
        if let w = windows.first(where: { ($0.contentView as? EditorView)?.displayID == display }) {
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(w.contentView)
        }
        refresh()
    }

    private func close(_ result: Result?) {
        let ws = windows
        windows = []
        views = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ws.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated { ws.forEach { $0.orderOut(nil) } }
        })
        let done = completion
        completion = nil
        done?(result)
        // Trả phím về app trước đó (thường là game) để chơi tiếp ngay.
        if let prev = previousApp, !prev.isTerminated {
            NSApp.yieldActivation(to: prev)
            prev.activate(from: .current, options: [])
        }
        previousApp = nil
    }

    // MARK: Thao tác (gọi từ EditorView)

    /// Mỗi lần mở chỉ sửa một loại vùng: "Chọn vùng phụ đề" sửa vùng phụ đề, "Thêm vùng dịch màn hình" sửa vùng dịch màn hình.
    /// Loại kia chỉ hiện mờ để tham khảo vị trí, không bắt chuột, nên hai loại chồng lên nhau cũng không cản nhau.
    fileprivate var editableKind: Kind { screenMode ? .secondary : .main }

    fileprivate var hasMain: Bool { items.contains { $0.kind == .main } }
    fileprivate var secondaryCount: Int { items.filter { $0.kind == .secondary }.count }
    /// Phần của lần chọn này chưa chạy thì mời Lưu & bắt đầu: phụ đề, hoặc dịch màn hình khi mở từ "Thêm dịch màn hình".
    fileprivate var canStart: Bool { screenMode ? (secondaryCount > 0 && !screenTranslating) : (hasMain && !running) }

    fileprivate func label(for item: Item) -> String {
        guard item.kind == .secondary else { return L("Phụ đề", "Subtitles") }
        let n = (items.filter { $0.kind == .secondary }.firstIndex { $0.id == item.id } ?? 0) + 1
        return L("Dịch màn hình \(n)", "Screen translation \(n)")
    }

    fileprivate func setRegion(_ id: UUID, _ rect: CGRect, display: UInt32) {
        guard let i = items.firstIndex(where: { $0.id == id }), let size = screens[display] else { return }
        let r = rect.intersection(CGRect(origin: .zero, size: size))
        guard !r.isNull else { return }
        items[i].region = CaptureRegion(displayID: display, x: r.minX, y: r.minY, w: r.width, h: r.height, sw: size.width, sh: size.height)
    }

    /// Kéo ở chỗ trống: đang bấm "+ Dịch màn hình" thì tạo vùng dịch màn hình mới, không thì vẽ lại khung phụ đề.
    fileprivate func beginNew(display: UInt32) -> UUID? {
        activeDisplay = display
        if screenMode, secondaryCount >= Self.maxSecondaries { return nil }   // đã đủ vùng dịch màn hình
        let kind = editableKind
        if kind == .main { items.removeAll { $0.kind == .main } }
        let item = Item(kind: kind, region: CaptureRegion(displayID: display, x: 0, y: 0, w: 0, h: 0, sw: nil, sh: nil))
        if kind == .main { items.insert(item, at: 0) } else { items.append(item) }
        selected = item.id
        adding = false
        return item.id
    }

    /// Bỏ vùng quá nhỏ (nhấp nhầm thay vì kéo).
    fileprivate func finishDraw(_ id: UUID) {
        if let it = items.first(where: { $0.id == id }), it.region.w < 20 || it.region.h < 10 {
            items.removeAll { $0.id == id }
            selected = items.first?.id
        }
        refresh()
    }

    fileprivate func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        if selected == id { selected = items.first?.id }
        refresh()
    }

    fileprivate func toggleAdding() {
        guard adding || secondaryCount < Self.maxSecondaries else { return }
        adding.toggle()
        refresh()
    }

    fileprivate func toggleFreeze() {
        frozen.toggle()
        if frozen {
            Task { @MainActor in
                await captureFrozen()   // lớp chọn là cửa sổ của app nên không lọt vào ảnh chụp
                refresh()
            }
        } else {
            frozenImages = [:]
        }
        refresh()
    }

    fileprivate func runAutoFind(display: UInt32) {
        guard let screen = fullScreen(display), let find = autoFind, !finding else { return }
        finding = true
        refresh()
        Task { @MainActor in
            let r = await find(screen)
            finding = false
            if let r {
                // Tự tìm luôn đặt khung phụ đề (chỉ có ở chế độ chọn vùng phụ đề).
                if !hasMain { adding = false }
                if let id = items.first(where: { $0.kind == .main })?.id ?? beginNew(display: display) {
                    setRegion(id, r, display: display)
                    selected = id
                    activeDisplay = display
                }
            }
            refresh()
            if r == nil { views.first { $0.displayID == display }?.flash(L("Không tìm thấy phụ đề trên màn hình này. Hãy mở một đoạn hội thoại trong game rồi thử lại.", "No subtitles found on this screen. Bring up dialogue in the game and try again.")) }
        }
    }

    /// Xong chỉnh vùng: đọc thử chữ của mọi vùng một lần rồi hiện bảng xem lại. Đang dừng hình thì đọc từ ảnh dừng;
    /// đang xem trực tiếp thì chụp một ảnh ngay lúc này (lớp chọn là cửa sổ của app nên không lọt vào ảnh).
    fileprivate func review() {
        guard !items.isEmpty else { return }
        stage = .review
        adding = false
        reviewTexts = [:]
        reviewShots = frozenImages
        refresh()
        let regions = items.map { ($0.id, $0.region) }
        Task { @MainActor in
            for id in Set(regions.map(\.1.displayID)) where reviewShots[id] == nil {
                if let r = fullScreen(id), let img = await grabScreen?(r) { reviewShots[id] = img }
            }
            for (id, region) in regions {
                let shot = reviewShots[region.displayID]
                Task { @MainActor in
                    reviewTexts[id] = await readText?(region, shot) ?? ""
                    refresh()
                }
            }
        }
    }

    /// Cho bước chụp kiểm tra giao diện: mở bảng xem lại như khi bấm Xong.
    func debugReview() { review() }

    fileprivate func backToEditing() {
        stage = .editing
        refresh()
    }

    fileprivate func save(start: Bool) {
        let main = items.first { $0.kind == .main }?.region
        let thumb = (main ?? items.first?.region).flatMap { reviewShots[$0.displayID] ?? frozenImages[$0.displayID] }
        close(Result(main: main, secondaries: items.filter { $0.kind == .secondary }.map(\.region), start: start, thumbnail: thumb))
    }

    fileprivate func cancel() { close(nil) }
}

// MARK: - Lớp chọn trên một màn hình

private final class EditorView: NSView {
    let displayID: UInt32
    private unowned let editor: RegionEditor

    private enum Drag { case draw(UUID), move(UUID, CGPoint, CGRect), resize(UUID, Int, CGRect) }
    private var drag: Drag?
    private var start: CGPoint = .zero

    private let topBar = NSVisualEffectView()
    private let freezeButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let autoButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "")
    private let actionBar = NSVisualEffectView()
    private let actionStack = NSStackView()
    private var flashText: String?

    init(frame: NSRect, displayID: UInt32, editor: RegionEditor) {
        self.displayID = displayID
        self.editor = editor
        super.init(frame: frame)
        buildTopBar()
        buildActionBar()
    }

    required init?(coder: NSCoder) { fatalError("không dùng") }

    override var isFlipped: Bool { true }   // gốc toạ độ ở góc trên trái, khớp với ScreenCaptureKit
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    override func mouseEntered(with event: NSEvent) { editor.activate(display: displayID) }
    override func mouseMoved(with event: NSEvent) { editor.activate(display: displayID) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var myItems: [RegionEditor.Item] { editor.items.filter { $0.region.displayID == displayID } }
    /// Các vùng sửa được trong lần mở này (xem `editableKind`).
    private var myEditable: [RegionEditor.Item] { myItems.filter { $0.kind == editor.editableKind } }
    private var isActive: Bool { editor.activeDisplay == displayID }

    func flash(_ text: String) {
        flashText = text
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.flashText = nil; self?.refresh() }
    }

    func refresh() {
        needsDisplay = true
        updateTopBar()
        updateActionBar()
        needsLayout = true
    }

    // MARK: Thanh trên: dừng hình, tự tìm, hướng dẫn

    private func hud(_ v: NSVisualEffectView) {
        v.material = .hudWindow
        v.blendingMode = .withinWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 14
        v.layer?.masksToBounds = true
    }

    private func style(_ b: NSButton, _ title: String, symbol: String?, action: Selector) {
        b.title = title
        b.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        b.imagePosition = symbol == nil ? .noImage : .imageLeading
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.target = self
        b.action = action
    }

    private func buildTopBar() {
        hud(topBar)
        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = .labelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        style(freezeButton, "", symbol: nil, action: #selector(freezeTapped))
        style(autoButton, L("Tự tìm phụ đề", "Find subtitles"), symbol: "sparkle.magnifyingglass", action: #selector(autoTapped))
        // Hai nút giữ nguyên chữ; dòng hướng dẫn nhường chỗ (cắt bớt) khi màn hình hẹp.
        for b in [freezeButton, autoButton] { b.setContentCompressionResistancePriority(.required, for: .horizontal) }
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [freezeButton, hintLabel, autoButton])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topBar.topAnchor), stack.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
        ])
        addSubview(topBar)
    }

    private func updateTopBar() {
        topBar.isHidden = !isActive   // chỉ hiện ở màn hình đang có chuột
        // Nút ghi việc sẽ làm khi bấm; đang dừng hình thì nút tô cam, viền màn hình cam và dòng hướng dẫn báo rõ.
        freezeButton.title = editor.frozen ? L("Chạy tiếp", "Resume") : L("Dừng hình", "Freeze frame")
        freezeButton.image = NSImage(systemSymbolName: editor.frozen ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        freezeButton.bezelColor = editor.frozen ? Theme.nsAccent : nil
        freezeButton.toolTip = editor.frozen ? L("Hình đang dừng. Bấm (hoặc phím Space) để xem trực tiếp lại", "The frame is frozen. Click (or press Space) to go back to live view") : L("Dừng hình để chọn vùng không bị trôi (phím Space)", "Freeze the frame so the region doesn't drift while you select (Space)")
        autoButton.title = editor.finding ? L("Đang tìm…", "Searching…") : L("Tự tìm phụ đề", "Find subtitles")
        autoButton.isEnabled = !editor.finding && editor.stage == .editing
        autoButton.isHidden = editor.stage == .review || editor.screenMode   // tự tìm chỉ dành cho phụ đề lời thoại
        freezeButton.isHidden = editor.stage == .review   // đang xem lại thì chữ đã đọc xong, không cần dừng/chạy hình
        // Chữ và biểu tượng đổi lúc chạy: đặt rõ vị trí biểu tượng và tính lại bề ngang, không thì biểu tượng đè lên chữ.
        for b in [freezeButton, autoButton] {
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            b.invalidateIntrinsicContentSize()
        }
        let hint = flashText ?? {
            if editor.stage == .review { return L("Xem lại các vùng trước khi lưu", "Review the regions before saving") }
            if editor.screenMode {
                if editor.secondaryCount == 0 { return L("Kéo quanh chữ cần dịch tại chỗ: bảng nhiệm vụ, menu, mô tả vật phẩm · Space dừng hình · Esc huỷ", "Drag around text to translate in place: quest logs, menus, item descriptions · Space to freeze · Esc to cancel") }
                return L("Kéo chỗ trống để thêm vùng (tối đa \(RegionEditor.maxSecondaries)) · kéo vùng để di chuyển, kéo góc để chỉnh · Enter xong", "Drag on empty space to add a region (up to \(RegionEditor.maxSecondaries)) · drag a region to move it, a corner to resize · Enter when done")
            }
            if editor.adding { return L("Kéo quanh chữ cần dịch tại chỗ: bảng nhiệm vụ, menu, mô tả vật phẩm · Esc để thôi", "Drag around text to translate in place: quest logs, menus, item descriptions · Esc to stop adding") }
            if !editor.hasMain { return L("Kéo quanh chỗ phụ đề hiện ra · Space dừng hình · Esc huỷ", "Drag around where subtitles appear · Space to freeze · Esc to cancel") }
            return L("Kéo chỗ trống để vẽ lại vùng phụ đề · kéo vùng để di chuyển, kéo góc để chỉnh · Enter xong", "Drag on empty space to redraw the subtitle region · drag the region to move it, a corner to resize · Enter when done")
        }()
        hintLabel.stringValue = editor.frozen && flashText == nil && editor.stage == .editing ? L("Hình đang dừng · ", "Frozen · ") + hint : hint
    }

    // MARK: Thanh thao tác (dưới vùng chính) và bảng xem lại

    private func buildActionBar() {
        hud(actionBar)
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 10
        actionStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionBar.addSubview(actionStack)
        NSLayoutConstraint.activate([
            actionStack.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor), actionStack.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor),
            actionStack.topAnchor.constraint(equalTo: actionBar.topAnchor), actionStack.bottomAnchor.constraint(equalTo: actionBar.bottomAnchor),
        ])
        actionBar.isHidden = true
        addSubview(actionBar)
    }

    private func makeButton(_ title: String, symbol: String? = nil, primary: Bool = false, key: String = "", action: Selector) -> NSButton {
        let b = FirstMouseButton(title: title, target: self, action: action)
        style(b, title, symbol: symbol, action: action)
        if primary { b.bezelColor = Theme.nsAccent }
        b.keyEquivalent = key
        return b
    }

    /// Một ô trong bảng xem lại: chấm màu và tên vùng, dưới là chữ đọc được (hoặc báo chưa thấy chữ).
    private func reviewRow(name: String, tint: NSColor, text: String?, width: CGFloat) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = tint.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let header = NSStackView(views: [dot, label])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        let body: NSView
        switch text {
        case nil:
            let l = NSTextField(labelWithString: L("Đang đọc chữ…", "Reading text…"))
            l.font = .systemFont(ofSize: 13)
            l.textColor = .secondaryLabelColor
            body = l
        case let t? where t.isEmpty:
            let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
            let l = NSTextField(labelWithString: L("Chưa thấy chữ trong vùng này", "No text found in this region yet"))
            l.font = .systemFont(ofSize: 13)
            l.textColor = .secondaryLabelColor
            let h = NSStackView(views: [icon, l])
            h.orientation = .horizontal
            h.spacing = 6
            body = h
        case let t?:
            let l = NSTextField(wrappingLabelWithString: t.count > 180 ? String(t.prefix(180)) + "…" : t)
            l.font = .systemFont(ofSize: 13)
            l.textColor = .labelColor
            l.maximumNumberOfLines = 3
            l.lineBreakMode = .byTruncatingTail
            l.preferredMaxLayoutWidth = width - 24
            body = l
        }
        let v = NSStackView(views: [header, body])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 5
        v.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 10, right: 12)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        v.layer?.cornerRadius = 10
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    private func updateActionBar() {
        actionStack.arrangedSubviews.forEach { actionStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        guard isActive else { actionBar.isHidden = true; return }
        if editor.stage == .editing {
            actionStack.orientation = .horizontal
            actionStack.alignment = .centerY
            actionStack.spacing = 10
            actionStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            let cancel = makeButton(L("Huỷ", "Cancel"), action: #selector(cancelTapped))
            var buttons = [cancel]
            if editor.screenMode {
                // Thêm dịch màn hình: tuỳ chọn thêm vùng, kèm số vùng đã có.
                let add = makeButton(L("Thêm vùng · \(editor.secondaryCount)/\(RegionEditor.maxSecondaries)", "Add region · \(editor.secondaryCount)/\(RegionEditor.maxSecondaries)"), symbol: "plus", action: #selector(addTapped))
                add.isEnabled = editor.secondaryCount < RegionEditor.maxSecondaries
                add.toolTip = L("Kéo ở chỗ trống để thêm một vùng dịch màn hình nữa", "Drag on empty space to add another screen region")
                buttons.append(add)
            }
            let done = makeButton(L("Xong", "Done"), symbol: "chevron.right", primary: true, key: "\r", action: #selector(doneTapped))
            done.isEnabled = editor.screenMode ? !editor.items.isEmpty : editor.hasMain
            buttons.append(done)
            buttons.forEach(actionStack.addArrangedSubview)
        } else {
            // Bảng xem lại: mỗi vùng một ô (chấm màu theo loại vùng, tên, chữ đọc được), nút ở dưới.
            actionStack.orientation = .vertical
            actionStack.alignment = .leading
            actionStack.spacing = 12
            actionStack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
            let width: CGFloat = 440
            let title = NSTextField(labelWithString: L("Xem lại các vùng", "Review regions"))
            title.font = .systemFont(ofSize: 16, weight: .semibold)
            let subtitle = NSTextField(labelWithString: L("Chữ OverSub đọc được trong từng vùng lúc bấm Xong", "The text OverSub read in each region when you clicked Done"))
            subtitle.font = .systemFont(ofSize: 12)
            subtitle.textColor = .secondaryLabelColor
            let head = NSStackView(views: [title, subtitle])
            head.orientation = .vertical
            head.alignment = .leading
            head.spacing = 2
            actionStack.addArrangedSubview(head)
            for it in editor.items {
                actionStack.addArrangedSubview(reviewRow(name: editor.label(for: it), tint: it.kind == .main ? .white : .systemOrange,
                                                         text: editor.reviewTexts[it.id], width: width))
            }
            if !editor.items.isEmpty, editor.items.allSatisfy({ editor.reviewTexts[$0.id] == "" }) {
                let note = NSTextField(wrappingLabelWithString: L("Lúc này chưa có chữ trong các vùng. Vẫn lưu được, OverSub sẽ đọc khi chữ hiện ra.", "There's no text in the regions right now. You can still save; OverSub will read text when it appears."))
                note.font = .systemFont(ofSize: 11)
                note.textColor = .tertiaryLabelColor
                note.preferredMaxLayoutWidth = width
                actionStack.addArrangedSubview(note)
            }
            let startNow = editor.canStart
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            var buttons: [NSView] = [makeButton(L("Sửa tiếp", "Keep editing"), symbol: "chevron.left", action: #selector(backTapped)), spacer,
                                     makeButton(L("Lưu", "Save"), primary: !startNow, key: startNow ? "" : "\r", action: #selector(saveTapped))]
            if startNow { buttons.append(makeButton(L("Lưu & bắt đầu", "Save & start"), symbol: "play.fill", primary: true, key: "\r", action: #selector(saveStartTapped))) }
            let row = NSStackView(views: buttons)
            row.orientation = .horizontal
            row.spacing = 10
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
            actionStack.setCustomSpacing(16, after: actionStack.arrangedSubviews.last!)
            actionStack.addArrangedSubview(row)
        }
        actionBar.layer?.cornerRadius = editor.stage == .review ? 18 : 14
        actionBar.isHidden = false
    }

    override func layout() {
        super.layout()
        topBar.layoutSubtreeIfNeeded()
        let ts = topBar.fittingSize
        // Màn hình có tai thỏ: đặt thanh dưới phần tai thỏ để không bị che.
        let notch = window?.screen?.safeAreaInsets.top ?? 0
        topBar.frame = NSRect(x: (bounds.width - ts.width) / 2, y: max(24, notch + 12), width: ts.width, height: ts.height)
        guard !actionBar.isHidden else { return }
        actionBar.layoutSubtreeIfNeeded()
        let size = actionBar.fittingSize
        let margin: CGFloat = 10
        if editor.stage == .review {
            actionBar.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            return
        }
        // Đặt dưới vùng chính; hết chỗ thì lên trên; hết chỗ nữa thì vào trong vùng.
        // Chưa có vùng nào: đặt giữa phía dưới màn hình.
        let anchor = myEditable.last?.region.rect
            ?? CGRect(x: bounds.midX + size.width / 2, y: bounds.height - size.height - 90, width: 0, height: 0)
        var x = min(max(margin, anchor.maxX - size.width), bounds.width - size.width - margin)
        var y = anchor.maxY + margin
        if y + size.height > bounds.height - margin {
            y = anchor.minY - margin - size.height
            if y < margin {
                y = anchor.maxY - size.height - margin
                x = min(max(margin, anchor.maxX - size.width - margin), bounds.width - size.width - margin)
            }
        }
        actionBar.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Nút

    @objc private func freezeTapped() { editor.toggleFreeze() }
    @objc private func autoTapped() { editor.runAutoFind(display: displayID) }
    @objc private func cancelTapped() { editor.cancel() }
    @objc private func addTapped() {
        if editor.screenMode { flash(L("Kéo ở chỗ trống để thêm vùng dịch màn hình", "Drag on empty space to add a screen region")) } else { editor.toggleAdding() }
    }
    @objc private func doneTapped() { editor.review() }
    @objc private func backTapped() { editor.backToEditing() }
    @objc private func saveTapped() { editor.save(start: false) }
    @objc private func saveStartTapped() { editor.save(start: true) }

    // MARK: Chuột và phím

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    private func deleteRect(_ r: CGRect) -> CGRect { CGRect(x: r.maxX - 9, y: r.minY - 9, width: 18, height: 18) }

    /// Góc của vùng đang chọn: 0 trên trái, 1 trên phải, 2 dưới phải, 3 dưới trái.
    private func corner(at p: CGPoint, of r: CGRect) -> Int? {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        return pts.firstIndex { hypot($0.x - p.x, $0.y - p.y) <= 12 }
    }

    override func mouseDown(with e: NSEvent) {
        guard editor.stage == .editing else { return }
        let p = point(e)
        editor.activeDisplay = displayID
        start = p
        if e.clickCount >= 2, myEditable.contains(where: { $0.region.rect.contains(p) }) { editor.review(); return }
        if let it = myEditable.first(where: { $0.kind == .secondary && deleteRect($0.region.rect).contains(p) }) {
            editor.delete(it.id); return
        }
        if let sel = editor.selected, let it = myEditable.first(where: { $0.id == sel }), let c = corner(at: p, of: it.region.rect) {
            drag = .resize(it.id, c, it.region.rect)
        } else if let it = myEditable.reversed().first(where: { $0.region.rect.contains(p) }) {
            editor.selected = it.id
            drag = .move(it.id, p, it.region.rect)
        } else {
            guard let id = editor.beginNew(display: displayID) else {
                flash(L("Đã đủ \(RegionEditor.maxSecondaries) vùng dịch màn hình. Để thêm vùng mới, hãy bấm × để bỏ bớt một vùng.", "You already have \(RegionEditor.maxSecondaries) screen regions. Click × to remove one."))
                return
            }
            drag = .draw(id)
        }
        editor.refresh()
    }

    override func mouseDragged(with e: NSEvent) {
        guard let drag else { return }
        let p = point(e)
        switch drag {
        case .draw(let id):
            editor.setRegion(id, CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(start.x - p.x), height: abs(start.y - p.y)), display: displayID)
        case .move(let id, let from, let r):
            var nr = r.offsetBy(dx: p.x - from.x, dy: p.y - from.y)
            nr.origin.x = min(max(0, nr.minX), bounds.width - nr.width)
            nr.origin.y = min(max(0, nr.minY), bounds.height - nr.height)
            editor.setRegion(id, nr, display: displayID)
        case .resize(let id, let c, let r):
            // Góc đối diện đứng yên.
            let fixed = [CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)][c]
            editor.setRegion(id, CGRect(x: min(fixed.x, p.x), y: min(fixed.y, p.y), width: abs(fixed.x - p.x), height: abs(fixed.y - p.y)), display: displayID)
        }
        editor.refresh()
    }

    override func mouseUp(with e: NSEvent) {
        guard let d = drag else { return }
        drag = nil
        switch d {
        case .draw(let id), .resize(let id, _, _): editor.finishDraw(id)
        case .move: editor.refresh()
        }
    }

    override func rightMouseDown(with e: NSEvent) { editor.cancel() }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 36, 76:   // Return, Enter
            if editor.stage == .editing { editor.review() } else { editor.save(start: editor.canStart) }
        case 53:       // Esc
            if editor.stage == .review { editor.backToEditing() }
            else if editor.adding { editor.toggleAdding() }
            else { editor.cancel() }
        case 49:       // Space
            editor.toggleFreeze()
        case 51, 117:  // Delete
            if let sel = editor.selected, editor.items.first(where: { $0.id == sel })?.kind == .secondary { editor.delete(sel) }
        default: break
        }
    }

    // MARK: Vẽ

    override func draw(_ dirtyRect: NSRect) {
        if editor.frozen, let img = editor.frozenImages[displayID] {
            NSImage(cgImage: img, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
        let radius: CGFloat = 12
        let dim = NSBezierPath(rect: bounds)
        for it in myEditable where it.region.w > 0 {
            dim.append(NSBezierPath(roundedRect: it.region.rect, xRadius: radius, yRadius: radius))
        }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()

        // Loại vùng không sửa trong lần này: chỉ một viền đứt mờ và tên, để biết nó ở đâu.
        for it in myItems where it.region.w > 0 && it.kind != editor.editableKind {
            let tint: NSColor = it.kind == .main ? .white : .systemOrange
            let path = NSBezierPath(roundedRect: it.region.rect, xRadius: radius, yRadius: radius)
            path.lineWidth = 1
            path.setLineDash([5, 4], count: 2, phase: 0)
            tint.withAlphaComponent(0.4).setStroke()
            path.stroke()
            let name = editor.label(for: it) as NSString
            name.draw(at: CGPoint(x: it.region.rect.minX + 8, y: it.region.rect.minY + 6),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: tint.withAlphaComponent(0.55)])
        }
        for it in myEditable where it.region.w > 0 {
            drawRegion(it, selected: it.id == editor.selected && editor.stage == .editing)
        }
        if editor.frozen {
            // Viền mảnh quanh màn hình cho biết đang dừng hình.
            let frame = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            frame.lineWidth = 4
            Theme.nsAccent.withAlphaComponent(0.55).setStroke()
            frame.stroke()
        }
    }

    private func drawRegion(_ it: RegionEditor.Item, selected: Bool) {
        let r = it.region.rect, radius: CGFloat = 12
        let tint: NSColor = it.kind == .main ? .white : .systemOrange
        let shape = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.03).setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = tint.withAlphaComponent(selected ? 0.6 : 0.35)
        glow.shadowBlurRadius = selected ? 18 : 10
        glow.shadowOffset = .zero
        glow.set()
        shape.lineWidth = selected ? 1.5 : 1
        tint.withAlphaComponent(selected ? 0.9 : 0.6).setStroke()
        shape.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if selected {
            // Tay nắm ở bốn góc để kéo chỉnh kích thước.
            for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)] {
                let h = NSBezierPath(ovalIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
                NSColor.white.setFill(); h.fill()
                (it.kind == .main ? NSColor.black.withAlphaComponent(0.4) : tint).setStroke()
                h.lineWidth = 1.5; h.stroke()
            }
        }
        drawTag(editor.label(for: it), at: r, tint: tint, size: "\(Int(r.width)) × \(Int(r.height))")
        if it.kind == .secondary, editor.stage == .editing {
            let d = deleteRect(r)
            let c = NSBezierPath(ovalIn: d)
            NSColor.black.withAlphaComponent(0.7).setFill(); c.fill()
            NSColor.white.withAlphaComponent(0.6).setStroke(); c.lineWidth = 1; c.stroke()
            let x = NSBezierPath()
            x.move(to: CGPoint(x: d.minX + 6, y: d.minY + 6)); x.line(to: CGPoint(x: d.maxX - 6, y: d.maxY - 6))
            x.move(to: CGPoint(x: d.maxX - 6, y: d.minY + 6)); x.line(to: CGPoint(x: d.minX + 6, y: d.maxY - 6))
            x.lineWidth = 1.6; NSColor.white.setStroke(); x.stroke()
        }
    }

    private func drawTag(_ text: String, at r: CGRect, tint: NSColor, size: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
        let t = NSMutableAttributedString(string: text + "  ", attributes: attrs)
        t.append(NSAttributedString(string: size, attributes: dim))
        let s = t.size()
        let h = s.height + 8
        let y = r.minY >= h + 8 ? r.minY - h - 8 : r.minY + 8
        let pill = NSRect(x: r.minX, y: y, width: s.width + 20, height: h)
        NSColor.black.withAlphaComponent(0.6).setFill()
        let p = NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2)
        p.fill()
        p.lineWidth = 1
        tint.withAlphaComponent(0.5).setStroke()
        p.stroke()
        t.draw(at: CGPoint(x: pill.minX + 10, y: pill.minY + 4))
    }
}
