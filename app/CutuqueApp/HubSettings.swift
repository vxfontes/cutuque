import SwiftUI

// MARK: - Configuração do hub em runtime

/// Endereço e token do hub, editáveis em runtime (UserDefaults) — sem rebuild
/// quando o hub muda de casa (dev local → MacBook via Tailscale → ZimaOS na
/// Fase 5). Defaults casam com o ambiente de dev (simulador + hub local).
enum HubSettings {
    static let urlKey = "hub_url"
    static let tokenKey = "hub_token"

    static let defaultURL = "http://127.0.0.1:8787"
    static let defaultToken = "dev-token"

    /// URL base atual do hub (fallback no default de dev se vazio/inválido).
    static var baseURL: URL {
        let raw = UserDefaults.standard.string(forKey: urlKey) ?? defaultURL
        return URL(string: raw.trimmingCharacters(in: .whitespaces)) ?? URL(string: defaultURL)!
    }

    /// Bearer token atual.
    static var token: String {
        let raw = UserDefaults.standard.string(forKey: tokenKey) ?? defaultToken
        return raw.isEmpty ? defaultToken : raw
    }
}

// MARK: - Tela de ajustes

/// Opções de intervalo do re-cutucão (segundos) oferecidas na tela.
private let renudgeChoices = [5, 10, 15, 30, 60, 120, 300]

/// Ajustes do hub (engrenagem na lista): URL + token (locais) e o intervalo do
/// re-cutucão (lido/gravado no hub via /settings/renudge).
struct HubSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(HubSettings.urlKey) private var url = HubSettings.defaultURL
    @AppStorage(HubSettings.tokenKey) private var token = HubSettings.defaultToken

    @State private var renudge = 15
    @State private var renudgeAvailable = false
    @State private var savingRenudge = false
    @State private var renudgeError: String?
    private let api = APIClient()

    var body: some View {
        NavigationStack {
            Form {
                Section("Hub") {
                    TextField("URL (ex: http://192.0.2.20:8787)", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    if renudgeAvailable {
                        Picker("Repetir a cada", selection: $renudge) {
                            ForEach(renudgeChoices, id: \.self) { s in
                                Text(intervalLabel(s)).tag(s)
                            }
                        }
                        .disabled(savingRenudge)
                        .onChange(of: renudge) { _, novo in
                            Task { await saveRenudge(novo) }
                        }
                    } else {
                        Text("Indisponível (push não configurado no hub).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Cutucão insistente")
                } footer: {
                    Text("Quando uma sessão precisa de você, o hub re-cutuca o seu iPhone/Watch neste intervalo até você aprovar ou negar.")
                }

                if let err = renudgeError {
                    Section {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .task { await loadRenudge() }
        }
    }

    private func intervalLabel(_ s: Int) -> String {
        s < 60 ? "\(s)s" : "\(s / 60) min"
    }

    private func loadRenudge() async {
        // try? sobre Int? achata para Int? — um único if let basta.
        if let secs = try? await api.renudgeSeconds() {
            renudge = nearestChoice(secs)
            renudgeAvailable = true
        }
    }

    private func saveRenudge(_ seconds: Int) async {
        savingRenudge = true
        defer { savingRenudge = false }
        do {
            try await api.setRenudgeSeconds(seconds)
            renudgeError = nil
        } catch {
            renudgeError = "não consegui salvar o intervalo no hub"
        }
    }

    /// Mapeia um valor vindo do hub para a opção mais próxima da lista.
    private func nearestChoice(_ s: Int) -> Int {
        renudgeChoices.min(by: { abs($0 - s) < abs($1 - s) }) ?? 15
    }
}
