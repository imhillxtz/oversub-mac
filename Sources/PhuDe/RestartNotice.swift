import AppKit
import SwiftUI

/// Bảng nổi dùng chung cho các thông báo về bộ nhận chữ và quyền: hiện trên Space người chơi đang ở, kể cả game toàn màn hình
/// (cùng cách đặt với lớp phụ đề), không giành tiêu điểm của game. Nền đặc như hộp thoại chuẩn để chữ dễ đọc trên mọi cảnh.
@MainActor
enum NoticePanel {
    enum Position { case center, top }

    static func show<V: View>(_ view: V, on screen: NSScreen?, at position: Position = .center) -> NSPanel {
        let host = NSHostingView(rootView: view)
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
            let y = position == .center ? f.midY - size.height / 2 : f.maxY - size.height - 8
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: y))
        }
        p.orderFrontRegardless()
        return p
    }
}

/// Khung chung của các thông báo: nền đặc bo góc, viền mảnh, chừa chỗ cho bóng.
private struct NoticeCard<Content: View>: View {
    var width: CGFloat = 500
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.1)))
            .padding(12)
    }
}

/// Hộp thoại báo trước khi app tự khởi động lại vì Vision treo (xem VisionGuard): đếm ngược vài giây để người chơi biết chuyện
/// gì đang xảy ra, không tưởng app tự tắt vì lỗi. Có nút khởi động lại ngay cho ai không muốn chờ. Nếu Vision lại treo ngay sau
/// lần tự khởi động lại, app không lặp nữa mà hiện kiểu "vẫn không phản hồi" để người dùng tự quyết.
@MainActor
final class RestartNotice {
    static let shared = RestartNotice()

    final class Model: ObservableObject {
        @Published var seconds = 5
    }

    private let model = Model()
    private var panel: NSPanel?
    private var countdown: Task<Void, Never>?

    /// Hiện hộp thoại giữa màn hình `screen`, đếm ngược `seconds` giây rồi gọi `restart`. Bấm "Khởi động lại ngay" thì gọi luôn.
    func show(on screen: NSScreen?, seconds: Int = 5, restart: @escaping () -> Void) {
        hide()
        model.seconds = seconds
        let fire = once { [weak self] in self?.countdown?.cancel(); restart() }
        panel = NoticePanel.show(RestartCountdownView(model: model, restartNow: fire), on: screen)
        countdown = Task { @MainActor [weak self] in
            for left in stride(from: seconds - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.model.seconds = left
            }
            fire()
        }
    }

    /// Vision lại treo trong vòng 10 phút sau lần tự khởi động lại: không đếm ngược, để người dùng chọn.
    func showStuckAgain(on screen: NSScreen?, restart: @escaping () -> Void) {
        hide()
        let fire = once { [weak self] in self?.hide(); restart() }
        panel = NoticePanel.show(StuckAgainView(restart: fire, openLog: { DebugLog.reveal() }, close: { [weak self] in self?.hide() }), on: screen)
    }

    func hide() {
        countdown?.cancel()
        countdown = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Bọc một việc để nó chỉ chạy một lần, dù bấm nút và hết giờ đếm ngược cùng lúc.
    private func once(_ action: @escaping () -> Void) -> () -> Void {
        var fired = false
        return { guard !fired else { return }; fired = true; action() }
    }

    #if DEVTOOLS
    var debugPanel: NSPanel? { panel }
    #endif
}

private struct RestartCountdownView: View {
    @ObservedObject var model: RestartNotice.Model
    let restartNow: () -> Void

    var body: some View {
        NoticeCard {
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
        }
    }
}

private struct StuckAgainView: View {
    let restart: () -> Void
    let openLog: () -> Void
    let close: () -> Void

    var body: some View {
        NoticeCard(width: 520) {
            HStack(alignment: .top, spacing: 16) {
                Mascot(mood: .asleep, size: 52)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Bộ nhận chữ của macOS vẫn không phản hồi", "macOS text recognition is still not responding"))
                        .font(.headline)
                    Text(L("OverSub đã tự khởi động lại một lần nhưng Vision vẫn bị treo, nên app không tự khởi động lại nữa để tránh lặp. Bạn có thể khởi động lại OverSub thêm một lần. Nếu lỗi còn lặp lại, hãy khởi động lại máy Mac, và mở một Issue trên GitHub kèm nhật ký để được hỗ trợ.",
                           "OverSub already restarted once, but Vision is still stuck, so it won't restart on its own again to avoid a loop. You can restart OverSub once more. If it keeps happening, restart your Mac and open an Issue on GitHub with the log attached."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(L("Đóng", "Close"), action: close)
                            .buttonStyle(.link)
                        Spacer(minLength: 8)
                        Button(L("Mở nhật ký", "Show log"), action: openLog)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .fixedSize()
                        Button(L("Khởi động lại OverSub", "Restart OverSub"), action: restart)
                            .buttonStyle(CTAButtonStyle())
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}

/// Thông báo đang chuẩn bị bộ nhận chữ: lần đầu trên một máy, macOS mất khoảng một phút dựng mô hình (xem VisionGuard).
/// Nằm ở mép trên màn hình, không chặn thao tác; xong thì báo "đã sẵn sàng" một lúc rồi tự tắt.
@MainActor
final class PreparingNotice {
    static let shared = PreparingNotice()

    final class Model: ObservableObject {
        @Published var elapsed = 0
        @Published var ready = false
    }

    private let model = Model()
    private var panel: NSPanel?
    private var ticker: Task<Void, Never>?

    func show(on screen: NSScreen?) {
        guard panel == nil else { return }
        model.elapsed = 0
        model.ready = false
        panel = NoticePanel.show(PreparingView(model: model), on: screen, at: .top)
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.model.elapsed += 1
            }
        }
    }

    func finish() {
        ticker?.cancel()
        ticker = nil
        guard panel != nil else { return }
        model.ready = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.model.ready else { return }
            self.panel?.orderOut(nil)
            self.panel = nil
        }
    }

    #if DEVTOOLS
    var debugPanel: NSPanel? { panel }
    #endif
}

private struct PreparingView: View {
    @ObservedObject var model: PreparingNotice.Model

    var body: some View {
        NoticeCard(width: 440) {
            HStack(alignment: .center, spacing: 14) {
                if model.ready {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.ready ? L("Bộ nhận chữ đã sẵn sàng", "Text recognition is ready")
                                     : L("Đang chuẩn bị bộ nhận chữ của macOS", "Preparing macOS text recognition"))
                        .font(.headline)
                    Text(model.ready ? L("OverSub bắt đầu đọc chữ ngay bây giờ.", "OverSub can read text now.")
                                     : L("Lần đầu trên máy này có thể mất khoảng một phút. Đã chờ \(model.elapsed) giây.",
                                         "The first time on this Mac can take about a minute. Waiting for \(model.elapsed) s."))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
