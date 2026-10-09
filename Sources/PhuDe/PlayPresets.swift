import Foundation

/// Chữ hiển thị của bộ chỉnh hình và các mục xử lý hình, dùng chung cho menu trong cửa sổ và trang Cài đặt.
/// Độ trễ thêm của chèn khung tính theo tốc độ khung của tín hiệu (`fps`, mặc định 60).
enum PlayLabels {
    /// Độ trễ thêm (ms, làm tròn) của một cách chèn khung.
    static func addedLatency(_ mode: PlayInterpolator.Mode, fps: Double) -> Int {
        let f = max(fps, 1)
        switch mode {
        case .off: return 0
        case .double: return Int((1000 / f / 2).rounded())
        case .thirty: return Int((1000 / f).rounded())
        }
    }

    static func preset(_ p: PlaySettings.Preset, fps: Double) -> String {
        switch p {
        case .original: return L("Gốc (nhanh nhất)", "Original (fastest)")
        case .sharp: return L("Nét (FSR 1)", "Sharp (FSR 1)")
        case .smoothEdges: return L("Mịn cạnh (khử răng cưa và FSR 1)", "Smooth edges (anti-aliasing and FSR 1)")
        case .game3D: return L("Game 3D (AI Anime4K)", "3D games (AI, Anime4K)")
        case .cartoon: return L("Hình hoạt hình (AI Anime4K)", "Cartoon art (AI, Anime4K)")
        case .fluid120:
            let ms = addedLatency(.double, fps: fps)
            return L("Mượt 120 khung/giây (chậm thêm \(ms) ms)", "Smooth 120 fps (adds \(ms) ms)")
        case .fluid30:
            let ms = addedLatency(.thirty, fps: fps)
            return L("Game 30 khung/giây lên 60 (chậm thêm \(ms) ms)", "30 fps games to 60 (adds \(ms) ms)")
        case .custom: return L("Tuỳ chỉnh", "Custom")
        }
    }

    /// Một câu nói bộ chỉnh hình làm gì, cho trang Cài đặt.
    static func presetDetail(_ p: PlaySettings.Preset, fps: Double) -> String {
        switch p {
        case .original: return L("Không xử lý thêm, độ trễ thấp nhất.", "No extra processing, lowest latency.")
        case .sharp: return L("Phóng to bằng FSR 1 của AMD rồi làm nét nhẹ: chữ và viền rõ hơn khi toàn màn hình.", "Upscales with AMD FSR 1 and adds light sharpening: text and edges look crisper in full screen.")
        case .smoothEdges: return L("Khử răng cưa bằng FXAA trước khi phóng FSR 1: hợp game có viền nhiều răng cưa.", "Applies FXAA anti-aliasing before FSR 1 upscaling: suits games with jagged edges.")
        case .game3D: return L("Mạng AI Anime4K dành cho hình 3D, có khử răng cưa, phóng gấp đôi.", "Anime4K's AI network for 3D graphics, with anti-aliasing, at twice the resolution.")
        case .cartoon: return L("Mạng AI Anime4K dành cho hình nét vẽ hoạt hình (Pokémon, game kiểu anime), phóng gấp đôi.", "Anime4K's AI network for line-art and anime-style games, at twice the resolution.")
        case .fluid120: return L("Chèn một khung giữa mỗi hai khung thật để màn 120 Hz chạy 120 khung/giây. Hình trễ thêm \(addedLatency(.double, fps: fps)) ms.", "Inserts a frame between every two real frames so a 120 Hz display runs at 120 fps. Adds \(addedLatency(.double, fps: fps)) ms of latency.")
        case .fluid30: return L("Game chạy 30 khung/giây: thay khung lặp bằng khung giữa để thành 60. Hình trễ thêm \(addedLatency(.thirty, fps: fps)) ms; game 60 khung/giây thì tự thôi chờ.", "For games running at 30 fps: replaces repeated frames with in-between frames to reach 60. Adds \(addedLatency(.thirty, fps: fps)) ms; 60 fps games skip the wait automatically.")
        case .custom: return L("Các mục bên dưới do bạn tự chọn.", "You picked the options below yourself.")
        }
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

    static func sharpen(_ s: PlaySettings.Sharpen) -> String {
        switch s {
        case .off: return L("Tắt", "Off")
        case .low: return L("Nhẹ", "Low")
        case .medium: return L("Vừa", "Medium")
        case .high: return L("Mạnh", "High")
        }
    }

    static func frameGen(_ m: PlayInterpolator.Mode, fps: Double) -> String {
        switch m {
        case .off: return L("Tắt", "Off")
        case .double:
            let ms = addedLatency(.double, fps: fps)
            return L("Gấp đôi, lên 120 khung/giây (chậm thêm \(ms) ms)", "Double to 120 fps (adds \(ms) ms)")
        case .thirty:
            let ms = addedLatency(.thirty, fps: fps)
            return L("Game 30 khung/giây lên 60 (chậm thêm \(ms) ms)", "30 fps games to 60 (adds \(ms) ms)")
        }
    }

    /// Ghi chú chung về chèn khung.
    static var frameGenNote: String {
        L("Khung chèn dựng từ hai khung thật nên vật chạy nhanh có thể nhoè ở mép. Gấp đôi cần màn hình 120 Hz (ProMotion). Độ trễ ghi kèm chưa tính thời gian GPU xử lý, khoảng 1 đến 2 ms.",
          "In-between frames are built from two real frames, so fast-moving objects can smear at their edges. Doubling needs a 120 Hz (ProMotion) display. The added latency shown excludes GPU processing time, about 1 to 2 ms.")
    }
}
