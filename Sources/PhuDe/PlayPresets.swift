import AppKit
import AVFoundation

/// Ước lượng độ trễ thêm (input lag: bấm nút thì hình phản hồi chậm hơn bao nhiêu so với Gốc) của một cách xử lý hình.
/// Gồm phần chờ của chèn khung (theo tốc độ khung của tín hiệu) và phần GPU vẽ lâu hơn. Thời gian GPU dựng theo số điểm ảnh
/// của hình gốc và vùng vẽ, hệ số mỗi bước lấy từ `Tools/fxbench` trên M1 Pro, rồi nhân với `factor` đo thật trên máy:
/// `PlayRenderer` so thời gian GPU đo được của cách đang dùng với ước lượng, chỉnh `factor` dần theo (GPU của Mac chạy chậm
/// lại khi ít việc, nên lúc chơi game 30 khung/giây thường gấp đôi số đo hết tốc độ).
struct PlayCost: Equatable, Sendable {
    /// Tốc độ khung của tín hiệu.
    var fps = 60.0
    /// Cỡ hình gốc (đã cắt theo Lấp đầy) và cỡ vùng vẽ, theo điểm ảnh thật.
    var sourceW = 1920.0, sourceH = 1080.0
    var outputW = 3024.0, outputH = 1701.0
    /// Thời gian GPU thật trên máy này chia cho ước lượng.
    var factor = 2.0

    typealias Values = PlaySettings.Preset.Values

    /// Chèn khung thực sự chạy: tín hiệu chỉ khoảng 30 khung/giây (như chế độ 1440p30 của card) thì không có khung lặp để
    /// thay, cách "30 lên 60" chèn khung giữa mọi cặp như gấp đôi.
    static func effective(_ mode: PlayInterpolator.Mode, fps: Double) -> PlayInterpolator.Mode {
        mode == .thirty && fps < 45 ? .double : mode
    }

    /// Khung hình lớn hơn hình gốc (chỉ khi đó mới chạy FSR, MetalFX, Anime4K).
    var upscales: Bool { outputW > sourceW + 2 || outputH > sourceH + 2 }

    static func processing(_ v: Values) -> Bool {
        v.upscaler != .bilinear || v.sharpen != .off || v.antiAlias || v.frameGen != .off
    }

    /// Thời gian GPU ước lượng (ms) cho mỗi khung tín hiệu, trước khi nhân `factor`. Theo đúng các bước của `PlayEffects.encode`.
    func model(_ v: Values) -> Double {
        let s = sourceW * sourceH / 1e6, d = outputW * outputH / 1e6
        guard Self.processing(v) else { return 0.08 * d + 0.04 * s }   // vẽ thẳng
        var fx = 0.08 * d   // bước cuối: chép, song tuyến hoặc RCAS vào drawable
        if v.antiAlias { fx += 0.39 * s }
        var scaled = false
        if upscales {
            switch v.upscaler {
            case .bilinear: break
            case .fsr: fx += 0.22 * d; scaled = true
            case .metalFX: fx += 0.23 * d; scaled = true
            case .anime3D: fx += 0.95 * s + 0.08 * d; scaled = true
            case .animeCel: fx += 1.4 * s + 0.08 * d; scaled = true
            }
        }
        if v.sharpen != .off { fx += scaled ? 0.02 * d : 0.1 * d }   // RCAS nặng hơn bước chép một chút; chưa phóng thì thêm bước đổi cỡ
        let convert = 0.08 * s
        switch Self.effective(v.frameGen, fps: fps) {
        case .off: return convert + fx
        case .double: return convert + 0.58 * s + 2 * fx   // dựng khung giữa, xử lý cả khung giữa lẫn khung thật
        case .thirty: return convert + 0.58 * s + fx
        }
    }

    /// Phần chờ của chèn khung (ms): gấp đôi hiện khung thật sau nửa nhịp, 30 lên 60 hiện trễ một nhịp.
    func wait(_ mode: PlayInterpolator.Mode) -> Double {
        let interval = 1000 / max(fps, 1)
        switch Self.effective(mode, fps: fps) {
        case .off: return 0
        case .double: return interval / 2
        case .thirty: return interval
        }
    }

    private static let original: Values = (.bilinear, .off, false, .off)

    /// Độ trễ thêm ước lượng (ms) so với Gốc.
    func added(_ v: Values) -> Double {
        wait(v.frameGen) + max(0, factor * (model(v) - model(Self.original)))
    }

    /// Độ trễ thêm (ms) từ thời gian GPU đo được của cách đang dùng.
    func measured(gpu ms: Double, frameGen: PlayInterpolator.Mode) -> Double {
        wait(frameGen) + max(0, ms - factor * model(Self.original))
    }

    /// Cùng tín hiệu, cùng cỡ khung hình, hệ số GPU lệch dưới 5%: chữ hiển thị gần như không đổi.
    func similar(to o: PlayCost) -> Bool {
        abs(fps - o.fps) < 0.5 && sourceW == o.sourceW && sourceH == o.sourceH && outputW == o.outputW && outputH == o.outputH
            && abs(factor - o.factor) < 0.05 * o.factor
    }

    // Nhớ lần đo gần nhất để trang Cài đặt có số đúng máy, đúng tín hiệu cả khi chưa mở màn hình chơi.
    private static let key = "play.cost"

    static var saved: PlayCost {
        var c = PlayCost()
        guard let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] else { return c }
        c.fps = d["fps"] ?? c.fps
        c.sourceW = d["sw"] ?? c.sourceW; c.sourceH = d["sh"] ?? c.sourceH
        c.outputW = d["ow"] ?? c.outputW; c.outputH = d["oh"] ?? c.outputH
        c.factor = d["factor"] ?? c.factor
        return c
    }

    func save() {
        UserDefaults.standard.set(["fps": fps, "sw": sourceW, "sh": sourceH, "ow": outputW, "oh": outputH, "factor": factor], forKey: Self.key)
    }
}

/// Chữ hiển thị của bộ chỉnh hình và các mục xử lý hình, dùng chung cho menu trong cửa sổ và trang Cài đặt.
/// Số trễ thêm tính bằng `PlayCost` theo tín hiệu và cỡ cửa sổ đang dùng (hoặc lần dùng gần nhất).
enum PlayLabels {
    static func lag(_ ms: Double) -> String {
        if ms < 0.5 { return L("không trễ thêm", "no added lag") }
        if ms < 1 { return L("trễ thêm dưới 1 ms", "adds under 1 ms") }
        return L("trễ thêm khoảng \(Int(ms.rounded())) ms", "adds about \(Int(ms.rounded())) ms")
    }

    static func presetName(_ p: PlaySettings.Preset, fps: Double) -> String {
        switch p {
        case .original: return L("Gốc", "Original")
        case .sharp: return L("Nét (FSR 1)", "Sharp (FSR 1)")
        case .smoothEdges: return L("Mịn cạnh (FXAA và FSR 1)", "Smooth edges (FXAA and FSR 1)")
        case .game3D: return L("Game 3D (AI Anime4K)", "3D games (AI, Anime4K)")
        case .cartoon: return L("Hình hoạt hình (AI Anime4K)", "Cartoon art (AI, Anime4K)")
        case .fluid120: return L("Mượt \(doubled(fps)) khung/giây", "Smooth \(doubled(fps)) fps")
        case .fluid30: return L("Game 30 khung/giây lên 60", "30 fps games to 60")
        case .custom: return L("Tuỳ chỉnh", "Custom")
        }
    }

    /// Tên bộ kèm độ trễ thêm. Tuỳ chỉnh tính theo các mục đang chọn (`current`).
    static func preset(_ p: PlaySettings.Preset, current: PlayCost.Values, cost: PlayCost) -> String {
        presetName(p, fps: cost.fps) + " · " + lag(cost.added(p.values ?? current))
    }

    /// Một câu nói bộ chỉnh hình làm gì, cho trang Cài đặt.
    static func presetDetail(_ p: PlaySettings.Preset, cost: PlayCost) -> String {
        switch p {
        case .original: return L("Không xử lý thêm, độ trễ thấp nhất.", "No extra processing, lowest latency.")
        case .sharp: return L("Phóng to bằng FSR 1 của AMD rồi làm nét nhẹ: chữ và viền rõ hơn khi toàn màn hình.", "Upscales with AMD FSR 1 and adds light sharpening: text and edges look crisper in full screen.")
        case .smoothEdges: return L("Khử răng cưa bằng FXAA trước khi phóng FSR 1: hợp game có viền nhiều răng cưa.", "Applies FXAA anti-aliasing before FSR 1 upscaling: suits games with jagged edges.")
        case .game3D: return L("Mạng AI Anime4K dành cho hình 3D, có khử răng cưa, phóng gấp đôi.", "Anime4K's AI network for 3D graphics, with anti-aliasing, at twice the resolution.")
        case .cartoon: return L("Mạng AI Anime4K dành cho hình nét vẽ hoạt hình (Pokémon, game kiểu anime), phóng gấp đôi.", "Anime4K's AI network for line-art and anime-style games, at twice the resolution.")
        case .fluid120:
            return L("Chèn một khung giữa mỗi hai khung thật để hình chạy \(doubled(cost.fps)) khung/giây.", "Inserts a frame between every two real frames so the picture runs at \(doubled(cost.fps)) fps.")
        case .fluid30:
            if PlayCost.effective(.thirty, fps: cost.fps) == .double {
                return L("Tín hiệu đang khoảng \(Int(cost.fps.rounded())) khung/giây nên bộ này chèn một khung giữa mỗi hai khung, giống Mượt \(doubled(cost.fps)) khung/giây.",
                         "The signal is about \(Int(cost.fps.rounded())) fps, so this inserts a frame between every two frames, the same as Smooth \(doubled(cost.fps)) fps.")
            }
            return L("Game chạy 30 khung/giây: thay khung lặp bằng khung giữa để thành 60. Game 60 khung/giây thì tự thôi chờ.", "For games running at 30 fps: replaces repeated frames with in-between frames to reach 60. 60 fps games skip the wait automatically.")
        case .custom: return L("Các mục bên dưới do bạn tự chọn.", "You picked the options below yourself.")
        }
    }

    /// Giải thích con số trễ thêm, ghi kèm số đo của cách đang dùng nếu có.
    static func lagNote(cost: PlayCost, measured: Double?) -> String {
        var s = L("Trễ thêm: bấm nút trên tay cầm thì hình phản hồi chậm hơn chừng đó so với Gốc. Số tính theo tín hiệu \(signal(cost)) và cỡ khung hình đang dùng, chỉnh theo thời gian GPU đo được trên máy này.",
                  "Added lag: how much later the picture responds to a button press than with Original. Worked out for the \(signal(cost)) signal and the current picture size, adjusted to the GPU time measured on this Mac.")
        if let m = measured {
            s += " " + L("Cách đang dùng đo được: \(lag(m)).", "Measured for the current setup: \(lag(m)).")
        }
        s += " " + L("Số càng lớn thì GPU càng nhiều việc, máy ấm và tốn pin hơn.", "Higher numbers also mean more GPU work, a warmer Mac and more battery use.")
        return s
    }

    private static func signal(_ c: PlayCost) -> String {
        "\(Int(c.sourceW))×\(Int(c.sourceH)) · \(Int(c.fps.rounded())) " + L("khung/giây", "fps")
    }

    /// Tốc độ sau khi gấp đôi, không vượt tần số màn hình chính (card 64 khung/giây trên màn 120 Hz thì là 120).
    private static func doubled(_ fps: Double) -> Int {
        let hz = Double(NSScreen.main?.maximumFramesPerSecond ?? 120)
        return Int((min(fps * 2, hz) / 10).rounded() * 10)
    }

    static func upscaler(_ u: PlayEffects.Upscaler) -> String {
        switch u {
        case .bilinear: return L("Thường (song tuyến)", "Standard (bilinear)")
        case .metalFX: return "MetalFX"
        case .fsr: return "FSR 1"
        case .anime3D: return L("Anime4K cho game 3D (AI)", "Anime4K for 3D games (AI)")
        case .animeCel: return L("Anime4K cho hình hoạt hình (AI)", "Anime4K for cartoon art (AI)")
        }
    }

    // Từng mục của Tuỳ chỉnh ghi phần trễ riêng mục đó cộng vào (so với tắt mục đó, giữ các mục khác như đang chọn);
    // bộ chỉnh hình thì ghi tổng so với Gốc.
    private static func delta(_ cost: PlayCost, _ on: PlayCost.Values, _ off: PlayCost.Values) -> Double {
        max(0, cost.added(on) - cost.added(off))
    }

    static func upscaler(_ u: PlayEffects.Upscaler, current: PlayCost.Values, cost: PlayCost) -> String {
        guard u != .bilinear else { return upscaler(u) }
        var on = current, off = current
        on.upscaler = u; off.upscaler = .bilinear
        return upscaler(u) + " · " + lag(delta(cost, on, off))
    }

    /// Khung hình không lớn hơn hình gốc thì các cách phóng không chạy (thu nhỏ chỉ cần song tuyến).
    static func upscaleNote(cost: PlayCost) -> String? {
        cost.upscales ? nil : L("Khung hình chưa lớn hơn hình gốc nên chưa cần phóng to.", "The picture isn't larger than the source yet, so no upscaling is needed.")
    }

    static func sharpen(_ s: PlaySettings.Sharpen, current: PlayCost.Values, cost: PlayCost) -> String {
        guard s != .off else { return sharpen(s) }
        var on = current, off = current
        on.sharpen = s; off.sharpen = .off
        return sharpen(s) + " · " + lag(delta(cost, on, off))
    }

    static func antiAlias(current: PlayCost.Values, cost: PlayCost) -> String {
        var on = current, off = current
        on.antiAlias = true; off.antiAlias = false
        return L("Khử răng cưa (FXAA)", "Anti-aliasing (FXAA)") + " · " + lag(delta(cost, on, off))
    }

    static func sharpen(_ s: PlaySettings.Sharpen) -> String {
        switch s {
        case .off: return L("Tắt", "Off")
        case .low: return L("Nhẹ", "Low")
        case .medium: return L("Vừa", "Medium")
        case .high: return L("Mạnh", "High")
        }
    }

    static func frameGen(_ m: PlayInterpolator.Mode, current: PlayCost.Values, cost: PlayCost) -> String {
        var on = current, off = current
        on.frameGen = m; off.frameGen = .off
        let name: String
        switch m {
        case .off: return L("Tắt", "Off")
        case .double: name = L("Gấp đôi, lên \(doubled(cost.fps)) khung/giây", "Double to \(doubled(cost.fps)) fps")
        case .thirty: name = L("Game 30 khung/giây lên 60", "30 fps games to 60")
        }
        return name + " · " + lag(delta(cost, on, off))
    }

    /// Ghi chú chung về chèn khung.
    static func frameGenNotes(cost: PlayCost) -> [String] {
        var notes = [L("Vật chạy nhanh có thể nhoè ở mép.", "Fast-moving objects can smear at their edges.")]
        if doubled(cost.fps) > 60 {
            notes.append(L("Gấp đôi lên \(doubled(cost.fps)) cần màn hình 120 Hz (ProMotion).", "Doubling to \(doubled(cost.fps)) needs a 120 Hz (ProMotion) display."))
        }
        notes.append(L("Số trễ thêm đã gồm thời gian GPU xử lý.", "Added lag includes GPU processing time."))
        return notes
    }

    static func frameGenNote(cost: PlayCost) -> String { frameGenNotes(cost: cost).joined(separator: " ") }

    // MARK: Các đánh đổi khác

    static var sharpenNote: String {
        L("Làm nét mạnh hơn thì chữ và viền rõ hơn nhưng dễ lộ viền sáng quanh nét và hạt nhiễu.",
          "Stronger sharpening makes text and edges crisper but can add bright halos and grain.")
    }

    static var antiAliasNote: String {
        L("Khử răng cưa làm mềm nhẹ cả chữ nhỏ.", "Anti-aliasing also softens small text slightly.")
    }

    /// Định dạng hình kèm đánh đổi: tín hiệu dưới 60 khung/giây kém mượt và trễ hơn (trung bình nửa khoảng cách giữa hai khung).
    static func format(_ f: AVCaptureDevice.Format) -> String {
        let fps = CaptureCards.fps(f)
        let text = CaptureCards.describe(f, fps: fps, codec: true)
        guard fps > 0, fps < 50 else { return text }
        let ms = Int(((1000 / fps - 1000 / 60) / 2).rounded())
        return text + " · " + L("kém mượt, trễ thêm khoảng \(ms) ms", "less smooth, adds about \(ms) ms")
    }

    static var formatNotes: [String] {
        [L("4:2:2 giữ màu ở viền chữ rõ hơn; 4:2:0 tốn ít CPU hơn.", "4:2:2 keeps colored text edges crisper; 4:2:0 uses less CPU."),
         L("Cỡ lớn hơn nét hơn nếu máy chơi game xuất đủ cỡ đó.", "A larger size is sharper only if the console outputs that size.")]
    }

    /// Loa kèm đánh đổi (Bluetooth trễ tiếng).
    static func output(_ d: AudioDevices.Device) -> String {
        AudioDevices.isBluetooth(d.id) ? d.name + " · " + L("Bluetooth, tiếng trễ hơn", "Bluetooth, delayed sound") : d.name
    }

    static var outputNote: String {
        L("Loa và tai nghe Bluetooth thường trễ tiếng hơn 0,1 giây so với hình. Chơi game nên dùng loa của máy hoặc tai nghe cắm dây.",
          "Bluetooth speakers and headphones usually play sound more than 0.1 seconds behind the picture. For games, use the built-in speakers or wired headphones.")
    }

    static var edrNote: String {
        L("Hiện HDR (EDR): bộ chỉnh hình chỉ còn phóng thường hoặc MetalFX, các bước khác tạm tắt.",
          "Show HDR (EDR): picture presets can only use standard upscaling or MetalFX; other steps are paused.")
    }
}
