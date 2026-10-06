import SwiftUI
import AppKit

/// Cửa sổ Cửa sổ phụ đề là NSPanel không kích hoạt app, giống phụ đề đè lên game. Cửa sổ thường của SwiftUI không theo sang
/// Space khác, nhất là Space của game toàn màn hình, dù đã đặt canJoinAllSpaces.
private final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Bấm đúp vào dải phụ đề không được phóng to cửa sổ ra cả màn hình.
    // Cho đặt ở bất kỳ đâu, kể cả sát mép dưới hay tràn một phần ra ngoài màn hình.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func zoom(_ sender: Any?) {}
    override func performZoom(_ sender: Any?) {}
}

/// Báo rê chuột vào hay ra khỏi cửa sổ, kể cả khi đang ở trong game (app không ở phía trước).
private final class SubtitleHostingView: NSHostingView<AnyView> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    // SwiftUI cũng có vùng theo dõi riêng (từng nút); chỉ xét vùng phủ cả cửa sổ.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === area { onHover?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === area { onHover?(false) }
    }
}

/// Trạng thái Cửa sổ phụ đề: mở/đóng, ghim (nổi trên cùng, theo sang mọi Space), giao diện nền, rê chuột mới hiện nút.
@MainActor
final class SubtitleWindowState: ObservableObject {
    static let shared = SubtitleWindowState()
    private let d = UserDefaults.standard
    private static let frameName = "OverSubSubtitlePanel"

    @Published var onTop: Bool { didSet { d.set(onTop, forKey: "subtitleWindowOnTop"); apply() } }
    /// Độ kính mờ của nền (0 = trong suốt hẳn, chỉ còn chữ; 1 = kính mờ đầy đủ của macOS).
    @Published var blur: Double { didSet { d.set(blur, forKey: "subtitleBlur") } }
    /// Độ tối phủ lên nền, để chữ dễ đọc trên cảnh sáng.
    @Published var dim: Double { didSet { d.set(dim, forKey: "subtitleDim") } }
    @Published var hovering = false
    @Published var showAppearance = false
    @Published private(set) var isOpen = false
    /// Cửa sổ đang thấp tới mức chỉ còn một dòng chữ (do người dùng kéo hoặc bấm "Một dòng").
    @Published var compact = false

    /// Kéo cửa sổ bằng bất kỳ chỗ nào không phải nút: vị trí chuột và cửa sổ lúc bắt đầu kéo.
    var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var panel: NSPanel?

    private init() {
        onTop = d.bool(forKey: "subtitleWindowOnTop")
        blur = d.object(forKey: "subtitleBlur") as? Double ?? 0.85
        dim = d.object(forKey: "subtitleDim") as? Double ?? 0.25
    }

    var window: NSWindow? { panel }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        // Mở lên là ghim sẵn: chưa ghim thì cửa sổ nằm dưới Dock và dưới game, kéo xuống sát đáy màn hình là bị Dock che mất,
        // không còn chỗ nào để rê chuột vào lấy lên (người dùng gặp 06/10/2026).
        if !onTop { onTop = true }
        rescueIfOffscreen(p)
        apply()
        p.orderFrontRegardless()
        isOpen = true
        d.set(true, forKey: "subtitleWindowOpen")
    }

    func close() {
        panel?.orderOut(nil)
        closed()
    }

    func toggle() { isOpen ? close() : show() }

    /// Mở lại lúc khởi động nếu lần trước thoát app khi Cửa sổ phụ đề đang mở.
    func restore() {
        if d.bool(forKey: "subtitleWindowOpen") { show() }
    }

    private func closed() {
        isOpen = false
        hovering = false
        showAppearance = false
        d.set(false, forKey: "subtitleWindowOpen")
    }

    private func makePanel() -> NSPanel {
        let p = SubtitlePanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 220),
                              // Không có thanh tiêu đề: macOS không cho kéo thanh tiêu đề xuống sát mép dưới màn hình, mà ở chế độ
                              // một dòng thì cả cửa sổ gần như là thanh tiêu đề, nên không kéo xuống dải đen dưới game được.
                              styleMask: [.borderless, .resizable, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.title = L("Cửa sổ phụ đề", "Subtitle window")
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
        p.isMovableByWindowBackground = false   // kéo bằng cử chỉ riêng (moveWindow), không bị hệ thống giới hạn vị trí
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.ignoresMouseEvents = false   // nhận chuột cả ở phần nền trong suốt, không lọt xuống game
        p.animationBehavior = .utilityWindow
        p.contentMinSize = NSSize(width: 300, height: 34)

        let root = SubtitleWindowView()
            .environmentObject(AppModel.shared.settings)
            .environmentObject(AppModel.shared.engine)
        let host = SubtitleHostingView(rootView: AnyView(root))
        host.sizingOptions = []   // kích thước do người dùng kéo, không theo nội dung
        host.onHover = { [weak self] in self?.hovering = $0 }
        p.contentView = host

        if !p.setFrameUsingName(Self.frameName), let screen = NSScreen.main {
            // Lần đầu: đặt ở giữa phía dưới màn hình, chỗ phụ đề thường nằm.
            let v = screen.visibleFrame
            p.setFrame(NSRect(x: v.midX - 380, y: v.minY + 60, width: 760, height: 220), display: false)
        }
        p.setFrameAutosaveName(Self.frameName)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed() }
        }
        return p
    }

    /// Ghim: nổi trên mọi cửa sổ, kể cả Dock (vẫn dưới thanh menu), và có mặt ở mọi Space, kể cả Space của game toàn màn hình.
    /// Bỏ ghim: nằm yên ở Space hiện tại; đang ở vùng Dock thì được đẩy lên, không thì Dock che mất.
    func apply() {
        guard let p = panel else { return }
        p.level = onTop ? Self.pinnedLevel : .normal
        p.collectionBehavior = onTop ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle] : [.managed, .participatesInCycle]
        if !onTop { liftAboveDock(p) }
    }

    /// Ngay trên Dock, dưới thanh menu và menu đang mở.
    static let pinnedLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

    /// Cửa sổ nằm ngoài mọi màn hình (vd. màn hình phụ đã rút ra) thì đưa về chỗ mặc định trên màn hình chính.
    private func rescueIfOffscreen(_ p: NSWindow) {
        let visible = NSScreen.screens.contains { s in
            let i = s.frame.intersection(p.frame)
            return i.width >= 80 && i.height >= min(30, p.frame.height)
        }
        guard !visible, let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        p.setFrame(NSRect(x: v.midX - p.frame.width / 2, y: v.minY + 60, width: p.frame.width, height: p.frame.height), display: false)
    }

    /// Mép dưới cửa sổ thấp hơn vùng dùng được của màn hình (tức là lấn vào chỗ Dock): đẩy lên sát trên Dock.
    private func liftAboveDock(_ p: NSWindow) {
        guard let screen = p.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        guard v.minY > screen.frame.minY, p.frame.minY < v.minY else { return }
        p.setFrameOrigin(NSPoint(x: p.frame.minX, y: v.minY))
    }

    // MARK: Một dòng

    /// Chiều cao vừa đúng một dòng chữ cỡ `font`.
    static func singleLineHeight(_ font: Double) -> CGFloat { ceil(font * 1.3 + 16) }
    /// Cửa sổ phải cao ít nhất chừng này mới xếp được nhiều dòng (tên nhân vật, câu thoại, câu gốc).
    static func multilineMinHeight(_ font: Double) -> CGFloat { ceil(font * 2.6 + 40) }

    /// Thu cửa sổ còn một dòng (giữ nguyên mép dưới), bấm lần nữa trả lại chiều cao trước đó.
    func toggleSingleLine(font: Double) {
        guard let p = panel else { return }
        var f = p.frame
        if compact {
            let saved = d.object(forKey: "subtitleTallHeight") as? Double ?? 220
            f.size.height = max(CGFloat(saved), Self.multilineMinHeight(font) + 20)
        } else {
            d.set(Double(f.height), forKey: "subtitleTallHeight")
            f.size.height = Self.singleLineHeight(font)
        }
        p.setFrame(f, display: true, animate: true)
    }

    /// Đang một dòng mà đổi cỡ chữ thì cửa sổ cao/thấp theo để chữ to/nhỏ thấy ngay.
    func fitSingleLine(font: Double) {
        guard compact, let p = panel else { return }
        var f = p.frame
        f.size.height = Self.singleLineHeight(font)
        p.setFrame(f, display: true, animate: true)
    }
}

/// Nền kính mờ của macOS.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Cửa sổ phụ đề: cửa sổ riêng chỉ có câu thoại. Kéo thấp xuống (hoặc bấm "Một dòng") thì còn một dải chữ mỏng để không che
/// thông tin game khi chơi trên một màn hình; nút điều khiển chỉ hiện khi rê chuột và nổi đè lên chữ.
struct SubtitleWindowView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine
    @ObservedObject private var state = SubtitleWindowState.shared

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let compact = h < SubtitleWindowState.multilineMinHeight(settings.windowFontSize)
            let radius = compact ? min(h / 2, 22) : 14
            ZStack(alignment: compact ? .trailing : .topTrailing) {
                Group {
                    if compact { singleLine(height: h, width: geo.size.width) } else { multiline }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.hovering || state.showAppearance {
                    let tight = compact && h < 44
                    let row = ViewThatFits(in: .horizontal) {
                        controls(labels: true, tight: tight)
                        controls(labels: false, tight: tight)
                    }
                    if compact {
                        // Một dòng: nút nằm đè lên đuôi câu, phía sau có nền mờ dần để chữ khuất gọn, không lộ qua lớp kính.
                        row.padding(.trailing, max(4, (h - 30) / 2))
                            .padding(.leading, 40)
                            .frame(maxHeight: .infinity)
                            .background { tray }
                            .transition(.opacity)
                    } else {
                        row.padding(10).transition(.opacity)
                    }
                }
                // Nút Bắt đầu / Dừng nằm riêng ở mép trái, xa cụm nút bên phải (sát nút đóng thì dễ bấm nhầm).
                if state.hovering || state.showAppearance {
                    let tight = compact && h < 44
                    Group {
                        if compact {
                            leftButtons(tight: tight)
                                .padding(.leading, max(6, (h - 30) / 2 + 3))
                                .padding(.trailing, 40)
                                .frame(maxHeight: .infinity)
                                .background { tray.scaleEffect(x: -1, y: 1) }   // cùng nền với cụm nút bên phải, mờ dần về phía câu
                        } else {
                            leftButtons(tight: false).padding(10)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .leading : .topLeading)
                    .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: h)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            .gesture(moveWindow)
            .onAppear { state.compact = compact }
            .onChange(of: compact) { _, c in state.compact = c }
        }
        .animation(.smooth(duration: 0.2), value: state.hovering)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)   // cửa sổ luôn nền tối chữ trắng, kể cả khi máy để chế độ sáng
    }

    private var moveWindow: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in
                guard let w = state.window else { return }
                let mouse = NSEvent.mouseLocation   // toạ độ màn hình, không đổi theo cửa sổ nên kéo không bị giật
                if state.dragStart == nil { state.dragStart = (mouse, w.frame.origin) }
                guard let s = state.dragStart else { return }
                w.setFrameOrigin(NSPoint(x: s.origin.x + mouse.x - s.mouse.x, y: s.origin.y + mouse.y - s.mouse.y))
            }
            .onEnded { _ in state.dragStart = nil }
    }

    private var background: some View {
        ZStack {
            VisualEffectBackground().opacity(state.blur)
            Color.black.opacity(state.dim)
        }
    }

    /// Nền sau cụm nút ở chế độ một dòng: giống nền cửa sổ nhưng đậm hơn một chút, mép trái mờ dần vào câu thoại.
    private var tray: some View {
        let fill = ZStack {
            VisualEffectBackground()   // kính đặc hẳn: che kín chữ phía dưới
            Color.black.opacity(max(state.dim, 0.35))
        }
        return HStack(spacing: 0) {
            fill.mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)).frame(width: 40)
            fill
        }
    }

    private var isEmpty: Bool { engine.lastTranslation.isEmpty && engine.lastSource.isEmpty }
    private var mainText: String { engine.lastTranslation.isEmpty ? engine.lastSource : engine.lastTranslation }
    /// Nền gần trong suốt: thêm bóng cho chữ dễ đọc.
    private var textShadow: Bool { state.blur < 0.3 && state.dim < 0.3 }

    /// Một dòng: tên nhân vật đứng trước câu thoại, cùng cỡ chữ; câu dài thì cả dòng cùng co lại cho vừa.
    private func singleLine(height h: CGFloat, width: CGFloat) -> some View {
        // Cỡ chữ theo chiều cao dải, rồi nhỏ lại theo bề ngang để cả câu luôn nằm vừa, căn giữa, không tràn lệch.
        var size = max(11, min(settings.windowFontSize, (h - 14) / 1.3))
        let pad = max(14, h * 0.45)
        if !isEmpty {
            let line = (engine.lastSpeaker.map { $0 + ":  " } ?? "") + mainText
            let w = (line as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]).width
            let avail = width - pad * 2 - 4
            if w > avail, w > 0 { size = max(9, size * avail / w) }
        }
        return HStack(spacing: 8) {
            if isEmpty {
                Image(systemName: "captions.bubble").foregroundStyle(.secondary)
                Text(L("Phụ đề sẽ hiện ở đây · rê chuột để chỉnh", "Subtitles will appear here · hover to adjust")).foregroundStyle(.secondary).lineLimit(1)
            } else {
                KaraokeText(speaker: engine.speaker, text: mainText, size: size, onDark: true, lines: 1, name: engine.lastSpeaker)
            }
        }
        .font(.system(size: size, weight: .semibold))
        .minimumScaleFactor(0.5)
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(textShadow ? 0.9 : 0), radius: 3, y: 1)
        .padding(.horizontal, pad)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.smooth(duration: 0.25), value: engine.lastTranslation)
    }

    private var multiline: some View {
        VStack(spacing: 10) {
            if isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "captions.bubble").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text(L("Phụ đề sẽ hiện ở đây", "Subtitles will appear here")).font(.title3.weight(.semibold))
                    Text(L("Rê chuột vào để ghim nổi trên mọi Space, thu còn một dòng, chỉnh nền và cỡ chữ.", "Hover to pin it above every Space, shrink it to one line, or adjust the background and text size."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                if let s = engine.lastSpeaker {
                    Text(s).font(.system(size: settings.windowFontSize * 0.45, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                }
                KaraokeText(speaker: engine.speaker, text: mainText, size: settings.windowFontSize, onDark: true)
                if settings.windowShowsOriginal, !engine.lastTranslation.isEmpty, !engine.lastSource.isEmpty {
                    Text(engine.lastSource)
                        .font(.system(size: settings.windowFontSize * 0.6))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(textShadow ? 0.9 : 0), radius: 3, y: 1)
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .animation(.smooth(duration: 0.25), value: engine.lastTranslation)
    }

    private func leftButtons(tight: Bool) -> some View {
        HStack(spacing: 8) {
            startButton(tight: tight)
            ignoreButton(tight: tight)
        }
    }

    /// Bỏ qua câu đang hiện: từ nay không dịch, không đọc nữa (logo, chữ cố định lọt vào vùng phụ đề). Cùng biểu tượng với
    /// nút này ở cửa sổ chính và bảng Lịch sử: chữ có dấu ×, dễ hiểu hơn con mắt gạch chéo (dễ tưởng là ẩn phụ đề).
    private func ignoreButton(tight: Bool) -> some View {
        let d: CGFloat = tight ? 24 : 30
        return Button { engine.ignoreCurrentSentence() } label: {
            Image(systemName: "text.badge.xmark")
                .font(.system(size: tight ? 10 : 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: d, height: d)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .disabled(engine.lastSource.isEmpty)
        .opacity(engine.lastSource.isEmpty ? 0.4 : 1)
        .help(L("Bỏ qua câu này: từ nay không dịch, không đọc nữa (logo, chữ cố định…)", "Ignore this line: never translate or read it again (logos, fixed text…)"))
    }

    /// Nút chính: bắt đầu hoặc dừng cả phiên, như nút Bắt đầu ở cửa sổ chính. Biểu tượng chỉ việc sẽ làm.
    /// Màu theo trạng thái như các nút tròn ở cửa sổ chính: đang dừng là kính xám, đang chạy mới cam phát sáng
    /// (cam cả lúc dừng thì nhìn tưởng đang chạy).
    private func startButton(tight: Bool) -> some View {
        let running = engine.anyRunning
        let key = HotkeyCenter.Action.toggleRunning.display
        let d: CGFloat = tight ? 24 : 30
        return Button { engine.toggleRunning() } label: {
            Image(systemName: running ? "stop.fill" : "play.fill")
                .font(.system(size: tight ? 10 : 12, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: running ? 0 : 1)   // tam giác "play" lệch trái về thị giác, đẩy nhẹ cho cân
                .frame(width: d, height: d)
                .background {
                    if running {
                        Circle().fill(Theme.gradient)
                            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                            .shadow(color: Theme.orangeEnd.opacity(0.45), radius: 6, y: 2)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(running ? .identity : .regular.interactive(), in: Circle())
        .animation(.smooth(duration: 0.2), value: running)
        .help(running ? L("Dừng phụ đề và dịch màn hình (\(key))", "Stop subtitles and screen translation (\(key))")
                      : L("Bắt đầu phụ đề và dịch màn hình (\(key))", "Start subtitles and screen translation (\(key))"))
    }

    /// Nút điều khiển: chỉ hiện khi rê chuột vào, nổi đè lên chữ. Cửa sổ hẹp thì bỏ chữ, chỉ còn biểu tượng.
    private func controls(labels: Bool, tight: Bool) -> some View {
        let vPad: CGFloat = tight ? 4 : 7
        return GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                // Đã ghim: nền nút sáng lên và biểu tượng ghim tô đặc; chữ vẫn trắng (chữ cam trên kính xám rất chói).
                capsule(labels, tight: tight, lit: state.onTop) {
                    Button { state.onTop.toggle() } label: {
                        Label(state.onTop ? L("Đã ghim", "Pinned") : L("Ghim", "Pin"), systemImage: state.onTop ? "pin.fill" : "pin")
                            .foregroundStyle(.primary)
                    }
                }
                .help(state.onTop ? L("Đang nổi trên cùng và theo sang mọi Space. Bấm để bỏ ghim.", "Floating on top and following you to every Space. Click to unpin.") : L("Nổi trên cùng và theo sang mọi Space", "Float on top and follow to every Space"))

                capsule(labels, tight: tight) {
                    Button { state.toggleSingleLine(font: settings.windowFontSize) } label: {
                        Label(state.compact ? L("Nhiều dòng", "Multiple lines") : L("Một dòng", "One line"),
                              systemImage: state.compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    }
                }
                .help(state.compact ? L("Trả lại cửa sổ cao như trước", "Restore the window to its previous height") : L("Thu còn một dải chữ mỏng để không che màn hình game", "Shrink to a thin strip of text so it doesn't cover the game"))

                capsule(labels, tight: tight) {
                    Button { state.showAppearance.toggle() } label: { Label(L("Nền", "Background"), systemImage: "circle.lefthalf.filled") }
                }
                .help(L("Kính mờ và độ tối của nền", "Background blur and darkness"))
                .popover(isPresented: $state.showAppearance.deduplicated, arrowEdge: .bottom) { AppearanceControls().padding(14).frame(width: 280) }

                HStack(spacing: 10) {
                    Button { changeFont(-2) } label: { Text("A−").font(.system(size: 12, weight: .semibold)) }
                        .help(L("Chữ nhỏ hơn", "Smaller text"))
                    Divider().frame(height: 14)
                    Button { changeFont(2) } label: { Text("A+").font(.system(size: 15, weight: .semibold)) }
                        .help(L("Chữ lớn hơn", "Larger text"))
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12).padding(.vertical, vPad - 1)
                .glassEffect(.regular.interactive(), in: Capsule())

                Button { state.close() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 9).padding(.vertical, vPad + 1)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .help(L("Đóng Cửa sổ phụ đề (⌘J để mở lại)", "Close the subtitle window (⌘J to reopen)"))

            }
            .font(.system(size: tight ? 12 : 13, weight: .medium))
            .fixedSize()
        }
    }

    private func capsule<B: View>(_ labels: Bool, tight: Bool, lit: Bool = false, @ViewBuilder _ button: () -> B) -> some View {
        Group {
            if labels { button().labelStyle(.titleAndIcon) } else { button().labelStyle(.iconOnly) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, labels ? 12 : 9).padding(.vertical, tight ? 4 : 7)
        .glassEffect(.regular.tint(lit ? Color.white.opacity(0.28) : .clear).interactive(), in: Capsule())
    }

    private func changeFont(_ delta: Double) {
        engine.adjustWindowFont(delta)
        state.fitSingleLine(font: settings.windowFontSize)
    }
}

/// Chỉnh nền Cửa sổ phụ đề: dùng ở nút trên cửa sổ và ở Cài đặt → Phụ đề.
struct AppearanceControls: View {
    @ObservedObject private var state = SubtitleWindowState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Nền Cửa sổ phụ đề", "Subtitle window background")).font(.headline)
            row(L("Kính mờ", "Blur"), value: $state.blur, help: L("0% = trong suốt hẳn, chỉ còn chữ (có bóng cho dễ đọc)", "0% = fully transparent, text only (with a shadow for legibility)"))
            row(L("Độ tối", "Darkness"), value: $state.dim, help: L("Tối hơn để chữ rõ trên cảnh sáng", "Darker so text stands out on bright scenes"))
            HStack {
                Button(L("Trong suốt", "Transparent")) { state.blur = 0; state.dim = 0 }
                Button(L("Kính mờ", "Frosted glass")) { state.blur = 0.85; state.dim = 0.25 }
                Button(L("Nền tối", "Dark")) { state.blur = 0.6; state.dim = 0.75 }
            }
            .controlSize(.small)
        }
    }

    private func row(_ title: String, value: Binding<Double>, help: String) -> some View {
        HStack {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
        }
        .help(help)
    }
}
