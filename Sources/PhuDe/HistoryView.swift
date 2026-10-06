import SwiftUI
import AppKit

/// Bảng lịch sử thoại bên phải cửa sổ: xem lại các câu vừa qua, mới nhất ở trên, sao chép được.
struct HistoryView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Lịch sử thoại", "Dialogue history")).font(.headline)
                Spacer()
                Button { copy(engine.transcript.map { line($0) }.joined(separator: "\n\n")) } label: { Image(systemName: "doc.on.doc") }
                    .help(L("Sao chép tất cả", "Copy all")).disabled(engine.transcript.isEmpty)
                Button { engine.clearTranscript() } label: { Image(systemName: "trash") }
                    .help(L("Xoá lịch sử", "Clear history")).disabled(engine.transcript.isEmpty)
            }
            .buttonStyle(.borderless)
            .padding(12)
            Divider()
            if engine.transcript.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text(L("Chưa có câu nào", "No lines yet")).font(.callout.weight(.medium))
                    Text(L("Các câu đã dịch sẽ hiện ở đây để bạn xem lại khi lỡ đọc không kịp.", "Translated lines show up here so you can catch anything you missed."))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(engine.transcript.reversed()) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if let s = item.speaker { Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                            Spacer()
                            Text(item.time, style: .time).font(.caption2).foregroundStyle(.tertiary)
                            let names = engine.termCandidates(in: item.source)
                            if !names.isEmpty {
                                Menu {
                                    Text(L("Giữ nguyên, không dịch:", "Keep as is, don't translate:"))
                                    ForEach(names, id: \.self) { n in Button(n) { engine.addTermToGlossary(n) } }
                                } label: { Image(systemName: "textformat.abc") }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .help(L("Giữ nguyên tên riêng trong câu này", "Keep a proper name from this line"))
                            }
                            Button { engine.ignore(item) } label: { Image(systemName: "text.badge.xmark") }
                                .buttonStyle(.borderless).help(L("Bỏ qua câu này: từ nay không dịch nữa (logo, chữ cố định…)", "Ignore this line: never translate it again (logos, fixed text…)"))
                            Button { engine.replay(item) } label: { Image(systemName: "play.circle") }
                                .buttonStyle(.borderless).help(L("Đọc lại câu này", "Replay this line"))
                        }
                        Text(item.translation).font(.callout.weight(.medium))
                        Text(item.source).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button(L("Đọc lại", "Replay")) { engine.replay(item) }
                        Button(L("Bỏ qua câu này", "Ignore this line")) { engine.ignore(item) }
                        let names = engine.termCandidates(in: item.source)
                        if !names.isEmpty {
                            Menu(L("Giữ nguyên tên riêng", "Keep proper name")) {
                                ForEach(names, id: \.self) { n in Button(n) { engine.addTermToGlossary(n) } }
                            }
                        }
                        Divider()
                        Button(L("Sao chép bản dịch", "Copy translation")) { copy(item.translation) }
                        Button(L("Sao chép câu gốc", "Copy original")) { copy(item.source) }
                    }
                }
                .listStyle(.inset)
                .animation(.smooth, value: engine.transcript.count)
            }
        }
    }

    private func line(_ i: TranscriptItem) -> String {
        (i.speaker.map { "[\($0)] " } ?? "") + i.source + "\n→ " + i.translation
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
