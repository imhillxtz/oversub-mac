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

    /// Nội dung chuyển khoản: "OverSub", thêm tên / nickname người ủng hộ nếu có. Nhiều app ngân hàng khoá ô nội dung khi quét
    /// mã có sẵn số tiền, nên tên phải nằm sẵn trong mã. Bỏ dấu, chỉ giữ chữ, số, khoảng trắng và gọn trong 25 ký tự: tài liệu
    /// VietQR cho tối đa 50 ký tự không ký tự đặc biệt, chuẩn EMV gốc chặt hơn, giữ 25 cho mọi ngân hàng đều nhận.
    static func message(nick: String) -> String {
        var s = nick.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
        s = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        let kept = String(s.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == " ") }.map(Character.init))
        let name = kept.split(separator: " ").joined(separator: " ")
        guard !name.isEmpty else { return note }
        return String((note + " " + name).prefix(25)).trimmingCharacters(in: .whitespaces)
    }

    static func payload(amount: Int?, message: String = note) -> String {
        func tlv(_ id: String, _ value: String) -> String { id + String(format: "%02d", value.utf8.count) + value }
        var s = tlv("00", "01") + tlv("01", amount == nil ? "11" : "12") + tlv("38", merchant) + tlv("53", "704")
        if let amount { s += tlv("54", String(amount)) }
        s += tlv("58", "VN") + tlv("62", tlv("05", reference) + tlv("08", message)) + "6304"
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

    /// Số đếm theo ngôn ngữ giao diện (1.000 hay 1,000), không theo vùng của máy.
    static func count(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: Lang.isEnglish ? "en_US" : "vi_VN")))
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
    @MainActor static func countLine() {
        let n = linesTranslated + 1
        UserDefaults.standard.set(n, forKey: linesKey)
        SupportPrompt.shared.check(n)
    }
}

// MARK: Lời cảm ơn theo mốc

/// Khi số câu đã dịch vượt một mốc (300, 1.000, 3.000, 10.000), màn hình chính hiện một thẻ cảm ơn nhỏ kèm nút Ủng hộ. Mỗi
/// mốc một lần; nhảy qua nhiều mốc thì chỉ nhắc mốc cao nhất. Không hiện lúc phiên đang chạy (đang chơi) hay lúc đang có lỗi
/// cần xử lý. Bấm "Mình đã ủng hộ rồi" trong cửa sổ Ủng hộ thì thôi hẳn.
@MainActor
final class SupportPrompt: ObservableObject {
    static let shared = SupportPrompt()
    static let milestones = [300, 1_000, 3_000, 10_000]
    private let d = UserDefaults.standard
    @Published private(set) var pending: Int?
    @Published var donated: Bool {
        didSet {
            d.set(donated, forKey: "supportDonated")
            if donated { pending = nil } else { check(Donation.linesTranslated) }   // hoàn tác thì nhắc lại như cũ
        }
    }

    private init() {
        donated = d.bool(forKey: "supportDonated")
        check(Donation.linesTranslated)
    }

    func check(_ lines: Int) {
        guard !donated, let m = Self.milestones.last(where: { $0 <= lines }), m > d.integer(forKey: "supportMilestoneShown") else { return }
        if pending != m { pending = m }
    }

    /// Đã xem thẻ (bấm Ủng hộ hay Để sau): không nhắc lại mốc này.
    func dismiss() {
        if let m = pending { d.set(m, forKey: "supportMilestoneShown") }
        pending = nil
    }

    #if DEVTOOLS
    /// Chỉ để chụp giao diện: hiện thẻ mà không ghi gì vào cài đặt.
    func debugShow(_ m: Int) { pending = m }
    #endif
}

// MARK: Bảng cảm ơn

/// Tên người ủng hộ (họ tự ghi thêm vào nội dung chuyển khoản hay lời nhắn PayPal), lưu ở `Docs/supporters.json` trên GitHub
/// để thêm tên không cần ra bản app mới. Tải khi mở cửa sổ Ủng hộ (chỉ tải về, không gửi gì đi), nhớ bản gần nhất để xem khi
/// không có mạng.
@MainActor
final class Supporters: ObservableObject {
    static let shared = Supporters()
    private static let url = URL(string: "https://raw.githubusercontent.com/imhillxtz/oversub-mac/main/Docs/supporters.json")!
    private static let cacheKey = "supporterNames"
    @Published private(set) var names: [String] = UserDefaults.standard.stringArray(forKey: Supporters.cacheKey) ?? []
    private var loaded = false

    func refresh() async {
        guard !loaded else { return }
        loaded = true
        struct File: Decodable {
            struct Entry: Decodable { let name: String }
            let supporters: [Entry]
        }
        let req = URLRequest(url: Self.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let file = try? JSONDecoder().decode(File.self, from: data) else { loaded = false; return }
        let list = file.supporters.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if list != names { names = list }
        UserDefaults.standard.set(list, forKey: Self.cacheKey)
    }
}

// MARK: Cửa sổ Ủng hộ

@MainActor
final class DonateState: ObservableObject {
    /// Giao diện tiếng Anh thì mặc định PayPal (người ở nước ngoài), tiếng Việt thì VietQR.
    @Published var channel: Donation.Channel = Lang.isEnglish ? .paypal : .vietQR {
        didSet { if channel != oldValue { tier = Donation.tiers(channel)[1] } }
    }
    @Published var tier = Donation.tiers(Lang.isEnglish ? .paypal : .vietQR)[1]
    @Published var copied: String?
    /// Tên hoặc nickname người ủng hộ muốn ghi vào nội dung chuyển khoản (để có tên trong bảng cảm ơn); không bắt buộc.
    @Published var nick = "" { didSet { if nick.count > 30 { nick = String(nick.prefix(30)) } } }
    var message: String { Donation.message(nick: nick) }
    /// Chiều cao nội dung và chiều cao màn hình dùng được: cửa sổ cao vừa nội dung, màn hình thấp hơn thì cuộn.
    @Published var contentHeight: CGFloat = 640
    @Published var screenHeight: CGFloat = 900

    init() {
        measureScreen()
        #if DEVTOOLS
        if let n = ProcessInfo.processInfo.environment["OVERSUB_DONATE_NICK"] { nick = n }   // chụp thử ô nhập tên
        #endif
    }

    func measureScreen() {
        var h = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        #if DEVTOOLS
        // Thử màn hình thấp mà không cần đổi độ phân giải thật: OVERSUB_SCREEN_HEIGHT=560.
        if let v = ProcessInfo.processInfo.environment["OVERSUB_SCREEN_HEIGHT"], let n = Double(v) { h = n }
        #endif
        if h != screenHeight { screenHeight = h }
    }
}

/// Cửa sổ "Ủng hộ OverSub": linh vật và lời nhờ ngắn, số câu app đã dịch cho bạn; bên trái chọn kênh (VietQR / PayPal) và mức,
/// bên phải mã QR; dưới cùng là bảng cảm ơn và cách ủng hộ không tốn tiền (gắn sao GitHub, giới thiệu bạn bè).
struct DonateView: View {
    @StateObject private var state = DonateState()
    @ObservedObject private var prompt = SupportPrompt.shared
    @ObservedObject private var supporters = Supporters.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if abs(h - state.contentHeight) > 0.5 { state.contentHeight = h }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Cao vừa nội dung nhưng không quá màn hình (màn hình nhỏ, hay vừa đổi độ phân giải thì cuộn).
        .frame(width: 660, height: min(state.contentHeight, max(320, state.screenHeight - 40)))
        .background { HomeBackdrop(vivid: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            state.measureScreen()
        }
        .onAppear { state.measureScreen() }
        .task { await supporters.refresh() }
        .animation(.smooth(duration: 0.25), value: state.tier)
        .animation(.smooth(duration: 0.25), value: state.channel)
    }

    private var content: some View {
        VStack(spacing: 18) {
            header
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 14) {
                    channelPicker
                    tierGrid
                    if state.channel == .vietQR { details } else { paypalButton }
                    Text(state.channel == .vietQR
                         ? L("Tên của bạn được ghi sẵn vào nội dung chuyển khoản trong mã QR để mình đưa vào bảng cảm ơn. Muốn ẩn danh thì bạn cứ để trống.", "Your name goes into the transfer message in the QR code so I can add you to the thank-you list. If you'd rather stay anonymous, leave it empty.")
                         : L("Để có tên trong bảng cảm ơn, ghi tên của bạn vào lời nhắn PayPal nhé.", "To be on the thank-you list, just add your name to the PayPal note."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 340)
                qrColumn
            }
            thanks
            Divider()
            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)   // thanh tiêu đề ẩn, chừa chỗ cho ba nút cửa sổ
        .padding(.bottom, 22)
    }

    private var header: some View {
        let lines = Donation.linesTranslated
        return HStack(spacing: 16) {
            Mascot(mood: .idle, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Ủng hộ OverSub", "Support OverSub")).font(.title2.weight(.bold))
                Text(L("OverSub miễn phí cho mọi người. Nếu app giúp bạn chơi game vui hơn, mong bạn mời mình một ly cà phê. Mỗi lượt ủng hộ đều giúp mình có thêm thời gian sửa lỗi và làm tính năng mới.",
                       "OverSub is free for everyone. If it makes your games more fun, I'd be grateful for a coffee. Every donation gives me more time to fix bugs and build new features."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if lines >= 10 {
                    Label(L("OverSub đã dịch \(Donation.count(lines)) câu thoại cho bạn", "OverSub has translated \(Donation.count(lines)) lines for you"),
                          systemImage: "text.bubble.fill")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .glassEffect(.regular, in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Chọn kênh, chọn mức

    /// Hai kênh ngang hàng: viên trắng trên nền kính như ô chọn mức (không dùng màu nhấn xanh của hệ thống).
    private var channelPicker: some View {
        HStack(spacing: 2) {
            ForEach(Donation.Channel.allCases) { c in
                let on = c == state.channel
                Button { state.channel = c } label: {
                    Text(c.title)
                        .font(.callout.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
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

    private var tierGrid: some View {
        let tiers = Donation.tiers(state.channel)
        return Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow { tierCell(tiers[0]); tierCell(tiers[1]) }
            GridRow { tierCell(tiers[2]); tierCell(tiers[3]) }
        }
        .padding(4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func tierCell(_ t: Donation.Tier) -> some View {
        let on = t == state.tier
        return Button { state.tier = t } label: {
            HStack(spacing: 10) {
                Image(systemName: t.icon).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.price ?? L("Tuỳ bạn", "Any")).font(.callout.weight(.semibold)).monospacedDigit()
                    Text(t.label).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
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

    // MARK: Mã QR

    private var qrColumn: some View {
        let paypal = state.channel == .paypal
        let payload = paypal ? Donation.paypalURL(state.tier.amount).absoluteString : Donation.payload(amount: state.tier.amount, message: state.message)
        return VStack(spacing: 10) {
            VStack(spacing: 8) {
                ZStack {
                    if let img = Donation.qrImage(payload) {
                        Image(decorative: img, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 196, height: 196)
                    }
                    // Icon ở giữa mã, như các ví hay đặt ảnh đại diện; mức sửa lỗi H chịu được phần bị che.
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 42, height: 42)
                        .padding(3)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .id(payload)
                .transition(.opacity)
                Text(paypal ? "paypal.me/ngochieuit" + (state.tier.price.map { " · \($0)" } ?? "")
                     : state.tier.price.map { L("\($0) · nội dung \"\(state.message)\"", "\($0) · message \"\(state.message)\"") }
                        ?? L("Tự nhập số tiền khi quét", "Enter any amount after scanning"))
                    .font(.caption.weight(.medium)).foregroundStyle(Color.black.opacity(0.6))
                    .monospacedDigit()
            }
            .padding(14)
            // Nền thẻ luôn trắng để mọi app ngân hàng quét dễ, kể cả ở chế độ tối.
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            Text(paypal ? L("Quét bằng camera điện thoại, hoặc bấm nút bên trái", "Scan with your phone camera, or use the button on the left")
                 : L("Quét bằng app ngân hàng, MoMo hoặc ZaloPay trên điện thoại", "Scan with a Vietnamese banking app, MoMo or ZaloPay"))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 224)
    }

    /// Hành động chính của kênh PayPal: mở trang PayPal với số tiền đã chọn.
    private var paypalButton: some View {
        Button { NSWorkspace.shared.open(Donation.paypalURL(state.tier.amount)) } label: {
            Label(state.tier.price.map { L("Ủng hộ \($0) qua PayPal", "Donate \($0) with PayPal") } ?? L("Ủng hộ qua PayPal", "Donate with PayPal"),
                  systemImage: "arrow.up.right")
        }
        .buttonStyle(CTAButtonStyle())
        .padding(.top, 4)
    }

    // MARK: Thông tin chuyển khoản tay

    /// Khung kính như ô chọn mức: vật liệu mờ mặc định phủ lên nền đào ở chế độ sáng thành màu be xám đục.
    private var details: some View {
        VStack(spacing: 0) {
            row(L("Người nhận", "Recipient"), "\(Donation.recipient) · \(Donation.wallet)")
            Divider().padding(.leading, 12)
            row(L("Số tài khoản", "Account"), Donation.account, copy: true)
            Divider().padding(.leading, 12)
            nickRow
            Divider().padding(.leading, 12)
            row(L("Nội dung", "Message"), state.message, copy: true)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Ô nhập tên / nickname: gõ tới đâu mã QR và dòng Nội dung đổi tới đó.
    private var nickRow: some View {
        HStack(spacing: 8) {
            Text(L("Tên của bạn", "Your name")).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            TextField("", text: $state.nick, prompt: Text(L("Tên hoặc nickname", "Name or nickname")))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .fontWeight(.medium)
                .frame(maxWidth: 210)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private func row(_ title: String, _ value: String, copy: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).textSelection(.enabled).lineLimit(1)
            if copy {
                Button { copyText(value, tag: value) } label: {
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
        .frame(height: 32)
    }

    private func copyText(_ text: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak state] in
            if state?.copied == tag { state?.copied = nil }
        }
    }

    // MARK: Bảng cảm ơn, cách ủng hộ khác

    private var thanks: some View {
        let names = supporters.names
        let limit = 40
        return VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(L("Cảm ơn mọi người đã ủng hộ OverSub", "Thank you to everyone who has supported OverSub"))
            } icon: {
                Image(systemName: "heart.fill").foregroundStyle(.pink)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            if names.isEmpty {
                Text(L("Chưa có tên nào. Mong bạn sẽ là người đầu tiên.", "No names yet. Maybe yours will be the first."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(names.prefix(limit).joined(separator: " · ")
                     + (names.count > limit ? L(" và \(names.count - limit) người khác", " and \(names.count - limit) more") : ""))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Nếu chưa tiện ủng hộ, bạn gắn sao cho OverSub trên GitHub hoặc giới thiệu app cho bạn bè cũng là giúp mình rất nhiều.",
                       "If donating isn't an option right now, starring OverSub on GitHub or telling a friend helps a lot too."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Đã ủng hộ thì thôi nhắc ở màn hình chính.
                if prompt.donated {
                    HStack(spacing: 8) {
                        Text(L("Cảm ơn bạn rất nhiều. OverSub sẽ không nhắc chuyện ủng hộ nữa.", "Thank you so much. OverSub won't ask again."))
                            .font(.caption.weight(.medium))
                        // Lỡ bấm nhầm thì bỏ được ngay, không phải đụng tới cài đặt ẩn.
                        Button(L("Hoàn tác", "Undo")) { prompt.donated = false }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                } else {
                    Button(L("Mình đã ủng hộ rồi", "I've already donated")) { prompt.donated = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Spacer(minLength: 0)
            Button { NSWorkspace.shared.open(Donation.repo) } label: {
                Label(L("Gắn sao", "Star"), systemImage: "star")
            }
            .help(L("Mở kho OverSub trên GitHub để gắn sao", "Open the OverSub repository on GitHub to star it"))
            Button { copyText(Donation.repo.absoluteString, tag: "link") } label: {
                Label(state.copied == "link" ? L("Đã sao chép", "Copied") : L("Sao chép link", "Copy link"),
                      systemImage: state.copied == "link" ? "checkmark" : "link")
            }
        }
        .buttonStyle(.glass)
    }
}
