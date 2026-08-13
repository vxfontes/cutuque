import SwiftUI

// MARK: - Chip de estado (compartilhado)

/// Cápsula de estado reutilizável na lista e no cabeçalho do detalhe.
/// Fundo `cor.opacity(0.15)` e conteúdo na cor do estado.
///
/// [13/08/2026] A cor vem de `CorDeStatus.para` e não mais de `state.color`
/// cru: "rodando" seguia o azul do sistema mesmo com outra cor escolhida em
/// Ajustes, e este chip aparece no cabeçalho do detalhe da sessão — um dos
/// "alguns lugares fica com cor padrao" do relato. Os demais estados são
/// semânticos e continuam literais (ver `CorDeStatus`).
struct StateChip: View {
    let state: SessionState
    @Environment(\.corDeDestaque) private var destaque

    var body: some View {
        let cor = CorDeStatus.para(state, destaque: destaque)
        return HStack(spacing: 6) {
            Circle()
                .fill(cor)
                .frame(width: 7, height: 7)
            Text(state.label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(cor.opacity(0.15), in: Capsule())
        .foregroundStyle(cor)
        // Nunca quebra: hugga o conteúdo e deixa a largura sobrando para o texto da row.
        .fixedSize(horizontal: true, vertical: false)
        // Leitor de tela anuncia só o rótulo do estado (ex.: "precisa de você").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label)
    }
}
