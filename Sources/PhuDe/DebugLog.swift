import AppKit

/// Nhật ký chẩn đoán: ghi từng bước xử lý phụ đề vào ~/Library/Logs/OverSub/debug.log để tìm lỗi chỉ xảy ra khi chơi thật.
/// Quá 2 MB thì đổi tên thành debug.1.log (đè bản cũ) rồi ghi tệp mới, nên luôn còn một tệp trước đó để đối chiếu nhiều buổi
/// chơi (trước bản 1.1.74 xoá hẳn, mất dấu lỗi lặp). Không ghi key hay dữ liệu nhạy cảm, chỉ chữ phụ đề và quyết định của app.
enum DebugLog {
    static let url: URL = {
        var dir = AppPaths.logs
        #if DEVTOOLS
        // Thử xoay nhật ký trong thư mục tạm, không đụng nhật ký thật của người dùng.
        if let d = ProcessInfo.processInfo.environment["OVERSUB_LOG_DIR"] { dir = URL(fileURLWithPath: d, isDirectory: true) }
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()
    /// Tệp trước đó, giữ lại sau lần xoay gần nhất.
    static let previousURL = url.deletingLastPathComponent().appendingPathComponent("debug.1.log")
    private static let maxBytes: Int = {
        #if DEVTOOLS
        if let n = Int(ProcessInfo.processInfo.environment["OVERSUB_LOG_ROTATE_BYTES"] ?? ""), n > 0 { return n }
        #endif
        return 2_000_000
    }()
    private static let queue = DispatchQueue(label: "phude.debuglog")
    private static let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    /// Mở Finder tại tệp nhật ký (để người dùng gửi kèm khi báo lỗi).
    @MainActor static func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                // rename đè debug.1.log cũ trong một bước; không đổi tên được thì xoá như trước để nhật ký không phình mãi.
                if rename(url.path, previousURL.path) != 0 { try? fm.removeItem(at: url) }
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
