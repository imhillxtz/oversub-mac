import AppKit
import Combine
import SwiftUI

/// Biểu tượng OverSub trên thanh menu, dựng bằng AppKit. Menu được dựng lại mỗi lần bấm chứ không cập nhật liên tục như
/// MenuBarExtra của SwiftUI: lúc đang dịch, Engine đổi trạng thái nhiều lần mỗi giây và menu SwiftUI bị dựng lại ngay khi đang mở.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()
    /// Hành động mở cửa sổ của SwiftUI, cửa sổ chính ghi lại lúc hiện lần đầu.
    static var openMain: (() -> Void)?
    static var openSettings: (() -> Void)?
    static var openDonate: (() -> Void)?

    private var item: NSStatusItem?
    private var bag = Set<AnyCancellable>()
    private var actions: [() -> Void] = []
    private var running = false
    private let menu = NSMenu()
    private var opening = false

    func start(engine: Engine, settings: AppSettings) {
        settings.$menuBarIcon.removeDuplicates().sink { [weak self] on in self?.setVisible(on) }.store(in: &bag)
        // Chỉ đổi hình khi trạng thái chạy thật sự đổi.
        engine.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshIcon() }.store(in: &bag)
    }

    private var engine: Engine { AppModel.shared.engine }
    private var settings: AppSettings { AppModel.shared.settings }

    private func setVisible(_ on: Bool) {
        if on, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            menu.delegate = self
            menu.autoenablesItems = false
            // Không gắn menu thẳng vào biểu tượng: cần chen một bước trước khi menu mở (xem clicked).
            i.button?.target = self
            i.button?.action = #selector(clicked)
            item = i
            running = !engine.anyRunning   // buộc vẽ hình lần đầu
            refreshIcon()
        } else if !on, let i = item {
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    private func refreshIcon() {
        guard let button = item?.button, engine.anyRunning != running else { return }
        running = engine.anyRunning
        // Hình đặc, nét đậm để không lép vế so với các biểu tượng khác trên thanh menu.
        let config = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .semibold)
        let image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "OverSub")?.withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
    }

    #if DEVTOOLS
    /// Thử nghiệm: bấm biểu tượng bằng mã rồi tự đóng menu sau vài giây.
    func debugClick(closeAfter seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.menu.cancelTracking() }
        DebugLog.write("Menu thanh menu: bấm thử, nút ở \(String(describing: item?.button?.window?.frame))")
        item?.button?.performClick(nil)
        DebugLog.write("Menu thanh menu: menu đã đóng")
    }
    #endif

    /// Trên màn hình đang có cửa sổ của app khác phủ kín bề ngang và chạm đáy màn hình (toàn màn hình) không. Chỉ khi đó mới
    /// cần mượn kiểu phụ trợ, để lúc bình thường biểu tượng ở Dock không chớp mất khi mở menu. Không đòi cửa sổ phải thuộc
    /// app đang ở phía trước: trình duyệt nhân Chromium (Comet, Chrome) dựng cửa sổ toàn màn hình theo cách riêng.
    private static func frontAppIsFullScreen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return true }
        let me = ProcessInfo.processInfo.processIdentifier
        let screens = NSScreen.screens.map(\.frame.size)
        let hit = list.first { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) != me, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], let width = b["Width"], let height = b["Height"], let y = b["Y"] else { return false }
            // Cửa sổ toàn màn hình nằm dưới tai thỏ nên thấp hơn màn hình; Comet còn tách thanh công cụ thành cửa sổ riêng,
            // phần nội dung chỉ cao khoảng 84% màn hình (đo thực: 1512 x 823 trên màn 982). Dấu hiệu chung: hết bề ngang và chạm đáy.
            return screens.contains { abs($0.width - width) < 2 && height > $0.height * 0.6 && y + height > $0.height - 2 }
        }
        DebugLog.write("Menu thanh menu: app phía trước \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"), toàn màn hình=\(hit != nil)")
        return hit != nil
    }

    // MARK: Menu

    /// Khi một app khác đang toàn màn hình, macOS không hiện menu của app kiểu thường (có biểu tượng ở Dock): biểu tượng
    /// sáng lên nhưng menu không ra. App kiểu phụ trợ thì hiện được, nên chuyển kiểu trước, mở menu sau, đóng menu thì trả lại.
    /// Đổi kiểu ngay lúc menu đang mở là quá muộn (đã thử), phải đổi trước một nhịp.
    @objc private func clicked() {
        guard !opening, let item else { return }
        opening = true
        let borrow = !NSApp.isActive && NSApp.activationPolicy() == .regular && Self.frontAppIsFullScreen()
        if borrow { NSApp.setActivationPolicy(.accessory) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (borrow ? 0.12 : 0)) { [weak self] in
            guard let self else { return }
            item.menu = self.menu
            item.button?.performClick(nil)   // chờ tới khi menu đóng
            item.menu = nil
            if borrow { NSApp.setActivationPolicy(.regular) }
            self.opening = false
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()
        actions.removeAll()
        typealias A = HotkeyCenter.Action
        let e = engine, s = settings
        if let r = Updater.shared.pending {
            add(menu, L("Cập nhật lên bản \(r.version)…", "Update to version \(r.version)…")) { UpdatePrompt.shared.show() }
            menu.addItem(.separator())
        }
        add(menu, e.anyRunning ? L("Dừng", "Stop") : L("Bắt đầu", "Start"), key: A.toggleRunning) { e.toggleRunning() }
        add(menu, L("Phụ đề đè lên game", "Subtitles over the game"), key: A.toggleOverlay, on: s.overlayEnabled) { e.toggleOverlay() }
        add(menu, s.dubCharacters ? "Dub" : "Voice-over", key: A.toggleDub, on: s.speakEnabled) { e.toggleDub() }
        add(menu, L("Đọc lại câu vừa rồi", "Replay last line"), key: A.replayLast) { e.replayLast() }
        menu.addItem(.separator())
        add(menu, L("Dịch nhanh một vùng", "Quick-translate an area"), key: A.quickTranslate) { e.quickTranslate() }
        add(menu, L("Dịch màn hình", "Screen translation"), key: A.screenTranslate, on: s.screenTranslateEnabled) { e.toggleScreenTranslate() }
        add(menu, RegionLabels.subtitle(s), key: A.selectRegion) { e.selectRegion() }
        let subs = SubtitleWindowState.shared
        add(menu, L("Cửa sổ phụ đề", "Subtitle window"), on: subs.isOpen) { subs.isOpen ? subs.close() : subs.show() }

        let profiles = NSMenu()
        for p in s.presets { add(profiles, p.name, on: p.id == s.activePresetID) { e.applyPreset(p) } }
        let profileItem = NSMenuItem(title: L("Hồ sơ game: \(s.activePreset?.name ?? "")", "Game profile: \(s.activePreset?.name ?? "")"), action: nil, keyEquivalent: "")
        profileItem.submenu = profiles
        menu.addItem(profileItem)

        let langs = NSMenu()
        for t in TargetLanguage.all { add(langs, t.displayName, on: t.code == s.targetLanguage) { s.targetLanguage = t.code } }
        let langItem = NSMenuItem(title: L("Dịch sang", "Translate to"), action: nil, keyEquivalent: "")
        langItem.submenu = langs
        menu.addItem(langItem)

        menu.addItem(.separator())
        add(menu, L("Mở cửa sổ OverSub", "Open OverSub window")) { Self.showMain() }
        add(menu, L("Lịch sử thoại", "Dialogue history"), key: A.history) { Self.showMain(); e.showHistory = true }
        add(menu, L("Cài đặt…", "Settings…")) { NSApp.activate(ignoringOtherApps: true); Self.openSettings?() }
        add(menu, L("Ủng hộ OverSub…", "Support OverSub…")) { NSApp.activate(ignoringOtherApps: true); Self.openDonate?() }
        menu.addItem(.separator())
        add(menu, L("Thoát OverSub", "Quit OverSub")) { NSApp.terminate(nil) }
    }

    private static func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        openMain?()
    }

    /// Thêm một mục; `key` hiện phím tắt trong game ở bên phải (chỉ để xem, phím tắt thật do HotkeyCenter đăng ký).
    private func add(_ menu: NSMenu, _ title: String, key: HotkeyCenter.Action? = nil, on: Bool? = nil, _ run: @escaping () -> Void) {
        let i = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        i.target = self
        i.tag = actions.count
        actions.append(run)
        if let on { i.state = on ? .on : .off }
        if let key, settings.globalHotkeys {
            let badge = NSMutableAttributedString(string: title + "\t")
            badge.append(NSAttributedString(string: key.display, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: 250)]
            badge.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: badge.length))
            badge.addAttribute(.font, value: NSFont.menuFont(ofSize: 0), range: NSRange(location: 0, length: badge.length))
            i.attributedTitle = badge
        }
        menu.addItem(i)
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}
