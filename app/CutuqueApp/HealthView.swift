import SwiftUI

@MainActor
final class HealthViewModel: ObservableObject {
    @Published var status: HealthStatus = .unknown
    private let client = HealthClient()

    func refresh() async {
        status = await client.check()
    }
}

struct HealthView: View {
    @StateObject private var model = HealthViewModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("Cutuque").font(.largeTitle.bold())
            switch model.status {
            case .unknown: Label("verificando…", systemImage: "circle.dotted")
            case .online:  Label("hub online", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .offline: Label("hub offline", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            Button("Verificar") { Task { await model.refresh() } }
        }
        .padding()
        .task { await model.refresh() }
    }
}
