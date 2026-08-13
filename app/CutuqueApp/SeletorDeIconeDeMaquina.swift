import SwiftUI

/// A grade de ícones de uma máquina: "Automático" (o ícone do sistema detectado)
/// mais um cartão por `MachineIcon`.
///
/// [13/08/2026] Extraída de `MachineInfoSheet` porque o formulário de máquina
/// passou a precisar da MESMA grade — "a parte de personalizar a maquina não
/// deixa escolher as coisas do hub tipo icone, tema e tal". Duas cópias da grade
/// divergiriam na primeira mexida em qualquer das duas.
///
/// Não guarda estado nem sabe salvar: recebe o escolhido e devolve o toque. Quem
/// persiste é quem a usa — a folha manda `PUT /appearance` na hora, o formulário
/// só ao salvar.
struct SeletorDeIconeDeMaquina: View {
    /// O sistema detectado, para o cartão "Automático" mostrar o ícone que o
    /// automático DE FATO daria. Opcional porque `Machine.os` é opcional —
    /// máquina cuja detecção nunca rodou cai no ícone genérico de
    /// `Machine.osIcon(para:)`.
    let so: String?
    /// `id` do ícone escolhido — `""` é o automático.
    let escolhido: String
    /// Máquina do `hub.env` (não editável) mostra a grade apagada, não some com
    /// ela: a usuária precisa ver qual ícone está valendo.
    let habilitado: Bool
    let aoEscolher: (String) -> Void

    @Environment(\.corDeDestaque) private var corDeDestaque

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 12) {
            cartao(id: "", symbol: Machine.osIcon(para: so), nome: "Automático")
            ForEach(MachineIcon.allCases) { opcao in
                cartao(id: opcao.rawValue, symbol: opcao.symbol, nome: opcao.label)
            }
        }
        .padding(.vertical, 4)
        .disabled(!habilitado)
    }

    private func cartao(id: String, symbol: String, nome: String) -> some View {
        let selecionado = id == escolhido
        return Button {
            aoEscolher(id)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(height: 26)
                Text(nome)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            // Realce pela cor de Ajustes → Tema. Era `Color.accentColor`, que
            // ignora o `.tint` da raiz e ficava azul mesmo com outro tema
            // escolhido (ver `EnvironmentValues.corDeDestaque`).
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selecionado ? corDeDestaque.opacity(0.18) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selecionado ? corDeDestaque : Color.secondary.opacity(0.25),
                        lineWidth: selecionado ? 2 : 1))
            .foregroundStyle(selecionado ? corDeDestaque : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(nome))
        .accessibilityAddTraits(selecionado ? [.isSelected] : [])
    }
}
