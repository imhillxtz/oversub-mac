import AppKit
import SwiftUI

/// Quyền Ghi màn hình: một chỗ kiểm duy nhất, để mọi tính năng chụp màn hình (Bắt đầu, chọn vùng, Dịch nhanh) cùng báo một
/// kiểu khi thiếu quyền, thay vì im lặng ("Chưa dịch được", trình chọn không có ảnh) như trước.
@MainActor
enum ScreenPermission {
    static var granted: Bool {
        #if DEVTOOLS
        // Thử khi thiếu quyền mà không phải gỡ quyền thật: OVERSUB_FAKE_NO_SCREEN_PERMISSION=1.
        if ProcessInfo.processInfo.environment["OVERSUB_FAKE_NO_SCREEN_PERMISSION"] != nil { return false }
        #endif
        return CGPreflightScreenCaptureAccess()
    }

    /// Trang Ghi màn hình & âm thanh hệ thống trong Cài đặt hệ thống.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

/// Hướng dẫn cấp quyền Ghi màn hình: hiện khi mở app mà chưa có quyền (sau hướng dẫn lần đầu), khi bấm một tính năng cần chụp
/// màn hình, hoặc khi macOS từ chối chụp. macOS chỉ áp quyền mới sau khi app mở lại, nên có nút mở lại OverSub.
///
/// Khi Cài đặt hệ thống mở ra (bằng nút của hướng dẫn hay nút của hộp thoại macOS), hướng dẫn thu gọn thành thẻ nhỏ đặt cạnh
/// cửa sổ Cài đặt, để không che danh sách quyền người dùng cần bật. Hướng dẫn ở tầng nổi thường, không ở tầng trên game như các
/// thông báo khác, để không che hộp thoại "thoát và mở lại" của macOS.
@MainActor
final class PermissionGuide {
    static let shared = PermissionGuide()
    static let settingsBundleID = "com.apple.systempreferences"

    private var panel: NSPanel?
    private var compact = false
    private var relaunch: (() -> Void)?
    private var docking: Task<Void, Never>?
    private var settingsObserver: NSObjectProtocol?

    var isShowing: Bool { panel != nil }

    func show(relaunch: @escaping () -> Void) {
        self.relaunch = relaunch
        guard panel == nil else { panel?.orderFrontRegardless(); return }
        DebugLog.write("Thiếu quyền Ghi màn hình: hiện hướng dẫn cấp quyền")
        compact = false
        panel = NoticePanel.show(PermissionGuideView(openSettings: { [weak self] in self?.openSettings() },
                                                     relaunch: { [weak self] in self?.reopen() },
                                                     close: { [weak self] in self?.hide() }),
                                 on: NSScreen.main, level: .floating)
        watchSettings()
    }

    func hide() {
        docking?.cancel()
        docking = nil
        if let settingsObserver { NSWorkspace.shared.notificationCenter.removeObserver(settingsObserver) }
        settingsObserver = nil
        panel?.orderOut(nil)
        panel = nil
        compact = false
    }

    func openSettings() {
        NSWorkspace.shared.open(ScreenPermission.settingsURL)
        dock()
    }

    private func reopen() {
        let action = relaunch
        hide()
        action?()
    }

    /// Cài đặt hệ thống được mở hoặc được chọn lại: thu gọn hướng dẫn và đặt cạnh nó. Thẻ đã thu gọn chỉ dời chỗ khi đang
    /// đè lên cửa sổ Cài đặt (người dùng kéo cửa sổ đi), không giật về khi người dùng tự kéo thẻ ra chỗ khác.
    private func watchSettings() {
        settingsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == PermissionGuide.settingsBundleID else { return }
            MainActor.assumeIsolated {
                let guide = PermissionGuide.shared
                guard guide.panel != nil else { return }
                if !guide.compact { guide.dock(); return }
                if let card = guide.panel?.frame, let settings = Self.settingsWindowFrame(), card.intersects(settings) { guide.dock() }
            }
        }
    }

    private func dock() {
        guard panel != nil else { return }
        docking?.cancel()
        // Ẩn bản đầy đủ ngay để không che Cài đặt trong lúc cửa sổ của nó đang mở ra.
        if !compact { panel?.orderOut(nil) }
        docking = Task { @MainActor [weak self] in
            let settings = await Self.waitForSettingsWindow()
            guard let self, !Task.isCancelled, self.panel != nil else { return }
            self.showCompact(beside: settings)
        }
    }

    private func showCompact(beside settings: NSRect?) {
        let p = NoticePanel.make(PermissionCompactView(openSettings: { [weak self] in self?.openSettings() },
                                                       relaunch: { [weak self] in self?.reopen() },
                                                       close: { [weak self] in self?.hide() }),
                                 level: .floating, movable: true)
        let screen = settings.flatMap { f in NSScreen.screens.first { $0.frame.intersects(f) } } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let origin = Self.dockOrigin(card: p.frame.size, settings: settings, visible: visible)
        p.setFrameOrigin(origin)
        panel?.orderOut(nil)
        p.orderFrontRegardless()
        panel = p
        compact = true
        DebugLog.write("Hướng dẫn cấp quyền: thu gọn, đặt ở \(Int(origin.x)),\(Int(origin.y)); cửa sổ Cài đặt "
                       + (settings.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "không thấy"))
    }

    /// Chỗ đặt thẻ thu gọn: bên phải cửa sổ Cài đặt, không vừa thì bên trái, rồi bên dưới. Màn hình hẹp không chỗ nào vừa thì
    /// đặt ở góc dưới bên trái, nếu có đè thì chỉ đè thanh bên của Cài đặt, không đè danh sách công tắc ở bên phải.
    /// `s` gồm cả viền trong suốt `pad` quanh thẻ (chỗ cho bóng), nên tính chỗ trống theo mép thẻ nhìn thấy.
    nonisolated static func dockOrigin(card s: NSSize, settings: NSRect?, visible v: NSRect, pad: CGFloat = 12) -> NSPoint {
        let gap: CGFloat = 8, margin: CGFloat = 4
        let w = s.width - 2 * pad, h = s.height - 2 * pad
        let corner = NSPoint(x: v.minX + margin - pad, y: v.minY + margin - pad)
        guard let f = settings else { return corner }
        let topY = min(max(f.maxY - h, v.minY + margin), v.maxY - h - margin) - pad
        if v.maxX - f.maxX >= w + gap + margin { return NSPoint(x: f.maxX + gap - pad, y: topY) }
        if f.minX - v.minX >= w + gap + margin { return NSPoint(x: f.minX - gap - w - pad, y: topY) }
        if f.minY - v.minY >= h + gap + margin {
            let x = min(max(f.midX - w / 2, v.minX + margin), v.maxX - w - margin)
            return NSPoint(x: x - pad, y: f.minY - gap - h - pad)
        }
        return corner
    }

    /// Chờ cửa sổ Cài đặt hệ thống hiện và đứng yên (tối đa 4 giây), trả về khung theo toạ độ AppKit.
    private static func waitForSettingsWindow() async -> NSRect? {
        var last: NSRect?
        for _ in 0..<27 {
            try? await Task.sleep(for: .seconds(0.15))
            if Task.isCancelled { return nil }
            let now = settingsWindowFrame()
            if let now, now == last { return now }
            last = now
        }
        return last
    }

    /// Khung cửa sổ chính của Cài đặt hệ thống. Danh sách cửa sổ vẫn cho biết vị trí và chủ cửa sổ khi chưa có quyền Ghi màn
    /// hình (chỉ giấu tên cửa sổ), nên dùng được đúng lúc cần.
    static func settingsWindowFrame() -> NSRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first?.frame else { return nil }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict),
                  r.width > 300, r.height > 200 else { continue }
            return NSRect(x: r.minX, y: primary.maxY - r.maxY, width: r.width, height: r.height)
        }
        return nil
    }

    #if DEVTOOLS
    var debugPanel: NSPanel? { panel }
    #endif
}

private struct PermissionGuideView: View {
    let openSettings: () -> Void
    let relaunch: () -> Void
    let close: () -> Void

    var body: some View {
        NoticeCard(width: 560) {
            HStack(alignment: .top, spacing: 16) {
                DialogAppIcon(badge: "record.circle")
                VStack(alignment: .leading, spacing: 12) {
                    DialogHeader(title: L("OverSub cần quyền Ghi màn hình", "OverSub needs Screen Recording permission"),
                                 message: L("OverSub đọc phụ đề bằng cách chụp vùng bạn chọn trên màn hình. Ảnh chụp chỉ được xử lý ngay trên máy, không gửi đi đâu.",
                                            "OverSub reads subtitles by capturing the region you select on screen. Captures are processed on your Mac and never sent anywhere."))
                    VStack(alignment: .leading, spacing: 6) {
                        DialogStep(n: 1, text: L("Bấm Mở Cài đặt hệ thống. Hướng dẫn này sẽ thu gọn và nằm cạnh cửa sổ Cài đặt.",
                                                 "Click Open System Settings. This guide will shrink and move next to the Settings window."))
                        DialogStep(n: 2, text: L("Ở mục Ghi màn hình & âm thanh hệ thống (Screen & System Audio Recording), bật OverSub. Nếu chưa thấy OverSub, bấm dấu + rồi chọn OverSub trong thư mục Applications.",
                                                 "Under Screen & System Audio Recording, turn on OverSub. If OverSub isn't listed, click + and choose OverSub in the Applications folder."))
                        DialogStep(n: 3, text: L("Bấm Mở lại OverSub để quyền có hiệu lực.", "Click Reopen OverSub so the permission takes effect."))
                    }
                    HStack(spacing: 8) {
                        Button(L("Để sau", "Later"), action: close)
                            .buttonStyle(.link)
                            .font(.callout)
                        Spacer(minLength: 8)
                        Button(L("Mở lại OverSub", "Reopen OverSub"), action: relaunch)
                            .buttonStyle(DialogButtonStyle())
                        Button(L("Mở Cài đặt hệ thống", "Open System Settings"), action: openSettings)
                            .buttonStyle(DialogButtonStyle(prominent: true))
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}

/// Thẻ thu gọn đặt cạnh Cài đặt hệ thống: nhắc việc cần bật và nút mở lại, đủ hẹp (340 điểm) để nằm cạnh cửa sổ Cài đặt trên
/// màn hình 13 inch mà không che danh sách quyền.
private struct PermissionCompactView: View {
    let openSettings: () -> Void
    let relaunch: () -> Void
    let close: () -> Void

    var body: some View {
        NoticeCard(width: 340) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 28, height: 28)
                    Text(L("Cấp quyền Ghi màn hình cho OverSub", "Give OverSub Screen Recording permission"))
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 5)
                    DialogCloseButton(action: close)
                }
                DialogStep(n: 1, text: L("Ở mục Ghi màn hình & âm thanh hệ thống, bật OverSub. Nếu chưa thấy OverSub, bấm dấu + rồi chọn OverSub trong thư mục Applications.",
                                         "Under Screen & System Audio Recording, turn on OverSub. If OverSub isn't listed, click + and choose OverSub in the Applications folder."))
                DialogStep(n: 2, text: L("Bấm Mở lại OverSub. Nếu macOS hỏi có thoát và mở lại OverSub không, hãy đồng ý.",
                                         "Click Reopen OverSub. If macOS asks whether to quit and reopen OverSub, agree."))
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(L("Mở Cài đặt", "Open Settings"), action: openSettings)
                        .buttonStyle(DialogButtonStyle())
                    Button(L("Mở lại OverSub", "Reopen OverSub"), action: relaunch)
                        .buttonStyle(DialogButtonStyle(prominent: true))
                }
                .padding(.top, 2)
            }
        }
    }
}
