import QuickLook
import SwiftUI

/// O lado "não é texto" do visualizador de arquivos: imagem, vídeo, áudio, PDF,
/// zip, Office/iWork — e também o raro caso de um hub ainda sem a cauda (ver
/// `FileContent.unreadableReason`), que hoje só sabe dizer "grande demais".
///
/// Nasceu de dentro do `FileViewerView` (12/08/2026) sem mudar comportamento: a
/// separação existe para que a frente do preview e a frente do texto pudessem
/// ser escritas em paralelo sem disputar o mesmo arquivo.
///
/// 12/08/2026 (leva do preview de arquivos): antes esta tela só oferecia um
/// botão "Baixar" que virava `ShareLink`. Agora, dentro do teto de
/// `LimitesDeArquivo.tetoDePreview`, ela baixa sozinha e mostra o
/// `QLPreviewController` embutido — decisão #1 da Vanessa: "um componente
/// cobre foto, vídeo, áudio, PDF, Office, iWork, zip, e o 'e tal' que ela não
/// listou", em vez de um visualizador escrito tipo a tipo (opção descartada no
/// desenho, junto com o híbrido).
///
/// `abaAtiva` é o que impede o vídeo de continuar tocando atrás de outra aba.
/// Não use `.onDisappear` para isso: com abas globais uma aba criada fica
/// montada para sempre e o `.onDisappear` **nunca dispara** lá dentro
/// (decisão #19) — é a mesma armadilha que produziu o "painel branco" e o
/// "Sessão encerrada" na leva das abas. Por isso o ciclo de vida daqui é
/// dirigido por `.task(id: abaAtiva)`: o `id` muda por CIMA da nossa própria
/// variável, não depende do SwiftUI perceber a view sumindo da árvore.
struct VisualizadorBinario: View {
    let machine: String
    let entry: FileEntry
    /// O que o hub disse sobre o arquivo. Usado só para explicar, na tela de
    /// confirmação, POR QUE ele não abre como texto — o teto de download é
    /// outra conta, decidida por `entry.size` (que já veio na listagem).
    let content: FileContent
    let abaAtiva: Bool
    /// Mantido pela assinatura compartilhada com `FileViewerView` (que já
    /// chama este init e não é deste worktree para mexer). O erro de download
    /// agora aparece embutido na tela — `falha(_:)` — em vez de alerta, então
    /// este gancho fica sem uso nesta leva; preservá-lo custa nada e evita
    /// mudar um contrato que outra frente depende.
    let reportaErro: (String) -> Void

    private enum Estado: Equatable {
        /// Acima do teto: nada foi baixado, espera o toque em "Baixar assim mesmo".
        case aguardandoConfirmacao
        case baixando
        case pronto(URL)
        case falhou(String)
    }

    @State private var estado: Estado
    private let api = APIClient()

    init(machine: String, entry: FileEntry, content: FileContent, abaAtiva: Bool,
         reportaErro: @escaping (String) -> Void) {
        self.machine = machine
        self.entry = entry
        self.content = content
        self.abaAtiva = abaAtiva
        self.reportaErro = reportaErro
        // O tamanho já veio na listagem — decidir aqui não custa um byte da
        // rede, que é exatamente o ponto do teto (spec, "O teto de 50 MB").
        _estado = State(initialValue: Self.devePedirConfirmacao(tamanho: entry.size)
            ? .aguardandoConfirmacao : .baixando)
    }

    var body: some View {
        Group {
            switch estado {
            case .aguardandoConfirmacao:
                confirmacao
            case .baixando:
                ProgressView("Baixando \(entry.sizeLabel)…")
            case .pronto(let url):
                preview(url)
            case .falhou(let mensagem):
                falha(mensagem)
            }
        }
        // Dispara (ou desmonta) o download sozinho. O `id` é a NOSSA variável
        // de estado — funciona mesmo dentro de uma aba eterna, que é
        // justamente o caso em que `.onDisappear` erraria (ver o comentário
        // da struct).
        .task(id: abaAtiva) {
            if abaAtiva {
                await iniciarSeNecessario()
            } else {
                desmontar()
            }
        }
        // Rede de segurança, não o mecanismo principal: fora de uma aba
        // global (por exemplo, se esta view um dia for usada num contexto sem
        // abas eternas) isto ainda dispara e limpa o tmp. Dentro de uma aba, a
        // decisão #19 diz que não vai chegar — quem faz o trabalho de
        // verdade é o `.task(id:)` acima.
        .onDisappear { desmontar() }
    }

    // MARK: - Telas

    private var confirmacao: some View {
        ContentUnavailableView {
            Label(content.binary ? "Arquivo binário" : "Arquivo grande demais",
                  systemImage: content.binary ? "doc.badge.gearshape" : "doc.badge.ellipsis")
        } description: {
            Text("\(content.unreadableReason ?? "") (\(entry.sizeLabel)) — acima do teto de baixar sozinho.")
        } actions: {
            Button("Baixar assim mesmo (\(entry.sizeLabel))") {
                Task { await baixar() }
            }
        }
    }

    @ViewBuilder
    private func preview(_ url: URL) -> some View {
        // `abreNoQuickLook` é sempre verdadeiro por desenho (decisão #1: um
        // componente único, sem roteamento por tipo). O `if` fica mesmo assim
        // porque é o lugar certo para o dia em que alguém tentar reintroduzir
        // o roteamento por tipo (o "híbrido" que a Vanessa descartou) sem
        // lembrar que `.outro` — zip, .docx — também precisa do QuickLook.
        if TipoDeArquivo.de(nome: entry.name).abreNoQuickLook {
            QuickLookView(url: url)
        } else {
            ContentUnavailableView("Sem preview para este arquivo", systemImage: "doc.questionmark")
        }
    }

    private func falha(_ mensagem: String) -> some View {
        ContentUnavailableView {
            Label("Não deu para baixar", systemImage: "exclamationmark.triangle")
        } description: {
            Text(mensagem)
        } actions: {
            Button("Tentar de novo") { Task { await baixar() } }
        }
    }

    // MARK: - Download

    /// Só age quando é o caso automático (dentro do teto) e nada começou
    /// ainda — reentrar aqui não reinicia um download que já deu certo, nem
    /// atropela um erro que está esperando o toque em "Tentar de novo".
    private func iniciarSeNecessario() async {
        guard case .baixando = estado else { return }
        await baixar()
    }

    private func baixar() async {
        estado = .baixando
        do {
            let url = try await api.downloadFile(machine: machine, path: entry.path)
            guard !Task.isCancelled else {
                apagar(url)
                return
            }
            estado = .pronto(url)
        } catch is CancellationError {
            // A aba perdeu o foco (ou a tela saiu) no meio do download — não é
            // falha do usuário, então fica em silêncio; `desmontar()` (chamado
            // pelo `.task(id:)` que cancelou isto) já cuida do estado.
        } catch {
            estado = .falhou(error.localizedDescription)
        }
    }

    /// Desliga a mídia — removendo o `QLPreviewController` da árvore — e apaga
    /// o arquivo do tmp. É o que a decisão #19 pede: sem isto, trocar de aba
    /// deixaria um vídeo tocando atrás, invisível e audível.
    private func desmontar() {
        if case .pronto(let url) = estado {
            apagar(url)
        }
        // Volta ao estado de partida: se o arquivo cabe no teto, a próxima
        // vez que a aba ficar ativa baixa de novo — não há cache de download
        // entre aberturas nesta leva (desenho, "O que este desenho NÃO faz").
        estado = Self.devePedirConfirmacao(tamanho: entry.size) ? .aguardandoConfirmacao : .baixando
    }

    /// `downloadFile` grava numa subpasta só dela (um UUID) — apagar só o
    /// arquivo deixaria a pasta vazia para trás; é a pasta inteira que precisa
    /// sumir para o tmp não encher com vídeo de 40 MB a cada abertura.
    private func apagar(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - Regras puras (testáveis sem simulador de UI)

    /// Acima do teto o app NÃO baixa sozinho — só baixa quem toca no botão.
    /// Função pura (`static`) para o teste conferir as bordas sem montar a
    /// view inteira.
    static func devePedirConfirmacao(tamanho: Int64) -> Bool {
        tamanho > LimitesDeArquivo.tetoDePreview
    }
}

/// Ponte para o `QLPreviewController` do UIKit — é o único jeito de mostrar
/// foto, vídeo, PDF, zip, Office/iWork etc. embutido na tela sem escrever um
/// visualizador por tipo. Exige URL de arquivo em DISCO, que é exatamente o
/// que `APIClient.downloadFile` devolve (e com o nome original preservado, o
/// que faz o QuickLook escolher o renderizador certo).
private struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        // Nada para sincronizar: a URL não muda depois de criada — cada
        // download tem seu próprio `estado.pronto(url)`, e portanto sua
        // própria instância desta view.
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

extension TipoDeArquivo {
    /// Todo arquivo que chega ao `VisualizadorBinario` (isto é,
    /// `!content.podeMostrarTexto`) abre no QuickLook — decisão #1 da
    /// Vanessa: um componente único cobre tudo, sem visualizador por tipo.
    ///
    /// Por isso esta propriedade NÃO delega para `abreNoPreview`: aquele campo
    /// exclui `.outro` DE PROPÓSITO (zip e .docx são identificados pelo
    /// `binary` do hub, não pela extensão — ver o comentário em
    /// `TipoDeArquivo.swift`), e é exatamente o `.outro` que mais precisa do
    /// QuickLook aqui. Fica sempre `true` hoje; existe como o lugar único e
    /// testado onde essa decisão vive, para o dia em que alguém precisar
    /// mexer nela sem repetir o erro de usar `abreNoPreview` puro.
    var abreNoQuickLook: Bool { true }
}
