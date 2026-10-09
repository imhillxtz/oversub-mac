import SwiftUI
import AppKit
import ImageIO

/// Ove: linh vật 3D của OverSub, đầu kính mờ có lõi cam. Hình dựng sẵn bằng bộ dựng 3D ở Tools/Ove (cùng bộ dựng của
/// prototype) rồi xếp thành từng tấm khung hình trong Resources/Ove. Core Animation lật khung nên app gần như không tốn
/// CPU (đo 0,3% một nhân ở 30 khung mỗi giây), và mọi hoạt ảnh dừng hẳn khi cửa sổ bị che.
///
/// Tấm khung hình: bộ góc đầu cho mặt chờ (`idle`) và mặt đang chạy (`live`), mỗi góc một khung mở mắt và một khung
/// nhắm mắt; vòng đọc (`speak`); các đoạn biểu cảm (`happy`, `sad`, `angry`, `dizzy`, `cry`); ngáp và tỉnh dậy riêng cho
/// nền sáng và nền tối (`yawn-light`, `wake-dark`...) vì mặt lúc ngủ xám khác nhau. Kính đã được tách độ trong thật nên
/// cùng một khung dùng được trên cả hai nền.
@MainActor
final class OveLibrary {
    static let shared = OveLibrary()

    struct Sheet {
        let image: CGImage
        let count: Int
        let cols: Int
        let rows: Int
        let hold: [Int]?

        /// Ô của khung thứ `i` theo toạ độ đơn vị của `contentsRect`. Tấm xếp hàng từ trên xuống, còn `contentsRect` trên
        /// macOS tính từ đáy ảnh lên, nên phải lật hàng.
        func rect(_ i: Int) -> CGRect {
            let i = max(0, min(count - 1, i))
            let w = 1 / CGFloat(cols), h = 1 / CGFloat(rows)
            return CGRect(x: CGFloat(i % cols) * w, y: 1 - CGFloat(i / cols + 1) * h, width: w, height: h)
        }
        var last: Int { count - 1 }
    }

    private struct Meta: Decodable {
        struct SheetInfo: Decodable { let count: Int; let rows: Int; let kind: String; let hold: [Int]? }
        struct Atlas: Decodable { let yaws: [Double]; let pitches: [Double] }
        let frame: Int
        let cols: Int
        let fps: Int
        let sheets: [String: SheetInfo]
        let atlas: Atlas
    }

    private lazy var meta: Meta? = {
        guard let url = Bundle.main.url(forResource: "ove", withExtension: "json", subdirectory: "Ove") else {
            DebugLog.write("Ove: không thấy Resources/Ove/ove.json trong gói app")
            return nil
        }
        do {
            return try JSONDecoder().decode(Meta.self, from: Data(contentsOf: url))
        } catch {
            DebugLog.write("Ove: đọc ove.json lỗi: \(error)")
            return nil
        }
    }()
    private var cache: [String: Sheet] = [:]
    private var stills: [String: CGImage] = [:]

    var available: Bool { meta != nil }
    var fps: Double { Double(meta?.fps ?? 24) }
    var yaws: [Double] { meta?.atlas.yaws ?? [0] }
    var pitches: [Double] { meta?.atlas.pitches ?? [0] }
    /// Tỉ lệ khung so với đường kính đầu (khung 280 px cho đầu 256 px).
    var frameRatio: CGFloat { CGFloat(meta?.frame ?? 280) / 256 }

    func sheet(_ name: String) -> Sheet? {
        if let s = cache[name] { return s }
        guard let meta, let info = meta.sheets[name] else { return nil }
        guard let image = Self.load(name) else {
            DebugLog.write("Ove: không đọc được tấm \(name).heic")
            return nil
        }
        let s = Sheet(image: image, count: info.count, cols: meta.cols, rows: info.rows, hold: info.hold)
        cache[name] = s
        return s
    }

    /// Thả tấm không còn dùng: mỗi tấm giải nén khoảng 28 MB, giữ hết thì app nặng thêm hơn 100 MB. Đọc lại một tấm
    /// HEIC chỉ mất vài chục mili giây, nằm gọn trong lúc hai hình mờ chồng chuyển cảnh.
    func release(_ name: String) {
        cache[name] = nil
    }

    func ripple(dark: Bool) -> CGImage? {
        let name = dark ? "ripple-dark" : "ripple-light"
        if let s = stills[name] { return s }
        let image = Self.load(name)
        stills[name] = image
        return image
    }

    /// Một khung đứng yên cho chỗ chỉ cần hình (cửa sổ Ủng hộ, bảng báo khởi động lại).
    func still(asleep: Bool, dark: Bool) -> CGImage? {
        let key = asleep ? (dark ? "still-asleep-dark" : "still-asleep-light") : "still-idle"
        if let s = stills[key] { return s }
        let name = asleep ? (dark ? "yawn-dark" : "yawn-light") : "idle"
        guard let meta, let s = sheet(name) else { return nil }
        let index = asleep ? s.last : frontIndex
        let f = meta.frame
        guard let crop = s.image.cropping(to: CGRect(x: (index % s.cols) * f, y: (index / s.cols) * f, width: f, height: f)),
              let ctx = CGContext(data: nil, width: f, height: f, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: f, height: f))
        let image = ctx.makeImage()
        stills[key] = image
        if !asleep { release(name) }
        return image
    }

    /// Khung nhìn thẳng, mở mắt trong bộ góc đầu.
    var frontIndex: Int { atlasIndex(row: pitches.count / 2, col: yaws.count / 2, closed: false) }

    func atlasIndex(row: Int, col: Int, closed: Bool) -> Int { (row * yaws.count + col) * 2 + (closed ? 1 : 0) }

    private static func load(_ name: String) -> CGImage? {
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.homeAnimating) private var animating

    func makeNSView(context: Context) -> OveLayerView { OveLayerView(size: size) }
    func updateNSView(_ view: OveLayerView, context: Context) {
        view.configure(mood: mood, dark: scheme == .dark, animating: animating, still: reduceMotion, cue: cue)
    }
}

/// Một khung Ove đứng yên; thiếu tài nguyên thì dùng lại linh vật 2D.
struct OveStill: View {
    var mood: Mascot.Mood
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let image = OveLibrary.shared.still(asleep: mood == .asleep, dark: scheme == .dark) {
            let ratio = OveLibrary.shared.frameRatio
            Image(decorative: image, scale: CGFloat(image.width) / (size * ratio))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.1), radius: size * 0.08, y: size * 0.04)
                .accessibilityHidden(true)
        } else {
            Mascot(mood: mood, size: size)
        }
    }
}

final class OveLayerView: NSView {
    private let lib = OveLibrary.shared
    private let size: CGFloat
    // Lớp: gợn sóng phía sau; thân (nảy khi có câu mới) chứa lớp thở, trong đó có quầng cam, bóng đổ và hình Ove.
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
    private var configured = false

    private enum Showing: Equatable { case atlas(String), clip, loop, asleep }
    private var showing: Showing = .asleep
    private var sheetName: String?
    private var inClip = false
    private var token = 0
    private var blinkGen = 0
    private var lookGen = 0
    private var pointerIdle: DispatchWorkItem?
    private var petStart: DispatchWorkItem?

    // Góc đầu đang hiện (hàng theo hướng dọc, cột theo hướng ngang) và đường đi dở giữa hai góc.
    private var cell = (row: 2, col: 4)
    private var path: [(row: Int, col: Int)] = []
    private var pathStart: CFTimeInterval = 0
    private var glanceOn = false
    private var lookAway: (row: Int, col: Int)?

    // Chuột.
    private var monitor: Any?
    private var pointerAt: CFTimeInterval = 0
    private var pointerCell: (row: Int, col: Int)?
    private var over = false
    private var overSince: CFTimeInterval = 0
    private var petting = false
    private var scrub = (dir: 0, lastX: CGFloat(0), lastT: CFTimeInterval(0), peak: CGFloat(0), len: CGFloat(0), flips: [CFTimeInterval]())
    private var circle = (lastAngle: CGFloat?.none, turns: [(CFTimeInterval, CGFloat)]())

    init(size: CGFloat) {
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        for r in ripples { r.isHidden = true; layer?.addSublayer(r) }
        layer?.addSublayer(bodyLayer)
        bodyLayer.addSublayer(breather)
        breather.addSublayer(glow)
        breather.addSublayer(drop)
        breather.addSublayer(sprite)
        sprite.contentsGravity = .resize
        sprite.minificationFilter = .trilinear
        for s in [glow, drop] {
            s.shadowPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size), transform: nil)
            s.shadowOpacity = 0
        }
        glow.shadowColor = NSColor(Theme.orangeEnd).cgColor
        drop.shadowColor = NSColor.black.cgColor
        drop.shadowRadius = 10
        drop.shadowOffset = CGSize(width: 0, height: -5)
        #if DEVTOOLS
        observeDebug()
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            MainActor.assumeIsolated { self?.pointer(e) }
            return e
        }
    }

    // MARK: Cấu hình từ SwiftUI

    func configure(mood: Mascot.Mood, dark: Bool, animating: Bool, still: Bool, cue: UUID?) {
        guard lib.available else { return }
        let first = !configured
        configured = true
        let old = self.mood
        let darkChanged = dark != self.dark || first
        let animChanged = animating != self.animating || still != self.still
        (self.dark, self.still) = (dark, still)
        if darkChanged {
            for r in ripples { r.contents = lib.ripple(dark: dark) }
            drop.shadowOpacity = dark ? 0.35 : 0.12
            if showing == .asleep && !inClip { showAsleep() }
        }
        if first {
            self.mood = mood
            self.animating = animating
            enter(mood, from: nil)
            self.cue = cue
            return
        }
        if animChanged {
            self.animating = animating
            if animating && !still { resume() } else { freeze() }
        }
        if mood != old {
            self.mood = mood
            enter(mood, from: old)
        }
        if cue != self.cue {
            self.cue = cue
            if mood != .asleep { bounce() }
        }
    }

    private var live: Bool { animating && !still }

    // MARK: Chuyển trạng thái

    private func enter(_ new: Mascot.Mood, from old: Mascot.Mood?) {
        endInteraction()
        if sheetName != (new == .idle ? "live" : "idle") { lib.release(new == .idle ? "live" : "idle") }
        updateGlow()
        updateMotion()
        startTimers()
        switch new {
        case .asleep:
            if let old, old != .asleep, live {
                playClip(dark ? "yawn-dark" : "yawn-light", fade: true) { [weak self] in self?.showAsleep() }
            } else {
                showAsleep()
            }
        case .speaking:
            if old == .asleep, live {
                playClip(dark ? "wake-dark" : "wake-light", fade: false) { [weak self] in self?.startSpeaking() }
            } else {
                startSpeaking()
            }
        case .idle, .listening:
            if old == .asleep, live {
                playClip(dark ? "wake-dark" : "wake-light", fade: false) { [weak self] in self?.showAtlas(fade: true) }
            } else {
                showAtlas(fade: old != nil)
            }
        }
    }

    private var face: String { mood == .idle ? "idle" : "live" }

    private var restCell: (row: Int, col: Int) {
        let mid = (row: lib.pitches.count / 2, col: lib.yaws.count / 2)
        if mood == .listening { return (mid.row, glanceOn ? mid.col - 3 : mid.col - 2) }   // quay sang nút Phụ đề
        return mid
    }

    private func showAsleep() {
        inClip = false
        showing = .asleep
        guard let s = setSheet(dark ? "yawn-dark" : "yawn-light", fade: false) else { return }
        sprite.removeAnimation(forKey: "frames")
        sprite.contentsRect = s.rect(s.last)
    }

    private func startSpeaking() {
        inClip = false
        showing = .loop
        guard let s = setSheet("speak", fade: true) else { return }
        if live {
            run(Array(0..<s.count), sheet: s, repeating: true)
        } else {
            sprite.removeAnimation(forKey: "frames")
            sprite.contentsRect = s.rect(0)
        }
    }

    private func showAtlas(fade: Bool) {
        inClip = false
        showing = .atlas(face)
        let target = pointerCell ?? lookAway ?? restCell
        guard let s = setSheet(face, fade: fade) else { return }
        sprite.removeAnimation(forKey: "frames")
        path = []
        cell = (lib.pitches.count / 2, lib.yaws.count / 2)
        sprite.contentsRect = s.rect(lib.atlasIndex(row: cell.row, col: cell.col, closed: false))
        look(at: target)
    }

    // MARK: Khung hình

    @discardableResult
    private func setSheet(_ name: String, fade: Bool) -> OveLibrary.Sheet? {
        guard let s = lib.sheet(name) else { return nil }
        if sheetName != name {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if fade && live {
                let t = CATransition()
                t.type = .fade
                t.duration = 0.22
                sprite.add(t, forKey: "fade")
            }
            sprite.contents = s.image
            CATransaction.commit()
            // Chỉ giữ tấm đang chiếu và bộ góc đầu của mặt hiện tại (để quay về sau mỗi đoạn biểu cảm không phải đọc lại).
            if let old = sheetName, old != face { lib.release(old) }
            sheetName = name
        }
        return s
    }

    /// Lật các khung `frames` của tấm hiện tại theo nhịp của bộ hình; xong thì gọi `done` (bị ngắt thì không gọi).
    private func run(_ frames: [Int], sheet s: OveLibrary.Sheet, repeating: Bool = false, done: (() -> Void)? = nil) {
        token += 1
        let mine = token
        guard let lastFrame = frames.last else { done?(); return }
        let anim = CAKeyframeAnimation(keyPath: "contentsRect")
        anim.values = frames.map { NSValue(rect: s.rect($0)) }
        anim.calculationMode = .discrete
        anim.duration = Double(frames.count) / lib.fps
        if repeating { anim.repeatCount = .infinity }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == mine else { return }
                done?()
            }
        }
        sprite.contentsRect = s.rect(repeating ? frames[0] : lastFrame)
        sprite.add(anim, forKey: "frames")
        CATransaction.commit()
    }

    private func playClip(_ name: String, from a: Int = 0, to b: Int? = nil, fade: Bool, done: @escaping () -> Void) {
        inClip = true
        showing = .clip
        guard let s = setSheet(name, fade: fade) else { inClip = false; done(); return }
        let end = min(b ?? s.last, s.last)
        guard live, a <= end else { sprite.contentsRect = s.rect(end); done(); return }
        run(Array(a...end), sheet: s, done: done)
    }

    // MARK: Góc đầu

    private func nearest(_ values: [Double], _ v: Double) -> Int {
        values.indices.min { abs(values[$0] - v) < abs(values[$1] - v) } ?? 0
    }

    /// Ô đang hiện, kể cả khi đang đi dở giữa hai góc.
    private var currentCell: (row: Int, col: Int) {
        guard !path.isEmpty else { return cell }
        let k = Int((CACurrentMediaTime() - pathStart) * lib.fps)
        return k >= path.count ? path[path.count - 1] : path[max(0, k)]
    }

    /// Quay đầu tới ô đích, mỗi khung đi một nấc theo cả hai hướng, nên đầu xoay đều chứ không nhảy cóc.
    private func look(at target: (row: Int, col: Int)) {
        guard case .atlas = showing, !inClip, let s = lib.sheet(face) else { return }
        var cur = currentCell
        guard cur != target else { return }
        var steps: [(row: Int, col: Int)] = []
        while cur != target {
            cur.row += (target.row > cur.row ? 1 : target.row < cur.row ? -1 : 0)
            cur.col += (target.col > cur.col ? 1 : target.col < cur.col ? -1 : 0)
            steps.append(cur)
        }
        cell = target
        guard live else {
            path = []
            sprite.removeAnimation(forKey: "frames")
            sprite.contentsRect = s.rect(lib.atlasIndex(row: target.row, col: target.col, closed: false))
            return
        }
        path = steps
        pathStart = CACurrentMediaTime()
        // Quay đầu lớn thì chớp mắt một cái cho tự nhiên.
        let blinkMid = steps.count >= 3
        let frames = steps.enumerated().map { i, c in
            lib.atlasIndex(row: c.row, col: c.col, closed: blinkMid && i == steps.count / 2)
        }
        run(frames, sheet: s) { [weak self] in self?.path = [] }
    }

    private func blink() {
        guard case .atlas = showing, !inClip, path.isEmpty, live, let s = lib.sheet(face) else { return }
        let open = lib.atlasIndex(row: cell.row, col: cell.col, closed: false)
        let shut = lib.atlasIndex(row: cell.row, col: cell.col, closed: true)
        var frames = [shut, shut, open]
        if Int.random(in: 0..<5) == 0 { frames += [open, open, shut, shut, open] }   // thỉnh thoảng chớp đôi
        run(frames, sheet: s)
    }

    // MARK: Nhịp sống

    /// Chớp mắt sau mỗi 2,8 đến 6,2 giây; lúc nghe thì một phần ba số lần là liếc kỹ hơn sang nút Phụ đề; lúc chờ mà không
    /// có chuột thì thỉnh thoảng nhìn quanh. Hẹn giờ nên giữa hai lần không tốn gì; cửa sổ bị che thì dừng hẳn.
    private func startTimers() {
        blinkGen += 1
        lookGen += 1
        lookAway = nil
        guard live, mood != .asleep, mood != .speaking else { return }
        blinkLoop(blinkGen)
        if mood == .idle { lookLoop(lookGen) }
    }

    private func blinkLoop(_ gen: Int) {
        after(Double.random(in: 2.8...6.2), alive: { [weak self] in self?.blinkGen == gen }) { [weak self] in
            guard let self else { return }
            if self.mood == .listening, self.pointerCell == nil, Int.random(in: 0..<3) == 0 {
                self.glanceOn.toggle()
                self.look(at: self.restCell)
            } else {
                self.blink()
            }
            self.blinkLoop(gen)
        }
    }

    private func lookLoop(_ gen: Int) {
        let alive: @MainActor () -> Bool = { [weak self] in self?.lookGen == gen && self?.mood == .idle }
        after(Double.random(in: 3...6), alive: alive) { [weak self] in
            guard let self else { return }
            guard self.pointerCell == nil, !self.inClip else { self.lookLoop(gen); return }
            let mid = (row: self.lib.pitches.count / 2, col: self.lib.yaws.count / 2)
            let away = (row: mid.row + Int.random(in: -1...1), col: mid.col + Int.random(in: -2...2))
            self.lookAway = away
            self.look(at: away)
            self.after(Double.random(in: 1.2...2.2), alive: alive) { [weak self] in
                guard let self else { return }
                self.lookAway = nil
                if self.pointerCell == nil { self.look(at: self.restCell) }
                self.lookLoop(gen)
            }
        }
    }

    private func after(_ seconds: Double, alive: @escaping @MainActor () -> Bool, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                guard alive() else { return }
                action()
            }
        }
    }

    private func workItem(_ seconds: Double, _ action: @escaping @MainActor () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    // MARK: Chuột

    private var canExpress: Bool { live && mood != .asleep && mood != .speaking && !inClip }

    private func pointer(_ e: NSEvent) {
        guard e.window === window, live, mood != .asleep else { return }
        let p = convert(e.locationInWindow, from: nil)
        let dx = p.x - bounds.midX, dy = p.y - bounds.midY
        let t = CACurrentMediaTime()
        pointerAt = t
        // Nhìn theo chuột: hướng ngang theo khoảng cách ngang, hướng dọc theo khoảng cách dọc (xuống dưới là cúi).
        let yaw = max(-0.6, min(0.6, Double(dx) / 220 * 0.8)), pitch = max(-0.36, min(0.36, Double(-dy) / 220 * 0.55))
        let target = (row: nearest(lib.pitches, pitch), col: nearest(lib.yaws, yaw))
        if mood != .speaking, pointerCell.map({ $0 != target }) ?? true {
            pointerCell = target
            look(at: target)
        }
        // Bốn giây không rê chuột thì thôi nhìn theo, quay về tư thế của trạng thái.
        pointerIdle?.cancel()
        pointerIdle = workItem(4) { [weak self] in
            guard let self, self.pointerCell != nil else { return }
            self.pointerCell = nil
            self.look(at: self.lookAway ?? self.restCell)
        }
        let r = hypot(dx, dy)
        updatePet(over: r < size / 2 * 1.05, t: t)
        if r < size / 2 * 1.05 { updateScrub(x: p.x, t: t) } else { scrub.lastX = .nan }
        updateCircle(dx: dx, dy: dy, r: r, t: t)
    }

    /// Đặt chuột lên đầu nửa giây là được vuốt ve: vui, mắt cong. Đang vuốt mà bỏ đi sau hơn 1,6 giây thì buồn.
    private func updatePet(over now: Bool, t: CFTimeInterval) {
        if now && !over {
            over = true
            overSince = t
            petStart?.cancel()
            petStart = workItem(0.5) { [weak self] in
                guard let self, self.over, self.canExpress, let s = self.lib.sheet("happy") else { return }
                self.petting = true
                self.playClip("happy", to: s.hold?.first ?? s.count / 2, fade: true) {}
            }
        } else if !now && over {
            over = false
            guard petting else { return }
            petting = false
            let long = t - overSince > 1.6
            let from = lib.sheet("happy")?.hold?.last ?? 0
            playClip("happy", from: from, fade: false) { [weak self] in
                guard let self else { return }
                if long { self.playClip("sad", fade: false) { [weak self] in self?.showAtlas(fade: true) } }
                else { self.showAtlas(fade: true) }
            }
        }
    }

    /// Rung chuột qua lại thật nhanh trên đầu: chỉ tính nhịp đi đủ xa (từ 14 điểm) và đủ nhanh (từ 1100 điểm mỗi giây),
    /// sáu nhịp trong một giây thì Ove giận. Xoa nhẹ để vuốt ve chậm hơn nhiều nên không bị tính.
    private func updateScrub(x: CGFloat, t: CFTimeInterval) {
        if scrub.lastX.isNaN || t - scrub.lastT > 0.25 { scrub = (0, x, t, 0, 0, []); return }
        let dx = x - scrub.lastX, dt = max(0.004, t - scrub.lastT)
        guard abs(dx) >= 2 else { return }
        scrub.lastX = x
        scrub.lastT = t
        let dir = dx > 0 ? 1 : -1
        if scrub.dir != 0 && dir != scrub.dir {
            if scrub.peak > 1100 && scrub.len >= 14 { scrub.flips.append(t) }
            scrub.peak = 0
            scrub.len = 0
        }
        scrub.dir = dir
        scrub.peak = max(scrub.peak, abs(dx) / CGFloat(dt))
        scrub.len += abs(dx)
        scrub.flips.removeAll { t - $0 > 1 }
        if scrub.flips.count >= 6 {
            scrub.flips = []
            express("angry")
        }
    }

    /// Rê chuột vòng tròn thật nhanh quanh Ove (hai vòng trong hai giây): chóng mặt rồi khóc nhè.
    private func updateCircle(dx: CGFloat, dy: CGFloat, r: CGFloat, t: CFTimeInterval) {
        guard r > size * 0.3, r < size * 1.6 else { circle.lastAngle = nil; return }
        let a = atan2(dy, dx)
        if let last = circle.lastAngle {
            var d = a - last
            if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
            circle.turns.append((t, d))
        }
        circle.lastAngle = a
        circle.turns.removeAll { t - $0.0 > 2 }
        if abs(circle.turns.reduce(0) { $0 + $1.1 }) > 4 * .pi {
            circle.turns = []
            express("dizzy", then: "cry")
        }
    }

    private func express(_ name: String, then next: String? = nil) {
        guard live, mood != .asleep, mood != .speaking, !inClip || petting else { return }
        petting = false
        playClip(name, fade: true) { [weak self] in
            guard let self else { return }
            if let next { self.playClip(next, fade: false) { [weak self] in self?.showAtlas(fade: true) } }
            else { self.showAtlas(fade: true) }
        }
    }

    private func endInteraction() {
        petting = false
        over = false
        lookAway = nil
        glanceOn = false
    }

    #if DEVTOOLS
    /// Móc thử (OVERSUB_OVE_TEST): chạy một biểu cảm như thể có tương tác chuột.
    private func observeDebug() {
        NotificationCenter.default.addObserver(forName: .oveDebugExpress, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let name = n.object as? String else { return }
                if name == "dizzy" { self.express("dizzy", then: "cry") } else { self.express(name) }
            }
        }
    }
    #endif

    // MARK: Hoạt ảnh nền

    private func updateGlow() {
        let o: Float = mood == .speaking ? 0.55 : mood == .listening ? 0.32 : mood == .idle ? 0.14 : 0
        glow.shadowOpacity = o
        glow.shadowRadius = mood == .speaking ? 26 : 16
        glow.shadowOffset = CGSize(width: 0, height: -6)
    }

    /// Thở chậm khi ngủ, nhún rất nhẹ khi thức, gợn sóng nước khi đang đọc: đều chạy bằng Core Animation.
    private func updateMotion() {
        breather.removeAllAnimations()
        for r in ripples { r.removeAllAnimations(); r.isHidden = true }
        guard live else { return }
        if mood == .asleep {
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 1
            a.toValue = 1.012
            a.duration = 1.85
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breather.add(a, forKey: "breath")
        } else {
            let a = CABasicAnimation(keyPath: "transform.translation.y")
            a.fromValue = -size * 0.006
            a.toValue = size * 0.006
            a.duration = 2.4
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breather.add(a, forKey: "bob")
        }
        if mood == .speaking {
            // Một vòng sóng ảnh 512 px nằm ở bán kính 0,62; phóng từ mép đầu (0,47) ra 0,97 và mờ dần, hai vòng lệch nhịp.
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

    // MARK: Dừng khi không ai nhìn

    /// Cửa sổ bị che hay bật giảm chuyển động: bỏ mọi hoạt ảnh, giữ một khung đứng yên đúng trạng thái.
    private func freeze() {
        blinkGen += 1
        lookGen += 1
        pointerIdle?.cancel()
        petStart?.cancel()
        pointerCell = nil
        token += 1
        path = []
        sprite.removeAllAnimations()
        bodyLayer.removeAllAnimations()
        breather.removeAllAnimations()
        for r in ripples { r.removeAllAnimations(); r.isHidden = true }
        if petting || inClip { petting = false; inClip = false }
        switch mood {
        case .asleep: showAsleep()
        case .speaking: startSpeaking()
        default: showAtlas(fade: false)
        }
    }

    private func resume() {
        updateMotion()
        startTimers()
        switch mood {
        case .asleep: showAsleep()
        case .speaking: startSpeaking()
        default: showAtlas(fade: false)
        }
    }

    override func removeFromSuperview() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        super.removeFromSuperview()
    }
}

#if DEVTOOLS
extension Notification.Name {
    static let oveDebugExpress = Notification.Name("vn.imhillxtz.oversub.oveDebugExpress")
}
#endif
