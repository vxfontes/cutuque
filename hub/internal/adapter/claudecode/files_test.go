package claudecode

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseFileListingLeEntradasEOrdena(t *testing.T) {
	out := []byte(`{"path":"/home/vx","parent":"/home","entries":[
		{"name":"docs","path":"/home/vx/docs","size":0,"mtime":1700000000,"is_dir":true},
		{"name":".env","path":"/home/vx/.env","size":128,"mtime":1700000100,"is_dir":false}
	]}`)
	fl, err := parseFileListing(out)
	if err != nil {
		t.Fatalf("parse falhou: %v", err)
	}
	if fl.Path != "/home/vx" || fl.Parent != "/home" {
		t.Errorf("path/parent errados: %+v", fl)
	}
	if len(fl.Entries) != 2 {
		t.Fatalf("esperava 2 entradas, veio %d", len(fl.Entries))
	}
	if !fl.Entries[0].IsDir || fl.Entries[0].Name != "docs" {
		t.Errorf("primeira entrada deve ser a pasta: %+v", fl.Entries[0])
	}
	if fl.Entries[1].Size != 128 {
		t.Errorf("tamanho do arquivo errado: %d", fl.Entries[1].Size)
	}
	if fl.Entries[1].ModTime != 1700000100 {
		t.Errorf("mtime errado: %d", fl.Entries[1].ModTime)
	}
}

// Saída vazia acontece quando o python3 não está no alvo ou a pasta explodiu.
// Não é erro de parse: o app mostra pasta vazia em vez de quebrar a navegação.
func TestParseFileListingVazioNaoEhErro(t *testing.T) {
	fl, err := parseFileListing([]byte("   "))
	if err != nil {
		t.Fatalf("saída vazia não deve ser erro: %v", err)
	}
	if len(fl.Entries) != 0 {
		t.Errorf("esperava listagem vazia, veio %+v", fl)
	}
}

// O caminho vai como argv single-quoted, nunca interpolado no shell. Um
// caminho com aspas ou ponto-e-vírgula não pode virar comando.
func TestSSHListFilesArgsMandamCaminhoComoArgumentoQuotado(t *testing.T) {
	tgt := NewSSHTarget("macbook", "vx@host")
	args := tgt.listFilesArgs("/tmp/a b'; rm -rf /")
	last := args[len(args)-1]
	if !strings.HasPrefix(last, "python3 - ") {
		t.Fatalf("último arg deve rodar o python3 com o caminho: %q", last)
	}
	// singleQuote fecha a aspa, escapa a do atacante e reabre: o "; rm" fica
	// dentro da string do argv, não vira comando.
	if !strings.Contains(last, `'\''`) {
		t.Errorf("a aspa simples do caminho não foi escapada: %q", last)
	}
	if strings.HasSuffix(last, "rm -rf /") {
		t.Errorf("o caminho terminou fora das aspas: %q", last)
	}
}

func TestParseFileContentTexto(t *testing.T) {
	fc, err := parseFileContent([]byte(`{"path":"/a.txt","size":5,"binary":false,"truncated":false,"content":"olá\n"}`))
	if err != nil {
		t.Fatalf("parse falhou: %v", err)
	}
	if fc.Binary || fc.Truncated || fc.Content != "olá\n" {
		t.Errorf("conteúdo errado: %+v", fc)
	}
}

// Arquivo binário volta com binary=true e content vazio: o app oferece só
// download em vez de tentar renderizar bytes crus.
func TestParseFileContentBinarioNaoTrazConteudo(t *testing.T) {
	fc, err := parseFileContent([]byte(`{"path":"/a.png","size":9999,"binary":true,"truncated":false,"content":""}`))
	if err != nil {
		t.Fatalf("parse falhou: %v", err)
	}
	if !fc.Binary || fc.Content != "" {
		t.Errorf("binário deve vir sem conteúdo: %+v", fc)
	}
}

// Até 12/08/2026 o script nunca devolvia conteúdo acima do teto de 1 MiB
// (content vinha vazio, sem a chave "tail" no JSON) — ficava só o aviso de
// "arquivo grande demais". Esse comportamento mudou (ver readScriptFmt: agora
// vem a CAUDA do arquivo), mas este teste continua valendo REESCRITO: prova
// que o parser decodifica sem quebrar esse shape antigo (truncated=true,
// content vazio, tail ausente) — útil se uma fixture congelada ou um hub
// ainda não atualizado mandar exatamente isso. O comportamento ATUAL do
// script real está em TestReadScriptCaudaDescartaAPrimeiraLinhaParcial.
func TestParseFileContentFormatoAntigoSemTailAindaDecodifica(t *testing.T) {
	fc, err := parseFileContent([]byte(`{"path":"/big.log","size":2097152,"binary":false,"truncated":true,"content":""}`))
	if err != nil {
		t.Fatalf("parse falhou: %v", err)
	}
	if !fc.Truncated || fc.Content != "" {
		t.Errorf("shape antigo deve seguir decodificando truncado sem conteúdo: %+v", fc)
	}
	// A chave "tail" nem existe neste JSON — Go não tem o problema do Swift
	// (Bool? só existe lá porque um Bool não-opcional quebra o decode inteiro
	// com chave ausente); aqui o zero-value (false) resolve sozinho.
	if fc.Tail {
		t.Errorf("tail ausente no JSON deve decodificar como false, veio true: %+v", fc)
	}
}

// TestParseFileContentComTailTrazAConteudoDaCauda cobre o campo novo "tail"
// (12/08/2026): texto acima do teto de leitura vem com o conteúdo da CAUDA do
// arquivo (não mais vazio) — era o pedido dela de não perder o fim de um log
// grande.
func TestParseFileContentComTailTrazAConteudoDaCauda(t *testing.T) {
	fc, err := parseFileContent([]byte(`{"path":"/big.log","size":5242880,"binary":false,"truncated":true,"tail":true,"content":"linha final\n"}`))
	if err != nil {
		t.Fatalf("parse falhou: %v", err)
	}
	if !fc.Truncated || !fc.Tail || fc.Content == "" {
		t.Errorf("esperava truncated+tail com conteúdo da cauda: %+v", fc)
	}
}

// O teto entra no script pelo Sprintf; se o %d sumir, a leitura vira ilimitada
// em silêncio.
func TestReadScriptCarregaOTetoDeVerdade(t *testing.T) {
	s := readScript()
	if !strings.Contains(s, "1048576") {
		t.Errorf("o teto de 1 MiB não entrou no script: %q", s)
	}
	if strings.Contains(s, "%d") {
		t.Errorf("sobrou verbo de formatação no script: %q", s)
	}
}

// TestReadScriptCaudaDescartaAPrimeiraLinhaParcial prova a regra central da
// cauda (12/08/2026): o seek por byte (size-tailBytes) quase nunca cai numa
// borda de linha, então o script tem que jogar fora tudo antes da primeira
// quebra encontrada — senão a "primeira linha" da cauda seria um fragmento do
// meio de uma linha real. Constrói um arquivo de linhas de largura fixa (137,
// que não divide tailBytes — garante que o seek cai no meio de uma linha),
// roda o script de verdade via python3 e compara byte a byte com o mesmo
// algoritmo replicado aqui em Go.
func TestReadScriptCaudaDescartaAPrimeiraLinhaParcial(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 ausente; pulando teste do script de leitura")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "grande.log")

	linha := strings.Repeat("a", 136) + "\n" // 137 bytes, não divide tailBytes
	raw := []byte(strings.Repeat(linha, 10000))
	if len(raw) <= maxReadBytes {
		t.Fatalf("fixture não passou do teto — teste não testa nada: %d bytes", len(raw))
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("escrever fixture: %v", err)
	}

	// mesmo algoritmo do script (seek + descarte da primeira quebra), calculado
	// em Go, para comparar com o que o python3 devolveu de verdade.
	tailEsperada := raw[len(raw)-tailBytes:]
	idx := bytes.IndexByte(tailEsperada, '\n')
	if idx <= 0 {
		t.Fatalf("fixture não gerou um seek no meio de uma linha — ajustar a largura da linha")
	}
	esperado := string(tailEsperada[idx+1:])

	cmd := exec.Command(py, "-", path)
	cmd.Stdin = strings.NewReader(readScript())
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("rodar o script: %v", err)
	}
	fc, err := parseFileContent(out)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if !fc.Truncated || !fc.Tail {
		t.Fatalf("esperava truncated+tail: %+v", fc)
	}
	if fc.Content != esperado {
		t.Errorf("cauda errada:\nquero  %q\nveio   %q", esperado, fc.Content)
	}
}

// TestReadScriptBinarioNuncaVemComCauda garante que a cauda (12/08/2026) só
// vale para texto: o corte de binário (byte nulo nos primeiros 8 KiB) é
// anterior e continua vencendo — arquivo binário grande não pode ganhar
// tail=true nem conteúdo.
func TestReadScriptBinarioNuncaVemComCauda(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 ausente; pulando teste do script de leitura")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "grande.bin")
	raw := make([]byte, maxReadBytes+tailBytes)
	raw[0] = 0x00 // um byte nulo nos primeiros 8 KiB já marca binário
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("escrever fixture: %v", err)
	}

	cmd := exec.Command(py, "-", path)
	cmd.Stdin = strings.NewReader(readScript())
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("rodar o script: %v", err)
	}
	fc, err := parseFileContent(out)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if !fc.Binary {
		t.Fatalf("esperava binary=true: %+v", fc)
	}
	if fc.Tail || fc.Content != "" {
		t.Errorf("binário acima do teto não pode ganhar cauda: %+v", fc)
	}
}

// TestReadScriptArquivoPequenoNaoGanhaCauda garante que a mudança da cauda
// (12/08/2026) não mexeu no caminho de sempre: arquivo abaixo do teto de
// leitura continua vindo inteiro, sem truncated nem tail.
func TestReadScriptArquivoPequenoNaoGanhaCauda(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 ausente; pulando teste do script de leitura")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "pequeno.txt")
	conteudo := "olá mundo\n"
	if err := os.WriteFile(path, []byte(conteudo), 0o600); err != nil {
		t.Fatalf("escrever fixture: %v", err)
	}

	cmd := exec.Command(py, "-", path)
	cmd.Stdin = strings.NewReader(readScript())
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("rodar o script: %v", err)
	}
	fc, err := parseFileContent(out)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if fc.Truncated || fc.Tail {
		t.Errorf("arquivo abaixo do teto não pode vir truncado/tail: %+v", fc)
	}
	if fc.Content != conteudo {
		t.Errorf("conteúdo errado: %+v", fc)
	}
}

// MARK: escrita

// O conteúdo viaja base64 DENTRO do script (pelo stdin), não no argv: um
// arquivo de 1 MB estoura o ARG_MAX do macOS se for como argumento.
func TestWriteScriptCarregaOConteudoEmBase64(t *testing.T) {
	s := writeScript([]byte("olá\nmundo\n"))
	if strings.Contains(s, "olá") {
		t.Errorf("o conteúdo cru vazou no script: %q", s)
	}
	if !strings.Contains(s, "b2zDoQptdW5kbwo=") {
		t.Errorf("o base64 do conteúdo não entrou no script: %q", s)
	}
	if strings.Contains(s, "%s") {
		t.Errorf("sobrou verbo de formatação no script: %q", s)
	}
}

// Só sobrescreve arquivo que já existe (regra de segurança do spec): o script
// tem que checar antes de abrir para escrita.
func TestWriteScriptSoSobrescreveArquivoExistente(t *testing.T) {
	s := writeScript([]byte("x"))
	if !strings.Contains(s, "not_a_file") {
		t.Errorf("o script não recusa caminho que não é arquivo: %q", s)
	}
	if !strings.Contains(s, "os.path.isfile") {
		t.Errorf("o script não checa existência antes de escrever: %q", s)
	}
}

// Escrita atômica: tmp no mesmo diretório + replace. Sem isso, uma queda no
// meio da gravação deixa o arquivo da usuária truncado.
func TestWriteScriptEhAtomico(t *testing.T) {
	s := writeScript([]byte("x"))
	if !strings.Contains(s, "os.replace") {
		t.Errorf("o script não faz replace atômico: %q", s)
	}
}

func TestParseFileWriteLeOTamanhoNovo(t *testing.T) {
	fw, err := parseFileWrite([]byte(`{"path":"/a.txt","size":11,"error":""}`))
	if err != nil {
		t.Fatalf("parse falhou: %v", err)
	}
	if fw.Path != "/a.txt" || fw.Size != 11 {
		t.Errorf("resultado errado: %+v", fw)
	}
}

func TestParseFileWriteNaoEhArquivoViraErroTipado(t *testing.T) {
	_, err := parseFileWrite([]byte(`{"path":"/x","size":0,"error":"not_a_file"}`))
	if !errors.Is(err, ErrNotAFile) {
		t.Errorf("err = %v, quero ErrNotAFile", err)
	}
}

func TestParseFileWriteOutroErroNaoEhNotAFile(t *testing.T) {
	_, err := parseFileWrite([]byte(`{"path":"/x","size":0,"error":"write_failed"}`))
	if err == nil {
		t.Fatal("erro do script tem que virar erro em Go")
	}
	if errors.Is(err, ErrNotAFile) {
		t.Errorf("write_failed não é ErrNotAFile: %v", err)
	}
}

// Saída vazia = o python3 nem rodou. Não pode virar "salvou com sucesso".
func TestParseFileWriteVazioEhErro(t *testing.T) {
	if _, err := parseFileWrite([]byte("  ")); err == nil {
		t.Error("saída vazia tem que ser erro — senão o app diz 'salvo' sem ter salvo")
	}
}

// MARK: download

func TestSSHDownloadArgsMandamCaminhoQuotadoDepoisDoTracoTraco(t *testing.T) {
	tgt := NewSSHTarget("macbook", "vx@host")
	args := tgt.downloadArgs("/tmp/a b'; rm -rf /")
	last := args[len(args)-1]
	if !strings.Contains(last, `'\''`) {
		t.Errorf("a aspa simples do caminho não foi escapada: %q", last)
	}
	var sepIdx, destIdx = -1, -1
	for i, a := range args {
		if a == "--" {
			sepIdx = i
		}
		if a == "vx@host" {
			destIdx = i
		}
	}
	if sepIdx == -1 || destIdx != sepIdx+1 {
		t.Errorf("destino deve vir logo após '--': %v", args)
	}
}

// O destino vai depois de "--" para o ssh nunca reinterpretar um dest que
// pareça opção.
func TestSSHListFilesArgsIsolamODestinoComTracoTraco(t *testing.T) {
	tgt := NewSSHTarget("macbook", "vx@host")
	args := tgt.listFilesArgs("/tmp")
	var sepIdx, destIdx = -1, -1
	for i, a := range args {
		if a == "--" {
			sepIdx = i
		}
		if a == "vx@host" {
			destIdx = i
		}
	}
	if sepIdx == -1 || destIdx != sepIdx+1 {
		t.Errorf("destino deve vir logo após '--': %v", args)
	}
}

// TestStartDownloadDevolveOsBytesCrus prova que o download em fluxo
// (12/08/2026, StdoutPipe + Start em vez de cmd.Output bufferizado) ainda
// entrega os bytes certos — só mudou COMO eles chegam, não o conteúdo.
func TestStartDownloadDevolveOsBytesCrus(t *testing.T) {
	if _, err := exec.LookPath("cat"); err != nil {
		t.Skip("cat ausente; pulando teste de download")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "a.txt")
	conteudo := []byte("conteúdo cru do arquivo\n")
	if err := os.WriteFile(path, conteudo, 0o600); err != nil {
		t.Fatalf("escrever fixture: %v", err)
	}

	rc, err := startDownload(exec.CommandContext(context.Background(), "cat", "--", path))
	if err != nil {
		t.Fatalf("startDownload: %v", err)
	}
	defer rc.Close()

	got, err := io.ReadAll(rc)
	if err != nil {
		t.Fatalf("ler: %v", err)
	}
	if !bytes.Equal(got, conteudo) {
		t.Errorf("bytes errados: got %q, want %q", got, conteudo)
	}
}

// TestDownloadCloseEsperaOProcessoSemDeixarZumbi prova a garantia central do
// downloadReadCloser (12/08/2026): Close() TEM que esperar o processo
// (cmd.Wait), ou cada download deixa um zumbi na tabela de processos do
// macmini que roda o hub 24h. cmd.ProcessState só fica preenchido depois que
// alguém chama Wait — nil antes do Close, não-nil depois, é a prova direta de
// que o Wait aconteceu (não basta o processo já ter terminado sozinho).
func TestDownloadCloseEsperaOProcessoSemDeixarZumbi(t *testing.T) {
	if _, err := exec.LookPath("cat"); err != nil {
		t.Skip("cat ausente; pulando teste de download")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "a.txt")
	if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
		t.Fatalf("escrever fixture: %v", err)
	}

	cmd := exec.CommandContext(context.Background(), "cat", "--", path)
	rc, err := startDownload(cmd)
	if err != nil {
		t.Fatalf("startDownload: %v", err)
	}
	if _, err := io.ReadAll(rc); err != nil {
		t.Fatalf("ler: %v", err)
	}
	if cmd.ProcessState != nil {
		t.Fatalf("ProcessState já veio preenchido antes do Close — o teste não prova nada")
	}
	if err := rc.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if cmd.ProcessState == nil {
		t.Error("Close() não esperou o processo (cmd.Wait) — deixaria zumbi no macmini")
	}
}

// TestDownloadCloseSemLerTudoAindaAssimEspera cobre o cenário real descrito no
// comentário de downloadReadCloser.Close: a usuária sai da tela (ou o cliente
// HTTP desconecta) antes do arquivo terminar de vir, e o handler só lê uma
// parte antes de fechar. `yes` escreve para sempre — sem o pipe fechado
// primeiro (EPIPE/SIGPIPE), o processo nunca terminaria sozinho, e o Close
// travaria esperando um Wait que nunca retorna.
func TestDownloadCloseSemLerTudoAindaAssimEspera(t *testing.T) {
	if _, err := exec.LookPath("yes"); err != nil {
		t.Skip("yes ausente; pulando teste de download")
	}
	cmd := exec.CommandContext(context.Background(), "yes")
	rc, err := startDownload(cmd)
	if err != nil {
		t.Fatalf("startDownload: %v", err)
	}

	buf := make([]byte, 16)
	if _, err := io.ReadFull(rc, buf); err != nil {
		t.Fatalf("ler um pedaço: %v", err)
	}

	done := make(chan error, 1)
	go func() { done <- rc.Close() }()
	select {
	case <-done:
		// erro (ou nil) aqui tanto faz: o `yes` costuma morrer por
		// EPIPE/SIGPIPE quando o pipe fecha no meio da escrita (ver o
		// comentário de Close) — o que importa é não travar.
	case <-time.After(5 * time.Second):
		t.Fatal("Close() travou esperando um processo que só terminaria fechando o pipe primeiro")
	}
	if cmd.ProcessState == nil {
		t.Error("Close() não esperou o processo (cmd.Wait)")
	}
}
