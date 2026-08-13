import SwiftUI

/// Grade de temas do terminal, cada um com uma prévia de verdade — sem isso a
/// escolha vira tentativa e erro (só dá pra saber se o Dracula fica legível
/// DEPOIS de aplicar e abrir o terminal).
///
/// `selection` é o `id` do tema (`""` = Padrão): a MESMA string que o hub
/// guarda em `machine.theme` e que `PTYTerminalView` recebe como `themeID`.
/// Isso é o contrato — quem monta este picker só faz um `Binding` direto no
/// campo, sem tradução nem tipo de paleta atravessando a fronteira.
struct TerminalThemePicker: View {
    @Binding var selection: String

    // [13/08/2026] `Color.accentColor` não lê o `.tint()` da raiz (ver
    // `AppTheme.swift`) — era por isso que o checkmark e a borda do tema
    // escolhido ficavam sempre azuis, mesmo trocando a cor em Ajustes.
    @Environment(\.corDeDestaque) private var destaque

    /// `.adaptive` reflow sozinho: 1-2 colunas no iPhone, 3+ no iPad, sem
    /// breakpoint escrito à mão. `maximum` evita um cartão esticado até a
    /// borda numa tela larga com poucos temas por linha.
    private let colunas = [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: colunas, spacing: 12) {
                ForEach(TerminalPalette.all) { tema in
                    cartao(tema)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    private func cartao(_ tema: TerminalPalette) -> some View {
        let selecionado = tema.id == selection
        return Button {
            selection = tema.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                previa(tema)
                HStack(spacing: 6) {
                    Text(tema.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if selecionado {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(destaque)
                    }
                }
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selecionado ? destaque : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(tema.name))
        .accessibilityAddTraits(selecionado ? [.isButton, .isSelected] : .isButton)
    }

    /// Terminal falso: fundo do tema, um prompt e palavras em 4 cores
    /// diferentes da paleta ANSI — o que poupa abrir o terminal de verdade só
    /// pra descobrir que o "verde" do tema é ilegível no fundo dele.
    ///
    /// Fonte é `.caption`/`.caption2` (não `.system(size:)` fixo): estilo de
    /// texto do sistema escala com Dynamic Type, tamanho fixo não.
    private func previa(_ tema: TerminalPalette) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            (Text("~ ").foregroundStyle(tema.ansiColor(2))
                + Text("$ ").foregroundStyle(tema.foregroundColor)
                + Text("ls ").foregroundStyle(tema.ansiColor(4))
                + Text("--color").foregroundStyle(tema.ansiColor(3)))
                .font(.system(.caption, design: .monospaced))

            (Text("app.py ").foregroundStyle(tema.ansiColor(6))
                + Text("README.md").foregroundStyle(tema.foregroundColor))
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)

            (Text("✗ erro: ").foregroundStyle(tema.ansiColor(1))
                + Text("não encontrado").foregroundStyle(tema.foregroundColor))
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tema.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
