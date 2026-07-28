package claudecode

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"
)

// transcriptIDsScript lista o id de TODA sessão que ainda tem transcript no
// disco da máquina. Só faz glob nos NOMES dos arquivos: não abre nenhum, não
// ordena por conteúdo e — de propósito — não corta a lista.
//
// É deliberadamente diferente do discoverScript, que lê cada .jsonl para montar
// título/preview e termina em `out[:40]`. Aquele corte é inofensivo para o sheet
// de descoberta (a usuária só quer as recentes) e seria DESTRUTIVO aqui: o
// reaper usa esta resposta para decidir entre marcar idle e esquecer a sessão,
// e uma máquina com mais de 40 transcrições faria ele esquecer sessões que
// existem. "Não sei" e "não existe" não podem se confundir neste caminho.
const transcriptIDsScript = `import os,json,glob
base=os.path.expanduser('~/.claude/projects')
print(json.dumps(sorted(os.path.basename(f)[:-6] for f in glob.glob(base+'/*/*.jsonl'))))
`

// runTranscriptIDs executa o comando (python3 lendo o script pelo stdin) e
// devolve a lista de ids. Lista vazia e erro são coisas diferentes: o chamador
// PRECISA distinguir, senão um ssh caído vira "nenhuma sessão existe".
func runTranscriptIDs(cmd *exec.Cmd) ([]string, error) {
	cmd.Env = childEnv()
	cmd.Stdin = strings.NewReader(transcriptIDsScript)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	trimmed := strings.TrimSpace(string(out))
	if trimmed == "" {
		return nil, nil
	}
	var ids []string
	if err := json.Unmarshal([]byte(trimmed), &ids); err != nil {
		return nil, err
	}
	return ids, nil
}

// TranscriptIDs lista os transcripts existentes na máquina LOCAL.
func (t *LocalTarget) TranscriptIDs(ctx context.Context) ([]string, error) {
	return runTranscriptIDs(exec.CommandContext(ctx, "python3", "-"))
}

// TranscriptIDs lista os transcripts existentes na máquina remota via ssh.
func (t *SSHTarget) TranscriptIDs(ctx context.Context) ([]string, error) {
	args := append(sshBaseOpts(), "--", t.dest, "python3 -")
	return runTranscriptIDs(exec.CommandContext(ctx, t.prog, args...))
}
