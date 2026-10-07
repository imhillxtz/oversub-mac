import AppKit
import SwiftUI

/// Dịch nhanh: bấm phím tắt, kéo một khung quanh chữ, thả chuột là bản dịch hiện ngay tại chỗ. Vùng chỉ dùng một lần.
/// Mặc định dừng hình (chọn và đọc trên ảnh tĩnh, không trôi, không chớp); tắt dừng hình thì game vẫn chạy phía sau.
/// Esc, bấm chuột ra ngoài hoặc bấm lại phím tắt để tắt.
@MainActor
final class QuickTranslator {
    struct Output {
        var pieces: [ScreenPiece]
        var background: NSImage?
        var plain: String
        var original = ""      // chữ gốc đọc được, để chép đi tra cứu
    }

    var grabScreen: ((CaptureRegion) async -> CGImage?)?
    var translate: ((CaptureRegion, CGImage) async -> Output?)?

    private var windows: [NSWindow] = []
    private var previousApp: NSRunningApplication?
    fileprivate var frozen: [UInt32: CGImage] = [:]
    fileprivate var freeze = true

    var isOpen: Bool { !windows.isEmpty }

    func begin(freeze: Bool) {
        guard windows.isEmpty else { return }
        self.freeze = freeze
        frozen = [:]
        Task { @MainActor in
            if freeze {
                // Chụp trước khi hiện lớp chọn, để ảnh dừng là đúng khung hình người dùng đang thấy.
                for s in NSScreen.screens {
                    guard let id = displayIDOf(s) else { continue }
                    let full = CaptureRegion(displayID: id, x: 0, y: 0, w: s.frame.width, h: s.frame.height, sw: s.frame.width, sh: s.frame.height)
                    if let img = await grabScreen?(full) { frozen[id] = img }
                }
            }
            open()
        }
    }

    private func open() {
        for screen in NSScreen.screens {
            guard let id = displayIDOf(screen) else { continue }
            let w = QuickWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.hidesOnDeactivate = false
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.contentView = QuickView(frame: NSRect(origin: .zero, size: screen.frame.size), displayID: id, owner: self)
            w.orderFrontRegardless()
            windows.append(w)
        }
        // Giành phím (Esc) về lớp chọn; đóng thì trả lại cho game.
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let target = windows.first { $0.frame.contains(mouse) } ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        target?.makeFirstResponder(target?.contentView)
    }

    func close() {
        let ws = windows
        windows = []
        frozen = [:]
        ws.forEach { $0.orderOut(nil) }
        if let prev = previousApp, !prev.isTerminated {
            NSApp.yieldActivation(to: prev)
            prev.activate(from: .current, options: [])
        }
        previousApp = nil
    }

    /// Ảnh của vùng vừa kéo: cắt từ ảnh dừng, hoặc chụp trực tiếp (lớp chọn là cửa sổ của app nên không lọt vào ảnh).
    fileprivate func image(for region: CaptureRegion) async -> CGImage? {
        if let full = frozen[region.displayID], let sw = region.sw, sw > 0 {
            let k = CGFloat(full.width) / sw
            return full.cropping(to: CGRect(x: region.x * k, y: region.y * k, width: region.w * k, height: region.h * k).integral)
        }
        return await grabScreen?(region)
    }

    /// Cho bước tự kiểm tra: chọn sẵn một vùng trên màn hình chính như thể người dùng vừa kéo xong.
    func debugSelect(_ r: CGRect) {
        (windows.first?.contentView as? QuickView)?.simulate(r)
    }

    fileprivate func otherViews(than v: QuickView) -> [QuickView] { windows.compactMap { $0.contentView as? QuickView }.filter { $0 !== v } }
}

private final class QuickWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class QuickView: NSView {
    let displayID: UInt32
    private unowned let owner: QuickTranslator
    private enum Phase { case choosing, working, showing, empty }
    private var phase: Phase = .choosing
    private var start: CGPoint?
    private var rect: CGRect = .zero
    private var plain = ""
    private var original = ""
    private let model = OverlayModel()
    private var host: NSView?
    private let hint = NSTextField(labelWithString: "")
    private let hintBox = NSVisualEffectView()
    private let tools = NSStackView()
    private let toolsBox = NSVisualEffectView()   // nền mờ sau hàng nút, để nút đọc được trên mọi cảnh
    private let textBox = NSVisualEffectView()
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let copyIcon = NSButton()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { if phase == .choosing { addCursorRect(bounds, cursor: .crosshair) } }

    init(frame: NSRect, displayID: UInt32, owner: QuickTranslator) {
        self.displayID = displayID
        self.owner = owner
        super.init(frame: frame)
        for v in [hintBox, textBox, toolsBox] {
            v.material = .hudWindow; v.blendingMode = .withinWindow; v.state = .active
            v.wantsLayer = true; v.layer?.cornerRadius = 12; v.layer?.masksToBounds = true
            addSubview(v)
        }
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = .labelColor
        hintBox.addSubview(hint)
        textLabel.font = .systemFont(ofSize: 14)
        textLabel.isSelectable = true
        textBox.addSubview(textLabel)
        // Hộp dạng chữ hiện chữ gốc (bản dịch đã nằm ngay trên màn hình); nút chép chữ gốc nằm ngay trong hộp, chỉ là biểu tượng
        // để đỡ tốn chỗ.
        copyIcon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("Chép chữ gốc", "Copy original text"))
        copyIcon.isBordered = false
        copyIcon.contentTintColor = .secondaryLabelColor
        copyIcon.target = self
        copyIcon.action = #selector(copyOriginal)
        copyIcon.toolTip = L("Chép chữ gốc để tra cứu (⇧⌘C)", "Copy the original text to look it up (⇧⌘C)")
        textBox.addSubview(copyIcon)
        textBox.isHidden = true
        tools.orientation = .horizontal
        tools.spacing = 8
        tools.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        toolsBox.isHidden = true
        toolsBox.addSubview(tools)
        setHint(L("Dịch nhanh: kéo quanh chữ cần dịch · Esc để thoát", "Quick translate: drag around the text · Esc to exit"))
    }
    required init?(coder: NSCoder) { fatalError("không dùng") }

    private func setHint(_ s: String) {
        hint.stringValue = s
        hint.sizeToFit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let notch = window?.screen?.safeAreaInsets.top ?? 0
        let hs = hint.frame.size
        hintBox.frame = NSRect(x: (bounds.width - hs.width - 28) / 2, y: max(24, notch + 12), width: hs.width + 28, height: hs.height + 16)
        hint.frame.origin = NSPoint(x: 14, y: 8)
        guard phase == .showing || phase == .empty else { return }
        // Nút nằm ngay dưới vùng (hết chỗ thì lên trên), bảng chữ nằm dưới hàng nút.
        let ts = tools.fittingSize
        var ty = rect.maxY + 10
        if ty + ts.height > bounds.height - 10 { ty = max(10, rect.minY - ts.height - 10) }
        toolsBox.frame = NSRect(x: min(max(10, rect.maxX - ts.width), bounds.width - ts.width - 10), y: ty, width: ts.width, height: ts.height)
        tools.frame = toolsBox.bounds
        if !textBox.isHidden {
            let w = min(560, max(320, rect.width))
            let tw = w - 28 - 30   // chừa chỗ bên phải cho nút chép
            textLabel.preferredMaxLayoutWidth = tw
            let h = textLabel.sizeThatFits(NSSize(width: tw, height: 4000)).height
            var y = toolsBox.frame.maxY + 8
            if y + h + 24 > bounds.height - 10 { y = max(10, rect.minY - h - 34 - ts.height) }
            textBox.frame = NSRect(x: min(max(10, rect.minX), bounds.width - w - 10), y: y, width: w, height: h + 24)
            textLabel.frame = NSRect(x: 14, y: 12, width: tw, height: h)
            copyIcon.frame = NSRect(x: w - 36, y: textBox.isFlipped ? 8 : h + 24 - 34, width: 26, height: 26)
        }
    }

    // MARK: Chuột và phím

    override func mouseDown(with e: NSEvent) {
        guard phase == .choosing else { owner.close(); return }   // đang xem bản dịch: bấm ra ngoài là tắt
        start = convert(e.locationInWindow, from: nil)
        rect = .zero
    }

    override func mouseDragged(with e: NSEvent) {
        guard phase == .choosing, let s = start else { return }
        let p = convert(e.locationInWindow, from: nil)
        rect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(s.x - p.x), height: abs(s.y - p.y)).intersection(bounds)
        needsDisplay = true
    }

    func simulate(_ r: CGRect) { rect = r; start = .zero; commit() }

    override func mouseUp(with e: NSEvent) { commit() }

    private func commit() {
        guard phase == .choosing, start != nil else { return }
        start = nil
        guard rect.width >= 24, rect.height >= 12 else { rect = .zero; needsDisplay = true; return }
        phase = .working
        window?.invalidateCursorRects(for: self)
        owner.otherViews(than: self).forEach { $0.isHidden = true }   // màn hình khác: bỏ lớp mờ
        setHint(L("Đang dịch…", "Translating…"))
        needsDisplay = true
        let region = CaptureRegion(displayID: displayID, x: rect.minX, y: rect.minY, w: rect.width, h: rect.height, sw: bounds.width, sh: bounds.height)
        Task { @MainActor in
            guard let img = await owner.image(for: region), let out = await owner.translate?(region, img), owner.isOpen else {
                if owner.isOpen { finish(nil) }
                return
            }
            finish(out)
        }
    }

    override func rightMouseDown(with e: NSEvent) { owner.close() }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { owner.close() }   // Esc
        else if e.keyCode == 8, e.modifierFlags.contains(.command) {   // ⌘C chép bản dịch, ⇧⌘C chép chữ gốc
            if e.modifierFlags.contains(.shift) { copyOriginal() } else { copyText() }
        }
    }

    // MARK: Kết quả

    private func finish(_ out: QuickTranslator.Output?) {
        guard let out, !out.pieces.isEmpty else {
            phase = .empty
            setHint(out == nil ? L("Chưa dịch được. Vui lòng bấm Esc và thử lại.", "Couldn't translate. Press Esc and try again.")
                               : L("Không thấy chữ cần dịch trong vùng này · Esc để thoát", "No text to translate in this area · Esc to exit"))
            needsDisplay = true
            return
        }
        phase = .showing
        plain = out.plain
        original = out.original
        model.pieces = out.pieces
        model.screenBackground = out.background
        model.visible = true
        // Lớp thay chữ dùng chung với dịch màn hình: khung của nó rộng bằng vùng và chừa 150 điểm trên dưới.
        let h = NSHostingView(rootView: OverlayView(model: model, settings: AppSettings.shared, screenTranslation: true))
        h.frame = NSRect(x: rect.minX, y: rect.minY - 150, width: rect.width, height: rect.height + 300)
        addSubview(h, positioned: .below, relativeTo: hintBox)
        host = h
        tools.arrangedSubviews.forEach { tools.removeArrangedSubview($0); $0.removeFromSuperview() }
        // Hàng nút chỉ dùng biểu tượng cho gọn; rê chuột vào thì hiện tên.
        for (title, symbol, action) in [(L("Xem chữ gốc", "Show the original text"), "text.alignleft", #selector(toggleText)),
                                        (L("Chép bản dịch (⌘C)", "Copy the translation (⌘C)"), "doc.on.doc", #selector(copyText)),
                                        (L("Đóng (Esc)", "Close (Esc)"), "xmark", #selector(closeTapped))] {
            let b = NSButton(title: "", target: self, action: action)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            b.imagePosition = .imageOnly
            b.bezelStyle = .rounded
            b.controlSize = .large
            b.toolTip = title
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            tools.addArrangedSubview(b)
        }
        toolsBox.isHidden = false
        textLabel.stringValue = original
        #if DEVTOOLS
        if ProcessInfo.processInfo.environment["OVERSUB_QUICK_TEXT"] != nil { textBox.isHidden = false }   // chụp kiểm tra hộp dạng chữ
        #endif
        setHint(L("Esc hoặc bấm ra ngoài để tắt · ⌘C chép bản dịch · ⇧⌘C chép chữ gốc", "Esc or click outside to close · ⌘C copies the translation · ⇧⌘C the original"))
        needsDisplay = true
    }

    @objc private func toggleText() { textBox.isHidden.toggle(); needsLayout = true }
    @objc private func copyText() {
        guard !plain.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain, forType: .string)
        setHint(L("Đã sao chép bản dịch", "Translation copied"))
    }
    @objc private func copyOriginal() {
        guard !original.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(original, forType: .string)
        setHint(L("Đã sao chép chữ gốc", "Original text copied"))
    }
    @objc private func closeTapped() { owner.close() }

    // MARK: Vẽ

    override func draw(_ dirtyRect: NSRect) {
        if let img = owner.frozen[displayID] {
            NSImage(cgImage: img, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
        // Lớp mờ quanh vùng: đậm lúc chọn, nhạt hơn khi đã có bản dịch. Không dừng hình mà đã có bản dịch thì bỏ hẳn
        // lớp mờ để thấy game đang chạy.
        let live = owner.frozen[displayID] == nil
        let dimAlpha: CGFloat = phase == .choosing ? 0.4 : (live && phase == .showing ? 0 : 0.3)
        if dimAlpha > 0 {
            let dim = NSBezierPath(rect: bounds)
            if rect.width > 0 { dim.append(NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)) }
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(dimAlpha).setFill()
            dim.fill()
        }
        if rect.width > 0 {
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 9, yRadius: 9)
            border.lineWidth = phase == .choosing ? 1.5 : 1
            NSColor.white.withAlphaComponent(phase == .showing ? 0.35 : 0.9).setStroke()
            border.stroke()
        }
    }
}
