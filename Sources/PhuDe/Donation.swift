import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// Thông tin nhận ủng hộ và mã VietQR. Mã dựng ngay trên máy theo chuẩn EMVCo của VietQR (Napas 247), từ mã "Nhận tiền"
/// của ví MoMo: thêm số tiền (thẻ 54) và nội dung chuyển khoản (thẻ 62-08) để người ủng hộ quét là xong, không phải gõ gì.
/// Bỏ số tiền thì ra đúng mã gốc của MoMo (đã đối chiếu cả mã kiểm tra CRC).
enum Donation {
    static let recipient = "TRINH NGOC HIEU"
    static let wallet = "MoMo"
    static let account = "PSP2603414800000452"
    static let note = "OverSub"
    static let repo = URL(string: "https://github.com/imhillxtz/oversub-mac")!
    /// Ủng hộ từ nước ngoài. Link gọn, không kèm tham số ngôn ngữ: PayPal tự hiện theo ngôn ngữ của người xem.
    static let paypal = "https://paypal.me/ngochieuit"
    /// Thẻ 38 (thông tin người nhận) của mã gốc: định danh VietQR, mã ngân hàng của MoMo, số tài khoản, dịch vụ chuyển nhanh.
    private static let merchant = "0010A000000727013300069710250119PSP26034148000004520208QRIBFTTA"
    /// Mã tham chiếu của ví trong mã gốc (thẻ 62-05), giữ nguyên.
    private static let reference = "MOMOW2W46756812"

    /// Trong nước: quét VietQR bằng app ngân hàng / ví. Quốc tế: PayPal.
    enum Channel: String, CaseIterable, Identifiable {
        case vietQR, paypal
        var id: String { rawValue }
        var title: String { self == .vietQR ? L("Trong nước · VietQR", "Vietnam · VietQR") : L("Quốc tế · PayPal", "International · PayPal") }
    }

    struct Tier: Identifiable, Equatable {
        let channel: Channel
        let amount: Int?
        let icon: String
        let label: String
        var id: Int { amount ?? 0 }
        var price: String? {
            guard let amount else { return nil }
            return channel == .paypal ? "$\(amount)" : Donation.vnd(amount)
        }
    }

    static func tiers(_ c: Channel) -> [Tier] {
        let amounts = c == .paypal ? [3, 5, 10] : [20_000, 50_000, 100_000]
        return [Tier(channel: c, amount: amounts[0], icon: "cup.and.saucer.fill", label: L("Ly cà phê", "A coffee")),
                Tier(channel: c, amount: amounts[1], icon: "takeoutbag.and.cup.and.straw.fill", label: L("Bữa sáng", "Breakfast")),
                Tier(channel: c, amount: amounts[2], icon: "fork.knife", label: L("Bữa trưa", "Lunch")),
                Tier(channel: c, amount: nil, icon: "heart.fill", label: L("Tự nhập số tiền", "Enter your own"))]
    }

    /// Link PayPal.me, kèm sẵn số tiền nếu có (vd. /5USD).
    static func paypalURL(_ amount: Int?) -> URL {
        URL(string: amount.map { "\(paypal)/\($0)USD" } ?? paypal)!
    }

    static func payload(amount: Int?) -> String {
        func tlv(_ id: String, _ value: String) -> String { id + String(format: "%02d", value.utf8.count) + value }
        var s = tlv("00", "01") + tlv("01", amount == nil ? "11" : "12") + tlv("38", merchant) + tlv("53", "704")
        if let amount { s += tlv("54", String(amount)) }
        s += tlv("58", "VN") + tlv("62", tlv("05", reference) + tlv("08", note)) + "6304"
        return s + crc(s)
    }

    /// CRC-16/CCITT-FALSE theo chuẩn EMVCo, 4 chữ số hex viết hoa.
    private static func crc(_ s: String) -> String {
        var c: UInt16 = 0xFFFF
        for b in s.utf8 {
            c ^= UInt16(b) << 8
            for _ in 0..<8 { c = (c & 0x8000) != 0 ? (c << 1) ^ 0x1021 : c << 1 }
        }
        return String(format: "%04X", c)
    }

    /// Ảnh mã QR, mỗi ô một điểm ảnh (phóng to bằng `.interpolation(.none)` cho sắc nét). Mức sửa lỗi cao để đặt icon ở giữa.
    static func qrImage(_ text: String) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "H"
        guard let out = f.outputImage else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }

    static func vnd(_ amount: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        return (f.string(from: NSNumber(value: amount)) ?? "\(amount)") + "đ"
    }

    // MARK: Số câu đã dịch (để nói "OverSub đã dịch bao nhiêu câu cho bạn")

    private static let linesKey = "statLinesTranslated"
    static var linesTranslated: Int { UserDefaults.standard.integer(forKey: linesKey) }
    static func countLine() { UserDefaults.standard.set(linesTranslated + 1, forKey: linesKey) }
}

@MainActor
final class DonateState: ObservableObject {
    /// Giao diện tiếng Anh thì mặc định PayPal (người ở nước ngoài), tiếng Việt thì VietQR.
    @Published var channel: Donation.Channel = Lang.isEnglish ? .paypal : .vietQR {
        didSet { if channel != oldValue { tier = Donation.tiers(channel)[1] } }
    }
    @Published var tier = Donation.tiers(Lang.isEnglish ? .paypal : .vietQR)[1]
    @Published var copied: String?
}

/// Cửa sổ "Ủng hộ OverSub": linh vật, lời nhờ ngắn, số câu app đã dịch cho bạn, chọn mức, quét mã. Không tiện ủng hộ tiền thì
/// gắn sao GitHub hoặc giới thiệu cho bạn bè.
struct DonateView: View {
    @StateObject private var state = DonateState()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let lines = Donation.linesTranslated
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Mascot(mood: .idle, size: 68)
                Text(L("Ủng hộ OverSub", "Support OverSub")).font(.title2.weight(.bold))
                Text(L("OverSub miễn phí cho mọi người. Nếu app giúp bạn chơi game vui hơn, mời mình một ly cà phê để có thêm động lực làm tiếp nhé.",
                       "OverSub is free for everyone. If it makes your games more fun, buy me a coffee to keep it going."))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                if lines >= 10 {
                    Label(L("OverSub đã dịch \(lines.formatted()) câu thoại cho bạn", "OverSub has translated \(lines.formatted()) lines for you"),
                          systemImage: "text.bubble.fill")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            channelPicker
            tierPicker
            qrCard
            if state.channel == .vietQR { details } else { paypalButton }
            Divider().padding(.horizontal, 8)
            alternatives
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)   // thanh tiêu đề ẩn, chừa chỗ cho ba nút cửa sổ
        .padding(.bottom, 20)
        .frame(width: 480)
        .background { HomeBackdrop(vivid: false) }
        .animation(.smooth(duration: 0.25), value: state.tier)
        .animation(.smooth(duration: 0.25), value: state.channel)
    }

    // MARK: Chọn kênh, chọn mức

    /// Hai kênh ngang hàng: viên trắng trên nền kính như hàng chọn mức (không dùng màu nhấn xanh của hệ thống).
    private var channelPicker: some View {
        HStack(spacing: 2) {
            ForEach(Donation.Channel.allCases) { c in
                let on = c == state.channel
                Button { state.channel = c } label: {
                    Text(c.title)
                        .font(.callout.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background {
                            if on {
                                Capsule().fill(scheme == .light ? Color.white : Color.white.opacity(0.14))
                                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: Capsule())
    }

    private var tierPicker: some View {
        HStack(spacing: 4) {
            ForEach(Donation.tiers(state.channel)) { t in
                let on = t == state.tier
                Button { state.tier = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(on ? Color.primary : Color.secondary)
                        Text(t.price ?? L("Tuỳ bạn", "Any")).font(.callout.weight(.semibold)).monospacedDigit()
                        Text(t.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(scheme == .light ? Color.white : Color.white.opacity(0.14))
                                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Mã QR

    private var qrCard: some View {
        let paypal = state.channel == .paypal
        let payload = paypal ? Donation.paypalURL(state.tier.amount).absoluteString : Donation.payload(amount: state.tier.amount)
        return VStack(spacing: 10) {
            ZStack {
                if let img = Donation.qrImage(payload) {
                    Image(decorative: img, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 208, height: 208)
                }
                // Icon ở giữa mã, như các ví hay đặt ảnh đại diện; mức sửa lỗi H chịu được phần bị che.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .padding(3)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .id(payload)
            .transition(.opacity)
            Text(paypal ? "paypal.me/ngochieuit" + (state.tier.price.map { " · \($0)" } ?? "")
                 : state.tier.price.map { L("\($0) · nội dung \"\(Donation.note)\"", "\($0) · message \"\(Donation.note)\"") }
                    ?? L("Bạn tự nhập số tiền khi quét", "Enter any amount after scanning"))
                .font(.caption.weight(.medium)).foregroundStyle(Color.black.opacity(0.6))
                .monospacedDigit()
        }
        .padding(16)
        // Nền thẻ luôn trắng để mọi app ngân hàng quét dễ, kể cả ở chế độ tối.
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .overlay(alignment: .bottom) {
            Text(paypal ? L("Quét bằng camera điện thoại, hoặc bấm nút bên dưới", "Scan with your phone camera, or use the button below")
                 : L("Quét bằng app ngân hàng, MoMo hoặc ZaloPay trên điện thoại", "Scan with a Vietnamese banking app, MoMo or ZaloPay"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize()
                .offset(y: 24)
        }
        .padding(.bottom, 18)
    }

    /// Hành động chính của kênh PayPal: mở trang PayPal với số tiền đã chọn.
    private var paypalButton: some View {
        Button { NSWorkspace.shared.open(Donation.paypalURL(state.tier.amount)) } label: {
            Label(state.tier.price.map { L("Ủng hộ \($0) qua PayPal", "Donate \($0) with PayPal") } ?? L("Ủng hộ qua PayPal", "Donate with PayPal"),
                  systemImage: "arrow.up.right")
        }
        .buttonStyle(CTAButtonStyle())
    }

    // MARK: Thông tin chuyển khoản tay

    private var details: some View {
        VStack(spacing: 0) {
            row(L("Người nhận", "Recipient"), "\(Donation.recipient) · \(Donation.wallet)")
            Divider().padding(.leading, 12)
            row(L("Số tài khoản", "Account"), Donation.account, copy: true)
            Divider().padding(.leading, 12)
            row(L("Nội dung", "Message"), Donation.note, copy: true)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ title: String, _ value: String, copy: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).textSelection(.enabled).lineLimit(1)
            if copy {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    state.copied = value
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak state] in
                        if state?.copied == value { state?.copied = nil }
                    }
                } label: {
                    Image(systemName: state.copied == value ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(L("Sao chép", "Copy"))
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    // MARK: Cách ủng hộ khác

    private var alternatives: some View {
        VStack(spacing: 10) {
            Text(L("Không tiện ủng hộ? Gắn sao cho OverSub trên GitHub hoặc giới thiệu cho bạn bè cũng là ủng hộ rồi.",
                   "Can't donate? Starring OverSub on GitHub or telling a friend helps just as much."))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { NSWorkspace.shared.open(Donation.repo) } label: {
                    Label(L("Gắn sao trên GitHub", "Star on GitHub"), systemImage: "star")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Donation.repo.absoluteString, forType: .string)
                    state.copied = "link"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak state] in
                        if state?.copied == "link" { state?.copied = nil }
                    }
                } label: {
                    Label(state.copied == "link" ? L("Đã sao chép", "Copied") : L("Sao chép đường dẫn", "Copy link"),
                          systemImage: state.copied == "link" ? "checkmark" : "link")
                }
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
        }
    }
}
