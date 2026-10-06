import Foundation
import CoreGraphics
import SwiftUI
import AppKit

/// Một cụm chữ trên giao diện game: một mục menu, một nút, một đoạn mô tả. Dịch màn hình tô và dịch riêng từng cụm.
struct ScreenBlock {
    var lines: [OCRLine]
    var text: String
}

enum ScreenText {
    // MARK: Hình học mảng thay chữ (dùng chung cho dựng nền và vẽ chữ)

    /// Lề quanh chữ gốc để xoá sạch nét chữ.
    static func pads(_ fit: TextFit) -> (x: CGFloat, y: CGFloat) {
        // Khung Vision ôm sát chữ; lề ngang vừa đủ xoá nét khử răng cưa, không lấn sang biểu tượng cạnh chữ.
        (max(2, fit.lineHeight * 0.12), max(2, fit.lineHeight * 0.14))
    }

    /// Cỡ chữ gốc ước từ bề ngang các dòng: Vision đo bề ngang dòng chữ chính xác, còn bề cao thì dao động tới 30%.
    static func fontSize(_ lines: [OCRLine], regionWidth: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let est = lines.compactMap { l -> CGFloat? in
            guard l.text.count >= 3 else { return nil }
            let ref = (l.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 100, weight: .medium)]).width
            return ref > 0 ? l.box.width * regionWidth / ref * 100 : nil
        }.sorted()
        guard !est.isEmpty else { return lineHeight * 0.82 }
        // Khung Vision rộng hơn nét chữ thật một chút (khoảng 6%).
        return min(max(est[est.count / 2] * 0.94, lineHeight * 0.6), lineHeight * 1.4)
    }

    /// Chỗ chữ dịch được nằm: khung chữ gốc, rộng thêm nếu nền quanh chữ (nút, hộp) còn chỗ, tối đa thêm 35%.
    /// Khung một dòng thì cao ít nhất bằng một dòng chữ cỡ `size` (khung Vision đo thường thấp hơn dòng chữ thật).
    static func area(_ fit: TextFit, size: CGFloat) -> CGRect {
        let b = fit.box, (padX, padY) = pads(fit)
        let roomL = max(0, b.minX - fit.cover.minX - padX), roomR = max(0, fit.cover.maxX - b.maxX - padX)
        let cap = b.width * 0.35
        var area = b.insetBy(dx: -padX * 0.3, dy: -padY * 0.3)
        switch fit.alignment {
        case .leading: area.size.width += min(roomR, cap)
        case .trailing: area.origin.x -= min(roomL, cap); area.size.width += min(roomL, cap)
        default: area = area.insetBy(dx: -min(roomL, roomR, cap / 2), dy: 0)
        }
        if fit.linePitch == nil {
            let need = size * 1.22 + 2
            if area.height < need { area = area.insetBy(dx: 0, dy: -(need - area.height) / 2) }
        }
        return area
    }

    /// Vùng có thể bị thay (để dựng lại nền trước): chữ gốc và chỗ chữ dịch được nằm, cộng lề.
    static func zone(_ fit: TextFit, size: CGFloat) -> CGRect {
        let (padX, padY) = pads(fit)
        return area(fit, size: size).union(fit.box).insetBy(dx: -padX, dy: -padY)
    }

    /// Đoán độ đậm chữ gốc từ độ dày nét so với cỡ chữ (nét dọc của SF: thường khoảng 0,085 cỡ chữ, đậm khoảng 0,13).
    /// Không đo được thì dùng Medium, gần với chữ giao diện của đa số game.
    static func weight(stem: Double, size: CGFloat) -> (font: Font.Weight, ns: NSFont.Weight) {
        guard stem > 0, size > 0 else { return (.medium, .medium) }
        // Đo ở ảnh Retina có khử răng cưa nên nét đo được dày hơn thật khoảng 40%; ngưỡng đã tính cả phần đó.
        switch stem / Double(size) {
        case ..<0.115: return (.regular, .regular)
        case ..<0.155: return (.medium, .medium)
        case ..<0.19: return (.semibold, .semibold)
        default: return (.bold, .bold)
        }
    }

    /// Chia các dòng OCR thành cụm. Dòng dưới nối vào cụm phía trên khi sát nhau, chồng nhau theo chiều ngang, cùng cỡ chữ,
    /// và trông như dòng bị xuống hàng của cùng một đoạn (dòng trên dài, hoặc dòng dưới bắt đầu bằng chữ thường).
    /// Mục menu, nút thường ngắn và cách nhau xa hơn nên thành cụm riêng.
    static func blocks(_ lines: [OCRLine], size: CGSize) -> [ScreenBlock] {
        typealias Item = (line: OCRLine, rect: CGRect)
        let items: [Item] = lines
            .compactMap(trimJunk)
            .map { l in (l, CGRect(x: l.box.minX * size.width, y: (1 - l.box.maxY) * size.height,
                                   width: l.box.width * size.width, height: l.box.height * size.height)) }
            .sorted { $0.rect.minY < $1.rect.minY }
        var groups: [[Item]] = []
        for it in items {
            let target = groups.lastIndex { g in
                guard let last = g.last?.rect else { return false }
                let h = min(last.height, it.rect.height)
                let gap = it.rect.minY - last.maxY
                let overlap = min(last.maxX, it.rect.maxX) - max(last.minX, it.rect.minX)
                let sameSize = max(last.height, it.rect.height) / max(1, h) < 1.35
                let widest = max(g.map(\.rect.width).max() ?? 0, it.rect.width)
                let wrapped = (last.width >= widest * 0.75 && last.width > h * 12)
                    || (it.line.text.first?.isLowercase ?? false)
                return gap > -h * 0.5 && gap < h * 0.6 && overlap > min(last.width, it.rect.width) * 0.3 && sameSize && wrapped
            }
            if let target { groups[target].append(it) } else { groups.append([it]) }
        }
        return groups.map { g in ScreenBlock(lines: g.map(\.line), text: g.map(\.line.text).joined(separator: " ")) }
    }

    /// Bỏ ký tự rác ở đầu và cuối dòng: Vision hay đọc nhầm biểu tượng (icon amiibo, hình nút bấm) thành vài ký hiệu
    /// như ":Q:" hay "SO;". Khung dòng co lại tương ứng để mảng thay chữ không che mất biểu tượng.
    /// Dòng không còn từ nào có từ hai chữ cái trở lên thì bỏ hẳn.
    /// Một "từ" là rác do đọc nhầm biểu tượng: toàn ký hiệu, hoặc ngắn, lẫn ký hiệu mà gần như không có chữ cái.
    nonisolated static func isJunkToken<S: StringProtocol>(_ t: S) -> Bool {
        let letters = t.filter(\.isLetter).count, digits = t.filter(\.isNumber).count
        let symbols = t.count - letters - digits
        if letters == 0 && digits == 0 { return true }   // toàn ký hiệu
        // Dấu câu cuối từ (Hi, OK. Yes!) không tính là rác; dấu ":" sau một hai chữ cái ("a:") thì là biểu tượng đọc nhầm.
        let trailingPunct = symbols == 1 && (t.last.map { ".,!?…".contains($0) } ?? false)
        return t.count <= 4 && symbols >= 1 && letters <= 2 && digits == 0 && !trailingPunct
    }

    /// Phần chữ thật của một dòng sau khi bỏ "từ" rác ở hai đầu; nil nếu không còn từ nào có từ hai chữ cái.
    /// Dùng lúc OCR để lấy đúng khung của phần chữ này từ Vision (không ước theo bề ngang).
    nonisolated static func cleanRange(_ s: String) -> Range<String.Index>? {
        var words: [Range<String.Index>] = []
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i] == " " { i = s.index(after: i) }
            let start = i
            while i < s.endIndex, s[i] != " " { i = s.index(after: i) }
            if start < i { words.append(start..<i) }
        }
        var lo = 0, hi = words.count - 1
        while lo <= hi, isJunkToken(s[words[lo]]) { lo += 1 }
        while hi >= lo, isJunkToken(s[words[hi]]) { hi -= 1 }
        guard lo <= hi, words[lo...hi].contains(where: { s[$0].filter(\.isLetter).count >= 2 }) else { return nil }
        return words[lo].lowerBound..<words[hi].upperBound
    }

    static func trimJunk(_ line: OCRLine) -> OCRLine? {
        var tokens = line.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        func junk(_ t: String) -> Bool { isJunkToken(t) }
        let font = NSFont.systemFont(ofSize: 20, weight: .medium)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let full = width(line.text)
        var leadCut = "", trailCut = ""
        while let f = tokens.first, junk(f) { leadCut += f + " "; tokens.removeFirst() }
        while let l = tokens.last, junk(l) { trailCut = " " + l + trailCut; tokens.removeLast() }
        guard tokens.contains(where: { $0.filter(\.isLetter).count >= 2 }) else { return nil }
        guard !leadCut.isEmpty || !trailCut.isEmpty, full > 0 else { return line }
        var box = line.box
        // Dự phòng khi OCR chưa cắt được bằng khung của Vision: ước theo bề ngang chữ.
        let l = box.width * width(leadCut) / full, r = box.width * width(trailCut) / full
        box.origin.x += l
        box.size.width = max(box.width * 0.2, box.width - l - r)
        return OCRLine(text: tokens.joined(separator: " "), box: box)
    }

    /// Lời nhắc dịch chữ giao diện game: mỗi cụm một dòng đánh số, trả về đúng số dòng.
    static func systemPrompt(source: String, target: TargetLanguage) -> String {
        let base = basePrompt(source: source, target: target)
        // Thể loại tuỳ chỉnh: cho AI biết bối cảnh game để dịch thuật ngữ giao diện cho khớp.
        let style = CustomStyle.current
        let world = style.world.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UserDefaults.standard.string(forKey: "genre") == GameGenre.custom.rawValue, !world.isEmpty else { return base }
        return base + "\n" + (target.isVietnamese ? "Bối cảnh game: " : "Game and setting: ") + String(world.prefix(CustomStyle.fieldLimit))
    }

    private static func basePrompt(source: String, target: TargetLanguage) -> String {
        if !target.isVietnamese {
            return """
            You translate video game UI text (menus, buttons, item names and descriptions, quest logs) from \(source) into \(target.english).
            - Each input line is numbered. Reply with exactly the same numbers, one translated line per number, in the form "1. ...".
            - Translate like an official game localization: short and natural. Keep proper names, numbers and button symbols (A, B, X, Y, L, R, ZL, ZR, +, -) unchanged.
            - Keep proper names and brand names (like amiibo) unchanged inside the translated line, e.g. "Scan amiibo" → translate "Scan" and keep "amiibo".
            - Reply with just "=" only when the WHOLE line needs no translation: a lone proper name or brand, a word players keep as-is (Menu, OK, HP), a lone button symbol, or garbage from a misread icon.
            - Never merge, split or skip lines. No explanations.
            """
        }
        return """
        Bạn dịch chữ trên giao diện game (menu, nút bấm, tên và mô tả vật phẩm, nhiệm vụ) từ \(source) sang tiếng Việt.
        - Mỗi dòng đầu vào có số thứ tự. Trả về đúng những số đó, mỗi số một dòng bản dịch, dạng "1. ...".
        - Dịch như bản Việt hoá chính thức của game: ngắn gọn, tự nhiên. Giữ nguyên tên riêng, con số và ký hiệu nút (A, B, X, Y, L, R, ZL, ZR, +, -).
        - Tên riêng, nhãn hiệu (như amiibo) giữ nguyên ngay trong câu dịch, vd. "Scan amiibo" → "Quét amiibo".
        - Chỉ trả về đúng dấu "=" khi CẢ dòng không cần dịch: chỉ có một tên riêng hay nhãn hiệu, một từ người chơi Việt vẫn dùng nguyên (Menu, OK, HP), một ký hiệu nút đứng riêng, hoặc chữ vô nghĩa do nhận nhầm biểu tượng.
        - Không gộp, không tách, không bỏ dòng nào. Không giải thích.
        """
    }

    static func userPrompt(_ items: [String], terms: [GlossaryEntry]) -> String {
        var s = ""
        if !terms.isEmpty {
            s += "Thuật ngữ cố định:\n"
            for t in terms { s += "- \(t.term) → \(t.keepsAsIs ? t.term : t.translation ?? t.term)\n" }
            s += "\n"
        }
        for (i, t) in items.enumerated() { s += "\(i + 1). \(t)\n" }
        return s
    }

    /// Đọc lại câu trả lời dạng "1. ...". Thiếu số nào thì coi như hỏng (trả nil) để thử engine khác.
    static func parseNumbered(_ reply: String, count: Int) -> [String]? {
        var out = [String?](repeating: nil, count: count)
        let rx = try? NSRegularExpression(pattern: #"^\s*(\d+)\s*[.):：]\s*(.*)$"#)
        for raw in reply.components(separatedBy: .newlines) {
            let ns = raw as NSString
            guard let m = rx?.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
                  let n = Int(ns.substring(with: m.range(at: 1))), (1...count).contains(n) else { continue }
            let text = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, out[n - 1] == nil { out[n - 1] = text }
        }
        if out.allSatisfy({ $0 != nil }) { return out.map { $0! } }   // "=" giữ nguyên, người gọi tự đổi về chữ gốc
        // Không đánh số nhưng đủ dòng: lấy theo thứ tự.
        let plain = reply.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return plain.count == count ? plain : nil
    }
}
