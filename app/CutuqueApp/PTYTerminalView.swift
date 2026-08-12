import SwiftTerm
import SwiftUI
import UIKit

/// O terminal livre desenhado por um emulador de verdade.
///
/// O `AnsiRenderer` daqui não serve para isto: ele entende SGR (cor, negrito) e
/// **descarta** movimento de cursor e limpeza de tela. Isso basta para o espelho
/// do tmux, que chega como uma tela já montada pelo `capture-pane`; num fluxo de
/// bytes cru, posicionar o cursor É o conteúdo — sem interpretar isso, `vim` e
/// `htop` viram lixo na tela. Daí o SwiftTerm.
///
/// Esta view só liga os fios: teclado → `PTYSession`, bytes do hub → emulador,
/// tamanho medido pelo próprio emulador → resize. A geometria não é calculada
/// aqui (como no `TerminalMirrorView`) porque quem sabe quantas células cabem é
/// quem desenha as células.
struct PTYTerminalView: UIViewRepresentable {
    @ObservedObject var session: PTYSession
    /// Falso quando o terminal está montado mas escondido atrás do painel de
    /// arquivos. Não desmonta nem fecha: para de consumir o socket.
    var isActive: Bool
    /// Id da paleta (vem de `machine.theme`; `""` = Padrão). STRING, não o
    /// objeto: é o mesmo formato que o hub guarda e que o
    /// `TerminalThemePicker` faz binding, então quem cadastra a máquina e
    /// quem desenha o terminal não trocam tipo nenhum entre si — só essa
    /// string. Resolvida pra `TerminalPalette` aqui dentro, via `byID`.
    ///
    /// Diverge de propósito do espelho do tmux (`TerminalMirrorView`), que
    /// segue com o `TerminalTheme` (enum) como preferência GLOBAL do app: a
    /// usuária pediu tema por MÁQUINA aqui, não migração do espelho antigo.
    var themeID: String
    var fontSize: CGFloat
    /// Ponte de leitura para a toolbar copiar o que está na tela. Opcional
    /// porque quem só desenha o terminal não precisa dela.
    var texto: TerminalTexto? = nil

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        view.terminalDelegate = context.coordinator
        // O terminal aceita foco por toque; o teclado do sistema sobe sozinho.
        view.isOpaque = false
        aplica(tema: themeID, em: view)
        context.coordinator.temaAplicado = themeID

        // O emulador é o dono do fluxo de saída: os bytes vão direto para ele,
        // sem passar por estado do SwiftUI. Uma tela cheia de `htop` a cada
        // segundo virando @Published seria um redesenho de árvore por frame.
        session.aoReceber = { [weak view] bytes in
            view?.feed(byteArray: bytes)
        }
        context.coordinator.session = session
        texto?.view = view
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.session = session
        context.coordinator.isActive = isActive
        context.coordinator.texto = texto

        if view.font.pointSize != fontSize {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        // Troca de tema passa por aqui como qualquer outra atualização de
        // estado do SwiftUI — não mexe na `PTYSession`, então reflete na tela
        // sem reconectar (reconectar perderia o que já está desenhado e
        // mataria o comando em execução).
        //
        // SÓ quando mudou de verdade, pelo mesmo motivo do `pointSize` acima:
        // `installColors` joga fora o cache de atributos, chama
        // `updateFullScreen()` (marca toda linha como suja) e enfileira
        // redesenho. Aplicar a cada `updateUIView` faria subir o teclado,
        // esconder o painel ou qualquer re-render do pai repintar a tela
        // inteira — no meio de um `htop` isso aparece como engasgo.
        if context.coordinator.temaAplicado != themeID {
            aplica(tema: themeID, em: view)
            context.coordinator.temaAplicado = themeID
        }

        // Painel escondido não fica com o teclado: sem isto, tocar em
        // "Arquivos" deixaria o teclado do terminal em pé sobre a outra tela.
        if !isActive && view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        // Corta o cano antes de a view sumir: um `feed` numa view em
        // desmontagem não tem para onde desenhar.
        coordinator.session?.aoReceber = { _ in }
        // A ponte é `weak`, mas zerar aqui é explícito: ninguém lê uma view em
        // desmontagem.
        coordinator.texto?.view = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func aplica(tema id: String, em view: TerminalView) {
        let paleta = TerminalPalette.byID(id)
        view.nativeBackgroundColor = paleta.nativeBackground
        view.nativeForegroundColor = paleta.nativeForeground
        view.caretColor = paleta.nativeCursor
        // `installColors` exige EXATAMENTE 16 cores — com qualquer outra
        // contagem ela não faz nada, em silêncio, sem erro nem log. O
        // catálogo garante 16 (testado), mas a armadilha é da lib, não do
        // catálogo: vale o comentário pra quem mexer aqui depois.
        view.installColors(paleta.ansiSwiftTermColors)
    }

    /// Ponte com o SwiftTerm. Os métodos sem default no protocolo precisam
    /// existir mesmo quando não há o que fazer — daí os corpos vazios.
    ///
    /// A classe NÃO é `@MainActor`: `TerminalViewDelegate` não é isolado, e
    /// marcar a classe inteira faria a conformidade cruzar a fronteira de ator
    /// (aviso hoje, erro no Swift 6). O isolamento é por membro, com
    /// `assumeIsolated` nos métodos — o SwiftTerm chama o delegate de dentro do
    /// próprio `UIView`, então a main thread é garantida de fato; a diferença é
    /// que agora isso está dito onde é verdade em vez de prometido no tipo.
    final class Coordinator: NSObject, TerminalViewDelegate {
        @MainActor var session: PTYSession?
        @MainActor var isActive = true
        /// Último tema instalado nesta view. Fica no coordinator porque a
        /// struct da `UIViewRepresentable` é recriada a cada atualização —
        /// guardar aqui é a única forma de saber se o tema mudou. `nil` = nada
        /// instalado ainda (não `""`, que é um tema de verdade, o Padrão).
        @MainActor var temaAplicado: String?
        /// A mesma ponte recebida pela struct, guardada aqui pelo mesmo motivo
        /// do `temaAplicado`: a struct é recriada a cada atualização, o
        /// coordinator não.
        @MainActor var texto: TerminalTexto?

        /// O emulador mediu quantas células cabem. É a ÚNICA fonte do tamanho:
        /// quem desenha é quem sabe.
        ///
        /// É também o gatilho da primeira conexão, e não um `.task` da view: a
        /// medida chega DEPOIS do layout, então abrir antes daria um shell
        /// 80x24 desenhando o prompt no tamanho errado antes do resize chegar.
        /// Painel escondido só guarda a medida — nada de abrir um `ssh` num
        /// host em que a usuária entrou direto nos arquivos.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                session?.resize(cols: newCols, rows: newRows)
                if isActive { session?.abre() }
            }
        }

        /// Tudo que foi digitado (inclusive as sequências das setas e do
        /// controle) sai por aqui, já como bytes.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                // Painel escondido não digita. O teclado já foi dispensado no
                // `updateUIView`, mas teclado físico continua alcançando a view.
                guard isActive else { return }
                session?.send(data)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        /// Link no terminal abre no Safari. É o único caso em que uma ação do
        /// conteúdo remoto sai do app, e por isso a allowlist de esquema: um
        /// `file://` ou um esquema de outro app impresso por um host qualquer
        /// não vira navegação.
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return }
            MainActor.assumeIsolated { UIApplication.shared.open(url) }
        }
    }
}

/// Quais linhas do buffer estão na tela. Separada da ponte porque é a única
/// parte disto que se testa sem um `TerminalView` de verdade — e é onde o erro
/// de 1 mora. Sem clamp de propósito: quem apara `base` ao tamanho real do
/// buffer é o `Terminal.getSelectedLines` do SwiftTerm, e `Buffer.lines` é
/// internal (o app não tem como contar as linhas).
enum JanelaVisivel {
    static func linhas(yDisp: Int, rows: Int) -> (topo: Int, base: Int)? {
        guard rows > 0 else { return nil }
        return (topo: yDisp, base: yDisp + rows - 1)
    }
}

/// Deixa o SwiftUI LER o terminal sem virar dono dele.
///
/// Existe porque no iOS o caminho de copiar do próprio SwiftTerm não chega na
/// usuária: `allowMouseReporting` nasce `true` e os guardas de mouse-reporting
/// desviam o gesto para o programa que roda dentro (`iOSTerminalView.swift:800,
/// 851, 876, 972`), e o menu usa `UIMenuController`, depreciado desde o iOS 16
/// (`iOSTerminalView.swift:629`). Em vez de mexer nesses dois — mouse dentro do
/// ssh é útil, e brigar com o menu do sistema é areia demais — o app lê o texto
/// por fora e oferece copiar na SUA toolbar.
///
/// `weak` não é detalhe: a ponte não pode manter o `TerminalView` vivo depois do
/// `dismantleUIView`. Com a aba montada para sempre (decisão #19), uma
/// referência forte aqui seria vazamento por aba aberta.
@MainActor
final class TerminalTexto {
    weak var view: TerminalView?

    /// A tela visível como texto. Só a tela — sem scrollback, por decisão da
    /// usuária (não mexe no hub).
    func telaVisivel() -> String {
        guard let view else { return "" }
        let terminal = view.getTerminal()
        guard let janela = JanelaVisivel.linhas(yDisp: terminal.buffer.yDisp,
                                               rows: terminal.rows) else { return "" }
        // `cols` e não `cols - 1`: o endCol do SwiftTerm é EXCLUSIVO e já apara
        // à direita (BufferLine.swift:502-511). Com `cols - 1` a última coluna
        // de uma linha cheia sumiria — é o erro que o `selectAll` da própria
        // lib comete.
        return terminal.getText(start: Position(col: 0, row: janela.topo),
                                end: Position(col: terminal.cols, row: janela.base))
    }

    /// O que a usuária selecionou dentro do SwiftTerm, quando ela conseguiu.
    /// Às vezes o gesto passa; quando passa, respeitar é melhor que ignorar.
    func selecionado() -> String? {
        guard let view, view.selection.active else { return nil }
        let texto = view.selection.getSelectedText()
        return texto.isEmpty ? nil : texto
    }
}
