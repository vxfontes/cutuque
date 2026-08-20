import SwiftUI
import WebKit

/// Tela do Code Server, iniciada quando o painel Editor fica ativo.
///
/// `isActive` é uma guarda de lifecycle para o chamador: enquanto a tela não
/// está ativa, nenhum POST é iniciado. O `.task(id:)` também cancela o request
/// ao sair da tela, e o URLSession respeita esse cancelamento. O Code Server é
/// exposto somente no iPad nesta versão.
struct CodeServerView: View {
    let machine: String
    let dir: String
    let isActive: Bool

    @State private var requestID = 0
    @State private var state: LoadState = .loading
    @State private var startError: String?
    @State private var webViewIsLoading = false
    @State private var webViewError: String?
    @State private var reloadID = 0

    private let api = APIClient()

    private enum LoadState {
        case idle
        case loading
        case loaded(URL)
    }

    init(machine: String, dir: String = "", isActive: Bool = true) {
        self.machine = machine
        self.dir = dir
        self.isActive = isActive
    }

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        Group {
            if !isPad {
                unsupportedDevice
            } else if !isActive {
                inactiveContent
            } else {
                content
            }
        }
        .navigationTitle("Code Server")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(requestID)-\(isActive)") {
            guard isPad, isActive else { return }
            if case .loaded = state { return }
            await start()
        }
    }

    private var unsupportedDevice: some View {
        ContentUnavailableView {
            Label("Indisponível no iPhone", systemImage: "iphone")
        } description: {
            Text("O Code Server está disponível apenas no iPad nesta versão.")
        }
    }

    private var inactiveContent: some View {
        ContentUnavailableView {
            Label("Code Server inativo", systemImage: "pause.circle")
        } description: {
            Text("Ative esta tela para iniciar o Code Server.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            if let startError {
                errorContent(title: "Não foi possível iniciar o Code Server",
                             message: startError,
                             actionTitle: "Tentar de novo") {
                    self.startError = nil
                    state = .loading
                    requestID += 1
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Preparando Code Server…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Iniciando Code Server…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let url):
            ZStack(alignment: .top) {
                CodeServerWebView(url: url,
                                 isLoading: $webViewIsLoading,
                                 errorMessage: $webViewError)
                    .id(reloadID)
                    .ignoresSafeArea(edges: .bottom)

                if webViewIsLoading {
                    ProgressView("Carregando Code Server…")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 10)
                }

                if let webViewError {
                    errorContent(title: "Não foi possível carregar o Code Server",
                                 message: webViewError,
                                 actionTitle: "Tentar de novo") {
                        self.webViewError = nil
                        reloadID += 1
                    }
                }
            }
        }
    }

    private func errorContent(title: String,
                              message: String,
                              actionTitle: String,
                              action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    @MainActor
    private func start() async {
        state = .loading
        startError = nil
        do {
            let response = try await api.startCodeServer(machine: machine, dir: dir)
            try Task.checkCancellation()
            state = .loaded(response.url)
        } catch is CancellationError {
            state = .idle
        } catch {
            if Task.isCancelled {
                state = .idle
                return
            }
            state = .idle
            startError = error.localizedDescription
        }
    }
}

private struct CodeServerWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, errorMessage: $errorMessage)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding private var isLoading: Bool
        @Binding private var errorMessage: String?

        init(isLoading: Binding<Bool>, errorMessage: Binding<String?>) {
            _isLoading = isLoading
            _errorMessage = errorMessage
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            isLoading = true
            errorMessage = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            isLoading = false
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation?,
                     withError error: Error) {
            isLoading = false
            errorMessage = error.localizedDescription
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation?,
                     withError error: Error) {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}
