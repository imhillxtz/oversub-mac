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
/// Bản Beta (`OVERSUB_BETA=1 ./build.sh`, mã định danh đuôi `.beta`) dùng thư mục "OverSub Beta" riêng để cài song song
/// với bản chính; lần mở đầu chép dữ liệu và cài đặt của bản chính sang, không đụng vào bản chính.
enum AppPaths {
    static let mainBundleID = "vn.imhillxtz.phude"
    static let isBeta = Bundle.main.bundleIdentifier == mainBundleID + ".beta"

    static let support: URL = isBeta ? seeded(appSupport, "OverSub", "OverSub Beta") : migrated(appSupport, "PhuDeDich", "OverSub")
    static let logs: URL = isBeta ? libraryLogs.appendingPathComponent("OverSub Beta", isDirectory: true) : migrated(libraryLogs, "PhuDeDich", "OverSub")

    private static var appSupport: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    private static var libraryLogs: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs", isDirectory: true)
    }

    /// Bản Beta mở lần đầu: chép cài đặt (UserDefaults) của bản chính sang miền của bản Beta. Gọi trước mọi lần đọc cài đặt.
    static func seedBetaDefaults() {
        guard isBeta, let id = Bundle.main.bundleIdentifier else { return }
        let d = UserDefaults.standard
        guard d.persistentDomain(forName: id)?.isEmpty ?? true,
              let main = d.persistentDomain(forName: mainBundleID), !main.isEmpty else { return }
        d.setPersistentDomain(main, forName: id)
        NSLog("OverSub Beta: đã chép %d mục cài đặt từ bản chính", main.count)
    }

    private static func seeded(_ base: URL, _ source: String, _ new: String) -> URL {
        let fm = FileManager.default
        let s = base.appendingPathComponent(source, isDirectory: true), n = base.appendingPathComponent(new, isDirectory: true)
        if fm.fileExists(atPath: s.path), !fm.fileExists(atPath: n.path) {
            do { try fm.copyItem(at: s, to: n) } catch { NSLog("OverSub Beta: không chép được dữ liệu bản chính: %@", "\(error)") }
        }
        return n
    }

    private static func migrated(_ base: URL, _ old: String, _ new: String) -> URL {
        let fm = FileManager.default
        let o = base.appendingPathComponent(old, isDirectory: true), n = base.appendingPathComponent(new, isDirectory: true)
        if fm.fileExists(atPath: o.path), !fm.fileExists(atPath: n.path) { try? fm.moveItem(at: o, to: n) }
        return n
    }
}
