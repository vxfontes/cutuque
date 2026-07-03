import Foundation

enum HealthStatus: Equatable {
    case unknown
    case online
    case offline
}

struct HealthClient {
    // Mesmo endereço configurável do APIClient (tela de Ajustes).
    var baseURL: URL { HubSettings.baseURL }

    func check() async -> HealthStatus {
        let url = baseURL.appendingPathComponent("health")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let body = try? JSONDecoder().decode([String: String].self, from: data),
                  body["status"] == "ok" else {
                return .offline
            }
            return .online
        } catch {
            return .offline
        }
    }
}
