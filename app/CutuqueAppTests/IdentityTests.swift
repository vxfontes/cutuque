import XCTest
@testable import CutuqueApp

/// Identidades da aba Máquinas: decode do que o hub manda e a regra de ouro do
/// PATCH — `nil` mantém a senha guardada, `""` apaga. É a parte mais sensível
/// deste redesenho (Termius: identidade separada do host, senha vive nela);
/// um `""` mandado por engano APAGARIA a senha da usuária sem ela pedir.
final class IdentityTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder.cutuque.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Decode

    func testIdentityDecodificaOQueOHubManda() throws {
        let i: Identity = try decode(#"{"name":"pessoal","username":"vx","has_password":true}"#)
        XCTAssertEqual(i.name, "pessoal")
        XCTAssertEqual(i.username, "vx")
        XCTAssertTrue(i.hasPassword)
        XCTAssertEqual(i.id, "pessoal")
    }

    func testIdentitySoDeChaveTemHasPasswordFalso() throws {
        let i: Identity = try decode(#"{"name":"vps","username":"root","has_password":false}"#)
        XCTAssertFalse(i.hasPassword)
    }

    func testIdentityListResponseTrazCanStorePassword() throws {
        let resp: IdentityListResponse = try decode("""
        {"identities":[{"name":"a","username":"vx","has_password":true}],"can_store_password":true}
        """)
        XCTAssertEqual(resp.identities.count, 1)
        XCTAssertTrue(resp.canStorePassword)
    }

    /// Hub que não guarda senha (`can_store_password: false`) é o que decide
    /// se a tela de "nova identidade" mostra o campo de senha.
    func testIdentityListResponseSemArmazenamentoDeSenha() throws {
        let resp: IdentityListResponse = try decode(#"{"identities":[],"can_store_password":false}"#)
        XCTAssertFalse(resp.canStorePassword)
        XCTAssertTrue(resp.identities.isEmpty)
    }

    /// `POST /identities`: a chave PÚBLICA volta pra exibição; a privada nasce
    /// e fica no hub — nunca aparece aqui, igual ao cadastro de máquina.
    func testIdentityCreatedTrazAIdentidadeEAChavePublica() throws {
        let c: IdentityCreated = try decode("""
        {"identity":{"name":"pessoal","username":"vx","has_password":false},
         "public_key":"ssh-ed25519 AAAA... cutuque-pessoal"}
        """)
        XCTAssertEqual(c.identity.name, "pessoal")
        XCTAssertEqual(c.publicKey, "ssh-ed25519 AAAA... cutuque-pessoal")
    }

    func testIdentityEnvelopeDecodificaARespostaDoPatch() throws {
        let e: IdentityEnvelope = try decode(#"{"identity":{"name":"a","username":"vx","has_password":true}}"#)
        XCTAssertEqual(e.identity.name, "a")
    }

    // MARK: - Regra de ouro do PATCH: nil mantém, "" apaga

    /// `password: nil` não pode nem aparecer como chave no corpo — é a
    /// diferença entre "mantém a senha guardada" e "manda string vazia", que
    /// o hub trataria como apagar.
    func testUpdateIdentityBodyOmiteSenhaQuandoNil() {
        let body = APIClient.identityUpdateBody(username: "vx", password: nil)
        XCTAssertEqual(body.count, 1, "só 'username' pode entrar — 'password' nil não é chave nenhuma")
        XCTAssertNil(body["password"])
        XCTAssertEqual(body["username"] as? String, "vx")
    }

    /// String vazia É a apagada explícita — entra no corpo como "".
    func testUpdateIdentityBodyApagaComStringVazia() {
        let body = APIClient.identityUpdateBody(username: "vx", password: "")
        XCTAssertEqual(body["password"] as? String, "")
        XCTAssertEqual(body.count, 2)
    }

    /// Texto novo troca a senha guardada.
    func testUpdateIdentityBodyTrocaComTextoNovo() {
        let body = APIClient.identityUpdateBody(username: "vx", password: "nova-senha")
        XCTAssertEqual(body["password"] as? String, "nova-senha")
    }

    /// Prova ponta a ponta: serializado de verdade, o `nil` some do JSON —
    /// não vira `"password":null` (que o hub poderia interpretar diferente
    /// de "campo ausente"). É o teste que garante a serialização de verdade,
    /// não só o dicionário em memória.
    func testUpdateIdentityBodySerializadoNaoContemPasswordQuandoNil() throws {
        let body = APIClient.identityUpdateBody(username: "vx", password: nil)
        let data = try JSONSerialization.data(withJSONObject: body)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("password"), "nil tem que sumir do JSON, não virar \"password\":null")
    }

    // MARK: - Erros de identidade

    func testErroDeIdentidadePrefereODetalhe() {
        let msg = APIClient.identityErrorMessage(
            from: Data(#"{"error":"duplicate_identity","detail":"já existe \"pessoal\""}"#.utf8),
            status: 409
        )
        XCTAssertEqual(msg, "já existe \"pessoal\"")
    }

    func testErroDeIdentidadeSemDetalheViraFrase() {
        let msg = APIClient.identityErrorMessage(from: Data(#"{"error":"identity_in_use"}"#.utf8), status: 409)
        XCTAssertEqual(msg, "identidade em uso por uma ou mais máquinas — remova das máquinas primeiro")
    }

    func testErroDeIdentidadeCannotStorePassword() {
        let msg = APIClient.identityErrorMessage(from: Data(#"{"error":"cannot_store_password"}"#.utf8), status: 400)
        XCTAssertEqual(msg, "este hub não guarda senha — cadastre só com chave")
    }
}
