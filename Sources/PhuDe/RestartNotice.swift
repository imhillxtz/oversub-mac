import AppKit
import SwiftUI

/// Hộp thoại báo trước khi app tự khởi động lại vì Vision treo (xem VisionGuard): nằm giữa màn hình có game, đếm ngược vài
/// giây để người chơi biết chuyện gì đang xảy ra, không tưởng app tự tắt vì lỗi. Có nút khởi động lại ngay cho ai không muốn chờ.
/// Hiện trên Space người chơi đang ở, kể cả game toàn màn hình (cùng cách đặt với lớp phụ đề); không giành tiêu điểm của game.
@MainActor
final class RestartNotice {
    static let shared = RestartNotice()

    final class Model: ObservableObject {
        @Published var seconds = 3
    }

    private let model = Model()
    private var panel: NSPanel?
    private var countdown: Task<Void, Never>?

    /// Hiện hộp thoại giữa màn hình `screen`, đếm ngược `seconds` giây rồi gọi `restart`. Bấm "Khởi động lại ngay" thì gọi luôn.
    func show(on screen: NSScreen?, seconds: Int = 5, restart: @escaping () -> Void) {
        hide()
        model.seconds = seconds
        var fired = false
        let fire = { [weak self] in
            guard !fired else { return }
            fired = true
            self?.countdown?.cancel()
            restart()
        }
        let host = NSHostingView(rootView: RestartNoticeView(model: model, restartNow: fire))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = host
        if let f = (screen ?? NSScreen.main)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2))
        }
        p.orderFrontRegardless()
        panel = p
        countdown = Task { @MainActor [weak self] in
            for left in stride(from: seconds - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.model.seconds = left
            }
            fire()
        }
    }

    func hide() {
        countdown?.cancel()
        countdown = nil
        panel?.orderOut(nil)
        panel = nil
    }

    #if DEVTOOLS
    var debugPanel: NSPanel? { panel }
    #endif
}

private struct RestartNoticeView: View {
    @ObservedObject var model: RestartNotice.Model
    let restartNow: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Mascot(mood: .asleep, size: 52)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Bộ nhận chữ của macOS không phản hồi", "macOS text recognition stopped responding"))
                    .font(.headline)
                Text(L("Vision, phần nhận chữ có sẵn trong macOS, đang bị treo nên OverSub không đọc được phụ đề. OverSub sẽ tự khởi động lại và chạy tiếp, bạn không cần thao tác gì.",
                       "Vision, the text recognition built into macOS, is stuck, so OverSub can't read subtitles. OverSub will restart and pick up where it left off. You don't need to do anything."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Text(model.seconds > 0 ? L("Khởi động lại sau \(model.seconds) giây", "Restarting in \(model.seconds) s")
                                           : L("Đang khởi động lại…", "Restarting…"))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 8)
                    Button(L("Khởi động lại ngay", "Restart now"), action: restartNow)
                        .buttonStyle(CTAButtonStyle())
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(width: 500)
        // Nền đặc như hộp thoại chuẩn: nằm trên nội dung bất kỳ (cả cảnh game sáng, rối) mà chữ vẫn dễ đọc.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        .padding(12)   // chừa chỗ cho bóng
    }
}
