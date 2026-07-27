import XCTest
@testable import CutuqueApp

/// Cobre `HelpContent` — o texto da tela de ajuda, que fica fora da View
/// justamente pra poder ser verificado aqui. A ajuda é a primeira coisa que
/// alguém que baixou o app da App Store lê, e ela ensina a subir um servidor:
/// seção vazia ou comando que não existe mais deixa a pessoa sem saída.
///
/// Todo valor esperado abaixo foi escrito à mão a partir do repositório —
/// nenhum é derivado do próprio `HelpContent`.
final class HelpContentTests: XCTestCase {

    /// Nenhuma seção pode chegar vazia na tela.
    func testTodaSecaoTemTituloSimboloEConteudo() {
        XCTAssertFalse(HelpContent.sections.isEmpty)
        for section in HelpContent.sections {
            XCTAssertFalse(section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "seção \(section.id) sem título")
            XCTAssertFalse(section.symbol.isEmpty, "seção \(section.id) sem símbolo")
            XCTAssertFalse(section.blocks.isEmpty, "seção \(section.id) sem blocos")
        }
    }

    /// `ForEach(HelpContent.sections)` usa `id` — dois iguais fariam o SwiftUI
    /// reciclar a linha errada.
    func testIDsDasSecoesSaoUnicos() {
        let ids = HelpContent.sections.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "ids repetidos em \(ids)")
    }

    /// Nenhum bloco pode ser texto/código em branco nem lista de itens vazia.
    func testNenhumBlocoEmBranco() {
        for section in HelpContent.sections {
            for block in section.blocks {
                switch block {
                case .text(let s), .code(let s):
                    XCTAssertFalse(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                   "bloco em branco na seção \(section.id)")
                case .bullets(let items):
                    XCTAssertFalse(items.isEmpty, "bullets vazio na seção \(section.id)")
                    for item in items {
                        XCTAssertFalse(item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                       "bullet em branco na seção \(section.id)")
                    }
                }
            }
        }
    }

    /// A seção de tmux precisa ensinar os três agentes. `HelpContent.tmuxCommands`
    /// espelha os subcomandos de `scripts/tmx.sh`; este teste garante que o que
    /// está declarado é o que aparece de fato num bloco de código — a lista e o
    /// texto não podem divergir com o tempo.
    func testComandosDoTmuxAparecemNaSecaoDeTmux() {
        guard let tmux = HelpContent.sections.first(where: { $0.id == "tmux" }) else {
            return XCTFail("seção de tmux sumiu")
        }
        let codigo = tmux.blocks.compactMap { block -> String? in
            if case .code(let s) = block { return s }
            return nil
        }.joined(separator: "\n")

        for cmd in ["cc", "cx", "oc"] {
            XCTAssertTrue(codigo.contains("tmx \(cmd)"),
                          "a ajuda não mostra `tmx \(cmd)`")
        }
        XCTAssertTrue(HelpContent.tmuxCommands.contains("cc"))
        XCTAssertTrue(HelpContent.tmuxCommands.contains("cx"))
        XCTAssertTrue(HelpContent.tmuxCommands.contains("oc"))
    }

    /// `config/hub.env.example` mora na RAIZ do repositório (ver `.gitignore`,
    /// regra `/config/*`), não em `hub/config/`. A ajuda já errou isso uma vez:
    /// mandava `cd cutuque/hub` e só depois `cp config/...`, o que falha. O
    /// `cp` tem que aparecer antes de qualquer `cd hub`.
    func testCopiaDoTemplateAconteceNaRaizDoRepo() {
        guard let hub = HelpContent.sections.first(where: { $0.id == "hub" }) else {
            return XCTFail("seção do hub sumiu")
        }
        let codigo = hub.blocks.compactMap { block -> String? in
            if case .code(let s) = block { return s }
            return nil
        }.joined(separator: "\n")

        guard let cp = codigo.range(of: "cp config/hub.env.example") else {
            return XCTFail("a ajuda não copia o template de configuração")
        }
        if let cdHub = codigo.range(of: "cd hub") ?? codigo.range(of: "cd cutuque/hub") {
            XCTAssertTrue(cp.lowerBound < cdHub.lowerBound,
                          "o cp do template tem que vir antes de entrar em hub/")
        }
        XCTAssertFalse(codigo.contains("cd cutuque/hub"),
                       "config/ não fica dentro de hub/")
    }

    /// O app é um cliente: sem o endereço do repositório, quem baixou não tem
    /// como chegar no servidor. Este link é o caminho inteiro.
    func testLinkDoRepositorio() {
        XCTAssertEqual(HelpContent.repoURL.absoluteString,
                       "https://github.com/vxfontes/cutuque")
    }

    /// As rotas citadas são as que o hub realmente serve
    /// (`hub/internal/server/server.go`): `/dashboard`, `/install`, `/health`.
    func testRotasCitadasSaoAsDoHub() {
        let todoCodigo = HelpContent.sections
            .flatMap(\.blocks)
            .compactMap { block -> String? in
                if case .code(let s) = block { return s }
                return nil
            }
            .joined(separator: "\n")

        XCTAssertTrue(todoCodigo.contains("8787/dashboard"), "ajuda sem o painel web")
        XCTAssertTrue(todoCodigo.contains("8787/install"), "ajuda sem a instalação da CLI")
        XCTAssertTrue(todoCodigo.contains("8787/health"), "ajuda sem o teste de conexão")
    }
}
