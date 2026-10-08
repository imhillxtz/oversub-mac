import AppKit
import ScreenCaptureKit
import Vision

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func displayIDOf(_ screen: NSScreen) -> UInt32? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

func screen(for displayID: UInt32) -> NSScreen? {
    NSScreen.screens.first { displayIDOf( $0) == displayID }
}

/// Màn hình của vùng đã chọn. ID đổi (cắm/rút màn hình) thì tìm màn hình cùng kích thước, rồi mới về màn hình chính.
func resolveScreen(for region: CaptureRegion) -> NSScreen? {
    if let s = screen(for: region.displayID) { return s }
    if let sw = region.sw, let sh = region.sh,
       let s = NSScreen.screens.first(where: { abs($0.frame.width - sw) < 1 && abs($0.frame.height - sh) < 1 }) {
        return s
    }
    return NSScreen.main
}

@MainActor
final class ScreenGrabber {
    private var cached: SCShareableContent?
    private var cachedAt = Date.distantPast

    /// Gọi khi cửa sổ phủ của app xuất hiện hoặc biến mất, để danh sách cửa sổ cần loại trừ được lấy lại.
    func invalidate() { cached = nil }

    private func content() async throws -> SCShareableContent {
        // Lấy danh sách cửa sổ mỗi lần quét rất tốn CPU; dùng lại tối đa 10 giây.
        if let c = cached, Date().timeIntervalSince(cachedAt) < 10 { return c }
        // Lấy cả cửa sổ đang ẩn, để danh sách luôn có OverSub (kể cả khi mọi cửa sổ của app đang ẩn lúc lấy danh sách).
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        cached = c
        cachedAt = Date()
        return c
    }

    /// Chụp đúng vùng phụ đề, loại trừ mọi cửa sổ của chính app để không đọc lại bản dịch đang phủ lên.
    /// `fullResolution`: giữ độ nét Retina (dùng cho ảnh dừng hình khi chọn vùng), mặc định giới hạn bề ngang cho OCR nhẹ.
    func grab(_ region: CaptureRegion, fullResolution: Bool = false) async throws -> CGImage {
        let content = try await content()
        guard let screen = resolveScreen(for: region), let id = displayIDOf( screen),
              let display = content.displays.first(where: { $0.displayID == id }) else {
            cached = nil
            throw AppError(L("Không tìm thấy màn hình đã chọn. Vui lòng chọn lại vùng.", "The selected display wasn't found. Select the region again."))
        }
        // Loại trừ cả ứng dụng OverSub, không liệt kê từng cửa sổ: lớp bản dịch ẩn hiện liên tục, cửa sổ nào vừa hiện lại hay
        // vừa tạo sau lúc lấy danh sách cũng không lọt vào ảnh. Lọt vào thì app đọc lại chính bản dịch của mình và chớp liên tục.
        let pid = ProcessInfo.processInfo.processIdentifier
        let filter: SCContentFilter
        if let me = content.applications.first(where: { $0.processID == pid }) {
            filter = SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.owningApplication?.processID == pid })
        }

        // Phụ đề không cần độ phân giải Retina đầy đủ; giới hạn bề ngang để OCR nhẹ hơn.
        let widthPx = region.w * screen.backingScaleFactor
        let factor = fullResolution ? 1.0 : min(1.0, 1800.0 / widthPx)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = region.rect
        cfg.width = max(1, Int(widthPx * factor))
        cfg.height = max(1, Int(region.h * screen.backingScaleFactor * factor))
        cfg.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}

// MARK: Canh chừng Vision

/// Vision có lúc treo hẳn. Đo thực 08/10/2026: đúng lúc giọng Siri mở Neural Engine để nạp giọng, ba lệnh nhận chữ đang chạy
/// chờ mãi ở semaphore bên trong Vision, và từ đó mọi lệnh sau trong cùng tiến trình xếp hàng chờ theo. Bấm Dừng rồi Bắt đầu
/// không gỡ được, chỉ khởi động lại app mới gỡ được.
/// Vì vậy mọi lệnh Vision chạy trên luồng GCD riêng (luồng bị treo không chiếm nhóm luồng của Swift concurrency) và không ai
/// chờ quá `softLimit` giây. Lệnh vẫn chưa xong sau `hardLimit` giây thì coi như Vision đã treo và gọi `onStuck` một lần.
///
/// Lần nhận chữ đầu tiên trên một máy thì khác: macOS phải dựng mô hình cho Neural Engine rồi mới lưu vào
/// `~/Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache`. Đo thực 08/10/2026: lệnh đầu tiên của một chương trình chưa
/// từng nhận chữ mất khoảng 57 giây, các lệnh sau 0,2 giây. Bản 1.1.58–1.1.63 coi khoảng chờ đó là treo, khởi động lại ở giây
/// thứ 12, việc dựng mô hình bị cắt ngang, chưa lưu được, và máy mới kẹt trong vòng lặp. Nên mỗi mức nhận chữ và ngôn ngữ được
/// `prepare` trước bằng một lần nhận chữ trên ảnh dựng sẵn, chờ tới `prepareLimit`; lệnh thật chỉ chạy sau khi đã chuẩn bị xong.
enum VisionGuard {
    static let softLimit: Double = 4
    static let hardLimit: Double = 12
    /// Máy chậm có thể dựng mô hình lâu hơn lần đo 57 giây, nên chờ tới 4 phút mới coi là treo.
    static let prepareLimit: Double = 240
    /// Việc cần làm khi Vision treo (Engine đặt: tự khởi động lại app). Chạy trên luồng chính.
    @MainActor static var onStuck: (() -> Void)?
    /// Báo bắt đầu (true) hay xong (false) một lần chuẩn bị kéo dài quá 1 giây, để Engine hiện thông báo. Chạy trên luồng chính.
    @MainActor static var onPreparing: ((Bool) -> Void)?
    @MainActor static private(set) var preparing = false
    @MainActor private static var warmups: [String: Task<Void, Never>] = [:]
    private static let reported = Once()

    struct Timeout: LocalizedError {
        var errorDescription: String? { L("Bộ nhận chữ của macOS không phản hồi.", "macOS text recognition is not responding.") }
    }

    #if DEVTOOLS
    /// Thử tình huống Vision treo (OVERSUB_VISION_HANG=n): lệnh thứ n trở đi treo hẳn như lần đo thực.
    private static let hangAfter = Int(ProcessInfo.processInfo.environment["OVERSUB_VISION_HANG"] ?? "")
    private static let calls = Counter()
    /// Thử lần chuẩn bị lâu (OVERSUB_VISION_SLOW_PREPARE=giây): mỗi lần chuẩn bị chờ thêm từng ấy giây.
    private static let slowPrepare = Double(ProcessInfo.processInfo.environment["OVERSUB_VISION_SLOW_PREPARE"] ?? "")
    #endif

    /// Chuẩn bị Vision cho một mức nhận chữ và ngôn ngữ. Gọi nhiều lần hay từ nhiều chỗ cùng lúc thì chỉ chạy một lần, các nơi
    /// gọi cùng chờ. Nhờ vậy không lệnh thật nào phải gánh lần dựng mô hình, cũng không dồn hàng chục luồng chờ sau nó.
    static func prepare(_ level: VNRequestTextRecognitionLevel, language: String) async {
        let task = await MainActor.run { () -> Task<Void, Never> in
            let key = "\(level == .fast ? "nhanh" : "kỹ")-\(language)"
            if let t = warmups[key] { return t }
            let t = Task { @MainActor in await warm(level, language: language, key: key) }
            warmups[key] = t
            return t
        }
        await task.value
    }

    /// Số lần chuẩn bị đang chạy; thông báo "đang chuẩn bị" tắt khi về 0.
    @MainActor private static var active = 0

    @MainActor private static func warm(_ level: VNRequestTextRecognitionLevel, language: String, key: String) async {
        let started = Date()
        active += 1
        let notice = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            DebugLog.write("Vision: đang chuẩn bị bộ nhận chữ (\(key)); lần đầu trên một máy có thể mất khoảng một phút")
            if !preparing { preparing = true; onPreparing?(true) }
        }
        let finished: Bool = await withCheckedContinuation { cont in
            let gate = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                #if DEVTOOLS
                if let extra = slowPrepare { Thread.sleep(forTimeInterval: extra) }
                #endif
                let r = VNRecognizeTextRequest()
                r.recognitionLevel = level
                r.usesLanguageCorrection = level == .accurate
                r.recognitionLanguages = [language]
                if let image = sampleImage() { try? VNImageRequestHandler(cgImage: image).perform([r]) }
                if gate.set() { cont.resume(returning: true) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + prepareLimit) {
                if gate.set() { cont.resume(returning: false) }
            }
        }
        notice.cancel()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if finished {
            DebugLog.write("Vision: chuẩn bị \(key) xong sau \(ms) ms")
        } else {
            DebugLog.write("Vision: chuẩn bị \(key) quá \(Int(prepareLimit)) giây vẫn chưa xong, bộ nhận chữ của macOS đã treo")
        }
        active -= 1
        if active == 0, preparing { preparing = false; onPreparing?(false) }
        if !finished, reported.set() { onStuck?() }
    }

    /// Ảnh có một dòng chữ in, dựng bằng CoreText (chạy được trên mọi luồng), chỉ để Vision dựng mô hình.
    private static func sampleImage() -> CGImage? {
        let w = 640, h = 120
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let text = NSAttributedString(string: "OverSub reads game text", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        ctx.textPosition = CGPoint(x: 20, y: 42)
        CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        return ctx.makeImage()
    }

    static func run<T>(_ label: String, level: VNRequestTextRecognitionLevel, language: String,
                       _ work: @escaping () throws -> T) async throws -> T {
        await prepare(level, language: language)
        let gate = Once(), done = Once()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                #if DEVTOOLS
                if let n = hangAfter, calls.next() >= n { while true { Thread.sleep(forTimeInterval: 60) } }
                #endif
                let result = Result { try work() }
                _ = done.set()
                if gate.set() { cont.resume(with: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + softLimit) {
                guard gate.set() else { return }
                DebugLog.write("Vision: \(label) chưa trả về sau \(Int(softLimit)) giây, bỏ qua lần này")
                cont.resume(throwing: Timeout())
                DispatchQueue.global().asyncAfter(deadline: .now() + hardLimit - softLimit) {
                    guard !done.isSet, reported.set() else { return }
                    DebugLog.write("Vision: \(label) vẫn chưa trả về sau \(Int(hardLimit)) giây, bộ nhận chữ của macOS đã treo")
                    DispatchQueue.main.async { MainActor.assumeIsolated { onStuck?() } }
                }
            }
        }
    }
}

/// Cờ bật đúng một lần, dùng được từ nhiều luồng.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    /// true nếu lần gọi này là lần bật cờ.
    func set() -> Bool { lock.lock(); defer { lock.unlock() }; if flag { return false }; flag = true; return true }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

#if DEVTOOLS
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
#endif

/// Dấu vân tay nhỏ của khung hình, để bỏ qua OCR khi vùng phụ đề không đổi.
enum FrameSignature {
    private static let w = 64, h = 16

    static func make(_ image: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .high   // lấy trung bình, để chữ mảnh vẫn làm đổi ô
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return px
    }

    /// Tỉ lệ ô đổi đáng kể giữa hai khung hình (0...1).
    static func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 12 { changed += 1 }
        return Double(changed) / Double(a.count)
    }

    /// Cảnh đổi hẳn (menu đóng, chuyển màn): hơn 30% ô đổi mạnh. Hiệu ứng nhỏ (lấp lánh, vệt chọn) không tính.
    static func bigChange(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        var changed = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 40 { changed += 1 }
        return Double(changed) / Double(a.count) > 0.3
    }

    static func unchanged(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var changed = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 12 { changed += 1 }
        return changed <= 2
    }
}

struct OCRLine {
    var text: String
    var box: CGRect   // toạ độ chuẩn hoá 0...1 của Vision, gốc ở góc dưới trái
}

struct OCRResult {
    var lines: [OCRLine]
    var speaker: String? = nil   // nhãn tên người nói nằm ngay trên hộp thoại, nếu có
    var text: String { lines.map(\.text).joined(separator: " ") }
}

enum OCR {
    // MARK: Gom dòng

    /// Gộp các mảnh OCR nằm cùng một hàng (Vision đôi khi tách một dòng thành nhiều mảnh) và xếp theo thứ tự đọc:
    /// hàng trên xuống dưới, trong hàng thì trái sang phải.
    private static func rows(_ pieces: [OCRLine], aspect: CGFloat) -> [OCRLine] {
        var rows: [[OCRLine]] = []
        for p in pieces.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let i = rows.firstIndex(where: { row in
                guard let r = row.first else { return false }
                let sameLevel = abs(r.box.midY - p.box.midY) < min(r.box.height, p.box.height) * 0.5
                // Cùng độ cao nhưng cách xa (nhãn tên bên trái, nút gợi ý bên phải) thì là hai hàng khác nhau.
                let span = row.dropFirst().reduce(r.box) { $0.union($1.box) }
                // Toạ độ Vision chuẩn hoá riêng từng chiều: đổi chiều cao dòng (đơn vị dọc) sang đơn vị ngang trước khi so.
                let reach = max(r.box.height, p.box.height) * aspect * 2.5
                let near = p.box.minX <= span.maxX + reach && p.box.maxX >= span.minX - reach
                return sameLevel && near
            }) { rows[i].append(p) } else { rows.append([p]) }
        }
        return rows.map { row in
            let ordered = row.sorted { $0.box.minX < $1.box.minX }
            let box = ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
            return OCRLine(text: ordered.map(\.text).joined(separator: " "), box: box)
        }.sorted { $0.box.midY > $1.box.midY }
    }

    /// Màu trung bình trong khung một dòng, để nhận ra nhãn tên nằm trên nền khác hẳn lời thoại.
    private static func meanColor(_ image: CGImage, _ box: CGRect) -> (Double, Double, Double)? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let r = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard r.width >= 2, r.height >= 2, let crop = image.cropping(to: r) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high   // thu về 1 điểm ảnh = lấy trung bình
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return ok ? (Double(px[0]), Double(px[1]), Double(px[2])) : nil
    }

    /// Dòng trên cùng có phải nhãn tên người nói không: ngắn, chỉ có chữ, và khác kiểu hẳn với dòng ngay dưới
    /// (nền hoặc màu chữ khác, hoặc cỡ chữ khác). Không dựa vào khoảng cách dòng vì game giãn dòng rất khác nhau.
    private static func isSpeakerLabel(_ top: OCRLine, below: OCRLine, image: CGImage) -> Bool {
        var text = top.text.trimmingCharacters(in: .whitespaces)
        while let last = text.last, ":-—".contains(last) { text.removeLast() }
        let words = text.split(separator: " ")
        // Nhãn tên thật viết hoa chữ đầu, có ít nhất 3 chữ cái và không kết thúc bằng dấu chấm; mảnh chữ rác như "nh." thì không.
        guard let first = text.first, first.isUppercase, text.filter(\.isLetter).count >= 3, !text.hasSuffix(".") else { return false }
        guard (1...3).contains(words.count), text.count <= 24,
              text.allSatisfy({ $0.isLetter || $0 == " " || $0 == "'" || $0 == "-" || $0 == "." }),
              !SubtitleFilter.isMenuVocabulary(words.map(String.init)) else { return false }
        let ratio = max(top.box.height, below.box.height) / max(0.0001, min(top.box.height, below.box.height))
        if ratio >= 1.15 { return true }
        if let a = meanColor(image, top.box), let b = meanColor(image, below.box) {
            let d = ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
            if d > 60 { return true }
        }
        return false
    }

    /// Gom các dòng liên tiếp thành khối. Ngưỡng theo chiều cao dòng LỚN NHẤT và rộng rãi, vì chiều cao khung OCR đổi theo nội dung
    /// (có hay không có chữ g, y, p...), dùng ngưỡng hẹp sẽ làm hai dòng của cùng một câu lúc dính lúc tách.
    private static func blocks(_ lines: [OCRLine], aspect: CGFloat) -> [[OCRLine]] {
        guard let first = lines.first else { return [] }
        var result: [[OCRLine]] = [[first]]
        for l in lines.dropFirst() {
            let block = result[result.count - 1]
            let prev = block.last!
            let gap = prev.box.minY - l.box.maxY   // Vision có gốc ở dưới, dòng trước nằm cao hơn
            let hMin = min(prev.box.height, l.box.height), hMax = max(prev.box.height, l.box.height)
            // Dòng phải nằm trong phạm vi ngang của khối (cho phép lệch chút): chữ bản đồ hay tên khu vực ở góc màn hình,
            // dù sát ngay dưới hộp thoại, không bị nối vào cuối câu thoại.
            let span = block.dropFirst().reduce(block[0].box) { $0.union($1.box) }
            let margin = hMax * aspect   // đổi sang đơn vị ngang
            let overlapsX = l.box.maxX >= span.minX - margin && l.box.minX <= span.maxX + margin
            if gap > 2.2 * hMax || hMax > 1.6 * hMin || !overlapsX { result.append([l]) } else { result[result.count - 1].append(l) }
        }
        return result
    }

    private static func area(_ c: [OCRLine]) -> CGFloat { c.reduce(0) { $0 + $1.box.width * $1.box.height } }

    /// Tách lời thoại khỏi nhãn tên người nói và chữ lặt vặt (hướng dẫn phím ở góc...).
    static func split(_ pieces: [OCRLine], image: CGImage) -> (body: [OCRLine], speaker: String?) {
        let aspect = CGFloat(image.height) / CGFloat(max(1, image.width))
        var lines = rows(pieces, aspect: aspect)
        // Có nhiều hàng thì loại trước các hàng chắc chắn là giao diện (biểu tượng nút "A", "Press A to continue"...).
        if lines.count >= 2 {
            let kept = lines.filter { $0.text.filter(\.isLetter).count >= 2 && !SubtitleFilter.isUIRow($0.text) }
            if !kept.isEmpty { lines = kept }
        }
        var speaker: String?
        if lines.count >= 2, isSpeakerLabel(lines[0], below: lines[1], image: image) {
            var t = lines[0].text.trimmingCharacters(in: .whitespaces)
            while let last = t.last, ":-—".contains(last) { t.removeLast() }
            t = t.trimmingCharacters(in: .whitespaces)
            // Tên nhân vật không kết thúc bằng dấu câu và có ít nhất ba chữ cái; không thì đó là một dòng thoại ngắn
            // hoặc chữ giao diện ("OD", "đâu."), không lập nhân vật mới từ nó.
            if t.filter(\.isLetter).count >= 3, !(t.last.map { ".!?…,".contains($0) } ?? false) {
                speaker = t
                lines.removeFirst()
            }
        }
        let body = blocks(lines, aspect: aspect).max { area($0) < area($1) } ?? lines
        return (body, speaker)
    }

    /// Đọc nhanh (chế độ fast, khoảng 14 ms thay vì 120 ms) chỉ để biết chữ trong khung có đổi không: cảnh nền chuyển động
    /// làm khung hình đổi liên tục dù lời thoại vẫn vậy, không cần đọc kỹ lại. Giữ chữ, số và dấu kết thúc câu.
    static func quickText(_ image: CGImage, language: String) async -> String {
        await quickScan(image, language: language).sig
    }

    /// Một mẩu chữ đọc nhanh: chữ đã chuẩn hoá (chữ thường, chỉ chữ và số) và khung (toạ độ Vision 0...1, gốc dưới trái).
    typealias QuickObs = (text: String, box: CGRect)

    /// Đọc nhanh: chuỗi dấu hiệu (để biết chữ có đổi không) và vị trí từng mẩu chữ (để biết chữ có di chuyển không).
    static func quickScan(_ image: CGImage, language: String) async -> (sig: String, obs: [QuickObs]) {
        let r = try? await VisionGuard.run("đọc nhanh", level: .fast, language: language) { () -> (sig: String, obs: [QuickObs]) in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            request.recognitionLanguages = [language]
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return ("", []) }
            // Nền chuyển động có vân (đá lát, lá cây, khi nhân vật đi lại) hay bị đọc thành vài mẩu chữ rác, mỗi khung một
            // khác: bỏ mẩu ít hơn 3 chữ cái hoặc độ tin cậy thấp, và xếp theo vị trí (trên xuống, trái sang) để thứ tự ghép
            // không đổi giữa các khung. Nhờ vậy chữ thật đọc ra giống nhau dù nền phía sau đang chạy.
            let obs = (request.results ?? []).compactMap { o -> (String, CGRect)? in
                guard let top = o.topCandidates(1).first, top.confidence >= 0.3, top.string.filter(\.isLetter).count >= 3 else { return nil }
                return (top.string, o.boundingBox)
            }.sorted { a, b in
                abs(a.1.midY - b.1.midY) > min(a.1.height, b.1.height) * 0.5 ? a.1.midY > b.1.midY : a.1.minX < b.1.minX
            }
            let raw = obs.map(\.0).joined(separator: " ").lowercased()
            let sig = String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || ".!?…".unicodeScalars.contains($0) })
            return (sig, obs.map { (String($0.0.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }), $0.1) })
        }
        return r ?? ("", [])
    }

    /// Dấu hiệu chữ của một vùng dịch màn hình, để biết chữ có đổi không (không cần đọc đúng, chỉ cần khung nào cũng ra
    /// giống nhau). Chữ sáng (thoại trắng viền tối) thì đọc trên ảnh tách chữ sáng, chịu được cảnh phía sau đang chạy;
    /// không có chữ sáng (menu chữ tối trên nền sáng) thì đọc nhanh trên ảnh gốc.
    static func screenSignature(_ image: CGImage, language: String) async -> String {
        await screenScan(image, language: language).sig
    }

    /// Như `screenSignature`, kèm vị trí từng mẩu chữ.
    static func screenScan(_ image: CGImage, language: String) async -> (sig: String, obs: [QuickObs]) {
        if let mask = brightTextMask(image) {
            let m = await quickScan(mask, language: language)
            if m.sig.filter(\.isLetter).count >= 8 { return m }
        }
        return await quickScan(image, language: language)
    }

    /// Độ dịch chuyển chung của chữ giữa hai lần đọc nhanh (đơn vị 0...1 của vùng): ghép các mẩu có cùng chữ, lấy trung vị.
    /// nil nếu không ghép được mẩu nào (chữ đã khác).
    static func shift(from a: [QuickObs], to b: [QuickObs]) -> CGVector? {
        var dx: [CGFloat] = [], dy: [CGFloat] = []
        var used = Set<Int>()
        for o in a where o.text.count >= 4 {
            guard let k = b.indices.first(where: { !used.contains($0) && b[$0].text == o.text }) else { continue }
            used.insert(k)
            dx.append(b[k].box.minX - o.box.minX); dy.append(b[k].box.midY - o.box.midY)
        }
        guard !dx.isEmpty else { return nil }
        dx.sort(); dy.sort()
        return CGVector(dx: dx[dx.count / 2], dy: dy[dy.count / 2])
    }

    /// Ảnh chỉ giữ lại chữ sáng (trắng, ít màu) thành chữ đen trên nền trắng. Chữ thoại game thường trắng viền tối nổi trên
    /// cảnh; khi cảnh phía sau rối (đá lát, lá cây, nhân vật đang chạy) Vision đọc nhanh trên ảnh gốc hay trượt, trên ảnh này
    /// thì đọc chắc.
    static func brightTextMask(_ image: CGImage) -> CGImage? {
        let W = image.width, H = image.height
        guard W > 0, H > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: W * H * 4)
        guard let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        var out = [UInt8](repeating: 255, count: W * H)
        for i in 0..<(W * H) {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
            let lum = (r * 299 + g * 587 + b * 114) / 1000, sat = max(r, g, b) - min(r, g, b)
            if lum > 205 && sat < 45 { out[i] = 0 }
        }
        guard let g = CGContext(data: &out, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        return g.makeImage()
    }

    /// Tự tìm khung phụ đề trên ảnh cả màn hình: khối chữ lớn nhất ở nửa dưới, ưu tiên nằm giữa và nhiều chữ,
    /// rồi nới rộng thêm phía trên (chỗ nhãn tên người nói) và hai bên. Trả về toạ độ chuẩn hoá, gốc ở góc trên trái.
    static func detectSubtitleArea(_ image: CGImage, language: String) async -> CGRect? {
        let r = try? await VisionGuard.run("tự tìm phụ đề", level: .fast, language: language) { () -> CGRect? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            request.recognitionLanguages = [language]
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
            let pieces = (request.results ?? []).compactMap { obs -> OCRLine? in
                guard let top = obs.topCandidates(1).first, top.confidence >= 0.3, top.string.filter(\.isLetter).count >= 2 else { return nil }
                return OCRLine(text: top.string, box: obs.boundingBox)
            }
            let aspect = CGFloat(image.height) / CGFloat(max(1, image.width))
            // Chỉ xét nửa dưới màn hình (Vision có gốc ở dưới): phụ đề và hộp thoại hầu như luôn nằm đây.
            let lines = rows(pieces, aspect: aspect).filter { $0.box.midY < 0.55 && $0.text.filter(\.isLetter).count >= 4 && !SubtitleFilter.isUIRow($0.text) }
            let candidates = blocks(lines, aspect: aspect)
            func score(_ b: [OCRLine]) -> CGFloat {
                let box = b.dropFirst().reduce(b[0].box) { $0.union($1.box) }
                let letters = CGFloat(b.reduce(0) { $0 + $1.text.filter(\.isLetter).count })
                let centered = 1 - min(1, abs(box.midX - 0.5) * 2)
                return letters * (0.6 + 0.4 * centered) * (1.2 - box.midY)
            }
            guard let best = candidates.filter({ $0.reduce(0) { $0 + $1.text.filter(\.isLetter).count } >= 10 }).max(by: { score($0) < score($1) }) else { return nil }
            let box = best.dropFirst().reduce(best[0].box) { $0.union($1.box) }
            let lineH = best.map(\.box.height).max() ?? 0.03
            // Nới: trên 1,8 dòng (nhãn tên), dưới 0,8 dòng, hai bên 2,5 dòng (đổi sang đơn vị ngang).
            let padX = lineH * 2.5 * aspect
            let minX = max(0, box.minX - padX), maxX = min(1, box.maxX + padX)
            let minY = max(0, box.minY - lineH * 0.8), maxY = min(1, box.maxY + lineH * 1.8)
            return CGRect(x: minX, y: 1 - maxY, width: maxX - minX, height: maxY - minY)
        }
        return r ?? nil
    }

    /// `keepAll`: giữ mọi dòng theo thứ tự đọc (vùng phụ như bảng nhiệm vụ), không tách nhãn tên hay chọn khối lời thoại.
    static func recognize(_ image: CGImage, language: String, keepAll: Bool = false) async throws -> OCRResult {
        try await VisionGuard.run(keepAll ? "đọc vùng dịch màn hình" : "đọc kỹ", level: .accurate, language: language) { () -> OCRResult in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = [language]
            try VNImageRequestHandler(cgImage: image).perform([request])

            let pieces = (request.results ?? []).compactMap { obs -> OCRLine? in
                guard let top = obs.topCandidates(1).first, top.confidence >= 0.45 else { return nil }
                let s = top.string.trimmingCharacters(in: .whitespaces)
                // Bỏ dòng không có chữ nào (số điểm, ký hiệu).
                guard s.contains(where: { $0.isLetter }) else { return nil }
                // Dịch màn hình: bỏ ký tự rác do đọc nhầm biểu tượng ở hai đầu dòng, lấy đúng khung phần chữ thật từ Vision
                // để mảng thay chữ không che biểu tượng.
                if keepAll, let r = ScreenText.cleanRange(top.string), r != top.string.startIndex..<top.string.endIndex,
                   let sub = try? top.boundingBox(for: r)?.boundingBox {
                    return OCRLine(text: String(top.string[r]), box: sub)
                }
                return OCRLine(text: s, box: obs.boundingBox)
            }
            // Hoạ tiết cảnh nền (gạch, lá cây) hay bị đọc thành vài ký tự rác; ít hơn 3 chữ cái thì coi như không có phụ đề.
            let letters = pieces.reduce(0) { $0 + $1.text.filter(\.isLetter).count }
            guard letters >= 3 else { return OCRResult(lines: []) }
            if keepAll {
                return OCRResult(lines: rows(pieces, aspect: CGFloat(image.height) / CGFloat(max(1, image.width))))
            }
            let (body, speaker) = split(pieces, image: image)
            return OCRResult(lines: body, speaker: speaker)
        }
    }
}
