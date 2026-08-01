package claudecode

import (
	"strings"
	"testing"
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

// Acima do teto de 1 MiB o script não devolve o conteúdo — evita puxar um log
// de 2 GB para a memória do iPhone.
func TestParseFileContentAcimaDoTetoVemTruncado(t *testing.T) {
	fc, err := parseFileContent([]byte(`{"path":"/big.log","size":2097152,"binary":false,"truncated":true,"content":""}`))
	if err != nil {
		t.Fatalf("parse falhou: %v", err)
	}
	if !fc.Truncated || fc.Content != "" {
		t.Errorf("acima do teto deve vir truncated sem conteúdo: %+v", fc)
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
