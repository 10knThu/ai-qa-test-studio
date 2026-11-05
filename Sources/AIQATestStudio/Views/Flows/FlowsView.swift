import SwiftUI
import SwiftData

/// Routes to screens learned from real runs. Later issues reuse them without reading the source code.
struct FlowsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \FlowRecord.learnedAt, order: .reverse) private var flows: [FlowRecord]

    var body: some View {
        Group {
            if flows.isEmpty {
                ContentUnavailableView("Chưa có luồng nào được học", systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                                       description: Text("Sau khi app tìm được đường tới một màn hình và xác nhận đã tới đúng, luồng được lưu ở đây."))
            } else {
                List {
                    ForEach(flows) { flow in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(flow.goal).font(.headline)
                                if flow.stale { Text("Hết hạn").font(.caption).padding(.horizontal, 6).background(.orange.opacity(0.25), in: Capsule()) }
                                Spacer()
                                Button(role: .destructive) { context.delete(flow); try? context.save() } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help("Xoá luồng này")
                            }
                            Text(flow.steps.isEmpty ? "(đã ở sẵn màn hình)" : flow.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "  →  "))
                                .font(.callout.monospaced()).textSelection(.enabled)
                            if !flow.aliases.isEmpty {
                                Text("Hiển thị trong app là: " + flow.aliases.prefix(4).joined(separator: " / ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Học từ \(flow.sourceIssueURL) · \(flow.learnedAt.formatted(date: .abbreviated, time: .shortened)) · đúng \(flow.successCount) lần, hỏng \(flow.failureCount) lần · scheme \(flow.scheme)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Learned Flows")
    }
}
