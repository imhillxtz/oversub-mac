import AppKit

/// Nhật ký chẩn đoán: ghi từng bước xử lý phụ đề vào ~/Library/Logs/OverSub/debug.log để tìm lỗi chỉ xảy ra khi chơi thật.
/// Tự cắt bớt khi quá 2 MB. Không ghi key hay dữ liệu nhạy cảm, chỉ chữ phụ đề và quyết định của app.
enum DebugLog {
    static let url: URL = {
        let dir = AppPaths.logs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()
    private static let queue = DispatchQueue(label: "phude.debuglog")
    private static let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    /// Mở Finder tại tệp nhật ký (để người dùng gửi kèm khi báo lỗi).
    @MainActor static func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
                try? fm.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
