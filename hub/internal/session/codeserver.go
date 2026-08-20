package session

// CodeServer é o estado público de uma instância de code-server iniciada sob
// demanda em uma máquina. O modelo fica no pacote session para que adapters,
// launcher e HTTP compartilhem exatamente o mesmo payload JSON.
//
// URL pode ser uma URL HTTPS publicada pelo Tailscale Serve ou, quando isso
// não for possível, a URL de acesso alternativa devolvida pelo adapter.
// State é mantido como string porque os estados são definidos pelo adapter e
// podem evoluir sem quebrar o contrato de transporte do hub.
type CodeServer struct {
	URL   string `json:"url"`
	State string `json:"state"`
}
