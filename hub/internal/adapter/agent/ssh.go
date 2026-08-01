package agent

import "strconv"

// IdentityOpts são as opções de ssh que amarram a conexão à chave, à porta e ao
// known_hosts que o hub gerou no cadastro de uma máquina pela aba Máquinas.
// Máquina do hub.env não usa isto: ela conecta pelo ~/.ssh do container.
//
// Estas opções vêm SEMPRE antes das opções base do alvo. O ssh honra a PRIMEIRA
// ocorrência de cada opção na linha de comando, e o StrictHostKeyChecking=yes
// daqui precisa vencer o accept-new do base. Na ordem inversa a checagem
// estrita seria descartada em silêncio — a pior forma de falhar, porque tudo
// continuaria funcionando e ninguém veria.
//
// Sem chave OU sem known_hosts devolve nil: meia identidade seria pior que
// nenhuma (chave própria com known_hosts do container, ou vice-versa).
func IdentityOpts(keyPath, knownHosts string, port int) []string {
	if keyPath == "" || knownHosts == "" {
		return nil
	}
	opts := make([]string, 0, 10)
	// A porta não é enfeite: o ssh-keyscan grava a entrada como "[host]:2222"
	// quando a porta não é a 22, e o ssh só acha essa linha se conectar na mesma
	// porta. Errar aqui não dá "porta errada" — dá host desconhecido com
	// StrictHostKeyChecking=yes, que é bem mais difícil de ler.
	if port > 0 && port != 22 {
		opts = append(opts, "-p", strconv.Itoa(port))
	}
	return append(opts,
		"-i", keyPath,
		// Sem IdentitiesOnly o ssh oferece antes as chaves do ~/.ssh do
		// container, e o servidor pode cortar por excesso de tentativas antes
		// de chegar na certa.
		"-o", "IdentitiesOnly=yes",
		"-o", "UserKnownHostsFile="+knownHosts,
		// A máquina só chega aqui depois de a usuária confirmar a impressão
		// digital no cadastro: nada de aceitar chave nova em silêncio.
		"-o", "StrictHostKeyChecking=yes",
	)
}

// WithIdentity monta a linha de opções final: identidade primeiro, base depois.
// Um só lugar para a ordem, para os três adaptadores não divergirem.
func WithIdentity(identity, base []string) []string {
	out := make([]string, 0, len(identity)+len(base))
	out = append(out, identity...)
	return append(out, base...)
}
