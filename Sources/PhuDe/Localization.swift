import Foundation

/// Giao diện song ngữ: mỗi chuỗi viết kèm bản tiếng Anh ngay tại chỗ, `L("Tiếng Việt", "English")`.
/// Ngôn ngữ theo Cài đặt → Chung (Tự động theo máy, Tiếng Việt, English).
enum Lang {
    /// "auto", "vi" hoặc "en". AppSettings ghi vào đây lúc khởi động và mỗi khi người dùng đổi.
    nonisolated(unsafe) static var choice = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"

    static var isEnglish: Bool {
        switch choice {
        case "vi": return false
        case "en": return true
        default: return !(Locale.preferredLanguages.first ?? "vi").hasPrefix("vi")
        }
    }
}

func L(_ vi: String, _ en: String) -> String { Lang.isEnglish ? en : vi }

/// Thư mục dữ liệu và nhật ký của app. Bản cũ dùng tên "PhuDeDich": chuyển sang "OverSub" một lần lúc khởi động.
enum AppPaths {
    static let support: URL = migrated(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], "PhuDeDich", "OverSub")
    static let logs: URL = migrated(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs", isDirectory: true),
                                    "PhuDeDich", "OverSub")

    private static func migrated(_ base: URL, _ old: String, _ new: String) -> URL {
        let fm = FileManager.default
        let o = base.appendingPathComponent(old, isDirectory: true), n = base.appendingPathComponent(new, isDirectory: true)
        if fm.fileExists(atPath: o.path), !fm.fileExists(atPath: n.path) { try? fm.moveItem(at: o, to: n) }
        return n
    }
}
