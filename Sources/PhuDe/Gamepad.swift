import Foundation
import GameController

/// Điều khiển OverSub bằng tay cầm game, kể cả khi game đang ở phía trước: giữ nút View/Share (nút nhỏ bên trái)
/// rồi bấm thêm một nút. Dùng tổ hợp để không đụng thao tác trong game.
@MainActor
final class GamepadControl {
    var onReplay: (() -> Void)?
    var onToggleVoice: (() -> Void)?
    var onToggleSubtitles: (() -> Void)?
    private(set) var connectedName: String?
    private var observers: [NSObjectProtocol] = []
    private var enabled = false

    static var combos: [(buttons: String, action: String)] { [
        (L("Giữ View/Share + Y (△)", "Hold View/Share + Y (△)"), L("Đọc lại câu vừa rồi", "Replay last line")),
        (L("Giữ View/Share + X (□)", "Hold View/Share + X (□)"), L("Bật / tắt giọng đọc", "Turn voice on / off")),
        (L("Giữ View/Share + B (○)", "Hold View/Share + B (○)"), L("Ẩn / hiện phụ đề đè lên game", "Hide / show subtitles over the game")),
    ] }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            // Nhận nút bấm cả khi app khác (game) đang ở phía trước.
            GCController.shouldMonitorBackgroundEvents = true
            observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
                guard let c = n.object as? GCController else { return }
                MainActor.assumeIsolated { self?.configure(c) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.connectedName = GCController.controllers().first?.vendorName }
            })
            GCController.controllers().forEach(configure)
        } else {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            GCController.controllers().forEach { $0.extendedGamepad?.valueChangedHandler = nil }
            connectedName = nil
        }
    }

    private func configure(_ c: GCController) {
        guard enabled, let pad = c.extendedGamepad else { return }
        connectedName = c.vendorName ?? L("Tay cầm", "Controller")
        DebugLog.write("Tay cầm: đã kết nối \(connectedName ?? "")")
        pad.valueChangedHandler = { [weak self] gamepad, element in
            guard let button = element as? GCControllerButtonInput, button.isPressed,
                  gamepad.buttonOptions?.isPressed == true else { return }
            let action: (() -> Void)?
            switch button {
            case gamepad.buttonY: action = self?.onReplay
            case gamepad.buttonX: action = self?.onToggleVoice
            case gamepad.buttonB: action = self?.onToggleSubtitles
            default: action = nil
            }
            guard let action else { return }
            DispatchQueue.main.async { action() }
        }
    }
}
