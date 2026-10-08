import AppKit
import Combine
import SwiftUI

/// Hộp thoại cập nhật: kết quả kiểm tra bản mới, những thay đổi kể từ bản đang dùng, và các nút cập nhật ngay trên đó. Mở từ
/// menu Kiểm tra cập nhật…, từ "Có gì mới" ở thông báo bản mới, từ menu trên thanh menu, hoặc khi bấm Kiểm tra ngay ở Cài đặt
/// mà có bản mới. Lần tự kiểm tra định kỳ không mở hộp thoại này (người dùng có thể đang chơi), chỉ hiện thông báo nhỏ ở chân
/// cửa sổ chính.
@MainActor
final class UpdatePrompt: NSObject, NSWindowDelegate {
    static let shared = UpdatePrompt()
    private var window: NSWindow?
    private var stateWatch: AnyCancellable?

    /// Mở hộp thoại ở trạng thái đang kiểm tra rồi kiểm tra; kết quả hiện ngay trong hộp thoại.
    func checkNow() {
        show()
        Task { await Updater.shared.check(manual: true) }
    }

    func show() {
        if window == nil {
            let host = NSHostingView(rootView: UpdatePromptView(close: { [weak self] in self?.close() }))
            host.sizingOptions = []   // cỡ cửa sổ do fit(_:to:) đặt, không để SwiftUI tự kéo (xem DialogWindow)
            let w = DialogWindow.make(host, title: L("Cập nhật OverSub", "OverSub Update"), size: Self.measure())
            w.delegate = self
            window = w
            // Trạng thái đổi (đang kiểm tra → có bản mới, đang tải…) thì đo lại một lần. $state báo trước khi giá trị đổi, nên
            // đo ở vòng chạy kế tiếp.
            stateWatch = Updater.shared.$state.removeDuplicates().sink { [weak self] _ in
                DispatchQueue.main.async { self?.refit() }
            }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func refit() {
        guard let window else { return }
        DialogWindow.fit(window, to: Self.measure())
    }

    /// Cỡ nội dung theo trạng thái hiện tại, đo trên một bản sao không nằm trong cửa sổ (xem DialogWindow.fit).
    private static func measure() -> NSSize {
        NSHostingView(rootView: UpdatePromptView(close: {})).fittingSize
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        DebugLog.write("Hộp thoại cập nhật: đóng")
        stateWatch = nil
        window = nil
    }

    #if DEVTOOLS
    var debugWindow: NSWindow? { window }
    #endif
}

private struct UpdatePromptView: View {
    @ObservedObject private var u = Updater.shared
    let close: () -> Void

    var body: some View {
        DialogLayout(width: 600) { content }
    }

    @ViewBuilder private var content: some View {
        switch u.state {
        case .idle, .checking:
            DialogHeader(title: L("Đang kiểm tra bản mới…", "Checking for updates…"),
                         message: L("Bạn đang dùng bản \(Updater.currentVersion).", "You're on version \(Updater.currentVersion)."))
            ProgressView().progressViewStyle(.linear).padding(.top, 2)
            HStack {
                Spacer()
                Button(L("Huỷ", "Cancel"), action: close)
                    .buttonStyle(DialogButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        case .upToDate:
            DialogHeader(title: L("OverSub đang là bản mới nhất", "OverSub is up to date"),
                         message: L("Bạn đang dùng bản \(Updater.currentVersion), là bản mới nhất hiện có.",
                                    "You're on version \(Updater.currentVersion), the latest available."))
            HStack {
                Spacer()
                Button(L("Đóng", "Close"), action: close)
                    .buttonStyle(DialogButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        case .failed(let detail):
            DialogHeader(title: L("Chưa cập nhật được", "Couldn't update"),
                         message: L("Vui lòng kiểm tra kết nối mạng rồi bấm Thử lại, hoặc tải bản mới ở trang phát hành.",
                                    "Check your internet connection and click Try Again, or download the new version from the Releases page."))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Link(L("Mở trang phát hành", "Open Releases Page"),
                     destination: URL(string: "https://github.com/\(Updater.repo)/releases")!)
                    .font(.callout)
                Spacer(minLength: 8)
                Button(L("Đóng", "Close"), action: close)
                    .buttonStyle(DialogButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(L("Thử lại", "Try Again")) { u.updateNow() }
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        case .installing:
            DialogHeader(title: L("Đang cài bản mới", "Installing the update"),
                         message: L("OverSub sẽ tự thoát và mở lại sau vài giây.", "OverSub will quit and reopen in a few seconds."))
            ProgressView().progressViewStyle(.linear).padding(.top, 2)
        case .available(let r), .downloading(let r, _), .ready(let r, _):
            DialogHeader(title: L("Đã có OverSub \(r.version)", "OverSub \(r.version) is available"),
                         message: L("Bạn đang dùng bản \(Updater.currentVersion). Cài đặt, key và quyền Ghi màn hình được giữ nguyên khi cập nhật.",
                                    "You're on version \(Updater.currentVersion). Your settings, keys and Screen Recording permission are kept when you update."))
            ReleaseNotesBox(changes: r.changes.isEmpty ? [Updater.Change(version: r.version, notes: r.notes)] : r.changes)
            footer(r).padding(.top, 4)
        }
    }

    @ViewBuilder private func footer(_ r: Updater.Release) -> some View {
        HStack(spacing: 8) {
            if case .downloading(_, let p) = u.state {
                ProgressView(value: p).frame(width: 160)
                Text(L("Đang tải \(Int(p * 100))%", "Downloading \(Int(p * 100))%"))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // Đóng hộp thoại thì vẫn tải tiếp; thông báo ở chân cửa sổ chính báo tiến độ.
                Button(L("Để sau", "Later"), action: close)
                    .buttonStyle(DialogButtonStyle())
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(L("Bỏ qua bản này", "Skip This Version")) { u.dismissedVersion = r.version; close() }
                    .buttonStyle(.link)
                    .font(.callout)
                Spacer(minLength: 8)
                Button(L("Để sau", "Later"), action: close)
                    .buttonStyle(DialogButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(primaryLabel) { u.updateNow() }
                    .buttonStyle(DialogButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var primaryLabel: String {
        if case .ready = u.state {
            return u.canInstallInPlace ? L("Cài và mở lại", "Install and Relaunch") : L("Mở tệp cài", "Open Installer")
        }
        return L("Cập nhật", "Update")
    }
}

/// Khung ghi chú phát hành: cao cố định 260 điểm, dài hơn thì cuộn, mép dưới mờ dần.
private struct ReleaseNotesBox: View {
    let changes: [Updater.Change]
    @State private var contentHeight: CGFloat = 0
    /// Cao cố định để cỡ hộp thoại không phụ thuộc vào việc đo ghi chú (đo theo nội dung từng làm cửa sổ co giãn).
    private static let height: CGFloat = 260
    private var overflows: Bool { contentHeight > Self.height }

    var body: some View {
        ScrollView {
            ReleaseNotesList(changes: changes)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, overflows ? 22 : 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in Color.clear.preference(key: NotesHeightKey.self, value: g.size.height) })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: Self.height)
        // Còn chữ bên dưới thì mờ dần ở mép dưới, để biết là cuộn được.
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: overflows ? 28 : 0)
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .onPreferenceChange(NotesHeightKey.self) { contentHeight = $0 }
    }
}

private struct NotesHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ReleaseNotesList: View {
    let changes: [Updater.Change]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 6) {
                    if changes.count > 1 {
                        Text(L("Bản \(change.version)", "Version \(change.version)")).font(.headline)
                    }
                    let blocks = ReleaseNotes.blocks(change.notes, english: Lang.isEnglish)
                    if blocks.isEmpty {
                        Text(L("Bản này không có ghi chú.", "No notes for this version.")).foregroundStyle(.secondary)
                    }
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in row(block) }
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ block: ReleaseNotes.Block) -> some View {
        switch block {
        case .heading(let t):
            Text(t).font(.callout.weight(.semibold)).padding(.top, 2)
        case .bullet(let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(t).fixedSize(horizontal: false, vertical: true)
            }
        case .text(let t):
            inline(t).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
        return Text(s)
    }
}

/// Tách ghi chú phát hành (Markdown song ngữ theo Docs/RELEASE_TEMPLATE.md) lấy phần đúng ngôn ngữ giao diện, bỏ mục Tải về
/// (app tự cập nhật nên không cần) và mục Ủng hộ (đã có nút Ủng hộ trong app).
enum ReleaseNotes {
    enum Block: Equatable {
        case heading(String)
        case bullet(String)
        case text(String)
    }

    static func blocks(_ body: String, english: Bool) -> [Block] {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        func isHeading(_ l: String, _ name: String) -> Bool {
            l.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("## " + name)
        }
        var part = lines[...]
        if let en = lines.firstIndex(where: { isHeading($0, "english") }) {
            if english {
                part = lines[(en + 1)...]
            } else {
                let start = lines.firstIndex(where: { isHeading($0, "tiếng việt") }).map { $0 + 1 } ?? 0
                part = start <= en ? lines[start..<en] : lines[..<en]
            }
        }
        let skipped = ["tải về", "download", "ủng hộ", "support"]
        var out: [Block] = []
        var skipping = false
        for raw in part {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") {
                let title = String(l.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                skipping = skipped.contains { title.lowercased().hasPrefix($0) }
                if !skipping, !title.isEmpty { out.append(.heading(title)) }
                continue
            }
            if skipping || l.isEmpty { continue }
            if l.hasPrefix("- ") || l.hasPrefix("* ") {
                out.append(.bullet(String(l.dropFirst(2))))
            } else {
                out.append(.text(l))
            }
        }
        // Bỏ tiêu đề không còn nội dung phía sau (mục chỉ có tiêu đề).
        return out.enumerated().filter { i, b in
            if case .heading = b { return i + 1 < out.count && { if case .heading = out[i + 1] { return false }; return true }() }
            return true
        }.map(\.element)
    }
}
