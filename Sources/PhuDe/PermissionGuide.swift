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

/// Hộp thoại hướng dẫn cấp quyền Ghi màn hình: hiện khi mở app mà chưa có quyền (sau hướng dẫn lần đầu), khi bấm một tính năng
/// cần chụp màn hình, hoặc khi macOS từ chối chụp. macOS chỉ áp quyền mới sau khi app mở lại, nên có nút mở lại OverSub.
@MainActor
final class PermissionGuide {
    static let shared = PermissionGuide()
    private var panel: NSPanel?

    var isShowing: Bool { panel != nil }

    func show(relaunch: @escaping () -> Void) {
        guard panel == nil else { panel?.orderFrontRegardless(); return }
        DebugLog.write("Thiếu quyền Ghi màn hình: hiện hướng dẫn cấp quyền")
        let view = PermissionGuideView(
            openSettings: { NSWorkspace.shared.open(ScreenPermission.settingsURL) },
            relaunch: { [weak self] in self?.hide(); relaunch() },
            close: { [weak self] in self?.hide() })
        panel = NoticePanel.show(view, on: NSScreen.main)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                    .frame(width: 52)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("OverSub cần quyền Ghi màn hình", "OverSub needs Screen Recording permission"))
                        .font(.headline)
                    Text(L("OverSub đọc phụ đề bằng cách chụp vùng bạn chọn trên màn hình. Ảnh chụp chỉ được xử lý ngay trên máy, không gửi đi đâu.",
                           "OverSub reads subtitles by capturing the region you select on screen. Captures are processed on your Mac and never sent anywhere."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        step(1, L("Bấm Mở Cài đặt hệ thống.", "Click Open System Settings."))
                        step(2, L("Ở mục Ghi màn hình & âm thanh hệ thống (Screen & System Audio Recording), bật OverSub. Nếu chưa thấy OverSub, bấm dấu + rồi chọn OverSub trong thư mục Applications.",
                                  "Under Screen & System Audio Recording, turn on OverSub. If OverSub isn't listed, click + and choose OverSub in the Applications folder."))
                        step(3, L("Quay lại đây và bấm Mở lại OverSub để quyền có hiệu lực.", "Come back here and click Reopen OverSub so the permission takes effect."))
                    }
                    .padding(.top, 2)
                }
            }
            HStack(spacing: 10) {
                Button(L("Để sau", "Later"), action: close)
                    .buttonStyle(.link)
                Spacer(minLength: 8)
                Button(L("Mở lại OverSub", "Reopen OverSub"), action: relaunch)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .fixedSize()
                Button(L("Mở Cài đặt hệ thống", "Open System Settings"), action: openSettings)
                    .buttonStyle(CTAButtonStyle())
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(20)
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        .padding(12)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 18, height: 18)
                .background(Circle().fill(.quaternary))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
