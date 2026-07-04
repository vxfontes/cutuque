import SwiftUI

/// Tela principal no pulso: as sessões que precisam de você. Toque abre as ações.
struct WatchRootView: View {
    @EnvironmentObject private var conn: WatchConnector

    var body: some View {
        NavigationStack {
            List {
                if conn.sessions.isEmpty {
                    ContentUnavailableView(
                        conn.reachable ? "Tudo em dia" : "iPhone fora de alcance",
                        systemImage: conn.reachable ? "checkmark.circle" : "iphone.slash",
                        description: Text(conn.reachable ? "Nada precisa de você agora." : "Abra o Cutuque no iPhone e deixe por perto.")
                    )
                } else {
                    ForEach(conn.sessions) { s in
                        NavigationLink(value: s) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.headline).lineLimit(1)
                                if !s.prompt.isEmpty {
                                    Text(s.prompt).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cutuque")
            .navigationDestination(for: WatchSession.self) { WatchActionView(session: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { conn.refresh() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }
}

/// Ações para uma sessão: aprovar / negar (permissão), ou responder por texto
/// (ditado do relógio). Para sessões de tmux só faz sentido responder.
struct WatchActionView: View {
    let session: WatchSession
    @EnvironmentObject private var conn: WatchConnector
    @Environment(\.dismiss) private var dismiss
    @State private var replyText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !session.prompt.isEmpty {
                    Text(session.prompt).font(.footnote)
                }
                if !session.hasPane {
                    Button {
                        conn.approve(session.id); dismiss()
                    } label: {
                        Label("Aprovar", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .tint(.green)

                    Button(role: .destructive) {
                        conn.deny(session.id); dismiss()
                    } label: {
                        Label("Negar", systemImage: "xmark").frame(maxWidth: .infinity)
                    }
                }

                TextField("Responder…", text: $replyText)
                Button {
                    let t = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    conn.reply(session.id, t); dismiss()
                } label: {
                    Label("Enviar", systemImage: "paperplane").frame(maxWidth: .infinity)
                }
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(session.title)
    }
}
