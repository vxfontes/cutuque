import SwiftUI

// MARK: - Chip de estado (compartilhado)

/// Cápsula de estado reutilizável na lista e no cabeçalho do detalhe.
/// Fundo `state.color.opacity(0.15)` e conteúdo na cor do estado.
struct StateChip: View {
    let state: SessionState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.color)
                .frame(width: 7, height: 7)
            Text(state.label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(state.color.opacity(0.15), in: Capsule())
        .foregroundStyle(state.color)
        // Leitor de tela anuncia só o rótulo do estado (ex.: "precisa de você").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label)
    }
}
