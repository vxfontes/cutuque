import Foundation

/// Nome de grupo e de sessão do tmux (D12). O alfabeto é `A-Za-z0-9-_`, e a razão
/// não é estética: o tmux usa ":" e "." como separador de alvo (sessão:janela.pane) e
/// o grupo vira caminho de socket, validado no hub por `^/[A-Za-z0-9._/ -]+$`. Nome
/// fora disso não daria erro bonito — daria alvo ambíguo.
///
/// O hub valida de novo (defesa em profundidade); esta é a camada de UX, que barra
/// enquanto a Vanessa digita.
enum NomeTmux {
    /// O que a UI explica embaixo do campo.
    static let aviso = "Letras, números, hífen e sublinhado"

    private static let permitidos: Set<Character> = {
        var s = Set<Character>("-_")
        for c in "abcdefghijklmnopqrstuvwxyz" { s.insert(c) }
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" { s.insert(c) }
        for c in "0123456789" { s.insert(c) }
        return s
    }()

    static func valido(_ nome: String) -> Bool {
        !nome.isEmpty && nome.allSatisfy { permitidos.contains($0) }
    }

    /// Filtra em vez de rejeitar: colar "mike.aux" no campo dá "mikeaux", e não um
    /// campo que se recusa a mudar sem dizer por quê.
    static func filtrando(_ texto: String) -> String {
        String(texto.filter { permitidos.contains($0) })
    }
}
