import SwiftUI
import AppKit
import ImageIO

/// Ove: linh vật 3D của OverSub, đầu kính mờ có lõi cam. Hình dựng sẵn bằng bộ dựng 3D ở Tools/Ove (cùng bộ dựng của
/// prototype) rồi xếp thành từng tấm khung hình trong Resources/Ove. Core Animation lật khung nên app gần như không tốn
/// CPU (đo 0,3% một nhân ở 30 khung mỗi giây), và mọi hoạt ảnh dừng hẳn khi cửa sổ bị che.
///
/// Tấm khung hình: bộ quay đầu cho mặt chờ (`look-idle`) và mặt đang chạy (`look-live`), gồm khung nhìn thẳng và các dãy
/// khung quay sang từng hướng nhìn quanh, kèm khung nhắm mắt để chớp; vòng đọc (`speak`); các đoạn biểu cảm (`happy`,
/// `sad`, `angry`, `dizzy`, `cry`); ngáp và tỉnh dậy riêng cho nền sáng và nền tối (`yawn-light`, `wake-dark`...) vì mặt
/// lúc ngủ xám khác nhau. Kính đã được tách độ trong thật nên cùng một khung dùng được trên cả hai nền.

/// Biểu cảm có sẵn trong bộ hình, mỗi biểu cảm là một đoạn dựng sẵn cùng tên.
enum OveReaction: String, CaseIterable {
    case happy, sad, angry, dizzy, cry

    /// Hai chuyện tới cùng lúc thì chuyện nặng hơn được làm trước: lỗi đi trước niềm vui.
    var weight: Int {
        switch self {
        case .happy: return 0
        case .sad, .angry: return 1
        case .dizzy: return 2
        case .cry: return 3
        }
    }

    /// Phản ứng sau khi đọc xong một câu thoại: câu cười thì vui, câu buồn thì buồn, câu hét thì giận, câu thường thì
    /// không. Dùng bộ đoán cảm xúc của giọng lồng tiếng (đoán theo câu gốc, đúng nhất với tiếng Anh).
    static func story(_ source: String) -> OveReaction? {
        switch Emotion.detect(source: source) {
        case .laugh: return .happy
        case .sad: return .sad
        case .shout: return .angry
        default: return nil
        }
    }
}

/// Việc view chứa Ove nhờ Ove làm (cửa sổ Ủng hộ, hộp thoại). Mỗi lần tạo là một `id` mới, nên cùng một việc gọi lại vẫn chạy.
struct OvePoke: Equatable {
    enum Action: Equatable {
        case express(OveReaction)                         // làm nét mặt rồi về mặt thường
        case hold(OveReaction)                            // làm nét mặt rồi giữ nguyên (hộp thoại báo lỗi)
        case look(yaw: Int, pitch: Int, seconds: Double)  // nhìn về một hướng một lúc rồi nhìn thẳng lại
        case cheer(Int)                                   // vui theo mức: 1 cười khẽ, 2 vui, 3 rất vui (giữ nụ cười, nảy lên)
        case calm                                         // thôi giữ nét mặt, về mặt thường
    }
    let action: Action
    let id = UUID()
    init(_ action: Action) { self.action = action }
}

/// Báo cho Ove ở cửa sổ chính chuyện vừa xảy ra trong app (lỗi dịch, Vision treo, dịch lại được...).
@MainActor
enum OveEvents {
    static func send(_ reaction: OveReaction, _ why: String) {
        DebugLog.write("Ove: \(reaction.rawValue) (\(why))")
        NotificationCenter.default.post(name: .oveReaction, object: reaction.rawValue)
    }
}

extension Notification.Name {
    static let oveReaction = Notification.Name("vn.imhillxtz.oversub.oveReaction")
    #if DEVTOOLS
    static let oveDebugLife = Notification.Name("vn.imhillxtz.oversub.oveDebugLife")
    static let oveDebugHover = Notification.Name("vn.imhillxtz.oversub.oveDebugHover")
    static let oveDebugFidget = Notification.Name("vn.imhillxtz.oversub.oveDebugFidget")
    #endif
}

/// Nút đang được rê chuột quanh Ove trên cửa sổ chính (Phụ đề, Dịch màn hình, Bắt đầu): Ove quay đầu nhìn theo.
@MainActor
final class OveGaze: ObservableObject {
    static let shared = OveGaze()
    @Published var target: OveAngle?
}

extension View {
    /// Rê chuột vào thì Ove nhìn về phía view này (`yaw`, `pitch` theo nấc của bộ quay đầu); rời ra hay view biến mất thì thôi.
    func oveLooks(yaw: Int, pitch: Int) -> some View {
        let a = OveAngle(yaw: yaw, pitch: pitch)
        return onHover { on in
            if on { OveGaze.shared.target = a } else if OveGaze.shared.target == a { OveGaze.shared.target = nil }
        }
        .onDisappear { if OveGaze.shared.target == a { OveGaze.shared.target = nil } }
    }
}

/// Hướng đầu: `yaw` theo nấc 0,15 rad (khoảng 9°; dương là nhìn sang phải màn hình), `pitch` theo nấc 0,18 rad (âm là ngước
/// lên). Chỉ các hướng có trong bộ quay đầu (`look` trong ove.json) mới dùng được.
struct OveAngle: Equatable {
    var yaw: Int
    var pitch: Int
    static let front = OveAngle(yaw: 0, pitch: 0)
}

@MainActor
final class OveLibrary {
    static let shared = OveLibrary()

    struct Sheet {
        let image: CGImage
        let count: Int
        let cols: Int
        let rows: Int
        /// Khoảng khung giữ nét mặt của đoạn biểu cảm (đỉnh biểu cảm).
        let hold: [Int]?
        /// Các khung miệng gần khép của vòng đọc.
        let rest: [Int]?
        /// Chỗ chia đoạn (bị cù: đoạn vào kết thúc trước `parts[0]`, vòng lặp từ `parts[0]` tới trước `parts[1]`, rồi đoạn ra).
        var parts: [Int]? = nil

        /// Ô của khung thứ `i` theo toạ độ đơn vị của `contentsRect`. Tấm xếp hàng từ trên xuống, còn `contentsRect` trên
        /// macOS tính từ đáy ảnh lên, nên phải lật hàng.
        func rect(_ i: Int) -> CGRect {
            let i = max(0, min(count - 1, i))
            let w = 1 / CGFloat(cols), h = 1 / CGFloat(rows)
            return CGRect(x: CGFloat(i % cols) * w, y: 1 - CGFloat(i / cols + 1) * h, width: w, height: h)
        }
        var last: Int { count - 1 }
        /// Khung giữa khoảng giữ nét mặt.
        var peak: Int { hold.map { ($0[0] + $0[1]) / 2 } ?? count / 2 }
    }

    private struct Meta: Decodable {
        struct SheetInfo: Decodable {
            let count: Int; let rows: Int; let kind: String; let hold: [Int]?; let rest: [Int]?; let parts: [Int]?
        }
        struct Look: Decodable { let targets: [[Int]]; let steps: Int }
        let frame: Int
        let cols: Int
        let fps: Int
        let sheets: [String: SheetInfo]
        let look: Look
        let scenes: Scenes?
    }

    /// Cảnh lúc rảnh và nhịp, ghi trong ove.json từ bản gốc `OverSubHead.Clips.SCENES` (Tools/Ove/oversub-head.js).
    struct Scenes: Decodable {
        struct Beat: Decodable { let look: [Int]?; let hold: Double?; let fx: String? }
        struct Pace: Decodable {
            let blink: [Double]; let small: [Double]; let sceneEvery: Int; let listenLook: [Double]; let listenHappy: [Double]
        }
        let small: [[Beat]]
        let scenes: [[Beat]]
        let looks: Int
        let pace: Pace
    }

    private lazy var meta: Meta? = {
        guard let url = Bundle.main.url(forResource: "ove", withExtension: "json", subdirectory: "Ove") else {
            DebugLog.write("Ove: không thấy Resources/Ove/ove.json trong gói app")
            return nil
        }
        do {
            let m = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: url))
            guard m.look.steps > 0, m.look.targets.allSatisfy({ $0.count == 2 }) else {
                DebugLog.write("Ove: bộ quay đầu trong ove.json không đúng dạng")
                return nil
            }
            return m
        } catch {
            DebugLog.write("Ove: đọc ove.json lỗi: \(error)")
            return nil
        }
    }()
    private var cache: [String: Sheet] = [:]
    private var ripples: [String: CGImage] = [:]
    /// Tấm có khai trong ove.json mà không đọc được (thiếu tệp hoặc hỏng). Không đọc lại: trước đây `showStill` chờ nạp
    /// xong rồi gọi lại chính nó, tấm hỏng thì không bao giờ nạp xong, app lặp đọc tệp mãi ở hơn 100% CPU.
    private var broken: Set<String> = []

    /// Có bộ hình và đọc được các tấm luôn dùng; không thì dùng linh vật 2D. Chỉ đọc phần đầu tệp (dưới 2 ms mỗi tấm).
    /// Tệp bị cắt cụt vẫn giải nén được thành ảnh thiếu phần nên không tính là hỏng; chỉ tệp mất hay hỏng phần đầu mới làm
    /// `load` trả nil.
    private(set) lazy var available: Bool = {
        guard let meta else { return false }
        let bad = Self.kept.filter { meta.sheets[$0] == nil || !Self.readable($0) }.sorted()
        guard bad.isEmpty else {
            DebugLog.write("Ove: thiếu hoặc hỏng tấm \(bad.joined(separator: ", ")), dùng linh vật 2D")
            return false
        }
        return true
    }()
    var scenes: Scenes? { meta?.scenes }
    var fps: Double { Double(meta?.fps ?? 24) }
    /// Tỉ lệ khung so với đường kính đầu (khung 280 px cho đầu 256 px).
    var frameRatio: CGFloat { CGFloat(meta?.frame ?? 280) / 256 }

    func sheet(_ name: String) -> Sheet? {
        if let s = cache[name] { return s }
        guard !broken.contains(name) else { return nil }
        // Giải nén trên luồng chính mất 100 đến 350 ms, cả cửa sổ khựng theo: mọi lần đổi trạng thái phải nạp trước bằng
        // prefetch. Còn dòng này trong nhật ký là còn chỗ quên nạp trước.
        DebugLog.write("Ove: giải nén \(name) trên luồng chính")
        guard let image = Self.load(name) else {
            markBroken(name)
            return nil
        }
        return store(name, image)
    }

    private func markBroken(_ name: String) {
        guard meta?.sheets[name] != nil, broken.insert(name).inserted else { return }
        DebugLog.write("Ove: không đọc được tấm \(name).heic (thiếu hoặc hỏng), bỏ qua tấm này tới khi mở lại app")
    }

    /// Giải nén trước một tấm ở luồng phụ (tấm biểu cảm giải nén mất vài chục mili giây, làm ở luồng chính thì Ove khựng),
    /// xong thì gọi `then` ở luồng chính.
    func prefetch(_ name: String, then: @escaping @MainActor () -> Void) {
        guard cache[name] == nil, meta?.sheets[name] != nil, !broken.contains(name) else { then(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = OveLibrary.load(name)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let lib = OveLibrary.shared
                    if let image {
                        if lib.cache[name] == nil { lib.store(name, image) }
                    } else {
                        lib.markBroken(name)
                    }
                    then()
                }
            }
        }
    }

    /// Các tấm đã nằm sẵn trong bộ nhớ chưa. Tấm không có hay không đọc được thì coi như xong, khỏi chờ nạp.
    func has(_ names: [String]) -> Bool { names.allSatisfy { !needsLoad($0) } }

    private func needsLoad(_ name: String) -> Bool {
        cache[name] == nil && meta?.sheets[name] != nil && !broken.contains(name)
    }

    /// Nạp trước nhiều tấm ở luồng phụ, xong hết thì gọi `then` ở luồng chính.
    func prefetchAll(_ names: [String], then: @escaping @MainActor () -> Void) {
        var left = names.filter(needsLoad)
        guard let first = left.popLast() else { then(); return }
        prefetch(first) { [weak self] in
            guard let self else { return }
            self.prefetchAll(left, then: then)
        }
    }

    @discardableResult
    private func store(_ name: String, _ image: CGImage) -> Sheet? {
        guard let meta, let info = meta.sheets[name] else { return nil }
        let s = Sheet(image: image, count: info.count, cols: meta.cols, rows: info.rows, hold: info.hold, rest: info.rest,
                      parts: info.parts)
        cache[name] = s
        return s
    }

    /// Các hướng có trong bộ quay đầu.
    var lookTargets: [OveAngle] { meta?.look.targets.map { OveAngle(yaw: $0[0], pitch: $0[1]) } ?? [] }

    /// Bộ quay đầu (`look-idle`, `look-live`): khung 0 và 1 là nhìn thẳng mở mắt và nhắm mắt; sau đó mỗi hướng một dãy khung
    /// đi từ nhìn thẳng tới hướng đó, rồi một khung nhắm mắt ở hướng đó. Hàm trả về dãy khung tới `a` (không gồm khung nhìn
    /// thẳng, khung cuối là `a` mở mắt), nil nếu không có hướng này.
    func lookPath(to a: OveAngle) -> [Int]? {
        guard let meta, a != .front, let k = lookTargets.firstIndex(of: a) else { return nil }
        let base = 2 + k * (meta.look.steps + 1)
        return Array(base..<base + meta.look.steps)
    }

    /// Khung `frame` của bộ quay đầu nằm ở hướng nào, bước thứ mấy trên dãy quay tới hướng đó (nhìn thẳng thì bước -1).
    func lookPosition(of frame: Int) -> (OveAngle, Int)? {
        guard let meta, frame >= 0 else { return nil }
        if frame < 2 { return (.front, -1) }
        let k = (frame - 2) / (meta.look.steps + 1), j = (frame - 2) % (meta.look.steps + 1)
        guard k < lookTargets.count else { return nil }
        return (lookTargets[k], min(j, meta.look.steps - 1))
    }

    /// Khung mở mắt (hay nhắm mắt) ở hướng `a` trong bộ quay đầu.
    func lookFrame(_ a: OveAngle, closed: Bool = false) -> Int {
        guard let last = lookPath(to: a)?.last else { return closed ? 1 : 0 }
        return closed ? last + 1 : last
    }

    /// Thả tấm không còn dùng: mỗi tấm giải nén khoảng 20 đến 30 MB, giữ hết thì app nặng thêm hơn 100 MB. Đọc lại một
    /// tấm HEIC chỉ mất vài chục mili giây.
    func release(_ name: String) {
        guard !Self.kept.contains(name) else { return }
        cache[name] = nil
    }

    /// Giữ sẵn trong bộ nhớ (khoảng 63 MB): hai mặt và vòng đọc, dùng liên tục khi đang chơi. Thả vòng đọc sau mỗi câu như
    /// trước thì câu sau phải giải nén lại, cửa sổ khựng mỗi lần Ove bắt đầu đọc.
    private static let kept: Set<String> = ["look-idle", "look-live", "speak"]

    func ripple(dark: Bool) -> CGImage? {
        let name = dark ? "ripple-dark" : "ripple-light"
        if let s = ripples[name] { return s }
        let image = Self.load(name)
        ripples[name] = image
        return image
    }

    /// Đọc được phần đầu tấm `name` (có ảnh, có cỡ), không giải nén.
    private static func readable(_ name: String) -> Bool {
        guard let url = Bundle.main.url(forResource: name, withExtension: "heic", subdirectory: "Ove"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        return props[kCGImagePropertyPixelWidth] != nil
    }

    nonisolated private static func load(_ name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "heic", subdirectory: "Ove"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// Ove sống trong nút giữa cửa sổ chính. Bấm vẫn do nút bên ngoài lo (bật, tắt giọng đọc); view này không nhận cú bấm.
struct OveView: NSViewRepresentable {
    var mood: Mascot.Mood
    var size: CGFloat
    /// Đổi giá trị là Ove nảy một cái (câu thoại mới tới).
    var cue: UUID? = nil
    /// Cảm xúc của câu vừa tới: đọc xong câu đó Ove phản ứng theo (nhiều nhất một lần mỗi phút).
    var story: OveReaction? = nil
    /// Nhận biểu cảm theo sự kiện của app (`OveEvents`). Chỉ Ove ở cửa sổ chính bật.
    var appEvents = false
    /// Chuột đang nằm trên Ove: Ove như bị cù.
    var hovered = false
    /// Chuột đang nằm trên một nút quanh Ove: Ove nhìn về phía đó.
    var gaze: OveAngle? = nil
    var poke: OvePoke? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.homeAnimating) private var animating

    func makeNSView(context: Context) -> OveLayerView { OveLayerView(size: size) }
    func updateNSView(_ view: OveLayerView, context: Context) {
        view.configure(.init(mood: mood, dark: scheme == .dark, animating: animating, still: reduceMotion, cue: cue,
                             story: story, appEvents: appEvents, hovered: hovered, gaze: gaze, poke: poke))
    }
}

/// Ove trong hộp thoại và cửa sổ phụ: sống như ở cửa sổ chính (chớp mắt, nhìn quanh, diễn cảnh lúc rảnh), làm nét mặt
/// theo `poke`, rê chuột vào thì như bị cù. Thiếu bộ hình thì dùng linh vật 2D.
struct OveFigure: View {
    var size: CGFloat
    var poke: OvePoke? = nil
    @State private var hovered = false

    var body: some View {
        if OveLibrary.shared.available {
            OveView(mood: .idle, size: size, hovered: hovered, poke: poke)
                .frame(width: size, height: size)
                .onHover { hovered = $0 }
                .accessibilityHidden(true)
        } else {
            Mascot(mood: .idle, size: size)
        }
    }
}

final class OveLayerView: NSView {
    struct Input {
        var mood: Mascot.Mood
        var dark: Bool
        var animating: Bool
        var still: Bool
        var cue: UUID?
        var story: OveReaction?
        var appEvents: Bool
        var hovered: Bool
        var gaze: OveAngle?
        var poke: OvePoke?
    }

    private let lib = OveLibrary.shared
    private let size: CGFloat
    // Lớp: gợn sóng phía sau (trong một lớp chứa để làm mờ cả cụm khi đọc xong); thân (nảy khi có câu mới) chứa lớp thở,
    // trong đó có quầng cam, bóng đổ và hình Ove.
    private let rippleHost = CALayer()
    private let ripples = [CALayer(), CALayer()]
    private let bodyLayer = CALayer()
    private let breather = CALayer()
    private let glow = CALayer()
    private let drop = CALayer()
    private let sprite = CALayer()

    private var mood: Mascot.Mood = .idle
    private var dark = false
    private var animating = true
    private var still = false
    private var cue: UUID?
    private var poke: OvePoke?
    private var configured = false
    private var observer: NSObjectProtocol?

    private enum Showing: Equatable { case face(String), clip, loop, asleep }
    private var showing: Showing = .asleep
    private var sheetName: String?
    /// Đang chạy một đoạn (ngáp, tỉnh, biểu cảm): không nhận đoạn khác chen ngang, trừ khi đổi trạng thái.
    private var inClip = false
    /// Tăng mỗi lần lật khung mới: hoạt ảnh cũ bị thay thì việc hẹn sau nó không chạy.
    private var token = 0
    /// Tăng mỗi lần đổi trạng thái (hay dừng, chạy lại khi cửa sổ bị che): việc hẹn giờ của trạng thái cũ thì bỏ.
    private var moodGen = 0
    /// Tăng mỗi lần dừng hay khởi động lại nhịp sống (chớp mắt, nhìn quanh, vui khẽ).
    private var lifeGen = 0
    /// Hướng đầu đang hiện trên bộ quay đầu.
    private var angle = OveAngle.front
    /// Nét mặt đang giữ (hộp thoại báo lỗi): không chớp mắt, không nhìn quanh.
    private var held: OveReaction?
    /// Biểu cảm chờ chạy khi Ove đang bận (đang đọc, đang ngáp...), kèm lúc tới; quá 8 giây thì bỏ.
    private var queued: (reaction: OveReaction, at: Date)?
    private var lastPlayed: [OveReaction: Date] = [:]
    /// Cảm xúc của câu vừa tới; đọc xong câu đó mà không có câu nối tiếp thì Ove phản ứng theo.
    private var story: OveReaction?
    private var lastStoryAt = Date.distantPast
    /// Lúc vòng đọc bắt đầu (giờ Core Animation), để biết miệng đang ở khung nào khi đọc xong.
    private var speakStart: CFTimeInterval = 0
    /// Lần lật khung gần nhất (dãy khung, lúc bắt đầu, có lặp không), để tua ngược đoạn đang làm dở khi bị ngắt.
    private var lastRun: (frames: [Int], start: CFTimeInterval, repeating: Bool)?

    #if DEVTOOLS
    /// Móc thử rút ngắn khoảng cách giữa các lần nhìn quanh, vui khẽ (OVERSUB_OVE_TEST).
    static var debugLifeScale = 1.0
    #endif

    init(size: CGFloat) {
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        layer?.addSublayer(rippleHost)
        for r in ripples { r.isHidden = true; rippleHost.addSublayer(r) }
        layer?.addSublayer(bodyLayer)
        bodyLayer.addSublayer(breather)
        breather.addSublayer(glow)
        breather.addSublayer(drop)
        breather.addSublayer(sprite)
        sprite.contentsGravity = .resize
        // Không cho Core Animation tự trượt ô cắt hay hình: đổi khung là nhảy thẳng sang khung mới. Thiếu dòng này thì mỗi
        // lần đặt khung ngoài hoạt ảnh lật khung, ô cắt trượt mượt 0,25 giây qua tấm và Ove hiện thành mảnh ghép bốn khung.
        sprite.actions = ["contentsRect": NSNull(), "contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        rippleHost.actions = ["opacity": NSNull()]
        for s in [glow, drop] {
            s.shadowPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size), transform: nil)
            s.shadowOpacity = 0
        }
        glow.shadowColor = NSColor(Theme.orangeEnd).cgColor
        drop.shadowColor = NSColor.black.cgColor
        drop.shadowRadius = 10
        drop.shadowOffset = CGSize(width: 0, height: -5)
        #if DEVTOOLS
        // Móc thử: hẹn lại nhịp sống ngay (sau khi đổi debugLifeScale), không phải chờ hết lượt hẹn cũ.
        NotificationCenter.default.addObserver(forName: .oveDebugLife, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.observer != nil else { return }
                self.startLife()
            }
        }
        // Móc thử: giả lập rê chuột vào Ove ở cửa sổ chính, và diễn một nét mặt lúc rảnh theo tên.
        NotificationCenter.default.addObserver(forName: .oveDebugHover, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, self.observer != nil, let on = n.object as? Bool else { return }
                self.hovered = on
                self.hoverChanged()
            }
        }
        NotificationCenter.default.addObserver(forName: .oveDebugFidget, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, self.observer != nil, let f = (n.object as? String).flatMap(Fidget.init(rawValue:)) else { return }
                self.act([.fx(f)])
            }
        }
        #endif
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) không dùng") }

    // Để cú bấm đi thẳng tới nút linh vật bên ngoài.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let center = CGPoint(x: b.midX, y: b.midY)
        rippleHost.frame = b
        bodyLayer.bounds = b
        bodyLayer.position = center
        breather.frame = bodyLayer.bounds
        let s = size * lib.frameRatio
        sprite.frame = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
        for l in [glow, drop] {
            l.frame = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            // Chỉ cho bóng hiện ra ngoài mép đầu: kính ở mép trong suốt, bóng nằm dưới sẽ làm kính xỉn.
            let mask = CAShapeLayer()
            let pad: CGFloat = 60
            mask.frame = l.bounds.insetBy(dx: -pad, dy: -pad)
            let p = CGMutablePath()
            p.addRect(mask.bounds)
            p.addEllipse(in: CGRect(x: pad + 1, y: pad + 1, width: size - 2, height: size - 2))
            mask.path = p
            mask.fillRule = .evenOdd
            l.mask = mask
        }
        for r in ripples {
            r.bounds = CGRect(x: 0, y: 0, width: size * 2, height: size * 2)
            r.position = center
        }
        CATransaction.commit()
    }

    // MARK: Cấu hình từ SwiftUI

    func configure(_ input: Input) {
        guard lib.available else { return }
        if input.appEvents != (observer != nil) { listen(input.appEvents) }
        let first = !configured
        configured = true
        let old = mood
        let darkChanged = input.dark != dark || first
        let animChanged = input.animating != animating || input.still != still
        (dark, still) = (input.dark, input.still)
        if darkChanged {
            for r in ripples { r.contents = lib.ripple(dark: dark) }
            drop.shadowOpacity = dark ? 0.35 : 0.12
            // Lần đầu thì để enter() nạp trước rồi mới hiện.
            if !first, showing == .asleep && !inClip { showAsleep() }
        }
        if first {
            mood = input.mood
            animating = input.animating
            cue = input.cue
            enter(mood, from: nil)
        } else {
            if animChanged {
                animating = input.animating
                if live { resume() } else { freeze() }
            }
            if input.mood != old {
                mood = input.mood
                enter(mood, from: old)
            }
            if input.cue != cue {
                cue = input.cue
                story = input.story
                if mood != .asleep { bounce() }
            }
        }
        if input.hovered != hovered {
            hovered = input.hovered
            hoverChanged()
        }
        if input.gaze != gaze {
            gaze = input.gaze
            gazeChanged()
        }
        if first {
            after(1.2, alive: { true }) { [weak self] in self?.greet() }
        }
        if let p = input.poke, p != poke {
            poke = p
            // Lần đầu thì chờ view vào cửa sổ và hiện xong khung đầu đã.
            if first {
                after(0.35, alive: { true }) { [weak self] in self?.handle(p.action) }
            } else {
                handle(p.action)
            }
        }
    }

    private var live: Bool { animating && !still }
    private var awake: Bool { mood == .idle || mood == .listening }
    /// Đứng chờ ở bộ quay đầu, không bận đoạn nào: được chớp mắt, nhìn quanh, làm nét mặt.
    private var resting: Bool {
        guard live, awake, !inClip, held == nil, !acting, !gazing else { return false }
        if case .face = showing { return true }
        return false
    }

    private func listen(_ on: Bool) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard on else { return }
        observer = NotificationCenter.default.addObserver(forName: .oveReaction, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let r = (n.object as? String).flatMap(OveReaction.init(rawValue:)) else { return }
                self.react(r)
            }
        }
    }

    // MARK: Chuyển trạng thái

    private func enter(_ new: Mascot.Mood, from old: Mascot.Mood?) {
        moodGen += 1
        lifeGen += 1
        cancelScene()
        gazing = false
        let gen = moodGen
        after(0.8, alive: { [weak self] in self?.moodGen == gen }) { [weak self] in
            if self?.gaze != nil { self?.gazeChanged() }
        }
        // Nạp trước ở luồng phụ các tấm lần chuyển này cần, rồi mới chuyển: giải nén ngay trên luồng chính thì cả cửa sổ
        // khựng (bấm Bắt đầu đổi sang mặt đang chạy mất khoảng 340 ms).
        var need = [new == .idle ? "look-idle" : "look-live"]
        if new == .speaking { need.append("speak") }
        if new == .asleep, old != nil, old != .asleep { need.append(dark ? "yawn-dark" : "yawn-light") }
        if new == .asleep, old == nil || old == .speaking { need.append(dark ? "yawn-dark" : "yawn-light") }
        if old == .asleep, new != .asleep, new != .speaking { need.append(dark ? "wake-dark" : "wake-light") }
        // Lần đầu: hiện ngay mặt hiện tại, các tấm giữ sẵn còn lại nạp dần ở luồng phụ.
        if old == nil { after(1.5, alive: { true }) { [weak self] in self?.lib.prefetchAll(["look-idle", "look-live", "speak"]) {} } }
        guard lib.has(need) else {
            lib.prefetchAll(Array(Set(need))) { [weak self] in
                guard let self, self.moodGen == gen else { return }
                self.enterLoaded(new, from: old)
            }
            return
        }
        enterLoaded(new, from: old)
    }

    private func enterLoaded(_ new: Mascot.Mood, from old: Mascot.Mood?) {
        tickling = false
        tickleLooping = false
        // Đang làm dở nét mặt thì tua ngược về mặt thường, đang nghiêng đầu nhìn quanh thì quay về nhìn thẳng, rồi mới chuyển:
        // hai hình khác tư thế mờ chồng lên nhau thì lộ hai mặt cùng lúc.
        if inClip, showing == .clip, rewindable, live {
            let gen = moodGen
            rewind { [weak self] in
                guard let self, self.moodGen == gen else { return }
                self.enterNow(new, from: old)
            }
            return
        }
        if angle != .front, case .face = showing, live, !inClip {
            let gen = moodGen
            turn(to: .front) { [weak self] in
                guard let self, self.moodGen == gen else { return }
                self.enterNow(new, from: old)
            }
            return
        }
        enterNow(new, from: old)
    }

    private func enterNow(_ new: Mascot.Mood, from old: Mascot.Mood?) {
        token += 1
        let other = new == .idle ? "look-live" : "look-idle"
        if sheetName != other { lib.release(other) }
        // Đọc xong: miệng khép nốt theo vòng đọc, sóng lặn dần, quầng cam nhạt dần rồi mới chuyển mặt.
        let finishing = old == .speaking && new != .speaking && live && showing == .loop
        updateGlow(slow: finishing)
        updateMotion(fadeRipples: finishing)
        startLife()
        switch new {
        case .asleep:
            if finishing {
                finishSpeaking { [weak self] in self?.showAsleep(fade: true, duration: 0.4) }
            } else if let old, old != .asleep, old != .speaking, live {
                // Ngáp chỉ khi tắt giọng đọc lúc đang thức; vừa đọc xong câu thử giọng mà giọng đang tắt thì về ngủ luôn.
                playClip(dark ? "yawn-dark" : "yawn-light", fade: true) { [weak self] in self?.showAsleep() }
            } else {
                showAsleep(fade: old != nil)
            }
        case .speaking:
            // Câu mới tới lúc miệng đang khép dở sau câu trước: đọc tiếp từ đúng khung đang hiện, không giật.
            startSpeaking(from: showing == .loop ? currentSpeakFrame() : 0)
        case .idle, .listening:
            if finishing {
                finishSpeaking { [weak self] in
                    guard let self else { return }
                    self.showFace(fade: true, duration: 0.3)
                    self.settle()
                    self.afterSpeech()
                }
            } else if old == .asleep, live {
                playClip(dark ? "wake-dark" : "wake-light", fade: false) { [weak self] in
                    self?.showFace(fade: true)
                    self?.flushSoon()
                }
            } else {
                showFace(fade: old != nil)
                if old != nil { flushSoon() }
            }
        }
    }

    private var face: String { mood == .idle ? "look-idle" : "look-live" }

    private func showAsleep(fade: Bool = false, duration: Double = 0.22) {
        inClip = false
        showing = .asleep
        guard let s = setSheet(dark ? "yawn-dark" : "yawn-light", fade: fade, duration: duration, at: { $0.last }) else { return }
        sprite.removeAnimation(forKey: "frames")
        sprite.contentsRect = s.rect(s.last)
    }

    private func startSpeaking(from frame: Int = 0) {
        // Từ mặt ngủ (nghe thử giọng lúc giọng đọc đang tắt) thì mờ chậm hơn: hai mặt khác màu hẳn.
        let fromSleep = showing == .asleep
        inClip = false
        showing = .loop
        guard let s = setSheet("speak", fade: true, duration: fromSleep ? 0.4 : 0.22, at: { _ in frame }) else { return }
        guard live else {
            sprite.removeAnimation(forKey: "frames")
            sprite.contentsRect = s.rect(0)
            return
        }
        speakStart = CACurrentMediaTime() - Double(frame) / lib.fps
        run((0..<s.count).map { (frame + $0) % s.count }, sheet: s, repeating: true)
    }

    private func currentSpeakFrame() -> Int {
        let n = lib.sheet("speak")?.count ?? 1
        return max(0, Int((CACurrentMediaTime() - speakStart) * lib.fps)) % n
    }

    /// Chạy vòng đọc tới khung miệng gần khép kế tiếp (nhiều nhất khoảng 0,3 giây) rồi mới gọi `next`.
    private func finishSpeaking(then next: @escaping () -> Void) {
        guard let s = lib.sheet("speak") else { next(); return }
        let cur = currentSpeakFrame()
        let rest = s.rest ?? [0]
        let stop = rest.first { $0 >= cur } ?? ((rest.first ?? 0) + s.count)
        run((cur...stop).map { $0 % s.count }, sheet: s, done: next)
    }

    /// Mặt chờ hoặc mặt đang chạy (theo trạng thái hiện tại, hoặc `name` nếu có), nhìn thẳng, mở mắt.
    private func showFace(fade: Bool, duration: Double = 0.22, name: String? = nil) {
        let name = name ?? face
        inClip = false
        showing = .face(name)
        angle = .front
        guard let s = setSheet(name, fade: fade, duration: duration, at: { [lib] _ in lib.lookFrame(.front) }) else { return }
        sprite.removeAnimation(forKey: "frames")
        sprite.contentsRect = s.rect(lib.lookFrame(.front))
    }

    private func showHeld(_ r: OveReaction) {
        inClip = false
        showing = .clip
        guard let s = setSheet(mood == .idle ? r.rawValue + "-idle" : r.rawValue, fade: false, at: { $0.peak }) else { return }
        sprite.removeAnimation(forKey: "frames")
        sprite.contentsRect = s.rect(s.peak)
    }

    // MARK: Khung hình

    /// Đổi sang tấm `name`, hiện khung `frame`. Gỡ hoạt ảnh lật khung cũ, đặt hình và ô cắt trong cùng một lần cập nhật:
    /// tách làm hai lần thì có lúc hệ thống vẽ hình mới với ô cắt (hay hoạt ảnh) của tấm cũ, lộ một khung có nhiều mặt hoặc
    /// mặt bị kéo dãn (hay gặp khi đổi tấm ngay sau một hoạt ảnh vừa xong).
    ///
    /// Mờ chuyển: ảnh cũ mà CATransition chụp là giá trị gốc của lớp hình trong lần cập nhật trước, không tính hoạt ảnh lật
    /// khung. Lúc một đoạn đang chạy hay vừa chạy xong trong cùng lượt (quay đầu về rồi sang mặt đang chạy, đọc xong rồi về
    /// mặt thường, tỉnh dậy), giá trị gốc là khung đầu của đoạn đó, nên Ove lóe lại tư thế cũ rồi mờ chồng lên tư thế mới,
    /// lộ hai cặp mắt (1.1.81, bấm Bắt đầu lúc Ove đang nhìn xuống nút). Vì vậy chốt khung đang hiện (`shownRect`) làm giá
    /// trị gốc và đẩy lần cập nhật đó đi trước, rồi mới mờ.
    @discardableResult
    private func setSheet(_ name: String, fade: Bool, duration: Double = 0.22,
                          at frame: (OveLibrary.Sheet) -> Int = { _ in 0 }) -> OveLibrary.Sheet? {
        guard let s = lib.sheet(name) else { return nil }
        if sheetName != name {
            let fading = fade && live
            if fading {
                let shown = shownRect()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                sprite.removeAnimation(forKey: "frames")
                sprite.contentsRect = shown
                CATransaction.commit()
                CATransaction.flush()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if fading {
                let t = CATransition()
                t.type = .fade
                t.duration = duration
                sprite.add(t, forKey: "fade")
            }
            sprite.removeAnimation(forKey: "frames")
            sprite.contents = s.image
            sprite.contentsRect = s.rect(frame(s))
            CATransaction.commit()
            // Chỉ giữ tấm đang chiếu và bộ quay đầu của mặt hiện tại (để quay về sau mỗi đoạn biểu cảm không phải đọc lại).
            if let old = sheetName, old != face { lib.release(old) }
            sheetName = name
        }
        return s
    }

    /// Ô cắt của khung đang hiện thật. Đang lật khung thì tính theo thời gian của lần lật (lúc đó giá trị gốc là khung đầu),
    /// không thì là giá trị gốc. Không đọc `presentation()`: nó giữ trạng thái của lần vẽ trước, nên vừa đổi tấm trong cùng
    /// lượt (tua nét bị cù về mặt thường rồi ngáp ngay) thì ô cắt của tấm cũ bị đặt lên tấm mới, lộ một khung nhiều mặt rồi
    /// mờ dần như bóng ma (1.1.82, rê chuột vào Ove rồi bấm cho ngủ).
    private func shownRect() -> CGRect {
        if sprite.animation(forKey: "frames") != nil, let r = lastRun, !r.frames.isEmpty,
           let s = sheetName.flatMap({ lib.sheet($0) }) {
            var i = Int((CACurrentMediaTime() - r.start) * lib.fps)
            i = r.repeating ? i % r.frames.count : min(max(0, i), r.frames.count - 1)
            return s.rect(r.frames[i])
        }
        return sprite.contentsRect
    }

    /// Lật các khung `frames` của tấm hiện tại theo nhịp của bộ hình; xong thì gọi `done` (bị ngắt thì không gọi).
    ///
    /// Giá trị gốc của lớp hình đặt bằng khung đầu, hoạt ảnh giữ khung cuối khi chạy xong, rồi mới chốt khung cuối và gỡ hoạt
    /// ảnh. Đặt giá trị gốc bằng khung cuối như trước thì có lúc hệ thống vẽ giá trị gốc một khung trước khi hoạt ảnh kịp
    /// chạy: khung cuối (mặt cười của đoạn bị cù, đầu ngoái hẳn của lần quay đầu) lóe lên giữa hai khung thường.
    private func run(_ frames: [Int], sheet s: OveLibrary.Sheet, repeating: Bool = false, done: (() -> Void)? = nil) {
        token += 1
        let mine = token
        guard let first = frames.first, let lastFrame = frames.last else { done?(); return }
        let anim = CAKeyframeAnimation(keyPath: "contentsRect")
        anim.values = frames.map { NSValue(rect: s.rect($0)) }
        anim.calculationMode = .discrete
        anim.duration = Double(frames.count) / lib.fps
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        anim.setValue(mine, forKey: "oveRun")
        if repeating { anim.repeatCount = .infinity }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Chốt khung cuối nếu hoạt ảnh này vẫn đang gắn trên lớp hình (chưa bị lần lật khác thay).
                if (self.sprite.animation(forKey: "frames")?.value(forKey: "oveRun") as? Int) == mine {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.sprite.contentsRect = s.rect(lastFrame)
                    self.sprite.removeAnimation(forKey: "frames")
                    CATransaction.commit()
                }
                guard self.token == mine else { return }
                done?()
            }
        }
        sprite.contentsRect = s.rect(first)
        sprite.add(anim, forKey: "frames")
        CATransaction.commit()
        lastRun = (frames, CACurrentMediaTime(), repeating)
    }

    private func playClip(_ name: String, from a: Int = 0, to b: Int? = nil, fade: Bool, done: @escaping () -> Void) {
        inClip = true
        showing = .clip
        guard let s = setSheet(name, fade: fade, at: { _ in a }) else { inClip = false; done(); return }
        let end = min(b ?? s.last, s.last)
        guard live, a <= end else { sprite.contentsRect = s.rect(end); done(); return }
        run(Array(a...end), sheet: s, done: done)
    }

    // MARK: Quay đầu

    /// Quay đầu tới `target` theo dãy khung của bộ quay đầu (mỗi khung 1/24 giây, chậm ở hai đầu): đang nhìn hướng khác thì
    /// chạy ngược về nhìn thẳng trước rồi mới sang. Hướng không có trong bộ thì coi như nhìn thẳng.
    private func turn(to target: OveAngle, done: @escaping () -> Void) {
        guard let s = lib.sheet(face) else { done(); return }
        let goal = lib.lookPath(to: target) == nil ? .front : target
        // Tính từ khung đang hiện thật: lần quay trước có thể bị ngắt giữa chừng, tính từ đích của nó thì đầu nhảy cóc.
        let (cur, idx) = shownLookPosition()
        var frames: [Int] = []
        if cur == goal, goal != .front, let path = lib.lookPath(to: goal) {
            frames = Array(path[min(path.count, idx + 1)...])
        } else {
            if cur != .front, let back = lib.lookPath(to: cur) { frames += back[0..<max(0, idx)].reversed() + [lib.lookFrame(.front)] }
            if let go = lib.lookPath(to: goal) { frames += go }
        }
        angle = goal
        guard live, !frames.isEmpty else {
            if !live {
                sprite.removeAnimation(forKey: "frames")
                sprite.contentsRect = s.rect(lib.lookFrame(goal))
            }
            done()
            return
        }
        run(frames, sheet: s, done: done)
    }

    /// Hướng và bước đang hiện trên bộ quay đầu: đang lật khung thì đọc khung đang chiếu, không thì theo `angle`.
    private func shownLookPosition() -> (OveAngle, Int) {
        if case .face = showing, let r = lastRun, !r.frames.isEmpty, sprite.animation(forKey: "frames") != nil {
            var i = Int((CACurrentMediaTime() - r.start) * lib.fps)
            i = r.repeating ? i % r.frames.count : min(max(0, i), r.frames.count - 1)
            if let pos = lib.lookPosition(of: r.frames[i]) { return pos }
        }
        if angle == .front { return (.front, -1) }
        return (angle, (lib.lookPath(to: angle)?.count ?? 1) - 1)
    }

    /// Đang nhìn quanh thì quay về nhìn thẳng trước, rồi mới làm `done`.
    private func toFront(_ done: @escaping () -> Void) {
        if angle != .front, case .face = showing, live {
            turn(to: .front, done: done)
        } else {
            angle = .front
            done()
        }
    }

    // MARK: Nhịp sống

    /// Nét mặt lúc rảnh, mỗi nét là một đoạn `fx-<tên>` dựng từ mặt chờ (khung đầu và khung cuối trùng mặt nhìn thẳng).
    private enum Fidget: String { case excited, wink, hum, shy, curious, sneeze, doze, surprised }

    /// Một nhịp trong cảnh: nhìn về một hướng rồi giữ (giây), hoặc làm một nét mặt.
    private enum Beat {
        case look(OveAngle, Double)
        case fx(Fidget)
    }

    /// Cảnh lúc rảnh đọc từ ove.json (bản gốc ở `OverSubHead.Clips.SCENES` trong Tools/Ove/oversub-head.js, cùng nguồn
    /// với prototype trên Claude Design). Thiếu thì chỉ chớp mắt.
    private static let script: (small: [[Beat]], scenes: [[Beat]], looks: [[Beat]], pace: OveLibrary.Scenes.Pace?) = {
        guard let sc = OveLibrary.shared.scenes else {
            DebugLog.write("Ove: ove.json không có danh sách cảnh lúc rảnh")
            return ([], [], [], nil)
        }
        func beats(_ list: [[OveLibrary.Scenes.Beat]]) -> [[Beat]] {
            list.map { row in
                row.compactMap { b -> Beat? in
                    if let l = b.look, l.count == 2 { return .look(OveAngle(yaw: l[0], pitch: l[1]), b.hold ?? 1) }
                    if let f = b.fx.flatMap(Fidget.init(rawValue:)) { return .fx(f) }
                    return nil
                }
            }.filter { !$0.isEmpty }
        }
        let small = beats(sc.small)
        return (small, beats(sc.scenes), Array(small.prefix(sc.looks)), sc.pace)
    }()
    private static var small: [[Beat]] { script.small }
    private static var scenes: [[Beat]] { script.scenes }
    private static var looks: [[Beat]] { script.looks }

    /// Khoảng ngẫu nhiên lấy từ nhịp trong ove.json, thiếu thì dùng mặc định.
    private static func span(_ key: KeyPath<OveLibrary.Scenes.Pace, [Double]>, _ fallback: ClosedRange<Double>) -> ClosedRange<Double> {
        guard let r = script.pace?[keyPath: key], r.count == 2, r[0] <= r[1] else { return fallback }
        return r[0]...r[1]
    }

    private var acting = false
    private var sceneGen = 0
    private var beatCount = 0
    private var recentScenes: [Int] = []
    private var recentSmall: [Int] = []
    private var hiddenSince: Date?

    /// Hệ số rút ngắn nhịp cho móc thử.
    private var debugScale: Double {
        #if DEVTOOLS
        return Self.debugLifeScale
        #else
        return 1
        #endif
    }

    /// Chớp mắt (2,8 đến 6,2 giây một lần). Lúc rảnh: cứ 5 đến 9 giây một cử động nhỏ, cứ ba lần thì một cảnh đời thường.
    /// Đang nhận phụ đề: 30 đến 60 giây nhìn quanh một lần, khoảng 4 phút vui một lần, để không kéo mắt khỏi game.
    /// Đều là hẹn giờ nên giữa hai lần không tốn gì; cửa sổ bị che thì dừng hẳn.
    private func startLife() {
        lifeGen += 1
        guard live, awake, held == nil else { return }
        let gen = lifeGen
        blinkLoop(gen)
        if mood == .idle {
            idleLoop(gen)
        } else {
            lookLoop(gen)
            happyLoop(gen)
        }
    }

    private func blinkLoop(_ gen: Int) {
        after(Double.random(in: Self.span(\.blink, 2.8...6.2)), alive: { [weak self] in self?.lifeGen == gen }) { [weak self] in
            self?.blink()
            self?.blinkLoop(gen)
        }
    }

    /// Chớp mắt ở hướng đang nhìn, cả lúc đang giữ ánh nhìn trong một cảnh.
    private func blink() {
        guard live, awake, held == nil, !inClip, case .face = showing, sprite.animation(forKey: "frames") == nil,
              let s = lib.sheet(face) else { return }
        let o = lib.lookFrame(angle), c = lib.lookFrame(angle, closed: true)
        var frames = [c, c, o]
        if Int.random(in: 0..<5) == 0 { frames += [o, o, c, c, o] }   // thỉnh thoảng chớp đôi
        run(frames, sheet: s)
    }

    private func idleLoop(_ gen: Int) {
        after(Double.random(in: Self.span(\.small, 5...9)) * debugScale, alive: { [weak self] in self?.lifeGen == gen }) { [weak self] in
            guard let self, !Self.small.isEmpty else { return }
            if self.resting, self.sprite.animation(forKey: "frames") == nil {
                self.beatCount += 1
                if self.beatCount % max(1, Self.script.pace?.sceneEvery ?? 3) == 0, !Self.scenes.isEmpty {
                    self.startScene(Self.pick(Self.scenes, recent: &self.recentScenes))
                } else {
                    self.startScene(Self.pick(Self.small, recent: &self.recentSmall))
                }
            }
            self.idleLoop(gen)
        }
    }

    private func lookLoop(_ gen: Int) {
        after(Double.random(in: Self.span(\.listenLook, 30...60)) * debugScale, alive: { [weak self] in self?.lifeGen == gen }) { [weak self] in
            guard let self, !Self.looks.isEmpty else { return }
            if self.resting, self.sprite.animation(forKey: "frames") == nil {
                self.startScene(Self.pick(Self.looks, recent: &self.recentSmall))
            }
            self.lookLoop(gen)
        }
    }

    private func happyLoop(_ gen: Int) {
        after(Double.random(in: Self.span(\.listenHappy, 200...320)) * debugScale, alive: { [weak self] in self?.lifeGen == gen }) { [weak self] in
            guard let self else { return }
            if self.resting { self.play(.happy) }
            self.happyLoop(gen)
        }
    }

    /// Chọn ngẫu nhiên một mục, tránh hai mục vừa làm.
    private static func pick(_ list: [[Beat]], recent: inout [Int]) -> [Beat] {
        let fresh = list.indices.filter { !recent.contains($0) }
        let i = fresh.randomElement() ?? 0
        recent = Array((recent + [i]).suffix(2))
        return list[i]
    }

    /// Diễn một cảnh: các nhịp nối nhau, xong thì nhìn thẳng lại. Cảnh mới, rê chuột, sự kiện của app hay đổi trạng thái
    /// đều ngắt cảnh đang diễn.
    private func startScene(_ beats: [Beat]) {
        sceneGen += 1
        acting = true
        perform(beats[...], scene: sceneGen, mood: moodGen)
    }

    private func cancelScene() {
        sceneGen += 1
        acting = false
    }

    private func perform(_ beats: ArraySlice<Beat>, scene: Int, mood gen: Int) {
        guard sceneGen == scene, moodGen == gen, live, awake, held == nil else {
            if sceneGen == scene { acting = false }
            return
        }
        let alive: @MainActor () -> Bool = { [weak self] in self?.sceneGen == scene && self?.moodGen == gen }
        guard let beat = beats.first else {
            turn(to: .front) { [weak self] in
                guard let self, alive() else { return }
                self.acting = false
                self.flushSoon()
            }
            return
        }
        let rest = beats.dropFirst()
        switch beat {
        case .look(let target, let hold):
            turn(to: target) { [weak self] in
                self?.after(hold * Double.random(in: 0.8...1.25), alive: alive) { [weak self] in
                    self?.perform(rest, scene: scene, mood: gen)
                }
            }
        case .fx(let f):
            // Nét mặt chỉ dựng cho mặt chờ; đang nhận phụ đề thì bỏ qua nhịp này.
            guard mood == .idle else { perform(rest, scene: scene, mood: gen); return }
            let name = "fx-" + f.rawValue
            lib.prefetch(name) { [weak self] in
                guard let self, alive() else { return }
                self.toFront { [weak self] in
                    guard let self, alive() else { return }
                    // Khung đầu của đoạn trùng mặt nhìn thẳng nên chuyển thẳng, không mờ chồng.
                    self.playClip(name, fade: false) { [weak self] in
                        guard let self else { return }
                        self.showFace(fade: false)
                        self.perform(rest, scene: scene, mood: gen)
                    }
                }
            }
        }
    }

    /// Ngắt cảnh đang diễn để làm việc khác ngay (rê chuột, sự kiện của app, việc hộp thoại nhờ): nét mặt dở dang thì mờ
    /// về mặt thường, đang nhìn đi chỗ khác thì quay về nhìn thẳng rồi mới làm `then`.
    private func interrupt(_ then: @escaping () -> Void) {
        cancelScene()
        gazing = false
        if inClip, showing == .clip, rewindable {
            rewind { [weak self] in self?.toFront(then) }
        } else {
            toFront(then)
        }
    }

    /// Đoạn đang hiện có khung đầu trùng mặt nhìn thẳng (nét mặt lúc rảnh, bị cù, biểu cảm theo sự kiện): tua ngược được.
    private var rewindable: Bool {
        guard let n = sheetName else { return false }
        return n.hasPrefix("fx-") || n.hasPrefix("tickle-") || OveReaction.allCases.contains { n == $0.rawValue || n == $0.rawValue + "-idle" }
    }

    /// Tua ngược nhanh đoạn đang làm dở về khung đầu (mặt nhìn thẳng), nhiều nhất khoảng 12 khung, rồi về bộ quay đầu.
    /// Mờ chồng thẳng sang mặt thường thì lộ hai mặt cùng lúc.
    ///
    /// Về đúng mặt mà đoạn được dựng từ đó, không theo trạng thái hiện tại: đổi trạng thái giữa chừng (đang bị cù thì bấm
    /// cho ngủ) thì trạng thái đã đổi trước khi tua, lấy mặt theo trạng thái là nhảy sang mặt đang chạy đỏ đậm rồi mới mờ
    /// sang ngáp.
    private func rewind(_ done: @escaping () -> Void) {
        let back = sheetName.map(Self.standingFace(of:)) ?? face
        guard let r = lastRun, !r.frames.isEmpty, let s = sheetName.flatMap({ lib.sheet($0) }) else {
            showFace(fade: false, name: back)
            done()
            return
        }
        var i = Int((CACurrentMediaTime() - r.start) * lib.fps)
        i = r.repeating ? i % r.frames.count : min(max(0, i), r.frames.count - 1)
        let from = r.frames[i]
        let step = max(2, Int((Double(from) / 12).rounded(.up)))
        let frames = Array(stride(from: from, to: 0, by: -step)) + [0]
        inClip = true
        run(frames, sheet: s) { [weak self] in
            self?.showFace(fade: false, name: back)
            done()
        }
    }

    /// Mặt đứng yên mà đoạn `name` được dựng từ đó: nét mặt lúc rảnh (`fx-…`) và các đoạn `…-idle` từ mặt chờ, còn lại từ mặt
    /// đang chạy.
    private static func standingFace(of name: String) -> String {
        name.hasPrefix("fx-") || name.hasSuffix("-idle") ? "look-idle" : "look-live"
    }

    /// Chào người dùng: lúc mở app hay lúc quay lại cửa sổ sau một lúc vắng.
    private func greet() {
        guard mood == .idle, resting else { return }
        startScene(Bool.random() ? [.fx(.wink)] : [.fx(.excited)])
    }

    // MARK: Rê chuột

    private var hovered = false
    /// Đang bị cù: từ lúc vào đoạn tới khi chạy xong đoạn ra.
    private var tickling = false
    private var tickleLooping = false
    private var tickleStart: CFTimeInterval = 0
    private var hoverEnters: [Date] = []
    private var tickleSheet: String { mood == .idle ? "tickle-idle" : "tickle-live" }

    /// Rê chuột vào thì Ove như bị cù: nheo mắt >< cười khúc khích, lắc lư tới khi chuột rời đi. Rê vào lại lúc đang cười
    /// thì Ove nảy lên; rê qua lại từ ba lần trong 8 giây thì lúc rời ra Ove đỏ mặt ngượng. Đang đọc, đang ngủ, đang giữ
    /// nét mặt hay đang làm biểu cảm theo sự kiện thì không phản ứng.
    private func hoverChanged() {
        if hovered {
            hoverEnters = hoverEnters.filter { Date().timeIntervalSince($0) < 8 } + [Date()]
            if tickling { bounce(); return }
            guard live, awake, held == nil, resting || acting || gazing else { return }
            interrupt { [weak self] in self?.startTickle() }
        } else if tickleLooping {
            endTickle()
        }
    }

    private func startTickle() {
        let gen = moodGen, name = tickleSheet
        tickling = true
        inClip = true
        lib.prefetch(name) { [weak self] in
            guard let self, self.moodGen == gen, self.tickling else { return }
            guard self.hovered, let s = self.lib.sheet(name), let p = s.parts, p.count == 2 else {
                self.tickling = false
                self.backToFace()
                return
            }
            self.playClip(name, to: p[0] - 1, fade: false) { [weak self] in
                guard let self, self.tickling else { return }
                if self.hovered {
                    self.tickleStart = CACurrentMediaTime()
                    self.tickleLooping = true
                    self.run(Array(p[0]..<p[1]), sheet: s, repeating: true)
                } else {
                    self.endTickle()
                }
            }
        }
    }

    /// Rời chuột: chạy nốt vòng cười tới pha đầu (nhiều nhất 0,5 giây) rồi đoạn ra.
    private func endTickle() {
        guard tickling, sheetName == tickleSheet, let s = lib.sheet(tickleSheet), let p = s.parts, p.count == 2 else {
            tickling = false
            tickleLooping = false
            backToFace()
            return
        }
        var frames: [Int] = []
        if tickleLooping {
            let n = p[1] - p[0]
            let cur = max(0, Int((CACurrentMediaTime() - tickleStart) * lib.fps)) % n
            frames += (cur..<n).map { p[0] + $0 }
        }
        frames += Array(p[1]..<s.count)
        tickleLooping = false
        let shy = mood == .idle && hoverEnters.filter { Date().timeIntervalSince($0) < 8 }.count >= 3
        run(frames, sheet: s) { [weak self] in
            guard let self else { return }
            self.tickling = false
            self.showFace(fade: false)
            if shy {
                self.hoverEnters.removeAll()
                self.startScene([.fx(.shy)])
            } else {
                self.flushSoon()
            }
        }
    }

    // MARK: Nhìn theo nút

    /// Đang nhìn theo nút người dùng rê chuột vào.
    private var gazing = false
    private var gaze: OveAngle?
    /// Tăng mỗi lần chuột vào, ra một nút: lượt hẹn của lần trước tự bỏ.
    private var gazeGen = 0

    /// Rê chuột vào nút Phụ đề, Dịch màn hình hay Bắt đầu thì Ove quay đầu nhìn theo (ngắt cảnh lúc rảnh), giữ ánh nhìn và
    /// vẫn chớp mắt; rời ra thì nhìn thẳng lại. Đang đọc, đang ngủ, đang bị cù, đang giữ nét mặt hay đang làm biểu cảm theo
    /// sự kiện thì không quay.
    ///
    /// Chuột phải dừng trên nút một nhịp (0,3 giây) Ove mới quay: lướt chuột ngang qua thì quay nửa chừng rồi quay về, trông
    /// giật (người dùng nhận xét ở 1.1.81). Đang nhìn một nút mà chuyển sang nút khác thì chờ ngắn hơn (0,15 giây); rời khỏi
    /// nút 0,4 giây mới nhìn thẳng lại, để lia từ nút này sang nút kia không quay về giữa rồi lại quay đi.
    private func gazeChanged() {
        gazeGen += 1
        let gen = moodGen, mine = gazeGen
        let alive: @MainActor () -> Bool = { [weak self] in self?.moodGen == gen && self?.gazeGen == mine }
        if let g = gaze {
            after(gazing ? 0.15 : 0.3, alive: alive) { [weak self] in
                guard let self, self.live, self.awake, self.held == nil, !self.tickling,
                      self.resting || self.acting || self.gazing else { return }
                if self.gazing {
                    self.turn(to: g) {}
                } else {
                    self.interrupt { [weak self] in
                        guard let self, alive() else { return }
                        self.gazing = true
                        self.turn(to: g) {}
                    }
                }
            }
        } else if gazing {
            after(0.4, alive: alive) { [weak self] in
                guard let self, self.gazing else { return }
                self.turn(to: .front) { [weak self] in
                    guard let self, self.gaze == nil else { return }
                    self.gazing = false
                    self.flushSoon()
                }
            }
        }
    }

    // MARK: Biểu cảm

    private func handle(_ action: OvePoke.Action) {
        // Đang giữ nét mặt (hộp thoại) mà được nhờ việc khác: tua ngược nét mặt về mặt thường trước.
        if held != nil, action != .calm, !isHold(action) {
            releaseHeld { [weak self] in self?.handle(action) }
            return
        }
        switch action {
        case .express(let r):
            react(r)
        case .hold(let r):
            // Bật giảm chuyển động thì hiện luôn khung đỉnh của nét mặt, không chạy đoạn.
            guard live else { held = r; showHeld(r); return }
            if held != nil {
                releaseHeld { [weak self] in self?.play(r, hold: true) }
            } else if acting {
                interrupt { [weak self] in self?.play(r, hold: true) }
            } else {
                play(r, hold: true)
            }
        case .look(let y, let p, let s):
            act([.look(OveAngle(yaw: y, pitch: p), s)])
        case .cheer(let level):
            // Mức tiền càng cao Ove càng vui; không mức nào làm Ove buồn để khỏi giống nài.
            act(level <= 1 ? [.fx(.wink)] : level == 2 ? [.fx(.excited)] : [.fx(.excited), .fx(.shy)])
        case .calm:
            releaseHeld {}
        }
    }

    private func isHold(_ action: OvePoke.Action) -> Bool {
        if case .hold = action { return true }
        return false
    }

    /// Thôi giữ nét mặt: tua ngược về mặt thường rồi sống lại như thường.
    private func releaseHeld(_ then: @escaping () -> Void) {
        guard held != nil else { then(); return }
        held = nil
        let gen = moodGen
        let finish: () -> Void = { [weak self] in
            guard let self, self.moodGen == gen else { return }
            self.startLife()
            self.flushSoon()
            then()
        }
        if live, rewindable { rewind(finish) } else { showFace(fade: false); finish() }
    }

    /// Diễn ngay một cảnh do view chứa nhờ, ngắt cảnh đang diễn nếu có.
    private func act(_ beats: [Beat]) {
        guard live, awake, held == nil, !tickling, resting || acting else { return }
        interrupt { [weak self] in self?.startScene(beats) }
    }

    /// Một chuyện vừa xảy ra: Ove đang rảnh (hay đang diễn cảnh lúc rảnh) thì làm nét mặt ngay, đang bận (đọc, ngáp, đang bị
    /// cù, đang làm nét mặt khác) thì xếp chờ.
    private func react(_ r: OveReaction) {
        // Cùng một chuyện lặp lại liên tục (lỗi dịch từng câu) thì 20 giây chỉ làm một lần.
        if let t = lastPlayed[r], Date().timeIntervalSince(t) < 20 { return }
        if acting, !tickling, live, awake {
            interrupt { [weak self] in self?.react(r) }
            return
        }
        if resting { play(r); return }
        if let q = queued, q.reaction.weight > r.weight, Date().timeIntervalSince(q.at) < 8 { return }
        queued = (r, Date())
    }

    private func flushSoon() {
        let gen = moodGen
        after(0.5, alive: { [weak self] in self?.moodGen == gen }) { [weak self] in self?.flush() }
    }

    @discardableResult
    private func flush() -> Bool {
        guard let q = queued, resting else { return false }
        queued = nil
        guard Date().timeIntervalSince(q.at) < 8 else { return false }
        play(q.reaction)
        return true
    }

    /// Làm một nét mặt: quay về nhìn thẳng, chạy đoạn biểu cảm rồi về mặt thường, hoặc dừng ở đỉnh biểu cảm nếu `hold`.
    /// Mỗi biểu cảm có bản mặt chờ (`-idle`) và bản mặt đang chạy.
    private func play(_ r: OveReaction, hold: Bool = false) {
        let gen = moodGen
        let name = mood == .idle ? r.rawValue + "-idle" : r.rawValue
        lib.prefetch(name) { [weak self] in
            guard let self, self.moodGen == gen, self.resting else { return }
            self.lastPlayed[r] = Date()
            self.lifeGen += 1
            if hold { self.held = r }
            self.inClip = true
            self.toFront { [weak self] in
                guard let self, self.moodGen == gen else { return }
                // Khung đầu, khung cuối của đoạn trùng mặt đứng yên của đúng mặt (chờ hay đang chạy): chuyển thẳng.
                if hold {
                    let peak = self.lib.sheet(name)?.peak
                    self.playClip(name, to: peak, fade: false) { [weak self] in self?.inClip = false }
                } else {
                    self.playClip(name, fade: false) { [weak self] in self?.backToFace(fade: false) }
                }
            }
        }
    }

    private func backToFace(fade: Bool = true) {
        showFace(fade: fade)
        startLife()
        flushSoon()
    }

    /// Đọc xong và không có câu nối tiếp trong 1,2 giây: làm biểu cảm đang chờ (sự kiện của app); không có thì phản ứng
    /// theo câu vừa đọc, nhiều nhất một lần mỗi phút để khỏi rối mắt khi đang chơi.
    private func afterSpeech() {
        let gen = moodGen
        after(1.2, alive: { [weak self] in self?.moodGen == gen }) { [weak self] in
            guard let self else { return }
            let r = self.story
            self.story = nil
            if self.flush() { return }
            guard let r, self.resting, Date().timeIntervalSince(self.lastStoryAt) >= 60 else { return }
            self.lastStoryAt = Date()
            DebugLog.write("Ove: \(r.rawValue) (theo câu vừa đọc)")
            self.play(r)
        }
    }

    // MARK: Hẹn giờ

    private func after(_ seconds: Double, alive: @escaping @MainActor () -> Bool, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                guard alive() else { return }
                action()
            }
        }
    }

    // MARK: Hoạt ảnh nền

    /// Quầng cam: đọc xong thì nhạt dần chậm (0,9 giây) cùng lúc sóng lặn, các lần đổi khác chuyển nhanh.
    private func updateGlow(slow: Bool = false) {
        let o: Float = mood == .speaking ? 0.55 : mood == .listening ? 0.32 : mood == .idle ? 0.14 : 0
        let radius: CGFloat = mood == .speaking ? 26 : 16
        if slow {
            let fromO = glow.presentation()?.shadowOpacity ?? glow.shadowOpacity
            let fromR = glow.presentation()?.shadowRadius ?? glow.shadowRadius
            for (key, from, to) in [("shadowOpacity", Double(fromO), Double(o)), ("shadowRadius", Double(fromR), Double(radius))] {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = from
                a.toValue = to
                a.duration = 0.9
                a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                glow.add(a, forKey: key)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(slow)
        glow.shadowOpacity = o
        glow.shadowRadius = radius
        glow.shadowOffset = CGSize(width: 0, height: -6)
        CATransaction.commit()
    }

    /// Thở chậm khi ngủ, nhún rất nhẹ khi thức, gợn sóng nước khi đang đọc: đều chạy bằng Core Animation.
    private func updateMotion(fadeRipples: Bool = false) {
        guard live else {
            breather.removeAllAnimations()
            stopRipples()
            return
        }
        // Đang chạy đúng kiểu thì giữ nguyên, để đổi trạng thái không làm nhịp nhún giật về đầu.
        let kind = mood == .asleep ? "breath" : "bob"
        if breather.animation(forKey: kind) == nil {
            breather.removeAllAnimations()
            let a = CABasicAnimation(keyPath: kind == "breath" ? "transform.scale" : "transform.translation.y")
            if kind == "breath" {
                a.fromValue = 1
                a.toValue = 1.012
                a.duration = 1.85
            } else {
                a.fromValue = -size * 0.006
                a.toValue = size * 0.006
                a.duration = 2.4
            }
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breather.add(a, forKey: kind)
        }
        if mood == .speaking {
            startRipples()
        } else if fadeRipples, ripples[0].animation(forKey: "ripple") != nil {
            // Đọc xong: sóng đang loang thì loang tiếp và mờ dần trong 1,6 giây rồi mới tắt.
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = rippleHost.presentation()?.opacity ?? 1
            a.toValue = 0
            a.duration = 1.6
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.mood != .speaking else { return }
                    self.stopRipples()
                }
            }
            rippleHost.opacity = 0
            rippleHost.add(a, forKey: "fade")
            CATransaction.commit()
        } else {
            stopRipples()
        }
    }

    /// Một vòng sóng ảnh 512 px nằm ở bán kính 0,62; phóng từ mép đầu (0,47) ra 0,97 và mờ dần, hai vòng lệch nhịp. Câu
    /// mới tới lúc sóng của câu trước đang lặn thì sóng sáng lại và loang tiếp, không bắt đầu lại từ mép.
    private func startRipples() {
        rippleHost.removeAnimation(forKey: "fade")
        rippleHost.opacity = 1
        guard ripples[0].animation(forKey: "ripple") == nil else { return }
        let now = CACurrentMediaTime()
        for (i, r) in ripples.enumerated() {
            r.isHidden = false
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.47 / 0.62
            scale.toValue = 0.97 / 0.62
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.92, 0.69, 0.41, 0.17, 0]
            fade.keyTimes = [0, 0.06, 0.25, 0.5, 0.75, 1]
            let g = CAAnimationGroup()
            g.animations = [scale, fade]
            g.duration = 3
            g.repeatCount = .infinity
            g.beginTime = r.convertTime(now, from: nil) - Double(i) * 1.5
            r.opacity = 0
            r.add(g, forKey: "ripple")
        }
    }

    private func stopRipples() {
        rippleHost.removeAnimation(forKey: "fade")
        for r in ripples { r.removeAllAnimations(); r.isHidden = true }
        rippleHost.opacity = 1
    }

    private func bounce() {
        guard live else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1, 1.07, 0.985, 1.01, 1]
        a.keyTimes = [0, 0.15, 0.45, 0.72, 1]
        a.duration = 0.8
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
                             CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeOut)]
        bodyLayer.add(a, forKey: "bounce")
    }

    /// Đọc xong: gật nhẹ một cái như vừa nói hết câu.
    private func settle() {
        guard live else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
        a.values = [0, -size * 0.025, size * 0.006, 0]
        a.keyTimes = [0, 0.4, 0.75, 1]
        a.duration = 0.7
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bodyLayer.add(a, forKey: "settle")
    }

    // MARK: Dừng khi không ai nhìn

    /// Cửa sổ bị che hay bật giảm chuyển động: bỏ mọi hoạt ảnh, giữ một khung đứng yên đúng trạng thái.
    private func freeze() {
        lifeGen += 1
        moodGen += 1
        token += 1
        sprite.removeAllAnimations()
        bodyLayer.removeAllAnimations()
        breather.removeAllAnimations()
        glow.removeAllAnimations()
        stopRipples()
        inClip = false
        cancelScene()
        tickling = false
        tickleLooping = false
        hiddenSince = Date()
        showStill()
    }

    private func resume() {
        moodGen += 1
        updateGlow()
        updateMotion()
        startLife()
        showStill()
        flushSoon()
        // Quay lại cửa sổ sau một lúc vắng thì Ove chào.
        if let h = hiddenSince, Date().timeIntervalSince(h) > 30 {
            after(0.8, alive: { true }) { [weak self] in self?.greet() }
        }
        hiddenSince = nil
    }

    private func showStill() {
        // Tấm cần hiện chưa nạp (vừa mở app, cửa sổ bị che ngay): nạp ở luồng phụ rồi mới hiện.
        let need = held.map { mood == .idle ? $0.rawValue + "-idle" : $0.rawValue }
            ?? (mood == .asleep ? (dark ? "yawn-dark" : "yawn-light") : mood == .speaking ? "speak" : face)
        guard lib.has([need]) else {
            let gen = moodGen
            lib.prefetchAll([need]) { [weak self] in
                guard let self, self.moodGen == gen else { return }
                self.showStill()
            }
            return
        }
        if let held { showHeld(held); return }
        switch mood {
        case .asleep: showAsleep()
        case .speaking: startSpeaking()
        default: showFace(fade: false)
        }
    }
}
