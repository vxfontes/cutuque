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

/// Ajustes do hub (engrenagem na lista): URL + token, salvos em UserDefaults.
struct HubSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(HubSettings.urlKey) private var url = HubSettings.defaultURL
    @AppStorage(HubSettings.tokenKey) private var token = HubSettings.defaultToken

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
                    Text("No simulador, use 127.0.0.1. No iPhone, use o IP Tailscale da máquina onde o hub roda.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }
}
