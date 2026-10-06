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
/// các vệt sáng trôi từ trái sang phải. Ba mức: chưa chạy (vệt trắng mờ, đứng yên để cửa sổ mở mà không tốn CPU), đang chạy
/// (vệt cam trôi), đang đọc (sáng và nhanh nhất, ống phát sáng nhẹ).
struct EnergyLink: View {
    var enabled = true    // giọng đọc đang bật; tắt thì không có gì truyền sang: ống trống và mờ
    var active: Bool      // phiên đang chạy và giọng đọc đang bật
    var speaking: Bool    // đang phát tiếng
    @Environment(\.colorScheme) private var scheme
    @Environment(\.homeAnimating) private var animating

    var body: some View {
        let light = scheme == .light
        let ink: Color = light ? .black : .white   // màu trung tính của ống và vệt lúc chưa chạy, theo nền
        let level: Double = speaking ? 1 : active ? (light ? 0.8 : 0.6) : (light ? 0.3 : 0.22)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !(active || speaking) || !animating)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let h = size.height, w = size.width
                // Thân ống: kính mờ, sáng ở mép trên, tối dần xuống dưới.
                let tube = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: h / 2)
                g.fill(tube, with: .linearGradient(Gradient(colors: light ? [ink.opacity(0.05), ink.opacity(0.10)] : [ink.opacity(0.13), ink.opacity(0.04)]),
                                                   startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
                g.stroke(tube, with: .color(ink.opacity(light ? 0.12 : 0.10)), lineWidth: 0.6)
                guard enabled else { return }
                // Các vệt năng lượng: đầu sáng, đuôi mờ dần về phía sau; trôi từ phụ đề (trái) sang giọng đọc (phải).
                g.clip(to: tube)
                let speed = speaking ? 0.62 : active ? 0.42 : 0.16   // số vòng mỗi giây
                let count = 3
                let len = w * 0.34
                let hot = active || speaking
                let head: Color = hot ? Theme.orangeStart : ink
                let tail: Color = hot ? Theme.orangeEnd : ink
                for i in 0..<count {
                    let p = (t * speed + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
                    let x = CGFloat(p) * (w + len) - len
                    let rect = CGRect(x: x, y: h * 0.18, width: len, height: h * 0.64)
                    g.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2),
                           with: .linearGradient(Gradient(colors: [tail.opacity(0), tail.opacity(0.55 * level), head.opacity(level)]),
                                                 startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
                    // Đầu vệt: một đốm sáng nhỏ.
                    let dot = CGRect(x: rect.maxX - h * 0.5, y: h * 0.22, width: h * 0.56, height: h * 0.56)
                    g.fill(Path(ellipseIn: dot), with: .color((hot ? Color.white : ink).opacity((hot ? 0.9 : 0.75) * level)))
                }
            }
        }
        .frame(height: 10)
        .opacity(enabled ? 1 : 0.5)
        .animation(.smooth(duration: 0.4), value: enabled)
        .shadow(color: Theme.orangeEnd.opacity(speaking ? 0.55 : active ? 0.3 : 0), radius: speaking ? 9 : 5)
        .animation(.smooth(duration: 0.5), value: active)
        .animation(.smooth(duration: 0.4), value: speaking)
        .allowsHitTesting(false)
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
