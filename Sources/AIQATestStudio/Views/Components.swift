import SwiftUI
import AppKit

struct LogView: View {
    let log: LogStore
    var minHeight: CGFloat = 160

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(log.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(color(line.level))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: log.lines.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .frame(minHeight: minHeight)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }

    private func color(_ level: LogStore.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}

struct StatusBadge: View {
    let status: ExecutionStatus
    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(status.color.opacity(0.15), in: Capsule())
            .foregroundStyle(status.color)
    }
}

struct StageRow: View {
    let title: String
    let state: StageState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if state.isRunning { ProgressView().controlSize(.small) }
                else { Image(systemName: state.symbol).foregroundStyle(state.color) }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(state.detail).font(.callout).foregroundStyle(state.color == .secondary ? .secondary : state.color)
                    .textSelection(.enabled).lineLimit(8)
            }
            Spacer()
        }
    }
}

struct ErrorBanner: View {
    let text: String
    var body: some View {
        Label { Text(text).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct InfoBanner: View {
    let text: String
    var body: some View {
        Label { Text(text).textSelection(.enabled) } icon: { Image(systemName: "info.circle.fill") }
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    seconds < 60 ? String(format: "%.1fs", seconds) : String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60)
}
