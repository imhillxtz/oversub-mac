import AppKit
import SwiftUI

/// Một mảng tô của dịch màn hình: bản dịch của một cụm chữ và vị trí, màu của cụm đó.
struct ScreenPiece: Identifiable, Equatable {
    var id: Int
    var vi: String
    var fit: TextFit
    var stem: Double = 0   // độ dày nét chữ gốc (điểm), để chọn độ đậm giống chữ game
    var size: CGFloat = 0  // cỡ chữ gốc ước từ bề ngang dòng chữ
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var pieces: [ScreenPiece] = []   // dịch màn hình: mỗi cụm chữ một mảng thay chữ
    /// Dịch màn hình: ảnh vùng đã xoá chữ gốc (dựng lại nền game), cắt theo từng mảng để chữ dịch nằm trên nền thật.
    @Published var screenBackground: NSImage?
    @Published var vi = ""
    @Published var original: String?
    @Published var fit: TextFit?
    @Published var visible = false
}

/// Khoảng chừa trên và dưới vùng quét để bản dịch dài hơn chữ gốc vẫn không bị cắt.
private let overlayPad: CGFloat = 150

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var settings: AppSettings
    /// Dịch màn hình: luôn đè đúng chỗ chữ gốc, nền khớp màu game, cỡ chữ theo chữ gốc, không theo kiểu phụ đề lời thoại.
    var screenTranslation = false

    private struct Layout {
        var plate: CGRect       // nền phủ chữ gốc, toạ độ trong cửa sổ (đã cộng phần chừa phía trên)
        var text: CGRect        // khung chữ dịch
        var alignment: TextAlignment
        var lineSpacing: CGFloat
    }

    var body: some View {
        let style = screenTranslation ? .matchOriginal : settings.style
        let matching = style == .matchOriginal
        let fit = (settings.overlayFit || screenTranslation) ? model.fit : nil
        let fg = (matching ? model.fit?.text : nil) ?? style.foreground
        // Nền khớp màu gốc phải đặc hẳn, nếu không chữ gốc còn lộ mờ phía dưới.
        let bg: Color = (matching ? model.fit?.background : nil) ?? style.background
        // Khớp phụ đề gốc: cỡ chữ lấy theo chiều cao dòng gốc; không thì dùng cỡ cố định.
        // Một thanh cỡ chữ duy nhất (phần trăm): khớp game thì nhân với chiều cao dòng gốc, không thì nhân với cỡ chuẩn 28.
        let scale = screenTranslation ? 1 : settings.overlayFontScale / 100
        let size: CGFloat = fit.map { min(120, max(10, ($0.fontSize ?? $0.lineHeight * 0.85) * scale)) } ?? CGFloat(28 * scale)
        let glass = style == .glass

        GeometryReader { geo in
            if screenTranslation {
                // Dịch màn hình: mỗi cụm chữ được thay ngay trên nền game đã dựng lại (mép làm mềm), chữ dịch cùng màu và độ đậm
                // với chữ gốc, nằm gọn trong khung. Không dựng được nền thì tô màu nền lấy quanh cụm chữ.
                let layouts = screenLayouts(model.pieces)
                let regionH = geo.size.height - overlayPad * 2
                ZStack(alignment: .topLeading) {
                    if let bg = model.screenBackground {
                        Image(nsImage: bg).resizable().interpolation(.high)
                            .frame(width: geo.size.width, height: regionH)
                            .mask(alignment: .topLeading) {
                                ZStack(alignment: .topLeading) {
                                    ForEach(model.pieces) { p in
                                        if let l = layouts[p.id] {
                                            RoundedRectangle(cornerRadius: 4)
                                                .frame(width: l.plate.width, height: l.plate.height)
                                                .offset(x: l.plate.minX, y: l.plate.minY - overlayPad)
                                        }
                                    }
                                }
                                .frame(width: geo.size.width, height: regionH, alignment: .topLeading)
                                .blur(radius: 1.5)   // mép mềm, không lộ khung chữ nhật
                            }
                            .offset(y: overlayPad)
                    } else {
                        ForEach(model.pieces) { p in
                            if let l = layouts[p.id] {
                                RoundedRectangle(cornerRadius: 3).fill(p.fit.background ?? style.background)
                                    .frame(width: l.plate.width, height: l.plate.height)
                                    .offset(x: l.plate.minX, y: l.plate.minY)
                            }
                        }
                    }
                    ForEach(model.pieces) { p in
                        if let l = layouts[p.id] {
                            // Khung chữ rộng hơn rồi nén ngang về đúng bề ngang chỗ chữ (neo theo căn lề).
                            let w = l.text.width / l.squeeze
                            let x = l.alignment == .leading ? l.text.minX : l.alignment == .trailing ? l.text.maxX - w : l.text.midX - w / 2
                            let anchor: UnitPoint = l.alignment == .leading ? .leading : l.alignment == .trailing ? .trailing : .center
                            Text(p.vi)
                                .font(.system(size: l.size, weight: ScreenText.weight(stem: p.stem, size: l.size).font))
                                .multilineTextAlignment(l.alignment)
                                .minimumScaleFactor(0.6)   // phòng hờ đo lệch vài điểm: co thêm chứ không tràn
                                .foregroundStyle(p.fit.text ?? style.foreground)
                                .frame(width: w, height: l.text.height, alignment: l.frame)
                                .scaleEffect(x: l.squeeze, y: 1, anchor: anchor)
                                .frame(width: w, height: l.text.height)
                                .clipped()
                                .offset(x: x, y: l.text.minY)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .animation(.easeOut(duration: 0.15), value: model.pieces)
            } else if let fit {
                let l = layout(fit, size: size, window: geo.size)
                ZStack(alignment: .topLeading) {
                    plate(bg: bg, glass: glass, radius: 6)
                        .frame(width: l.plate.width, height: l.plate.height)
                        .offset(x: l.plate.minX, y: l.plate.minY)
                    VStack(alignment: stackAlignment(l.alignment), spacing: 4) {
                        if let original = model.original {
                            Text(original).font(.system(size: size * 0.8)).opacity(0.8)
                        }
                        Text(model.vi)
                            .font(.system(size: size, weight: .semibold))
                            .lineSpacing(l.lineSpacing)
                            .contentTransition(.opacity)   // đổi câu thì chữ chuyển mờ, không nhảy cụt
                    }
                    .multilineTextAlignment(l.alignment)
                    .foregroundStyle(fg)
                    .frame(width: l.text.width, alignment: frameAlignment(l.alignment))
                    .offset(x: l.text.minX, y: l.text.minY)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .animation(.easeOut(duration: 0.18), value: fit)
            } else {
                let label = VStack(spacing: 6) {
                    if let original = model.original {
                        Text(original).font(.system(size: size * 0.8)).opacity(0.8)
                    }
                    Text(model.vi).font(.system(size: size, weight: .semibold)).contentTransition(.opacity)
                }
                .foregroundStyle(fg)
                .multilineTextAlignment(.center)
                .shadow(color: style == .transparent ? .black : .clear, radius: 3)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                label
                    .background { plate(bg: bg, glass: glass, radius: 12) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .animation(.smooth(duration: 0.25), value: model.vi)
        .opacity(model.visible ? 1 : 0)
        // Dịch màn hình: không co lại (mảng thay chữ phải nằm đúng chỗ) và tắt thật nhanh để không đọng bản dịch cũ.
        .scaleEffect(model.visible || screenTranslation ? 1 : 0.97)
        .animation(.easeOut(duration: screenTranslation ? 0.08 : (model.visible ? 0.2 : 0.1)), value: model.visible)   // hiện mềm, tắt nhanh   // hiện ra và tắt đi mềm
    }

    /// Nền phụ đề: màu đặc (khớp game hoặc kiểu đã chọn), hoặc kính mờ Liquid Glass.
    @ViewBuilder
    private func plate(bg: Color, glass: Bool, radius: CGFloat) -> some View {
        if glass {
            Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            RoundedRectangle(cornerRadius: radius).fill(bg)
        }
    }

    private func stackAlignment(_ a: TextAlignment) -> HorizontalAlignment {
        switch a { case .leading: return .leading; case .trailing: return .trailing; default: return .center }
    }

    private func frameAlignment(_ a: TextAlignment) -> Alignment {
        switch a { case .leading: return .topLeading; case .trailing: return .topTrailing; default: return .top }
    }

    /// `squeeze`: nén ngang chữ dịch (0,88 đến 1) khi câu dịch dài hơn chữ gốc, để giữ cỡ chữ bằng chữ gốc thay vì thu nhỏ.
    typealias ScreenLayout = (plate: CGRect, text: CGRect, size: CGFloat, alignment: TextAlignment, frame: Alignment, squeeze: CGFloat)

    /// Bố cục mọi mảng tô của một vùng. Các mục một dòng cùng cột (thẳng lề trái hoặc thẳng tâm, như các mục menu xếp dọc)
    /// và cỡ chữ gốc gần nhau dùng chung cỡ chữ nhỏ nhất của nhóm, để menu dịch ra đều nhau như menu gốc. Tiêu đề lệch cột
    /// thì giữ cỡ riêng.
    private func screenLayouts(_ pieces: [ScreenPiece]) -> [Int: ScreenLayout] {
        // Vision đo chiều cao dòng dao động nhiều (cùng cỡ chữ mà lệch tới 30%), nên lấy trung vị của cả cột làm cỡ gốc.
        func est(_ p: ScreenPiece) -> CGFloat { p.size > 0 ? p.size : p.fit.lineHeight * 0.82 }
        // Cùng nhóm: cỡ chữ gốc ước được gần nhau (chênh dưới 15%) và cùng cột (thẳng lề trái hoặc tâm) hoặc cùng hàng.
        func mates(of p: ScreenPiece) -> [ScreenPiece] {
            guard p.fit.linePitch == nil else { return [p] }
            return pieces.filter { q in
                guard q.fit.linePitch == nil else { return false }
                let hi = max(est(q), est(p)), lo = max(1, min(est(q), est(p)))
                let column = abs(q.fit.box.minX - p.fit.box.minX) <= hi * 0.6 || abs(q.fit.box.midX - p.fit.box.midX) <= hi * 0.6
                let row = abs(q.fit.box.midY - p.fit.box.midY) <= hi * 0.5
                return hi / lo <= 1.15 && (column || row)
            }
        }
        var out: [Int: ScreenLayout] = [:]
        for p in pieces {
            let group = mates(of: p)
            // Cỡ chữ gốc của nhóm: trung vị cỡ ước từ bề ngang (không có thì từ bề cao dòng).
            let ss = group.map(est).sorted()
            let start = min(72, max(9, ss[ss.count / 2]))
            let size = group.map { screenLayout($0.fit, text: $0.vi, stem: $0.stem, origin: start, start: start).size }.min() ?? start
            out[p.id] = screenLayout(p.fit, text: p.vi, stem: p.stem, origin: start, size: size)
        }
        return out
    }

    /// Dịch màn hình: nền phủ sát chữ (chữ gốc và chữ dịch, chừa một chút cho khỏi lộ nét), chữ dịch chỉ nằm trong nền đó.
    /// Chữ dịch được rộng hơn chữ gốc một chút nếu nền quanh chữ (nút, hộp) còn chỗ; cỡ chữ bắt đầu từ cỡ chữ gốc và nhỏ
    /// dần tới khi vừa. `size`: ép cỡ chữ (để các mục cùng nhóm đều nhau).
    private func screenLayout(_ fit: TextFit, text: String, stem: Double = 0, origin: CGFloat? = nil,
                              size forced: CGFloat? = nil, start: CGFloat? = nil) -> ScreenLayout {
        let b = fit.box
        let (padX, padY) = ScreenText.pads(fit)
        let align = fit.alignment
        let originSize = origin ?? fit.lineHeight * 0.82
        let area = ScreenText.area(fit, size: originSize)
        // Câu dịch dài hơn: nén ngang nhẹ trước (khó nhận ra), không vừa nữa mới giảm cỡ chữ.
        let squeezes: [CGFloat] = [1, 0.94, 0.88]
        func fits(_ size: CGFloat, _ sq: CGFloat) -> Bool {
            Self.measure(text, size: size, weight: ScreenText.weight(stem: stem, size: size).ns, width: area.width / sq, lineSpacing: 0).height <= area.height
        }
        var size = forced ?? start ?? min(72, max(9, fit.lineHeight * 0.82))
        var squeeze: CGFloat = squeezes.last!
        if forced == nil {
            while size > 9, !squeezes.contains(where: { fits(size, $0) }) { size -= 0.5 }
        }
        squeeze = squeezes.first { fits(size, $0) } ?? squeezes.last!
        // Phần chữ dịch thực sự chiếm, đặt theo căn lề; nền ôm chữ gốc và chữ dịch.
        let m = Self.measure(text, size: size, weight: ScreenText.weight(stem: stem, size: size).ns, width: area.width / squeeze, lineSpacing: 0)
        let used = min(area.width, (m.width + 4) * squeeze)
        let usedX: CGFloat
        switch align {
        case .leading: usedX = area.minX
        case .trailing: usedX = area.maxX - used
        default: usedX = area.midX - used / 2
        }
        let usedH = fit.linePitch == nil ? min(area.height, m.height) : b.height
        let textBand = CGRect(x: usedX, y: fit.linePitch == nil ? area.midY - usedH / 2 : b.minY, width: used, height: usedH)
        let plate = b.insetBy(dx: -padX, dy: -padY).union(textBand.insetBy(dx: -padX * 0.7, dy: -padY))
        // Một dòng gốc (nút, tên mục): canh giữa theo chiều dọc; nhiều dòng (đoạn mô tả): bắt đầu từ dòng đầu như chữ gốc.
        let vertical: VerticalAlignment = fit.linePitch == nil ? .center : .top
        let frame: Alignment
        switch (align, vertical) {
        case (.leading, .center): frame = .leading
        case (.trailing, .center): frame = .trailing
        case (_, .center): frame = .center
        case (.leading, _): frame = .topLeading
        case (.trailing, _): frame = .topTrailing
        default: frame = .top
        }
        let shift = overlayPad   // cửa sổ chừa thêm phía trên vùng quét
        return (plate.offsetBy(dx: 0, dy: shift), area.offsetBy(dx: 0, dy: shift), size, align, frame, squeeze)
    }

    /// Đặt khung chữ dịch theo căn lề của chữ gốc, dòng đầu cùng độ cao với dòng đầu gốc. Nền chỉ dày vừa đủ che chữ gốc
    /// và ôm sát chữ dịch, không phủ cả hộp thoại.
    private func layout(_ fit: TextFit, size: CGFloat, window: CGSize) -> Layout {
        let b = fit.box
        let c = fit.cover.union(b)   // chỉ dùng để biết chữ được phép rộng tới đâu
        let align = (screenTranslation ? nil : settings.overlayAlign.textAlignment) ?? fit.alignment
        let padX = max(5, fit.lineHeight * 0.45), padY = max(3, fit.lineHeight * 0.28)

        // Bề ngang cho phép của chữ, và mép trái của khung chữ.
        var width: CGFloat, left: CGFloat
        switch align {
        case .leading:
            width = max(b.width, c.maxX - b.minX) - padX
            left = b.minX
        case .trailing:
            width = max(b.width, b.maxX - c.minX) - padX
            left = b.maxX - width
        default:
            let half = max(b.width / 2, min(b.midX - c.minX, c.maxX - b.midX))
            width = 2 * half - padX
            left = b.midX - width / 2
        }
        width = max(60, min(width, window.width - 8))
        left = min(max(0, left), max(0, window.width - width))

        // Giữ nhịp dòng của game: khoảng cách dòng gốc trừ chiều cao dòng của chữ dịch.
        let spacing = fit.linePitch.map { max(0, $0 - size * 1.22) } ?? 0
        let vi = Self.measure(model.vi, size: size, weight: .semibold, width: width, lineSpacing: spacing)
        let orig = model.original.map { Self.measure($0, size: size * 0.8, weight: .regular, width: width, lineSpacing: 0) }
        let used = max(vi.width, orig?.width ?? 0) + 6   // dư vài điểm vì SwiftUI xuống dòng hơi khác NSAttributedString
        let height = vi.height + (orig.map { $0.height + 4 } ?? 0)
        let textRect = CGRect(x: left, y: b.minY, width: width, height: height)

        // Phần chữ dịch thực sự chiếm, theo căn lề.
        let usedX: CGFloat
        switch align {
        case .leading: usedX = left
        case .trailing: usedX = left + width - used
        default: usedX = left + (width - used) / 2
        }
        let translated = CGRect(x: usedX, y: b.minY, width: min(used, width), height: height).insetBy(dx: -padX, dy: -padY)
        let plate = b.insetBy(dx: -padX, dy: -padY).union(translated)

        let shift = overlayPad   // cửa sổ chừa thêm phía trên vùng quét
        return Layout(plate: plate.offsetBy(dx: 0, dy: shift), text: textRect.offsetBy(dx: 0, dy: shift),
                      alignment: align, lineSpacing: spacing)
    }

    /// Kích thước chữ sau khi xuống dòng trong bề ngang cho trước; SwiftUI không đo hộ được để dựng nền ôm vừa chữ.
    private static func measure(_ s: String, size: CGFloat, weight: NSFont.Weight, width: CGFloat, lineSpacing: CGFloat) -> CGSize {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = lineSpacing
        let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .paragraphStyle: para])
        let r = attr.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(r.width), height: ceil(r.height) + 2)
    }
}

/// Cửa sổ trong suốt phủ lên vùng phụ đề gốc, bấm xuyên qua được và nổi trên cả game toàn màn hình.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    /// Vùng phụ đề trên màn hình hiện tại. Engine cập nhật mỗi lần quét, vì ở chế độ cửa sổ game nó đổi khi cửa sổ di chuyển.
    var region: CaptureRegion?
    private var panel: NSPanel?
    private var hideToken = 0
    private let settings: AppSettings
    /// Vùng dịch màn hình không dùng độ lệch vị trí người dùng chỉnh cho phụ đề chính.
    private let applyOffsets: Bool
    private let screenTranslation: Bool

    init(settings: AppSettings, applyOffsets: Bool = true, screenTranslation: Bool = false) {
        self.settings = settings
        self.applyOffsets = applyOffsets
        self.screenTranslation = screenTranslation
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: OverlayView(model: model, settings: settings, screenTranslation: screenTranslation))
        panel = p
        return p
    }

    func place(on region: CaptureRegion) {
        guard let screen = resolveScreen(for: region) else { return }
        let f = screen.frame
        let r = region.rect
        let p = ensurePanel()
        let dx = applyOffsets ? settings.overlayDX : 0, dy = applyOffsets ? settings.overlayDY : 0
        if settings.overlayFit || !applyOffsets {
            // Cửa sổ trùng bề ngang vùng quét và chừa thêm trên dưới; vị trí chữ bên trong tính theo toạ độ vùng quét.
            // Không cắt theo mép màn hình, vì cắt sẽ làm lệch toạ độ bên trong.
            let box = NSRect(x: f.minX + r.minX + dx,
                             y: f.maxY - r.maxY - overlayPad - dy,
                             width: r.width, height: r.height + overlayPad * 2)
            p.setFrame(box, display: true)
        } else {
            // Tâm vùng quét (toạ độ Cocoa, gốc ở góc dưới trái) cộng độ lệch người dùng chỉnh; dương = sang phải, xuống dưới.
            let cx = f.minX + r.midX + dx
            let cy = f.maxY - r.midY - dy
            let width = max(200, r.width * settings.overlayWidthPct / 100)
            let height = max(r.height, 120) + overlayPad * 2
            let box = NSRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height).intersection(f)
            if !box.isEmpty { p.setFrame(box, display: true) }
        }
    }

    /// Đặt lại vị trí khi người dùng kéo thanh chỉnh trong Cài đặt.
    func reposition() {
        guard let region, panel?.isVisible == true else { return }
        place(on: region)
    }

    /// Dịch màn hình: hiện các mảng tô của một vùng.
    func show(pieces: [ScreenPiece], background: NSImage?) {
        guard let region else { return }
        let p = ensurePanel()
        hideToken += 1
        model.screenBackground = background
        model.pieces = pieces
        place(on: region)
        if !p.isVisible { p.orderFrontRegardless() }
        model.visible = true
    }

    func show(vi: String, original: String?, fit: TextFit?) {
        guard let region else { return }
        let p = ensurePanel()
        hideToken += 1   // huỷ lệnh ẩn đang chờ
        model.vi = vi
        model.original = original
        model.fit = fit
        place(on: region)
        if !p.isVisible { p.orderFrontRegardless() }
        model.visible = true
    }

    /// Chế độ bám theo: cập nhật vị trí khi chữ gốc nhích đi, bỏ qua dao động nhỏ để khỏi giật.
    func updateFit(_ fit: TextFit?) {
        guard model.visible, let fit else { return }
        if let old = model.fit,
           abs(old.box.midX - fit.box.midX) < 1.5, abs(old.box.midY - fit.box.midY) < 1.5, abs(old.box.width - fit.box.width) < 3 { return }
        model.fit = fit
    }

    /// Ẩn mờ dần rồi mới gỡ cửa sổ, để không tắt cụt.
    func hide() {
        guard model.visible || panel?.isVisible == true else { return }
        model.visible = false
        hideToken += 1
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + (screenTranslation ? 0.1 : 0.12)) { [weak self] in
            guard let self, self.hideToken == token, !self.model.visible else { return }
            self.panel?.orderOut(nil)
        }
    }
}
