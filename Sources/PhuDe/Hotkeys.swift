import AppKit
import Carbon

/// Một câu thoại đã dịch, hiện trong bảng Lịch sử.
struct TranscriptItem: Identifiable, Equatable {
    let id = UUID()
    let time = Date()
    var speaker: String?
    var source: String
    var translation: String
}

/// Một tổ hợp phím tắt: mã phím, phím bổ trợ (kiểu Carbon) và tên phím để hiển thị.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Đọc tổ hợp từ một lần bấm phím. nil nếu thiếu phím bổ trợ (phím F thì được đứng một mình).
    init?(event: NSEvent) {
        let f = event.modifierFlags
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        let code = Int(event.keyCode)
        let name = Self.named[code] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        let isFunction = name.hasPrefix("F") && name.count > 1
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, m & UInt32(controlKey | optionKey | cmdKey) != 0 || isFunction else { return nil }
        self.init(keyCode: UInt32(code), modifiers: m, label: name)
    }

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
}

/// Phím tắt toàn cục qua Carbon (RegisterEventHotKey): không cần quyền Trợ năng, dùng được khi game đang toàn màn hình.
@MainActor
final class HotkeyCenter {
    enum Action: UInt32, CaseIterable {
        case toggleRunning = 1, toggleOverlay, selectRegion, history, toggleDub, replayLast, screenTranslate, quickTranslate

        var defaultKeyCode: UInt32 {
            switch self {
            case .toggleRunning: return UInt32(kVK_ANSI_S)
            case .toggleOverlay: return UInt32(kVK_ANSI_H)
            case .selectRegion: return UInt32(kVK_ANSI_K)
            case .history: return UInt32(kVK_ANSI_L)
            case .toggleDub: return UInt32(kVK_ANSI_D)
            case .replayLast: return UInt32(kVK_ANSI_R)
            case .screenTranslate: return UInt32(kVK_ANSI_T)
            case .quickTranslate: return UInt32(kVK_ANSI_Q)
            }
        }
        var defaultCombo: KeyCombo {
            let letter: String
            switch self {
            case .toggleRunning: letter = "S"
            case .toggleOverlay: letter = "H"
            case .selectRegion: letter = "K"
            case .history: letter = "L"
            case .toggleDub: letter = "D"
            case .replayLast: letter = "R"
            case .screenTranslate: letter = "T"
            case .quickTranslate: letter = "Q"
            }
            return KeyCombo(keyCode: defaultKeyCode, modifiers: UInt32(controlKey | optionKey), label: letter)
        }
        /// Tổ hợp đang dùng: người dùng đã đổi thì theo bản đã lưu, chưa thì mặc định ⌃⌥ + chữ.
        var combo: KeyCombo { HotkeyCenter.custom[rawValue] ?? defaultCombo }
        var isCustom: Bool { HotkeyCenter.custom[rawValue] != nil }
        var display: String { combo.display }
        var title: String {
            switch self {
            case .toggleRunning: return L("Bắt đầu / Dừng", "Start / Stop")
            case .toggleOverlay: return L("Ẩn / hiện phụ đề đè lên", "Hide / show subtitle overlay")
            case .selectRegion: return L("Chọn vùng phụ đề", "Select subtitle region")
            case .history: return L("Mở lịch sử thoại", "Open dialogue history")
            case .toggleDub: return L("Bật / tắt giọng đọc", "Turn voice on / off")
            case .replayLast: return L("Đọc lại câu vừa rồi", "Replay last line")
            case .screenTranslate: return L("Bật / tắt dịch màn hình", "Turn screen translation on / off")
            case .quickTranslate: return L("Dịch nhanh một vùng", "Quick-translate an area")
            }
        }
    }

    static let shared = HotkeyCenter()
    /// Phím tắt người dùng đã đổi, theo rawValue của hành động.
    nonisolated(unsafe) static var custom: [UInt32: KeyCombo] = {
        guard let data = UserDefaults.standard.data(forKey: "hotkeys"),
              let raw = try? JSONDecoder().decode([String: KeyCombo].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UInt32(k).map { ($0, v) } })
    }()

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    func register(_ action: Action, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        handlers[action.rawValue] = handler
        bind(action)
    }

    private func bind(_ action: Action) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4F565342), id: action.rawValue)   // 'OVSB'
        let combo = action.combo
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
        } else {
            DebugLog.write("Không đăng ký được phím tắt \(action.display) (mã lỗi \(status)), có thể app khác đang dùng.")
        }
    }

    func unregisterAll() {
        suspend()
        handlers.removeAll()
    }

    /// Tạm gỡ phím tắt (lúc người dùng đang bấm tổ hợp mới), giữ lại hành động để gắn lại sau.
    func suspend() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    /// Gắn lại mọi phím tắt theo tổ hợp hiện tại.
    func rebind() {
        suspend()
        for a in Action.allCases where handlers[a.rawValue] != nil { bind(a) }
    }

    /// Đổi tổ hợp của một hành động (nil = về mặc định). Trả về hành động đang dùng trùng tổ hợp nếu có, khi đó không đổi.
    func setCombo(_ combo: KeyCombo?, for action: Action) -> Action? {
        if let combo, let clash = Action.allCases.first(where: { $0 != action && $0.combo.keyCode == combo.keyCode && $0.combo.modifiers == combo.modifiers }) {
            return clash
        }
        Self.custom[action.rawValue] = combo == action.defaultCombo ? nil : combo
        let raw = Dictionary(uniqueKeysWithValues: Self.custom.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(raw), forKey: "hotkeys")
        rebind()
        return nil
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: Đổi phím tắt

import SwiftUI

/// Trạng thái lúc người dùng đang bấm tổ hợp phím mới. Dùng ObservableObject thay cho @State (xem ghi chú ở Engine).
@MainActor
final class HotkeyRecording: ObservableObject {
    static let shared = HotkeyRecording()
    @Published var action: HotkeyCenter.Action?
    @Published var message = ""
    @Published var revision = 0     // tăng mỗi lần đổi để các nhãn phím tắt vẽ lại
    private var monitor: Any?

    func start(_ a: HotkeyCenter.Action) {
        stop()
        action = a
        message = ""
        HotkeyCenter.shared.suspend()   // để tổ hợp đang dùng không kích hoạt lúc bấm thử
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if action != nil { HotkeyCenter.shared.rebind() }
        action = nil
    }

    func reset(_ a: HotkeyCenter.Action) {
        stop()
        if let clash = HotkeyCenter.shared.setCombo(nil, for: a) {
            message = L("Tổ hợp mặc định đang được dùng cho \"\(clash.title)\".", "The default shortcut is already used by \"\(clash.title)\".")
        } else { message = "" }
        revision += 1
    }

    private func handle(_ event: NSEvent) {
        guard let a = action else { return }
        if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty {
            stop(); return
        }
        guard let combo = KeyCombo(event: event) else {
            message = L("Cần kèm ít nhất một phím ⌃, ⌥ hoặc ⌘.", "Include at least one of ⌃, ⌥ or ⌘.")
            return
        }
        if let clash = HotkeyCenter.shared.setCombo(combo, for: a) {
            message = L("\(combo.display) đang được dùng cho \"\(clash.title)\". Bạn chọn tổ hợp khác nhé.", "\(combo.display) is already used by \"\(clash.title)\". Pick another.")
            return
        }
        message = ""
        stop()
        revision += 1
    }
}

/// Ô phím tắt bấm vào để đổi: bấm ô, gõ tổ hợp mới; Esc để thôi.
struct HotkeyField: View {
    let action: HotkeyCenter.Action
    @ObservedObject private var rec = HotkeyRecording.shared

    var body: some View {
        let recording = rec.action == action
        HStack(spacing: 6) {
            if action.isCustom && !recording {
                Button { rec.reset(action) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help(L("Về mặc định (\(action.defaultCombo.display))", "Back to default (\(action.defaultCombo.display))"))
            }
            Button { recording ? rec.stop() : rec.start(action) } label: {
                Text(recording ? L("Bấm tổ hợp phím…", "Press a shortcut…") : action.display)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(recording ? .secondary : .primary)
                    .frame(minWidth: 44)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: recording ? 1.5 : 0))
            }
            .buttonStyle(.plain)
            .help(L("Bấm để đổi phím tắt", "Click to change the shortcut"))
        }
    }
}
