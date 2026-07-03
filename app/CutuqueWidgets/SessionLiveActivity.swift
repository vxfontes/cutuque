import ActivityKit
import SwiftUI
import WidgetKit

// Glyph "cutuque" (ondas do ícone do app) e cor de marca (a extension não lê o
// tema do app — processo separado — então usa o azul de marca fixo).
private let cutuqueGlyph = "dot.radiowaves.left.and.right"
private let brand = Color.blue

/// Live Activity agregada: um resumo de quantas sessões estão ao vivo/rodando.
@available(iOS 16.1, *)
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CutuqueActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.4))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let live = context.state.live
            let active = context.state.active
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("Cutuque").font(.caption).fontWeight(.semibold)
                    } icon: {
                        Image(systemName: cutuqueGlyph).foregroundStyle(brand)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 10) {
                        countPill(value: live, label: "ao vivo", color: brand)
                        countPill(value: active, label: "rodando", color: active > 0 ? .green : .secondary)
                    }
                }
            } compactLeading: {
                // Ícone do Cutuque de um lado…
                Image(systemName: cutuqueGlyph).foregroundStyle(brand)
            } compactTrailing: {
                // …e do outro, quantas ao vivo (ou o nº de rodando quando houver).
                Text("\(live)").font(.caption2).fontWeight(.semibold).monospacedDigit()
            } minimal: {
                // Sem nada rodando → só o ícone; senão, o número ao vivo.
                if live > 0 {
                    Text("\(live)").font(.caption2).fontWeight(.bold).monospacedDigit()
                } else {
                    Image(systemName: cutuqueGlyph).foregroundStyle(brand)
                }
            }
        }
    }

    private func countPill(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 0) {
            Text("\(value)").font(.headline).monospacedDigit().foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

@available(iOS 16.1, *)
private struct LockScreenView: View {
    let state: CutuqueActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: cutuqueGlyph)
                .font(.title2).foregroundStyle(brand)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cutuque").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 16) {
                bigCount(state.live, "ao vivo", brand)
                bigCount(state.active, "rodando", state.active > 0 ? .green : .secondary)
            }
        }
        .padding()
    }

    private var subtitle: String {
        if state.active > 0 { return "\(state.active) rodando agora no seu Mac" }
        if state.live > 0 { return "\(state.live) ao vivo, ociosas" }
        return "nenhuma sessão ao vivo"
    }

    private func bigCount(_ value: Int, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(value)").font(.title2).fontWeight(.bold).monospacedDigit().foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
