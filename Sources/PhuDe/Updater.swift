import AppKit
import CryptoKit
import Foundation

/// Kiểm tra và cài bản mới từ trang Releases của kho GitHub.
///
/// Mỗi bản phát hành kèm file `.dmg` và chữ ký Ed25519 của nó (`.dmg.sig`, ký bằng khoá bí mật chỉ nằm trên máy tác giả,
/// xem `Tools/sign_update.swift`). App chỉ cài file có chữ ký khớp khoá công khai nhúng dưới đây, nên kể cả khi trang
/// Releases bị chiếm, kẻ gian cũng không đẩy được bản giả. Cài: chờ app thoát, mở `.dmg`, chép app mới vào cạnh app cũ rồi
/// đổi chỗ (lỗi giữa chừng thì trả app cũ về), mở lại nếu cần. App ký theo định danh cố định nên quyền Ghi màn hình giữ nguyên.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "imhillxtz/oversub-mac"
    /// Khoá công khai Ed25519 (32 byte, base64) ứng với khoá ký ở `~/Library/Application Support/OverSub Release`.
    static let publicKey = "BLPVVKSgCCcaMlI7x3dJdm0EKBaZalrEGOhC4BXv8Is="

    struct Release: Equatable {
        var version: String
        var notes: String
        var page: URL
        var dmg: URL
        var signature: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, Double)
        case ready(Release, URL)      // đã tải và kiểm chữ ký xong, chờ cài
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    @Published var autoCheck: Bool { didSet { d.set(autoCheck, forKey: "updateAutoCheck") } }
    @Published var autoInstall: Bool { didSet { d.set(autoInstall, forKey: "updateAutoInstall") } }
    /// Người dùng bấm "Để sau" ở thông báo trên cửa sổ chính: không nhắc lại bản này nữa (vẫn thấy ở Cài đặt).
    @Published var dismissedVersion: String? { didSet { d.set(dismissedVersion, forKey: "updateDismissed") } }

    private let d = UserDefaults.standard
    private var timer: Timer?

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    private init() {
        autoCheck = d.object(forKey: "updateAutoCheck") as? Bool ?? true
        autoInstall = d.object(forKey: "updateAutoInstall") as? Bool ?? false
        dismissedVersion = d.string(forKey: "updateDismissed")
        lastChecked = d.object(forKey: "updateLastChecked") as? Date
        // Tự cài khi thoát: bản mới đã tải sẵn thì thay app lúc app đóng, lần mở sau là bản mới, không làm gián đoạn lúc chơi.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let u = Updater.shared
                if u.autoInstall, case .ready(_, let file) = u.state { u.runInstaller(dmg: file, relaunch: false) }
            }
        }
    }

    /// Bản mới đang chờ (để hiện thông báo), nil nếu không có.
    var pending: Release? {
        switch state {
        case .available(let r), .downloading(let r, _), .ready(let r, _): return r
        default: return nil
        }
    }

    // MARK: Kiểm tra

    /// Lúc mở app: kiểm tra sau ít giây (không tranh mạng với lúc khởi động), rồi mỗi 12 giờ một lần nếu bật tự kiểm tra.
    func start() {
        guard autoCheck else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if let last = lastChecked, Date().timeIntervalSince(last) < 6 * 3600 { return }
            await check(manual: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { if Updater.shared.autoCheck { Task { await Updater.shared.check(manual: false) } } }
        }
    }

    func check(manual: Bool) async {
        switch state {
        case .checking, .downloading, .installing: return
        case .ready: if !manual { return }
        default: break
        }
        state = .checking
        do {
            let release = try await fetchLatest()
            lastChecked = Date()
            d.set(lastChecked, forKey: "updateLastChecked")
            guard let release, Self.isNewer(release.version, than: Self.currentVersion) else {
                state = .upToDate
                DebugLog.write("Cập nhật: đang là bản mới nhất (\(Self.currentVersion))")
                return
            }
            DebugLog.write("Cập nhật: có bản \(release.version) (đang dùng \(Self.currentVersion))")
            state = .available(release)
            if autoInstall { await download(release) }
        } catch {
            state = manual ? .failed(error.localizedDescription) : .idle
            DebugLog.write("Cập nhật: không kiểm tra được: \(error.localizedDescription)")
        }
    }

    private func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: Self.feedURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("OverSub/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 { return nil }   // chưa có bản phát hành nào
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { throw UpdateError(L("Trang Releases trả về dữ liệu lạ.", "The Releases page returned unexpected data.")) }
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        }
        guard let dmg = asset(".dmg") else { return nil }   // bản phát hành không kèm file cài
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(Self.repo)/releases")!
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: (json["body"] as? String) ?? "", page: page, dmg: dmg, signature: asset(".dmg.sig"))
    }

    private static var feedURL: URL {
        #if DEVTOOLS
        // Thử không cần phát hành thật: OVERSUB_UPDATE_FEED=file:///…/latest.json theo đúng dạng API của GitHub.
        if let s = ProcessInfo.processInfo.environment["OVERSUB_UPDATE_FEED"], let u = URL(string: s) { return u }
        #endif
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    /// So phiên bản dạng 1.2.3 theo từng số.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: Tải và kiểm chữ ký

    func download(_ release: Release) async {
        state = .downloading(release, 0)
        do {
            guard let sigURL = release.signature else {
                throw UpdateError(L("Bản \(release.version) không kèm chữ ký số nên app không tự cài được. Bạn tải tay ở trang Releases nhé.", "Version \(release.version) has no signature, so it can't be installed automatically. Download it from the Releases page."))
            }
            let (sigData, _) = try await URLSession.shared.data(from: sigURL)
            let watcher = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(0.2))
                    guard let self, let p = DownloadBox.current?.task?.progress.fractionCompleted else { continue }
                    if case .downloading = self.state { self.state = .downloading(release, p) }
                }
            }
            defer { watcher.cancel() }
            let file = try await fetch(release.dmg) { [weak self] p in self?.state = .downloading(release, p) }
            let data = try Data(contentsOf: file)
            guard let sigText = String(data: sigData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let sig = Data(base64Encoded: sigText),
                  let keyData = Data(base64Encoded: Self.publicKey),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                  key.isValidSignature(sig, for: data) else {
                try? FileManager.default.removeItem(at: file)
                throw UpdateError(L("Chữ ký của bản tải về không khớp, app đã huỷ để an toàn.", "The download's signature doesn't match; it was discarded for safety."))
            }
            DebugLog.write("Cập nhật: đã tải \(release.version), chữ ký hợp lệ")
            state = .ready(release, file)
        } catch {
            DebugLog.write("Cập nhật: tải không được: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Tải cả file về thư mục tạm (một lần, nhanh), báo tiến độ bằng cách hỏi tiến độ của tác vụ tải mỗi 0,2 giây.
    /// Đọc từng byte như trước thì file 3 MB mất tới 30 giây.
    private func fetch(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("OverSub-update-\(UUID().uuidString).dmg")
        let box = DownloadBox()
        let result: URL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { tmp, resp, error in
                if let error { cont.resume(throwing: error); return }
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    cont.resume(throwing: UpdateError(L("Tải bản cập nhật lỗi HTTP \(http.statusCode).", "Download failed with HTTP \(http.statusCode).")))
                    return
                }
                guard let tmp else { cont.resume(throwing: UpdateError(L("Không tải được bản cập nhật.", "Couldn't download the update."))); return }
                do {
                    try FileManager.default.moveItem(at: tmp, to: dest)   // file tạm bị xoá ngay khi hàm này trả về
                    cont.resume(returning: dest)
                } catch { cont.resume(throwing: error) }
            }
            box.task = task
            task.resume()
        }
        _ = result
        return dest
    }

    /// Nút "Cập nhật" ở thông báo, menu: tải (nếu chưa) rồi cài và mở lại.
    func updateNow() {
        switch state {
        case .available(let r):
            Task { await download(r); if case .ready = state { installNow() } }
        case .ready:
            installNow()
        case .failed:
            Task { await check(manual: true) }
        default:
            break
        }
    }

    // MARK: Cài

    /// Thư mục chứa app có ghi được không (app nằm trong thư mục người dùng có quyền, như Applications của máy cá nhân).
    var canInstallInPlace: Bool {
        let target = Self.installTarget
        return FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: target.path)
    }

    private static var installTarget: URL {
        #if DEVTOOLS
        if let s = ProcessInfo.processInfo.environment["OVERSUB_UPDATE_TARGET"] { return URL(fileURLWithPath: s) }
        #endif
        return Bundle.main.bundleURL
    }

    /// Thay app bằng bản mới rồi mở lại. Không ghi được vào thư mục chứa app thì mở file .dmg để người dùng tự kéo vào.
    func installNow() {
        guard case .ready(_, let file) = state else { return }
        guard canInstallInPlace else {
            NSWorkspace.shared.open(file)
            return
        }
        state = .installing
        runInstaller(dmg: file, relaunch: true)
        #if DEVTOOLS
        if ProcessInfo.processInfo.environment["OVERSUB_UPDATE_TARGET"] != nil { return }   // thử cài vào bản sao, không thoát app
        #endif
        NSApp.terminate(nil)
    }

    /// Chạy một tiến trình riêng: chờ app thoát, mở .dmg, chép app mới vào cạnh app cũ rồi đổi chỗ; lỗi thì trả app cũ về.
    private func runInstaller(dmg: URL, relaunch: Bool) {
        let script = """
        PID="$1"; DMG="$2"; TARGET="$3"; RELAUNCH="$4"; LOG="$5"
        exec >>"$LOG" 2>&1
        echo "$(date '+%F %T') cài $DMG vào $TARGET"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
        MNT=$(mktemp -d "${TMPDIR:-/tmp}/oversub-mount.XXXXXX") || exit 1
        fail() { echo "$(date '+%F %T') lỗi: $1"; hdiutil detach "$MNT" -quiet 2>/dev/null; rmdir "$MNT" 2>/dev/null; rm -rf "$NEW"; rm -f "$DMG"; exit 1; }
        NEW="$TARGET.update-new"; OLD="$TARGET.update-old"
        hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null || fail "không mở được file cài"
        rm -rf "$NEW" "$OLD"
        ditto "$MNT/OverSub.app" "$NEW" || fail "không chép được app mới"
        hdiutil detach "$MNT" -quiet; rmdir "$MNT" 2>/dev/null
        if mv "$TARGET" "$OLD" && mv "$NEW" "$TARGET"; then rm -rf "$OLD"; else
          [ -d "$OLD" ] && [ ! -d "$TARGET" ] && mv "$OLD" "$TARGET"; fail "không thay được app cũ, đã giữ nguyên bản cũ"
        fi
        rm -f "$DMG"
        echo "$(date '+%F %T') xong"
        [ "$RELAUNCH" = "1" ] && open "$TARGET"
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        #if DEVTOOLS
        let waitFor = ProcessInfo.processInfo.environment["OVERSUB_UPDATE_TARGET"] != nil ? "999999" : String(ProcessInfo.processInfo.processIdentifier)
        #else
        let waitFor = String(ProcessInfo.processInfo.processIdentifier)
        #endif
        let log = AppPaths.logs.appendingPathComponent("update.log").path
        p.arguments = ["-c", script, "oversub-update", waitFor, dmg.path, Self.installTarget.path, relaunch ? "1" : "0", log]
        do {
            try p.run()
            DebugLog.write("Cập nhật: bắt đầu cài vào \(Self.installTarget.path)")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Giữ tác vụ tải đang chạy để vòng báo tiến độ đọc được.
final class DownloadBox: @unchecked Sendable {
    nonisolated(unsafe) static var current: DownloadBox?
    var task: URLSessionDownloadTask?
    init() { DownloadBox.current = self }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
