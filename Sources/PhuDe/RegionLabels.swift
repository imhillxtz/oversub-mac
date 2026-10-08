import SwiftUI

/// Tên các nút mở trình chọn vùng, đổi theo trạng thái: chưa có vùng thì "Thêm", có rồi thì "Chỉnh" (trình chọn cho kéo,
/// đổi cỡ, xoá và thêm vùng). Vùng dịch kèm số n/3 để biết còn thêm được mấy vùng. Thanh công cụ, menu thanh trên, trang
/// Vùng trong Cài đặt và hướng dẫn lần đầu cùng dùng các tên này.
@MainActor
enum RegionLabels {
    /// Có vùng phụ đề chưa, và có mấy vùng dịch màn hình.
    static func state(_ s: AppSettings) -> (subtitle: Bool, screens: Int) {
        #if DEVTOOLS
        // Chụp các trạng thái mà không đụng vùng thật: OVERSUB_REGION_STATE="0,0" (chưa có gì), "1,2", "1,3"...
        if let n = ProcessInfo.processInfo.environment["OVERSUB_REGION_STATE"]?.split(separator: ",").compactMap({ Int($0) }), n.count == 2 {
            return (n[0] > 0, n[1])
        }
        #endif
        return (s.region != nil, s.secondaryRegions.count)
    }

    static func subtitle(_ s: AppSettings) -> String {
        state(s).subtitle ? L("Chỉnh vùng phụ đề", "Edit subtitle region") : L("Thêm vùng phụ đề", "Add subtitle region")
    }

    /// `count`: kèm số vùng (thanh công cụ); trang Cài đặt đã có dòng đếm riêng nên không kèm.
    static func screen(_ s: AppSettings, count: Bool = true) -> String {
        let n = state(s).screens, max = RegionEditor.maxSecondaries
        if n == 0 { return L("Thêm vùng dịch", "Add screen region") }
        return count ? L("Chỉnh vùng dịch · \(n)/\(max)", "Edit screen regions · \(n)/\(max)") : L("Chỉnh vùng dịch", "Edit screen regions")
    }

    static func subtitleHelp(_ s: AppSettings) -> String {
        let key = HotkeyCenter.Action.selectRegion.display
        return state(s).subtitle
            ? L("Di chuyển, đổi cỡ hoặc vẽ lại vùng phụ đề, xem lại rồi lưu · ⌘K · trong game \(key)",
                "Move, resize or redraw the subtitle region, then review and save · ⌘K · in game \(key)")
            : L("Kéo khung quanh chỗ phụ đề lời thoại hiện ra, xem lại rồi lưu · ⌘K · trong game \(key)",
                "Drag a box around where dialogue subtitles appear, then review and save · ⌘K · in game \(key)")
    }

    static func screenHelp(_ s: AppSettings) -> String {
        let n = state(s).screens, max = RegionEditor.maxSecondaries
        let key = HotkeyCenter.Action.screenTranslate.display
        if n == 0 {
            return L("Kéo khung quanh chữ ngoài lời thoại (bảng nhiệm vụ, menu, mô tả vật phẩm) để dịch ngay tại chỗ, tối đa \(max) vùng · bật/tắt \(key)",
                     "Drag a box around non-dialogue text (quest logs, menus, item descriptions) to translate it in place, up to \(max) regions · toggle with \(key)")
        }
        if n >= max {
            return L("Di chuyển, đổi cỡ hoặc xoá vùng dịch; đã đủ \(max) vùng · bật/tắt \(key)",
                     "Move, resize or remove screen regions; all \(max) are in use · toggle with \(key)")
        }
        return L("Di chuyển, đổi cỡ, xoá vùng dịch hoặc thêm vùng mới (còn thêm được \(max - n) vùng) · bật/tắt \(key)",
                 "Move, resize or remove screen regions, or add another (\(max - n) more allowed) · toggle with \(key)")
    }
}

/// Huy hiệu số vùng dịch trên biểu tượng nút (0 thì không hiện). Màu trung tính: cam chỉ dành cho nút chính.
struct RegionCountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.background)
                .frame(minWidth: 13, minHeight: 13)
                .background(Circle().fill(.secondary))
                .offset(x: 7, y: -6)
                .accessibilityLabel(L("\(count) vùng", "\(count) regions"))
        }
    }
}
