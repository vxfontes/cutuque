import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Cor/rótulo por estado (espelha SessionState do app, sem depender dele)

private func stateColor(_ state: String) -> Color {
    switch state {
    case "running":   return .blue
    case "needs_you": return .orange
    case "done":      return .green
    case "error":     return .red
    default:          return .gray
    }
}

private func stateLabel(_ state: String) -> String {
    switch state {
    case "running":   return "rodando"
    case "needs_you": return "precisa de você"
    case "done":      return "concluiu"
    case "error":     return "falhou"
    default:          return "ocioso"
    }
}

private func stateSymbol(_ state: String) -> String {
    switch state {
    case "running":   return "circle.dotted"
    case "needs_you": return "exclamationmark.triangle.fill"
    case "done":      return "checkmark.circle.fill"
    case "error":     return "xmark.octagon.fill"
    default:          return "circle"
    }
}

// MARK: - Live Activity

@available(iOS 16.1, *)
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CutuqueActivityAttributes.self) { context in
            // Tela de bloqueio / banner.
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: stateSymbol(s)).foregroundStyle(stateColor(s))
                        .font(.title3)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 64)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title).font(.callout).fontWeight(.semibold).lineLimit(1)
                        Text("\(stateLabel(s)) · \(context.attributes.machine)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: stateSymbol(s)).foregroundStyle(stateColor(s))
            } compactTrailing: {
                Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                    .font(.caption2).monospacedDigit().frame(maxWidth: 44)
            } minimal: {
                Image(systemName: stateSymbol(s)).foregroundStyle(stateColor(s))
            }
            .widgetURL(URL(string: "cutuque://session/\(context.attributes.sessionID)"))
        }
    }
}

@available(iOS 16.1, *)
private struct LockScreenView: View {
    let context: ActivityViewContext<CutuqueActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: stateSymbol(context.state.state))
                .font(.title2)
                .foregroundStyle(stateColor(context.state.state))
            VStack(alignment: .leading, spacing: 3) {
                Text(context.state.title).font(.headline).lineLimit(1)
                Text("\(stateLabel(context.state.state)) · \(context.attributes.machine)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                .font(.callout).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: 70)
        }
        .padding()
    }
}
