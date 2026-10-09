import AppKit
import SwiftUI

/// Gửi báo lỗi: gói nhật ký và thông tin máy thành một tệp .zip, rồi hiện cửa sổ nhỏ có tệp đó (kéo thẳng vào trang báo lỗi
/// được) và hai cách gửi: mở trang Issue mới trên GitHub với tiêu đề và thông tin máy điền sẵn (cách chính), hoặc mở thư trong
/// app thư mặc định tới hộp thư hỗ trợ (cho người không có tài khoản GitHub). App không tự gửi gì.
///
/// Bản 1.1.65 mở thư soạn sẵn có đính kèm qua app Mail; Mail khởi động chậm (và hiện màn thêm tài khoản nếu chưa dùng Mail)
/// nên người dùng tưởng nút không phản hồi và bấm lại. Giờ cửa sổ hiện ngay sau khi gói xong, trình duyệt hay app thư chỉ mở
/// khi người dùng chọn.
@MainActor
enum ErrorReport {
    /// Hộp thư nhận báo lỗi (người dùng chọn ngày 08/10/2026, công khai trong app).
    static let supportEmail = "hillx.design@gmail.com"
    static let newIssueURL = "https://github.com/\(Updater.repo)/issues/new"

    private static var window: NSWindow?
    private static var dock: NSPanel?

    static func send(reason: String? = nil) {
        DebugLog.write("Báo lỗi: tạo gói nhật ký" + (reason.map { " (\($0))" } ?? ""))
        let started = Date()
        Task { @MainActor in
            // Chờ dòng nhật ký vừa ghi xuống đĩa rồi mới chép tệp.
            try? await Task.sleep(for: .seconds(0.2))
            guard let zip = await makeArchive() else {
                DebugLog.write("Báo lỗi: không tạo được gói, mở Finder ở nhật ký")
                DebugLog.reveal()
                return
            }
            show(zip: zip, reason: reason)
            DebugLog.write("Báo lỗi: hiện cửa sổ gửi sau \(Int(Date().timeIntervalSince(started) * 1000)) ms, tệp \(zip.lastPathComponent)")
        }
    }

    private static func show(zip: URL, reason: String?) {
        window?.close()
        hideDock()
        let view = ReportView(zip: zip,
                              openIssue: { openIssue(zip: zip, reason: reason) },
                              sendEmail: { sendEmail(zip: zip, reason: reason) },
                              close: { window?.close() })
        let w = DialogWindow.make(NSHostingView(rootView: view), title: L("Gửi báo lỗi", "Send Bug Report"))
        // Nổi trên trình duyệt để kéo tệp vào trang báo lỗi; hiện được cả khi bấm từ hộp thoại nằm trên game toàn màn hình.
        w.level = .floating
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    /// Sau khi mở trang báo lỗi hay app thư: thu hộp thoại thành thẻ nhỏ chỉ có tệp, đặt ở mép phải giữa màn hình (ngang cột
    /// bên của trang GitHub, không che ô nội dung hay nút Create). Thẻ là bảng nổi trên mọi Space như các thông báo khác, nên
    /// vẫn thấy khi trình duyệt chạy toàn màn hình (cửa sổ thường ở lại Space cũ, thử ngày 08/10/2026).
    private static func showDock(zip: URL) {
        let screen = window?.screen ?? NSScreen.main
        window?.close()
        hideDock()
        let p = NoticePanel.make(ReportDockView(zip: zip, close: { hideDock() }), level: .floating)
        if let v = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: v.maxX - p.frame.width - 4, y: v.midY - p.frame.height / 2))
        }
        p.orderFrontRegardless()
        dock = p
    }

    private static func hideDock() {
        dock?.orderOut(nil)
        dock = nil
    }

    static func issueURL(zip: URL, reason: String?) -> URL? {
        let title = "[OverSub \(appVersion)] " + (reason ?? L("Báo lỗi", "Bug report"))
        let body = L("""
            **Mô tả lỗi** (bạn đang làm gì, chuyện gì xảy ra):



            **Tệp nhật ký:** kéo tệp `\(zip.lastPathComponent)` từ thẻ Đính kèm tệp báo lỗi của OverSub (mép phải màn hình) vào ô này.

            **Thông tin máy:**
            ```
            \(summary())
            ```
            """, """
            **What went wrong** (what you were doing, what happened):



            **Log file:** drag `\(zip.lastPathComponent)` from OverSub's Attach the bug report file card (right edge of the screen) into this box.

            **System information:**
            ```
            \(summary())
            ```
            """)
        var c = URLComponents(string: newIssueURL)
        c?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        return c?.url
    }

    private static func openIssue(zip: URL, reason: String?) {
        guard let url = issueURL(zip: zip, reason: reason) else { return }
        NSWorkspace.shared.open(url)
        DebugLog.write("Báo lỗi: mở trang Issue trên GitHub (\(url.absoluteString.count) ký tự)")
        showDock(zip: zip)
    }

    private static func sendEmail(zip: URL, reason: String?) {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = supportEmail
        c.queryItems = [
            URLQueryItem(name: "subject", value: "[OverSub \(appVersion)] " + (reason ?? L("Báo lỗi", "Bug report"))),
            URLQueryItem(name: "body", value: L("""
                Mô tả lỗi (bạn đang làm gì, chuyện gì xảy ra):



                Vui lòng đính kèm tệp \(zip.lastPathComponent) (kéo từ thẻ Đính kèm tệp báo lỗi của OverSub ở mép phải màn hình vào thư này).

                Thông tin máy:
                \(summary())
                """, """
                What went wrong (what you were doing, what happened):



                Please attach \(zip.lastPathComponent) (drag it from OverSub's Attach the bug report file card at the right edge of the screen into this email).

                System information:
                \(summary())
                """)),
        ]
        guard let url = c.url else { return }
        NSWorkspace.shared.open(url)
        DebugLog.write("Báo lỗi: mở thư trong app thư mặc định")
        showDock(zip: zip)
    }

    /// Thư mục tạm gồm nhật ký và tệp thông tin máy, nén thành .zip đặt cạnh nhật ký (~/Library/Logs/OverSub). Chép và nén
    /// chạy ngoài luồng chính để cửa sổ không khựng khi nhật ký lớn.
    static func makeArchive() async -> URL? {
        let info = summary() + "\n\n" + L("Các dòng nhật ký đáng chú ý gần đây:", "Recent notable log lines:") + "\n" + notableLines()
        return await Task.detached(priority: .userInitiated) { archive(info: info) }.value
    }

    nonisolated private static func archive(info: String) -> URL? {
        let fm = FileManager.default
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "OverSub-bao-loi-\(f.string(from: Date()))"
        let dir = fm.temporaryDirectory.appendingPathComponent(name)
        let zip = DebugLog.url.deletingLastPathComponent().appendingPathComponent(name + ".zip")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Kèm cả tệp trước lần xoay gần nhất: lỗi lặp thường phải đối chiếu nhiều buổi chơi.
            for log in [DebugLog.url, DebugLog.previousURL] where fm.fileExists(atPath: log.path) {
                try fm.copyItem(at: log, to: dir.appendingPathComponent(log.lastPathComponent))
            }
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

    /// Tối đa 60 dòng nhật ký gần nhất về lỗi, Vision, quyền, khởi động lại. Nhật ký vừa xoay chưa đủ dòng thì lấy thêm từ
    /// debug.1.log (chỉ đọc khi cần, để cửa sổ hiện nhanh như cũ).
    private static func notableLines() -> String {
        let keys = ["Lỗi", "Vision", "treo", "quyền", "Mở lại", "khởi động lại", "Không "]
        func notable(_ url: URL) -> [Substring]? {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return text.split(separator: "\n").filter { line in keys.contains { line.contains($0) } }
        }
        var lines = notable(DebugLog.url) ?? []
        if lines.count < 60, let older = notable(DebugLog.previousURL) { lines = older + lines }
        return lines.isEmpty ? "-" : lines.suffix(60).joined(separator: "\n")
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buf)
    }

    #if DEVTOOLS
    static var debugWindow: NSWindow? { window }
    /// Như bấm Mở trang báo lỗi (mở trình duyệt, dời cửa sổ sang góc).
    static func debugOpenIssue(zip: URL) { openIssue(zip: zip, reason: L("Thử báo lỗi", "Test report")) }
    static var debugDock: NSPanel? { dock }
    #endif
}

private struct ReportView: View {
    let zip: URL
    let openIssue: () -> Void
    let sendEmail: () -> Void
    let close: () -> Void

    var body: some View {
        DialogLayout(badge: "ladybug.fill", width: 560) {
            DialogHeader(title: L("Gửi báo lỗi", "Send a bug report"),
                         message: L("OverSub đã gói nhật ký và thông tin máy (không có key) vào tệp bên dưới. Nhật ký có chữ đọc được trong game; bạn có thể mở tệp xem trước khi gửi.",
                                    "OverSub packed the log and system information (no API keys) into the file below. The log includes text read from your games; you can open the file to review it before sending."))
            FileChip(zip: zip)
            VStack(alignment: .leading, spacing: 6) {
                DialogStep(n: 1, text: L("Bấm Mở trang báo lỗi. Trang Issue trên GitHub mở ra với tiêu đề và thông tin máy điền sẵn (cần đăng nhập GitHub).",
                                         "Click Open Bug Report Page. A new GitHub issue opens with the title and system information filled in (you need to sign in to GitHub)."))
                DialogStep(n: 2, text: L("Kéo tệp ở trên vào ô nội dung, mô tả ngắn lỗi bạn gặp rồi bấm Create.",
                                         "Drag the file above into the description box, describe what happened, then click Create."))
            }
            Text(L("Chưa có tài khoản GitHub? Bấm Gửi qua email rồi đính kèm tệp này vào thư gửi tới \(ErrorReport.supportEmail).",
                   "No GitHub account? Click Send by Email and attach this file to the email to \(ErrorReport.supportEmail)."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(L("Đóng", "Close"), action: close)
                    .buttonStyle(.link)
                    .font(.callout)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                Button(L("Gửi qua email", "Send by Email"), action: sendEmail)
                    .buttonStyle(DialogButtonStyle())
                Button(L("Mở trang báo lỗi", "Open Bug Report Page"), action: openIssue)
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }
}

/// Tệp báo lỗi: kéo thẳng vào trang báo lỗi hay vào thư, hoặc mở Finder ở tệp.
private struct FileChip: View {
    let zip: URL
    var compact = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: zip.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(zip.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if compact {
                    HStack(spacing: 4) {
                        Text(size).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.secondary)
                        finderLink
                    }
                    .font(.caption)
                } else {
                    Text(L("\(size) · Kéo tệp này vào trang báo lỗi", "\(size) · Drag this file into the report"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !compact {
                Spacer(minLength: 8)
                finderLink.font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(hovering ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .onHover { hovering = $0 }
        .pointerStyle(.grabIdle)
        .onDrag { NSItemProvider(object: zip as NSURL) }
    }

    private var finderLink: some View {
        Button(L("Hiện trong Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
            .buttonStyle(.link)
    }

    private var size: String {
        let bytes = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Thẻ nhỏ nổi ở mép phải sau khi mở trang báo lỗi hay app thư: chỉ còn tệp để kéo vào và lời nhắc bước cuối.
private struct ReportDockView: View {
    let zip: URL
    let close: () -> Void

    var body: some View {
        NoticeCard(width: 320) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text(L("Đính kèm tệp báo lỗi", "Attach the bug report file"))
                        .font(.headline)
                    Spacer(minLength: 4)
                    DialogCloseButton(action: close)
                }
                FileChip(zip: zip, compact: true)
                Text(L("Kéo tệp vào ô nội dung trên trang báo lỗi hoặc vào thư, mô tả lỗi rồi bấm gửi.",
                       "Drag the file into the description box on the report page or into your email, describe what happened, then send it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
