import SwiftUI
import AppKit

/// Linh vật OverSub: chữ O có đôi mắt và má hồng, cùng hình với icon app. Đứng giữa màn hình chính thay nút giọng đọc,
/// bấm vào là bật / tắt giọng đọc. Lời thoại chảy từ nút Phụ đề sang linh vật qua ống năng lượng; có câu mới thì linh vật
/// nảy nhẹ như vừa nhận được.
///
/// Bốn trạng thái: ngủ (tắt giọng đọc, mắt nhắm, mặt xám), chờ (bật mà chưa chạy, mặt cam dịu, chớp mắt), nghe (đang chạy,
/// mặt cam đậm, liếc về phía Phụ đề), đọc (miệng mấp máy theo giọng, phát sáng, sóng loang).
struct Mascot: View {
    enum Mood: Equatable { case asleep, idle, listening, speaking }

    var mood: Mood
    var size: CGFloat
    /// Đổi giá trị là linh vật nảy một cái (câu thoại mới tới).
    var cue: UUID? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.homeAnimating) private var animating
    @StateObject private var life = MascotLife()

    var body: some View {
        let light = scheme == .light
        let awake = mood != .asleep
        let live = mood == .listening || mood == .speaking
        let d = size * Self.faceRatio
        // Phần đứng yên (vòng, mặt, kính, bóng đổ) tách khỏi phần chuyển động (mắt, miệng) để kính và bóng đổ chỉ vẽ một lần.
        // Chớp mắt, liếc mắt chạy theo hẹn giờ (giữa hai lần không tốn gì); chỉ miệng lúc đang đọc mới cần vẽ liên tục.
        ZStack {
            ring(light: light, live: live)
            face(light: light, awake: awake, live: live)
                .frame(width: d, height: d)
        }
        .frame(width: size, height: size)
        .glassEffect(.regular.tint(live ? Theme.accent.opacity(0.18) : .clear), in: Circle())
        .shadow(color: .black.opacity(light ? 0.10 : 0.35), radius: 10, y: 5)
        .shadow(color: Theme.orangeEnd.opacity(mood == .speaking ? 0.55 : live ? 0.32 : awake ? 0.14 : 0),
                radius: mood == .speaking ? 26 : 16, y: 6)
        .overlay {
            ZStack {
                eyes(light: light, awake: awake)
                if mood == .speaking {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !animating)) { ctx in
                        mouth(t: reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: d, height: d)
        }
        .keyframeAnimator(initialValue: CGFloat(1), trigger: cue) { content, s in
            content.scaleEffect(s)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(1.07, duration: 0.12)
                SpringKeyframe(1, duration: 0.5, spring: .bouncy)
            }
        }
        .animation(.smooth(duration: 0.45), value: mood)
        .task(id: MascotLife.Key(mood: mood, on: animating && !reduceMotion)) {
            await life.run(mood: mood, on: animating && !reduceMotion)
        }
    }

    /// Tỉ lệ mặt (lòng chữ O) so với cả linh vật, giống icon (đường kính trong 388 / ngoài 620).
    static let faceRatio: CGFloat = 0.626

    // MARK: Vòng chữ O

    private func ring(light: Bool, live: Bool) -> some View {
        let w = size * (1 - Self.faceRatio) / 2
        return ZStack {
            // Thân vòng trắng sữa, hơi trong để lớp kính bên dưới vẫn ánh lên.
            Circle().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.97), Color(red: 1, green: 0.95, blue: 0.92).opacity(0.9)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: w)
            // Vệt sáng trên mặt kính, góc trên bên trái.
            Circle().strokeBorder(
                AngularGradient(colors: [.white.opacity(0), .white.opacity(0.9), .white.opacity(0), .white.opacity(0)],
                                center: .center, startAngle: .degrees(150), endAngle: .degrees(510)),
                lineWidth: w * 0.35)
                .padding(w * 0.12)
                .blendMode(.plusLighter)
            // Viền mảnh để vòng trắng không chìm vào nền sáng.
            Circle().strokeBorder(Color.black.opacity(light ? 0.07 : 0.0), lineWidth: 0.75)
        }
    }

    // MARK: Mặt

    private func face(light: Bool, awake: Bool, live: Bool) -> some View {
        let colors: [Color] = !awake
            ? (light ? [Color(white: 0.89), Color(white: 0.80)] : [Color(white: 0.30), Color(white: 0.21)])
            : live ? [Color(red: 1.0, green: 0.62, blue: 0.38), Color(red: 0.95, green: 0.33, blue: 0.24)]
                   : [Color(red: 1.0, green: 0.74, blue: 0.57), Color(red: 0.97, green: 0.52, blue: 0.40)]
        return ZStack {
            Circle().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            // Lòng chữ O lõm vào: tối nhẹ ở mép trên.
            Circle().fill(LinearGradient(colors: [Color(red: 0.55, green: 0.2, blue: 0.1).opacity(awake ? 0.2 : 0.12), .clear],
                                         startPoint: .top, endPoint: .center))
            Circle().strokeBorder(Color(red: 0.45, green: 0.15, blue: 0.08).opacity(awake ? 0.14 : 0.08), lineWidth: 1)
            blush(awake: awake, live: live)
        }
    }

    private func blush(awake: Bool, live: Bool) -> some View {
        let s = size
        let cheek = Color(red: 1.0, green: 0.71, blue: 0.64)
        // Màu loang mờ dần ra mép, không có viền.
        let one = Ellipse()
            .fill(EllipticalGradient(colors: [cheek.opacity(0.95), cheek.opacity(0.6), cheek.opacity(0)], center: .center))
            .frame(width: s * 0.2, height: s * 0.11)
        return ZStack {
            one.offset(x: -s * 0.174, y: s * 0.135)
            one.offset(x: s * 0.174, y: s * 0.135)
        }
        .opacity(awake ? (mood == .speaking ? 1 : live ? 0.9 : 0.75) : 0.3)
    }

    private func eyes(light: Bool, awake: Bool) -> some View {
        let s = size
        let w = s * 0.106, h = s * 0.213
        let open: CGFloat = !awake ? 0.13 : (life.blink ? 0.12 : 1) * (mood == .speaking ? 0.9 : 1)
        // Đang nghe: thỉnh thoảng liếc sang trái, phía nút Phụ đề, nơi lời thoại chảy tới.
        let glance: CGFloat = mood == .listening && life.glance ? -s * 0.024 : 0
        let eyeFill: AnyShapeStyle = awake
            ? AnyShapeStyle(LinearGradient(colors: [.white, Color(red: 1, green: 0.93, blue: 0.89)], startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(light ? Color.black.opacity(0.32) : Color.white.opacity(0.55))
        let one = Capsule().fill(eyeFill)
            .frame(width: w, height: max(w * 0.32, h * open))
            .shadow(color: .black.opacity(awake ? 0.12 : 0), radius: 1.5, y: 1)
        return ZStack {
            one.offset(x: -s * 0.098 + glance, y: -s * 0.042 + (awake ? 0 : s * 0.03))
            one.offset(x: s * 0.098 + glance, y: -s * 0.042 + (awake ? 0 : s * 0.03))
        }
    }

    /// Miệng nhỏ mấp máy khi đang đọc. Giọng Siri không cho đo âm lượng nên nhịp miệng là hoạt ảnh, không khớp từng âm.
    private func mouth(t: Double) -> some View {
        let s = size
        // Miệng tròn nhỏ luôn hé (khép hẳn thành gạch ngang trông như đang chán): há to thì hẹp lại chút cho tròn.
        let open = CGFloat(abs(sin(t * 8.6) * cos(t * 3.1)))
        return Ellipse()
            .fill(LinearGradient(colors: [Color(red: 0.50, green: 0.12, blue: 0.08), Color(red: 0.70, green: 0.22, blue: 0.14)],
                                 startPoint: .top, endPoint: .bottom).opacity(0.8))
            .frame(width: s * (0.085 - 0.015 * open), height: s * (0.04 + 0.04 * open))
            .offset(y: s * 0.13)
    }
}

/// Nhịp sống của linh vật: chớp mắt sau mỗi 3–6 giây (thỉnh thoảng chớp đôi), lúc đang nghe thì đôi khi liếc sang phía
/// Phụ đề. Chạy bằng hẹn giờ và hoạt ảnh ngắn nên giữa hai lần chớp không tốn CPU.
@MainActor
final class MascotLife: ObservableObject {
    struct Key: Equatable { var mood: Mascot.Mood; var on: Bool }

    @Published var blink = false
    @Published var glance = false

    func run(mood: Mascot.Mood, on: Bool) async {
        blink = false
        if glance { withAnimation(.smooth(duration: 0.5)) { glance = false } }
        guard on, mood != .asleep else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.8...6.2)))
            if Task.isCancelled { return }
            if mood == .listening, Int.random(in: 0..<3) == 0 {
                withAnimation(.easeInOut(duration: 0.45)) { glance.toggle() }
                continue
            }
            await blinkOnce()
            if Int.random(in: 0..<5) == 0 {
                try? await Task.sleep(for: .seconds(0.14))
                await blinkOnce()
            }
        }
    }

    private func blinkOnce() async {
        withAnimation(.easeOut(duration: 0.07)) { blink = true }
        try? await Task.sleep(for: .seconds(0.09))
        withAnimation(.easeIn(duration: 0.11)) { blink = false }
    }
}

/// Nút linh vật ở giữa màn hình chính: bật / tắt giọng đọc. Chữ bên dưới giữ như nút giọng đọc cũ.
struct MascotButton: View {
    @ObservedObject var speaker: Speaker
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine

    var body: some View {
        let on = settings.speakEnabled
        VStack(spacing: 8) {
            Button { engine.toggleDub() } label: {
                Mascot(mood: mood, size: orbRowHeight, cue: engine.transcript.last?.id)
            }
            .buttonStyle(MascotPressStyle())
            .background { SpeakingRipples(active: on && speaker.isSpeaking, size: orbRowHeight) }
            VStack(spacing: 2) {
                Text(settings.dubCharacters ? "Dub" : "Voice-over").font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).contentTransition(.opacity)
            }
        }
        .frame(width: orbColumn)
        .animation(.smooth(duration: 0.3), value: on)
        .help(on ? L("Tắt giọng đọc (⇧⌘D · trong game \(HotkeyCenter.Action.toggleDub.display)). Giọng chỉ đọc lời thoại trong vùng phụ đề, không đọc chữ ở vùng dịch màn hình.", "Turn off the voice (⇧⌘D · in game \(HotkeyCenter.Action.toggleDub.display)). Voice reads only dialogue in the subtitle region, not text in screen regions.") : L("Bật giọng đọc (⇧⌘D · trong game \(HotkeyCenter.Action.toggleDub.display))", "Turn on the voice (⇧⌘D · in game \(HotkeyCenter.Action.toggleDub.display))"))
    }

    private var mood: Mascot.Mood {
        guard settings.speakEnabled else { return .asleep }
        if speaker.isSpeaking { return .speaking }
        return engine.running ? .listening : .idle
    }

    private var detail: String {
        guard settings.speakEnabled else { return L("Đang tắt · \(HotkeyCenter.Action.toggleDub.display)", "Off · \(HotkeyCenter.Action.toggleDub.display)") }
        if speaker.isSpeaking {
            if settings.dubCharacters, let n = speaker.speakingName { return L("Đang đọc · \(n)", "Speaking · \(n)") }
            return L("Đang đọc", "Speaking")
        }
        // Giọng đọc lấy lời thoại từ vùng phụ đề: chưa có vùng thì nhắc.
        if settings.region == nil { return L("Cần vùng phụ đề · \(HotkeyCenter.Action.toggleDub.display)", "Needs a subtitle region · \(HotkeyCenter.Action.toggleDub.display)") }
        if engine.running { return L("Đang nghe lời thoại · \(HotkeyCenter.Action.toggleDub.display)", "Listening for dialogue · \(HotkeyCenter.Action.toggleDub.display)") }
        return settings.dubCharacters ? L("Đọc lời thoại, theo nhân vật · \(HotkeyCenter.Action.toggleDub.display)", "Reads dialogue, per character · \(HotkeyCenter.Action.toggleDub.display)") : L("Đọc lời thoại · \(HotkeyCenter.Action.toggleDub.display)", "Reads dialogue · \(HotkeyCenter.Action.toggleDub.display)")
    }
}

/// Rê chuột thì linh vật nổi lên nhẹ, bấm thì lún xuống (như nút tròn kính).
struct MascotPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MascotPress(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct MascotPress<Label: View>: View {
    let label: Label
    let pressed: Bool
    @StateObject private var hover = HoverState()

    var body: some View {
        label
            .scaleEffect(pressed ? 0.95 : (hover.on ? 1.03 : 1))
            .animation(.spring(response: 0.28, dampingFraction: 0.65), value: pressed)
            .animation(.smooth(duration: 0.2), value: hover.on)
            .contentShape(Circle())
            .onHover { hover.on = $0 }
    }
}

/// Nền màn hình chính: các khối màu cam đào loang mềm trôi chậm liên tục. Khi phiên chạy, lớp màu rực hơn hiện dần lên và
/// trôi nhanh hơn. Giữa và mép trên luôn sáng (hoặc tối) hơn để linh vật, thanh công cụ và chữ nổi rõ. Chế độ sáng là chính:
/// màu pastel, không gắt.
///
/// Dựng bằng Core Animation: hoạt ảnh do hệ thống chạy, app không phải vẽ lại từng khung hình (bản SwiftUI tốn khoảng 15%
/// CPU chỉ vì nền chuyển động). Cửa sổ bị che thì hệ thống tự thôi vẽ.
struct HomeBackdrop: View {
    var vivid: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BackdropLayers(dark: scheme == .dark, vivid: vivid, still: reduceMotion)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

private struct BackdropLayers: NSViewRepresentable {
    var dark: Bool
    var vivid: Bool
    var still: Bool

    func makeNSView(context: Context) -> BackdropView { BackdropView() }
    func updateNSView(_ view: BackdropView, context: Context) { view.configure(dark: dark, vivid: vivid, still: still) }
}

final class BackdropView: NSView {
    /// Một khối màu: tâm và bán kính theo tỉ lệ khung (gốc dưới trái, bán kính theo cạnh dài), biên độ trôi, chu kỳ (giây).
    private struct Blob { var x, y, r, dx, dy: CGFloat; var tx, ty: Double }
    private static let blobs: [Blob] = [
        Blob(x: 0.0, y: 0.3, r: 0.55, dx: 0.10, dy: 0.08, tx: 19, ty: 23),
        Blob(x: 1.0, y: 0.45, r: 0.5, dx: 0.09, dy: 0.10, tx: 21, ty: 17),
        Blob(x: 0.45, y: -0.08, r: 0.55, dx: 0.14, dy: 0.05, tx: 25, ty: 19),
        Blob(x: 0.95, y: 0.0, r: 0.45, dx: 0.06, dy: 0.06, tx: 17, ty: 27),
        Blob(x: 0.2, y: 1.0, r: 0.42, dx: 0.12, dy: 0.04, tx: 23, ty: 21),
        Blob(x: 0.82, y: 1.0, r: 0.38, dx: 0.10, dy: 0.04, tx: 27, ty: 18),
    ]
    // Màu nền rồi màu sáu khối, theo thứ tự trên.
    private static let lightCalm: [UInt32] = [0xFFF5EE, 0xFFD3B8, 0xFFCDC4, 0xFFDABF, 0xF0DBF2, 0xFFE4D3, 0xFFE2E5]
    private static let lightVivid: [UInt32] = [0xFFEEE3, 0xFFAA7E, 0xFF9A84, 0xFFBC9A, 0xF5B9D4, 0xFFCBAB, 0xFFC4CA]
    private static let darkCalm: [UInt32] = [0x141114, 0x2E1910, 0x2B141B, 0x28180F, 0x23141F, 0x1F1613, 0x22141B]
    private static let darkVivid: [UInt32] = [0x1A1214, 0x622D12, 0x62261A, 0x48220F, 0x3E1837, 0x401F13, 0x461A2B]

    private let calm = CALayer()
    private let bright = CALayer()
    private var dark: Bool?
    private var still = false
    private var vivid = false
    private var builtSize: CGSize = .zero
    private var needsBuild = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(calm)
        layer?.addSublayer(bright)
        bright.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) không dùng") }

    func configure(dark: Bool, vivid: Bool, still: Bool) {
        if dark != self.dark || still != self.still {
            self.dark = dark
            self.still = still
            needsBuild = true
            needsLayout = true
        }
        if vivid != self.vivid {
            self.vivid = vivid
            let target: Float = vivid ? 1 : 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = bright.presentation()?.opacity ?? bright.opacity
            fade.toValue = target
            fade.duration = 1.4
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bright.opacity = target
            bright.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        // Đổi cỡ nhiều thì dựng lại cho biên độ trôi khớp khung mới; đổi ít chỉ đặt lại vị trí.
        let changed = abs(size.width - builtSize.width) > builtSize.width * 0.25 || abs(size.height - builtSize.height) > builtSize.height * 0.25
        if needsBuild || changed { build() } else { place() }
    }

    private func build() {
        needsBuild = false
        builtSize = bounds.size
        let isDark = dark ?? false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill(calm, colors: isDark ? Self.darkCalm : Self.lightCalm, speed: 1)
        fill(bright, colors: isDark ? Self.darkVivid : Self.lightVivid, speed: 1.9)
        place()
        CATransaction.commit()
    }

    private func fill(_ group: CALayer, colors: [UInt32], speed: Double) {
        group.sublayers?.forEach { $0.removeFromSuperlayer() }
        group.backgroundColor = Self.cg(colors[0], 1)
        let w = bounds.width, h = bounds.height
        for (i, b) in Self.blobs.enumerated() {
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            let c = colors[i + 1]
            blob.colors = [Self.cg(c, 1), Self.cg(c, 0.55), Self.cg(c, 0)]
            blob.locations = [0, 0.45, 1]
            group.addSublayer(blob)
            guard !still else { continue }
            let now = blob.convertTime(CACurrentMediaTime(), from: nil)
            func drift(_ key: String, _ amount: CGFloat, _ period: Double, _ phase: Double) {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = -amount
                a.toValue = amount
                a.duration = period / speed
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.beginTime = now - phase * a.duration   // mỗi khối bắt đầu ở một pha khác nhau
                blob.add(a, forKey: key)
            }
            drift("transform.translation.x", b.dx * w, b.tx, Double(i) * 0.37)
            drift("transform.translation.y", b.dy * h, b.ty, Double(i) * 0.61)
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 0.9
            breathe.toValue = 1.12
            breathe.duration = (b.tx + b.ty) / 2 / speed
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.beginTime = now - Double(i) * 0.43 * breathe.duration
            blob.add(breathe, forKey: "breathe")
        }
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = bounds.width, h = bounds.height, long = max(w, h)
        for group in [calm, bright] {
            group.frame = bounds
            for (blob, b) in zip(group.sublayers ?? [], Self.blobs) {
                let r = b.r * long
                blob.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
                blob.position = CGPoint(x: b.x * w, y: b.y * h)
            }
        }
        CATransaction.commit()
    }

    private static func cg(_ hex: UInt32, _ alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: Dừng hoạt ảnh khi không ai nhìn

/// Màn hình chính có đang lộ ra không. Cửa sổ bị game che kín, app bị ẩn hay thu nhỏ thì nền, linh vật, ống năng lượng
/// và sóng loang dừng hẳn, không ăn CPU lúc đang chơi. Mặc định là có (các chỗ khác dùng chung view vẫn chạy bình thường).
struct HomeAnimatingKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var homeAnimating: Bool {
        get { self[HomeAnimatingKey.self] }
        set { self[HomeAnimatingKey.self] = newValue }
    }
}

/// Theo dõi trạng thái che khuất của một cửa sổ (macOS báo khi cửa sổ hết / lại hiện trên màn hình).
@MainActor
final class WindowPresence: ObservableObject {
    @Published private(set) var visible = true
    private weak var window: NSWindow?
    private var token: NSObjectProtocol?

    func track(_ w: NSWindow?) {
        guard let w, w !== window else { return }
        if let token { NotificationCenter.default.removeObserver(token) }
        window = w
        update()
        token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        let v = window?.occlusionState.contains(.visible) ?? true
        if v != visible { visible = v }
        #if DEVTOOLS
        DebugLog.write("Màn hình chính: \(v ? "đang hiện" : "bị che / ẩn")")
        #endif
    }
}

/// View rỗng đặt sau nội dung để biết nó nằm trong cửa sổ nào.
struct WindowPresenceReader: NSViewRepresentable {
    let presence: WindowPresence

    func makeNSView(context: Context) -> NSView { Probe(presence: presence) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        let presence: WindowPresence
        init(presence: WindowPresence) {
            self.presence = presence
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) không dùng") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            presence.track(window)
        }
    }
}

