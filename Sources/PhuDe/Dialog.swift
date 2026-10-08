import AppKit
import SwiftUI

/// Khung chung cho các hộp thoại kiểu macOS của OverSub (cập nhật, báo lỗi): biểu tượng app ở cột trái, nội dung một mép
/// thẳng hàng ở cột phải, nút ở chân bên phải, nút phụ ít dùng ở chân bên trái.
struct DialogLayout<Content: View>: View {
    var badge: String?
    var width: CGFloat = 560
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            DialogAppIcon(badge: badge)
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
        .frame(width: width)
    }
}

/// Tiêu đề và câu giải thích của hộp thoại.
struct DialogHeader: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Một bước đánh số trong hướng dẫn.
struct DialogStep: View {
    let n: Int
    let text: String

    var body: some View {
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

@MainActor
enum DialogWindow {
    /// Cửa sổ có thanh tiêu đề trong suốt, chỉ còn nút đóng, cỡ theo nội dung lúc tạo. Không dùng
    /// `NSHostingController.sizingOptions = .preferredContentSize`: cách đó làm AppKit tính lại bố cục mãi rồi dừng app
    /// (crash khi thử ngày 08/10/2026). Hộp thoại đổi cỡ theo trạng thái thì tự gọi `fit(_:to:)`.
    static func make(_ content: NSView, title: String, size: NSSize? = nil) -> NSWindow {
        let size = size ?? content.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.contentView = content
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = title
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.center()
        return w
    }

    /// Đặt lại cỡ cửa sổ theo `size` (cỡ nội dung), giữ nguyên mép trên. Cỡ phải đo bằng một NSHostingView mới tạo: đo trên
    /// chính view đang nằm trong cửa sổ (sizingOptions rỗng) trả về 0x0, làm cửa sổ thu về thanh tiêu đề rồi bung ra, trông
    /// như co giãn liên tục (bản 1.1.66).
    static func fit(_ w: NSWindow, to size: NSSize) {
        let current = w.contentRect(forFrameRect: w.frame).size
        guard size.width > 100, size.height > 60 else { return }
        // Lệch dưới 2 điểm là sai số làm tròn giữa hai lần đo, chỉnh nữa chỉ làm cửa sổ giật.
        guard abs(size.height - current.height) >= 2 || abs(size.width - current.width) >= 2 else { return }
        DebugLog.write("Hộp thoại \(w.title): đổi cỡ \(Int(current.width))x\(Int(current.height)) → \(Int(size.width))x\(Int(size.height))")
        var frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - frame.height)
        w.setFrame(frame, display: true, animate: w.isVisible)
    }
}

/// Nút đóng tròn nhỏ ở góc thẻ nổi (thẻ không có thanh tiêu đề).
struct DialogCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel(L("Đóng", "Close"))
    }
}
