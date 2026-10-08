import SwiftUI
import AppKit

/// Màu chủ đạo của OverSub: gradient cam #FB8132 → #F7564C (cùng tông với icon).
enum Theme {
    static let orangeStart = Color(red: 0xFB / 255.0, green: 0x81 / 255.0, blue: 0x32 / 255.0)
    static let orangeEnd = Color(red: 0xF7 / 255.0, green: 0x56 / 255.0, blue: 0x4C / 255.0)
    /// Màu giữa hai đầu gradient: màu nhấn cho công tắc, thanh trượt, nút chính (các điều khiển hệ thống không nhận gradient).
    static let accent = Color(red: 0xF9 / 255.0, green: 0x6B / 255.0, blue: 0x3F / 255.0)
    static let nsAccent = NSColor(srgbRed: 0xF9 / 255.0, green: 0x6B / 255.0, blue: 0x3F / 255.0, alpha: 1)
    static let gradient = LinearGradient(colors: [orangeStart, orangeEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
}

@MainActor
final class HoverState: ObservableObject {
    @Published var on = false
}

/// Nút tròn kiểu kính, ba trạng thái: tắt (kính trung tính), bật nhưng chưa chạy (nhuộm cam dịu, không phát sáng), đang chạy
/// (gradient cam đầy đủ, phát sáng; `glowing` mạnh hơn nữa, vd. đang đọc). Rê chuột thì nổi lên nhẹ, bấm thì lún xuống.
struct GlassOrbStyle: ButtonStyle {
    var on: Bool
    var active = true       // phiên đang chạy: bật mà chưa chạy thì chỉ nhuộm dịu, để không tưởng app đang hoạt động
    var glowing = false
    var size: CGFloat = 100

    func makeBody(configuration: Configuration) -> some View {
        GlassOrb(label: configuration.label, on: on, active: active, glowing: glowing, size: size, pressed: configuration.isPressed)
    }
}

private struct GlassOrb<Label: View>: View {
    let label: Label
    let on: Bool
    let active: Bool
    let glowing: Bool
    let size: CGFloat
    let pressed: Bool
    @StateObject private var hover = HoverState()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let live = on && active
        let light = scheme == .light
        ZStack {
            // Thân kính nhuộm gradient cam, trong mờ để vẫn thấy lớp kính bên dưới. Nền sáng cần đậm hơn nhiều, không thì
            // nút bật-chưa-chạy chỉ còn hồng nhạt và biểu tượng trắng chìm mất.
            Circle().fill(Theme.gradient).opacity(live ? (light ? 0.96 : 0.62) : on ? (light ? 0.66 : 0.22) : 0)
            // Nút tắt trên nền sáng: một lớp xám nhẹ để vẫn ra hình cái nút.
            if light && !on { Circle().fill(Color.black.opacity(0.06)) }
            // Ánh sáng chiếu qua mặt kính: một vệt sáng mềm ở góc trên bên trái, không có viền cứng.
            Circle().fill(RadialGradient(colors: [.white.opacity(live ? 0.34 : (light && on ? 0.28 : 0.16)), .white.opacity(0)],
                                         center: UnitPoint(x: 0.32, y: 0.18), startRadius: 0, endRadius: size * 0.62))
            label
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .glassEffect(.regular.tint(live ? Theme.accent.opacity(0.45) : on ? Theme.accent.opacity(0.16) : .clear).interactive(), in: Circle())
        .overlay(
            Circle().strokeBorder(
                LinearGradient(colors: light ? [.black.opacity(0.10), .black.opacity(0.03), .black.opacity(0.08)]
                                             : [.white.opacity(0.55), .white.opacity(0.04), .white.opacity(0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1)
        )
        .shadow(color: Theme.orangeEnd.opacity(live ? (glowing ? 0.5 : 0.28) : 0), radius: glowing ? 22 : 12, y: 4)
        .animation(.smooth(duration: 0.4), value: glowing)
        .scaleEffect(pressed ? 0.95 : (hover.on ? 1.03 : 1))
        .animation(.spring(response: 0.28, dampingFraction: 0.65), value: pressed)
        .animation(.smooth(duration: 0.2), value: hover.on)
        .animation(.smooth(duration: 0.35), value: live)
        .animation(.smooth(duration: 0.3), value: on)
        .contentShape(Circle())
        .onHover { hover.on = $0 }
    }
}

/// Sóng âm loang ra quanh nút giọng đọc khi đang phát: ba vòng tròn nối nhau nở rộng và mờ dần. Đặt làm nền của nút
/// (không chiếm chỗ trong bố cục), tâm trùng tâm nút.
struct SpeakingRipples: View {
    var active: Bool
    var size: CGFloat
    @Environment(\.homeAnimating) private var animating

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || !animating)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let p = (t / 2.1 + Double(i) / 3).truncatingRemainder(dividingBy: 1)   // 0...1 theo vòng đời một gợn sóng
                    Circle()
                        .strokeBorder(Theme.orangeStart.opacity(0.55 * (1 - p)), lineWidth: 2.5 * (1 - p) + 0.5)
                        .frame(width: size, height: size)
                        .scaleEffect(1 + 0.62 * p)
                }
            }
            .opacity(active ? 1 : 0)
            .animation(.easeOut(duration: 0.5), value: active)
        }
        .allowsHitTesting(false)
    }
}

/// Ống nối giữa nút Phụ đề và linh vật (giọng đọc): lời thoại "chảy" từ phụ đề sang giọng đọc. Ống kính mềm, bên trong có
/// các vệt sáng luôn trôi từ trái sang phải. Ba mức: chưa chạy (vệt trắng mờ, trôi chậm), đang chạy (vệt cam, nhanh hơn),
/// đang đọc (sáng và nhanh nhất, ống phát sáng nhẹ).
///
/// Vệt sáng chạy bằng Core Animation (hệ thống tự chạy, app không vẽ lại từng khung hình): bản vẽ bằng SwiftUI tốn khoảng 15%
/// CPU suốt lúc cửa sổ mở. Đổi mức thì đổi tốc độ nhưng giữ nguyên vị trí vệt, không giật.
struct EnergyLink: View {
    var enabled = true    // giọng đọc đang bật; tắt thì không có gì truyền sang: ống trống và mờ
    var active: Bool      // phiên đang chạy và giọng đọc đang bật
    var speaking: Bool    // đang phát tiếng
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let light = scheme == .light
        let ink: Color = light ? .black : .white   // màu trung tính của ống, theo nền
        Capsule()
            // Thân ống: kính mờ, sáng ở mép trên, tối dần xuống dưới.
            .fill(LinearGradient(colors: light ? [ink.opacity(0.05), ink.opacity(0.10)] : [ink.opacity(0.13), ink.opacity(0.04)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Capsule().strokeBorder(ink.opacity(light ? 0.12 : 0.10), lineWidth: 0.6))
            .overlay {
                if enabled {
                    LinkStreaks(light: light, active: active, speaking: speaking, still: reduceMotion)
                        .clipShape(Capsule())
                }
            }
            // Ánh cam quanh ống khi đang chạy / đang đọc (lớp tĩnh, chỉ đổi khi đổi mức).
            .background {
                Capsule().fill(Theme.orangeEnd.opacity(speaking ? 0.5 : active ? 0.25 : 0))
                    .blur(radius: speaking ? 7 : 4)
            }
            .frame(height: 10)
            .opacity(enabled ? 1 : 0.5)
            .animation(.smooth(duration: 0.4), value: enabled)
            .animation(.smooth(duration: 0.5), value: active)
            .animation(.smooth(duration: 0.4), value: speaking)
            .allowsHitTesting(false)
    }
}

private struct LinkStreaks: NSViewRepresentable {
    var light: Bool
    var active: Bool
    var speaking: Bool
    var still: Bool

    func makeNSView(context: Context) -> StreakView { StreakView() }
    func updateNSView(_ view: StreakView, context: Context) { view.configure(light: light, active: active, speaking: speaking, still: still) }
}

/// Ba vệt sáng (đầu sáng, đuôi mờ dần, đốm sáng ở đầu) trôi vòng trong ống.
final class StreakView: NSView {
    private struct Streak { let holder = CALayer(); let body = CAGradientLayer(); let dot = CALayer() }
    private let lane = CALayer()
    private var streaks: [Streak] = []
    private var light = false, active = false, speaking = false, still = false
    private var configured = false
    private var builtWidth: CGFloat = -1
    /// Một vòng trôi ở mức chậm nhất (giây); mức nhanh hơn chỉ tăng tốc độ của cả lớp.
    private static let period: CFTimeInterval = 6.25

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(lane)
        for _ in 0..<3 {
            let s = Streak()
            s.body.startPoint = CGPoint(x: 0, y: 0.5)
            s.body.endPoint = CGPoint(x: 1, y: 0.5)
            s.holder.addSublayer(s.body)
            s.holder.addSublayer(s.dot)
            lane.addSublayer(s.holder)
            streaks.append(s)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) không dùng") }

    func configure(light: Bool, active: Bool, speaking: Bool, still: Bool) {
        let rebuild = still != self.still
        let animated = configured
        (self.light, self.active, self.speaking, self.still) = (light, active, speaking, still)
        configured = true
        paint(animated: animated)
        setSpeed()
        if rebuild { builtWidth = -1; needsLayout = true }
    }

    override func layout() {
        super.layout()
        guard bounds.width > 1, abs(bounds.width - builtWidth) > 0.5 else { return }
        build()
    }

    /// Đặt lại hình học và hoạt ảnh theo bề ngang hiện tại.
    private func build() {
        builtWidth = bounds.width
        let w = bounds.width, h = bounds.height
        let len = w * 0.34
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lane.frame = bounds
        for (i, s) in streaks.enumerated() {
            s.holder.bounds = CGRect(x: 0, y: 0, width: len, height: h * 0.64)
            s.holder.position = CGPoint(x: -len / 2, y: h / 2)
            s.body.frame = s.holder.bounds
            s.body.cornerRadius = h * 0.32
            let d = h * 0.56
            s.dot.frame = CGRect(x: len - h * 0.5, y: (h * 0.64 - d) / 2, width: d, height: d)
            s.dot.cornerRadius = d / 2
            s.holder.removeAllAnimations()
            let phase = Double(i) / Double(streaks.count)
            if still {
                s.holder.position.x = -len / 2 + (w + len) * phase
                continue
            }
            let a = CABasicAnimation(keyPath: "position.x")
            a.fromValue = -len / 2
            a.toValue = w + len / 2
            a.duration = Self.period
            a.repeatCount = .infinity
            a.beginTime = s.holder.convertTime(CACurrentMediaTime(), from: nil) - phase * Self.period
            s.holder.add(a, forKey: "flow")
        }
        CATransaction.commit()
    }

    /// Màu theo mức: chưa chạy thì trắng (đen trên nền sáng) mờ, chạy thì cam.
    private func paint(animated: Bool) {
        let level: CGFloat = speaking ? 1 : active ? (light ? 0.8 : 0.6) : (light ? 0.3 : 0.22)
        let hot = active || speaking
        let ink = light ? NSColor.black : NSColor.white
        let head = hot ? NSColor(Theme.orangeStart) : ink
        let tail = hot ? NSColor(Theme.orangeEnd) : ink
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.4 : 0)
        CATransaction.setDisableActions(!animated)
        for s in streaks {
            s.body.colors = [tail.withAlphaComponent(0).cgColor, tail.withAlphaComponent(0.55 * level).cgColor, head.withAlphaComponent(level).cgColor]
            s.dot.backgroundColor = (hot ? NSColor.white : ink).withAlphaComponent((hot ? 0.9 : 0.75) * level).cgColor
        }
        CATransaction.commit()
    }

    /// Đổi tốc độ cả lớp mà giữ nguyên vị trí các vệt: neo thời gian hiện tại rồi mới đổi.
    private func setSpeed() {
        let target: Float = speaking ? 3.9 : active ? 2.6 : 1
        guard lane.speed != target else { return }
        let now = CACurrentMediaTime()
        lane.timeOffset = lane.convertTime(now, from: nil)
        lane.beginTime = now
        lane.speed = target
    }
}

/// Thanh trượt mảnh: rãnh 4 điểm, phần đã chọn sáng, núm tròn nhỏ lớn lên khi rê chuột hoặc kéo.
struct SlimSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double = 0.05
    @StateObject private var hover = HoverState()

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - 14)
            let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                // Màu theo nền (đen trên nền sáng, trắng trên nền tối) để thanh luôn thấy rõ.
                Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4).padding(.horizontal, 7)
                Capsule().fill(Color.primary.opacity(0.8)).frame(width: max(4, w * frac), height: 4).padding(.leading, 7)
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .frame(width: hover.on ? 14 : 10, height: hover.on ? 14 : 10)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: 7 + w * frac - (hover.on ? 7 : 5))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = min(1, max(0, (g.location.x - 7) / w))
                let v = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                let snapped = (v / step).rounded() * step
                if snapped != value { value = snapped }
            })
            .animation(.smooth(duration: 0.15), value: hover.on)
        }
        .frame(height: 22)
        .onHover { hover.on = $0 }
    }
}

/// Nút hành động chính (CTA) to, nổi bật: viên thuốc gradient cam, chữ trắng đậm, phát sáng nhẹ; rê chuột nổi lên, bấm lún xuống.
struct CTAButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CTABody(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct CTABody<Label: View>: View {
    let label: Label
    let pressed: Bool
    @StateObject private var hover = HoverState()

    var body: some View {
        label
            .font(.system(size: 15, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    Capsule().fill(Theme.gradient)
                    // Ánh sáng nhẹ ở nửa trên cho cảm giác nổi khối.
                    Capsule().fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)], startPoint: .top, endPoint: .center))
                }
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: Theme.orangeEnd.opacity(hover.on ? 0.5 : 0.35), radius: hover.on ? 16 : 12, y: 5)
            .scaleEffect(pressed ? 0.97 : (hover.on ? 1.03 : 1))
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
            .animation(.smooth(duration: 0.2), value: hover.on)
            .contentShape(Capsule())
            .onHover { hover.on = $0 }
    }
}

/// Nút phụ (secondary): viên thuốc kính trung tính, chữ trắng; không phát sáng để không tranh chú ý với nút chính.
struct SecondaryCTAStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryCTABody(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct SecondaryCTABody<Label: View>: View {
    let label: Label
    let pressed: Bool
    @StateObject private var hover = HoverState()

    var body: some View {
        label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: Capsule())
            .scaleEffect(pressed ? 0.97 : (hover.on ? 1.02 : 1))
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
            .animation(.smooth(duration: 0.2), value: hover.on)
            .contentShape(Capsule())
            .onHover { hover.on = $0 }
    }
}

/// Nút trong hộp thoại và thông báo (cập nhật, báo lỗi, cấp quyền, khởi động lại). Nút chính và nút phụ cùng cỡ chữ, cùng
/// chiều cao, cùng bề rộng tối thiểu; nút chính tô gradient cam, nút phụ nền trung tính. Nhỏ hơn CTAButtonStyle của cửa sổ
/// chính để hợp cỡ hộp thoại macOS.
struct DialogButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        DialogButtonBody(label: configuration.label, prominent: prominent, pressed: configuration.isPressed)
    }
}

private struct DialogButtonBody<Label: View>: View {
    let label: Label
    let prominent: Bool
    let pressed: Bool
    @StateObject private var hover = HoverState()
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 16)
            .frame(minWidth: 84, minHeight: 30)
            .background {
                if prominent {
                    ZStack {
                        Capsule().fill(Theme.gradient)
                        Capsule().fill(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0)], startPoint: .top, endPoint: .center))
                    }
                    .shadow(color: Theme.orangeEnd.opacity(hover.on ? 0.35 : 0.22), radius: hover.on ? 8 : 5, y: 2)
                } else {
                    Capsule().fill(Color.primary.opacity(hover.on ? 0.11 : 0.07))
                }
            }
            .overlay(Capsule().strokeBorder(prominent ? Color.white.opacity(0.18) : Color.primary.opacity(0.08), lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
            .animation(.smooth(duration: 0.15), value: hover.on)
            .contentShape(Capsule())
            .onHover { hover.on = $0 && enabled }
            .fixedSize()
    }
}

/// Biểu tượng app cho hộp thoại, kèm huy hiệu nhỏ ở góc dưới phải như hộp thoại của macOS (vd. con bọ cho báo lỗi).
struct DialogAppIcon: View {
    var badge: String?

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 64, height: 64)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .overlay(Circle().strokeBorder(.primary.opacity(0.1)))
                        .offset(x: 4, y: 4)
                }
            }
    }
}
