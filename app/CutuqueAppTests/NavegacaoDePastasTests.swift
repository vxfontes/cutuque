import XCTest
@testable import CutuqueApp

/// "Dá pra subir a partir daqui?" — `NavegacaoDePastas.podeSubir`, a peça pura
/// que resolveu o card `2fc2b3f628041f08` ("iPad/Arquivos: não dá pra subir
/// de pasta — o navegador só desce a partir da home").
///
/// O caso real dela: no macmini o home cai perto de `/root`, e ela quer
/// chegar em `/DATA`. Antes desta função não havia NENHUMA saída pra cima —
/// nem linha "..", nem botão, nem "Voltar" (que só desfaz descida, nunca
/// sobe acima de onde a instância nasceu).
///
/// O que se testa aqui é exatamente o que a revisão de mecanismo (16/08)
/// levantou como armadilha: o precedente da casa (`FolderPickerView.swift:35`,
/// `listing.path != "/"`) assume que a raiz do FS sempre se chama `"/"`. A
/// guarda certa compara `parent` com o caminho atual — o hub calcula `parent`
/// via `os.path.dirname` (`files.go:41`), e `dirname` de uma raiz devolve a
/// própria raiz, seja ela `"/"`, vazia, ou qualquer outra convenção.
final class NavegacaoDePastasTests: XCTestCase {

    /// Caso comum: pasta normal, pai diferente do caminho atual. Tem que
    /// poder subir — é o caminho feliz que a `..`/botão precisam cobrir.
    func testPodeSubirQuandoParentDifereDoCaminhoAtual() {
        XCTAssertTrue(NavegacaoDePastas.podeSubir(caminhoAtual: "/DATA/projetos", parent: "/DATA"))
    }

    /// A raiz do FS, com a convenção `"/"`: `dirname("/") == "/"`, então
    /// `parent == caminhoAtual`. NÃO pode subir — e o teste não pode passar
    /// só porque comparou contra a string `"/"` cravada (ver o teste
    /// seguinte, com outra convenção de raiz, pra provar que não é isso).
    func testNaoPodeSubirNaRaizComBarra() {
        XCTAssertFalse(NavegacaoDePastas.podeSubir(caminhoAtual: "/", parent: "/"))
    }

    /// Mesma forma (`parent == caminhoAtual`), convenção de raiz DIFERENTE de
    /// `"/"`. Se a guarda comparasse contra `"/"` cravado (o defeito do
    /// precedente em `FolderPickerView.swift:35`), este caso passaria batido
    /// e ofereceria "subir" numa raiz que não usa barra — reabrindo o mesmo
    /// bug com outro hub.
    func testNaoPodeSubirEmRaizQueNaoUsaBarraComoConvencao() {
        XCTAssertFalse(NavegacaoDePastas.podeSubir(caminhoAtual: "C:\\", parent: "C:\\"))
    }

    /// Degradação honesta: um hub que mandasse `parent` vazio (fora do
    /// contrato atual, que sempre preenche — `Models.swift:628`) não deve
    /// virar convite pra subir pra lugar nenhum.
    func testNaoPodeSubirComParentVazio() {
        XCTAssertFalse(NavegacaoDePastas.podeSubir(caminhoAtual: "/qualquer", parent: ""))
    }

    /// `listing` ainda não chegou (carregando) — `parent` é `nil` porque não
    /// há do que derivar. Sem afordância de subir enquanto não se sabe pra
    /// onde.
    func testNaoPodeSubirSemListingAindaCarregando() {
        XCTAssertFalse(NavegacaoDePastas.podeSubir(caminhoAtual: "/DATA", parent: nil))
    }

    /// Caminho com espaço e acento — string comum neste app (nome de
    /// usuária no macmini, "São Paulo" em pastas de projeto). Comparação de
    /// igualdade não tem tratamento especial hoje; teste de regressão barato
    /// pra garantir que continua não precisando.
    func testFuncionaComCaminhoComAcentoOuEspaco() {
        XCTAssertTrue(NavegacaoDePastas.podeSubir(
            caminhoAtual: "/Users/Vanessa Fontes/São Paulo",
            parent: "/Users/Vanessa Fontes"))
        XCTAssertFalse(NavegacaoDePastas.podeSubir(
            caminhoAtual: "/Users/Vanessa Fontes",
            parent: "/Users/Vanessa Fontes"))
    }

    /// A decisão não depende de `estadoVazio`/`visible.isEmpty` — é
    /// exatamente por isso que "os dois" (linha ".." + botão da toolbar)
    /// resolve o pior caso do card: uma pasta vazia (só ocultos, ou vazia de
    /// verdade) continua tendo pai alcançável, então o botão da toolbar (que
    /// compõe fora do `switch` de `estadoVazio`) tem que aparecer mesmo
    /// quando a lista some. Este teste prova que a função em si não recebe
    /// nem depende de nenhum sinal de "lista vazia" — só `parent`/caminho.
    func testDecisaoIndependeDeListaVaziaOuOcultos() {
        // Pasta vazia (com ou sem ocultos) ainda tem pai: sobe igual.
        XCTAssertTrue(NavegacaoDePastas.podeSubir(caminhoAtual: "/DATA/vazia", parent: "/DATA"))
    }
}

/// A marca de repositório Git no seletor de pastas (`is_repo`, 20/09/2026).
///
/// Nasceu quando o painel Diff deixou de aceitar caminho digitado e passou a
/// escolher a pasta pelo `FolderPickerView`: sem marca, achar o repositório é
/// descer às cegas. O campo é OPCIONAL no app de propósito — o hub que está no
/// ar antes do deploy desta leva não emite `is_repo`, e "ausente" não pode ser
/// lido como "não é repositório", que seria mentira com cara de informação.
final class MarcaDeRepositorioTests: XCTestCase {

    private func decodificar(_ json: String) throws -> DirListing {
        try JSONDecoder.cutuque.decode(DirListing.self, from: Data(json.utf8))
    }

    /// Caminho feliz: hub novo marca a pasta atual e cada subpasta.
    /// `is_repo` chega em snake_case e tem que cair em `isRepo` pela
    /// estratégia do decoder da casa.
    func testHubNovoMarcaPastaAtualESubpastas() throws {
        let listing = try decodificar("""
        {"path":"/Users/example/code","parent":"/Users/example","is_repo":true,
         "dirs":[{"name":"cutuque","path":"/Users/example/code/cutuque","is_repo":true},
                 {"name":"rascunhos","path":"/Users/example/code/rascunhos","is_repo":false}]}
        """)
        XCTAssertTrue(listing.ehRepositorio)
        XCTAssertTrue(listing.dirs[0].ehRepositorio)
        XCTAssertFalse(listing.dirs[1].ehRepositorio)
    }

    /// Hub antigo (sem o campo): decodifica sem erro e NÃO marca ninguém.
    /// É o caso que roda no aparelho dela entre o build do app e o deploy do
    /// hub no macmini — se isto lançasse, o seletor pararia de listar pasta.
    func testHubAntigoSemCampoNaoMarcaNemQuebra() throws {
        let listing = try decodificar("""
        {"path":"/Users/example","parent":"/Users",
         "dirs":[{"name":"Desktop","path":"/Users/example/Desktop"}]}
        """)
        XCTAssertNil(listing.isRepo)
        XCTAssertFalse(listing.ehRepositorio)
        XCTAssertNil(listing.dirs[0].isRepo)
        XCTAssertFalse(listing.dirs[0].ehRepositorio)
    }

    /// `ehRepositorio` só é verdade com afirmação explícita — nem `false` nem
    /// ausente podem virar marca.
    func testMarcaExigeAfirmacaoExplicita() throws {
        let listing = try decodificar("""
        {"path":"/tmp","parent":"/","is_repo":false,
         "dirs":[{"name":"vazia","path":"/tmp/vazia","is_repo":false}]}
        """)
        XCTAssertFalse(listing.ehRepositorio)
        XCTAssertFalse(listing.dirs[0].ehRepositorio)
    }

    /// Pasta oculta continua oculta por padrão mesmo sendo repositório: a
    /// marca nova não pode virar exceção ao toggle de ocultas do seletor.
    func testPastaOcultaRepositorioContinuaOculta() throws {
        let listing = try decodificar("""
        {"path":"/Users/example","parent":"/Users","is_repo":false,
         "dirs":[{"name":".dotfiles","path":"/Users/example/.dotfiles","is_repo":true}]}
        """)
        XCTAssertTrue(listing.dirs[0].isHidden)
        XCTAssertTrue(listing.dirs[0].ehRepositorio)
    }
}
