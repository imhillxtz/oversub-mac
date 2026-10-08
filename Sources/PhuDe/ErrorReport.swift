import AppKit

/// Gửi báo lỗi qua email: gói nhật ký và thông tin máy thành một tệp .zip, rồi mở thư soạn sẵn trong app Mail có đính kèm tệp đó,
/// gửi tới hộp thư hỗ trợ. Người dùng xem được thư và tệp trước khi bấm gửi; app không tự gửi gì. Máy chưa cài tài khoản Mail
/// thì mở thư trống qua mailto (không đính kèm được) và mở Finder ở tệp .zip để người dùng tự đính kèm.
@MainActor
enum ErrorReport {
    /// Hộp thư nhận báo lỗi (người dùng chọn ngày 08/10/2026, công khai trong app).
    static let supportEmail = "hillx.design@gmail.com"

    static func send(reason: String? = nil) {
        DebugLog.write("Báo lỗi: tạo gói nhật ký" + (reason.map { " (\($0))" } ?? ""))
        // Chờ dòng nhật ký vừa ghi xuống đĩa rồi mới chép tệp.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.3))
            guard let zip = makeArchive() else {
                DebugLog.write("Báo lỗi: không tạo được gói, mở Finder ở nhật ký")
                DebugLog.reveal()
                return
            }
            compose(zip: zip, reason: reason)
        }
    }

    private static func compose(zip: URL, reason: String?) {
        let subject = L("[OverSub \(appVersion)] Báo lỗi", "[OverSub \(appVersion)] Bug report") + (reason.map { ": \($0)" } ?? "")
        let body = L("""
            Mô tả lỗi (bạn đang làm gì, chuyện gì xảy ra):



            Thông tin máy:
            \(summary())

            Tệp đính kèm có nhật ký của OverSub. Nhật ký có chữ đọc được trong game; bạn có thể mở tệp xem trước khi gửi.
            """, """
            What went wrong (what you were doing, what happened):



            System information:
            \(summary())

            The attached file contains OverSub's log. The log includes text read from your games; you can open the file to review it before sending.
            """)
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body, zip]) {
            service.recipients = [supportEmail]
            service.subject = subject
            service.perform(withItems: [body, zip])
            DebugLog.write("Báo lỗi: đã mở thư soạn sẵn trong Mail, đính kèm \(zip.lastPathComponent)")
            return
        }
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = supportEmail
        c.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body + "\n\n" + L("Vui lòng đính kèm tệp \(zip.lastPathComponent) vừa được mở trong Finder.",
                                                                "Please attach the file \(zip.lastPathComponent) that was just shown in Finder.")),
        ]
        if let url = c.url { NSWorkspace.shared.open(url) }
        NSWorkspace.shared.activateFileViewerSelecting([zip])
        DebugLog.write("Báo lỗi: không mở được thư soạn sẵn có đính kèm, mở mailto và Finder ở \(zip.lastPathComponent)")
    }

    /// Thư mục tạm gồm nhật ký và tệp thông tin máy, nén thành .zip đặt cạnh nhật ký (~/Library/Logs/OverSub).
    static func makeArchive() -> URL? {
        let fm = FileManager.default
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "OverSub-bao-loi-\(f.string(from: Date()))"
        let dir = fm.temporaryDirectory.appendingPathComponent(name)
        let zip = DebugLog.url.deletingLastPathComponent().appendingPathComponent(name + ".zip")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: DebugLog.url.path) {
                try fm.copyItem(at: DebugLog.url, to: dir.appendingPathComponent("debug.log"))
            }
            let info = summary() + "\n\n" + L("Các dòng nhật ký đáng chú ý gần đây:", "Recent notable log lines:") + "\n" + notableLines()
            try info.write(to: dir.appendingPathComponent("thong-tin-may.txt"), atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", dir.path, zip.path]   // không kèm tệp ẩn ._
            try p.run()
            p.waitUntilExit()
            try? fm.removeItem(at: dir)
            guard p.terminationStatus == 0, fm.fileExists(atPath: zip.path) else {
                DebugLog.write("Báo lỗi: ditto thoát với mã \(p.terminationStatus)")
                return nil
            }
            return zip
        } catch {
            DebugLog.write("Báo lỗi: không tạo được gói: \(error.localizedDescription)")
            return nil
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Thông tin máy và cài đặt chính, không có key, thuật ngữ hay chỉ dẫn văn phong của người dùng.
    static func summary() -> String {
        let s = AppSettings.shared
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let ram = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        let cache = FileManager.default.fileExists(atPath: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "vn.imhillxtz.phude")
            .appendingPathComponent("com.apple.e5rt.e5bundlecache").path)
        let voice = !s.speakEnabled ? L("tắt", "off") : (s.dubCharacters ? "Dub" : "Voice-over")
        let screen = s.screenTranslateEnabled ? L("bật, \(s.secondaryRegions.count) vùng", "on, \(s.secondaryRegions.count) regions") : L("tắt", "off")
        return [
            "OverSub \(appVersion) (\(build))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            L("Máy: \(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string")), RAM \(ram) GB",
              "Mac: \(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string")), RAM \(ram) GB"),
            L("Giao diện: \(Lang.isEnglish ? "English" : "Tiếng Việt")", "Interface: \(Lang.isEnglish ? "English" : "Vietnamese")"),
            L("Quyền Ghi màn hình: \(ScreenPermission.granted ? "có" : "chưa có")", "Screen Recording: \(ScreenPermission.granted ? "granted" : "not granted")"),
            L("Bộ nhớ đệm nhận chữ: \(cache ? "có" : "chưa có")", "Text recognition cache: \(cache ? "present" : "missing")"),
            L("Ngôn ngữ: \(s.sourceLanguage) → \(s.target.displayName)", "Languages: \(s.sourceLanguage) → \(s.target.displayName)"),
            L("Cách bắt thoại: \(s.captureMode), hiển thị: \(s.outputMode)", "Capture mode: \(s.captureMode), output: \(s.outputMode)"),
            L("Giọng đọc: \(voice), dịch màn hình: \(screen)", "Voice: \(voice), screen translation: \(screen)"),
            L("Vùng phụ đề: \(s.region == nil ? "chưa chọn" : "đã chọn")", "Subtitle region: \(s.region == nil ? "not set" : "set")"),
        ].joined(separator: "\n")
    }

    /// Tối đa 60 dòng nhật ký gần nhất về lỗi, Vision, quyền, khởi động lại.
    private static func notableLines() -> String {
        guard let text = try? String(contentsOf: DebugLog.url, encoding: .utf8) else { return "-" }
        let keys = ["Lỗi", "Vision", "treo", "quyền", "Mở lại", "khởi động lại", "Không "]
        let lines = text.split(separator: "\n").filter { line in keys.contains { line.contains($0) } }
        return lines.suffix(60).joined(separator: "\n")
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buf)
    }
}
