import SwiftUI

/// O lado "é texto" do visualizador de arquivos.
///
/// Nasceu de dentro do `FileViewerView` (12/08/2026) sem mudar comportamento: a
/// separação existe para que a frente do texto (markdown renderizado, JSON
/// formatado, realce, cauda) e a frente do preview pudessem ser escritas em
/// paralelo sem disputar o mesmo arquivo.
///
/// A regra que não se negocia aqui: o conteúdo sai num **único `Text`**. Quebrar
/// em um `Text` por linha mataria a seleção — é o bug que a leva do copiar
/// acabou de consertar no chat.
struct VisualizadorDeTexto: View {
    let entry: FileEntry
    let content: FileContent

    /// Como abrir, decidido pela extensão. `TipoDeArquivo` e o QuickLook leem a
    /// mesma pista, então as duas metades da tela nunca discordam.
    private var tipo: TipoDeArquivo { TipoDeArquivo.de(nome: entry.name) }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(content.content)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}
