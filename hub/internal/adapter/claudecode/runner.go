package claudecode

import "github.com/vxfontes/cutuque/hub/internal/adapter/agent"

// NewRunner cria o Runner do Claude Code: traduz o stream-json (ParseLine) e
// marca as sessões com o rótulo "claude-code". A plataforma de execução (o loop
// de leitura, o preenchimento de metadados, o tratamento de EOF) vive no pacote
// agent, compartilhada com os demais adapters.
func NewRunner(app Applier) *Runner {
	return agent.NewRunner(app, ParseLine, agentKind)
}
