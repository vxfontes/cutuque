// [16/08/2026] Teste do parser ANSI do dashboard, rodando FORA do browser.
//
// Por que existe: `parseAnsiToHtml` passou a alimentar `innerHTML` com texto de
// terminal de TERCEIRO (a saída do Claude Code/Codex rodando na máquina remota).
// Antes disso o dashboard usava `textContent` e a garantia anti-XSS era estrutural
// — o browser não interpretava nada. Agora a garantia depende do PARSER, e garantia
// que depende de código precisa de teste que a exercite.
//
// Como funciona: o parser vive dentro de `dashboard.html` (arquivo servido via
// //go:embed, sem build step e sem <script src> — restrição do projeto: zero
// recurso externo). Para testar sem duplicar o código, este script EXTRAI por
// regex o trecho entre os marcadores `ANSI_PARSER_START`/`ANSI_PARSER_END` e a
// linha do `esc`, e avalia num `new Function`. Extrair em vez de copiar é o ponto:
// se alguém editar o parser, o teste testa a versão editada. Se os marcadores
// sumirem ou o `esc` mudar de forma, o teste FALHA em voz alta em vez de passar
// testando uma cópia velha.
//
// Rodar: `node hub/internal/server/dashboard_ansi_test.js`
// (ou, junto com o resto, `make test` no hub — ver dashboard_ansi_test.go).

const fs = require('fs');
const path = require('path');

const HTML = path.join(__dirname, 'dashboard.html');
const src = fs.readFileSync(HTML, 'utf8');

function extrair(nome, re) {
  const m = src.match(re);
  if (!m) {
    console.error(`FALHA DE EXTRAÇÃO: não achei ${nome} em ${HTML}.`);
    console.error('O parser mudou de forma. Ajuste este teste — não o apague.');
    process.exit(2);
  }
  return m[1] !== undefined ? m[1] : m[0];
}

// O `esc` real, não uma reimplementação: a garantia anti-XSS é dele.
const escSrc = extrair('a definição de `const esc`', /^\s*const esc = \(t\) =>.*$/m);
const blocoSrc = extrair(
  'o bloco ANSI_PARSER_START..ANSI_PARSER_END',
  /\/\/ ANSI_PARSER_START\n([\s\S]*?)\n\s*\/\/ ANSI_PARSER_END/
);

// O bloco é PURO (nenhuma referência a document/window — conferido por grep e
// mantido assim de propósito), então basta o `esc` de dependência.
const parseAnsiToHtml = new Function(`${escSrc}\n${blocoSrc}\nreturn parseAnsiToHtml;`)();

const E = '\x1b';
let falhas = 0;
function ok(nome, cond, detalhe) {
  if (cond) return;
  falhas++;
  console.error(`✗ ${nome}`);
  if (detalhe !== undefined) console.error(`  ${detalhe}`);
}
function igual(nome, obtido, esperado) {
  ok(nome, obtido === esperado, `esperado: ${JSON.stringify(esperado)}\n  obtido:  ${JSON.stringify(obtido)}`);
}

// ---------------------------------------------------------------------------
// 1. GARANTIA ANTI-XSS — a razão de o teste existir.
// As ÚNICAS tags que podem sair são <span style="..."> e </span> geradas por
// esta função. Removidas essas, não pode sobrar NENHUM '<' ou '>' cru.
// ---------------------------------------------------------------------------
const HOSTIS = [
  '<img src=x onerror=alert(1)>',
  '<script>alert(1)</script>',
  '</span><script>alert(1)</script>',
  '<a href="javascript:alert(1)">x</a>',
  `${E}[31m<img src=x onerror=alert(1)>${E}[0m`,          // dentro de um SGR válido
  `${E}]8;;javascript:alert(1)${E}\\clique${E}]8;;${E}\\`, // hyperlink OSC 8 hostil
  `${E}]0;<script>alert(1)</script>\x07ok`,                // título de janela hostil
  `${E}[38;5;9m" onmouseover="alert(1)${E}[0m`,            // tentativa de sair do atributo style
  `${E}[38;2;1;2;3;m<b>x</b>`,
  "' onclick='alert(1)",                                   // aspa simples (defesa em profundidade do esc)
  `${E}[999m<i>x</i>`,
  `${E}[38;5;300m<u>x</u>`,                                // índice fora de faixa
];
for (const payload of HOSTIS) {
  const out = parseAnsiToHtml(payload);
  const semSpans = out.replace(/<span style="[^"]*">/g, '').replace(/<\/span>/g, '');
  ok(`anti-XSS: nenhuma tag crua em ${JSON.stringify(payload)}`,
    !semSpans.includes('<') && !semSpans.includes('>'), `saída: ${out}`);
  ok(`anti-XSS: nenhum atributo de evento em ${JSON.stringify(payload)}`,
    !/on\w+\s*=/.test(out.replace(/&#39;|&quot;/g, '')) || !/<[^>]*on\w+\s*=/.test(out), `saída: ${out}`);
}
igual('esc escapa aspa simples', parseAnsiToHtml("a'b"), 'a&#39;b');
igual('esc escapa & antes de tudo', parseAnsiToHtml('&lt;'), '&amp;lt;');

// ---------------------------------------------------------------------------
// 2. PROVA FUNCIONAL CENTRAL — a amostra real de captura que motivou a mudança.
// Antes, "38;5;246" vazava como TEXTO na tela dela.
// ---------------------------------------------------------------------------
igual('amostra real (cinza 246)',
  parseAnsiToHtml(`${E}[38;5;246m*${E}[39m ${E}[38;5;246mCooked for 56m 19s${E}[39m`),
  '<span style="color:#949494">*</span> <span style="color:#949494">Cooked for 56m 19s</span>');
ok('nenhum parâmetro SGR vaza como texto',
  !parseAnsiToHtml(`${E}[38;5;246mx${E}[0m`).includes('38;5;246'));

// ---------------------------------------------------------------------------
// 3. SGR: cores, estilos, e o caso composto que o parser ingênuo erra.
// ---------------------------------------------------------------------------
igual('16 cores básicas', parseAnsiToHtml(`${E}[31mx${E}[0m`), '<span style="color:#cd3131">x</span>');
igual('bright via 90-97', parseAnsiToHtml(`${E}[91mx${E}[0m`), '<span style="color:#f14c4c">x</span>');
igual('truecolor válido', parseAnsiToHtml(`${E}[38;2;10;20;30mx${E}[0m`), '<span style="color:rgb(10,20,30)">x</span>');
igual('truecolor fora de faixa é descartado', parseAnsiToHtml(`${E}[38;2;10;20;300mx${E}[0m`), 'x');
igual('composto 1;38;5;231 não trata 231 como SGR solto',
  parseAnsiToHtml(`${E}[1;38;5;231mx${E}[0m`),
  '<span style="font-weight:700;color:#ffffff">x</span>');
igual('ESC[m sozinho == reset', parseAnsiToHtml(`${E}[1mx${E}[my`), '<span style="font-weight:700">x</span>y');
igual('reset limpa estado', parseAnsiToHtml(`${E}[1;31mx${E}[0my`), '<span style="font-weight:700;color:#cd3131">x</span>y');

// Regressão do defeito corrigido em 16/08/2026: modo desconhecido depois de 38.
// Antes, o '4' voltava ao laço como SGR independente e PINTAVA sublinhado —
// uma sequência malformada acabava alterando a tela em vez de ser ignorada.
ok('modo 38 desconhecido não vira sublinhado',
  !parseAnsiToHtml(`${E}[38;4;200mx${E}[0m`).includes('underline'),
  `saída: ${parseAnsiToHtml(`${E}[38;4;200mx${E}[0m`)}`);

// ---------------------------------------------------------------------------
// 4. DESCARTE POR GRAMÁTICA — o motivo de o parser não ter lista fechada de
// finals. Qualquer sequência não catalogada tem que sumir, não vazar.
// ---------------------------------------------------------------------------
const DESCARTAVEIS = [
  [`a${E}[2Jb`, 'ab', 'apagar tela (J)'],
  [`a${E}[Kb`, 'ab', 'apagar linha (K)'],
  [`a${E}[10;20Hb`, 'ab', 'mover cursor (H)'],
  [`a${E}[?1049hb`, 'ab', 'tela alternativa (modo DEC privado)'],
  [`a${E}[>4;2mb`, 'ab', 'CSI com prefixo > (final m, mas não é SGR de cor)'],
  [`a${E}7b${E}8c`, 'abc', 'save/restore cursor (ESC 7 / ESC 8)'],
  [`a${E}(Bb`, 'ab', 'seleção de charset (ESC ( B)'],
  [`a\x07b`, 'ab', 'BEL solto'],
  [`a\rb`, 'ab', 'CR isolado'],
  [`a${E}]8;;http://x${E}\\link${E}]8;;${E}\\b`, 'alinkb', 'hyperlink OSC 8: some o wrapper, fica o texto'],
  [`a${E}]0;titulo\x07b`, 'ab', 'título de janela OSC 0 terminado por BEL'],
];
for (const [entrada, esperado, nome] of DESCARTAVEIS) igual(`descarte: ${nome}`, parseAnsiToHtml(entrada), esperado);

// ---------------------------------------------------------------------------
// 5. TRUNCAMENTO — o poll corta a captura no meio de uma sequência. Não pode
// lançar exceção nem despejar o resto cru.
// ---------------------------------------------------------------------------
const TRUNCADOS = [`ok${E}[38;5`, `ok${E}[`, `ok${E}]8;;http://x`, `ok${E}`, `ok${E}[38;5;`];
for (const t of TRUNCADOS) {
  let out;
  try { out = parseAnsiToHtml(t); } catch (e) { out = `EXCEÇÃO: ${e}`; }
  igual(`truncado ${JSON.stringify(t)} vira só o texto já completo`, out, 'ok');
}

// ---------------------------------------------------------------------------
// 6. Entradas degeneradas.
// ---------------------------------------------------------------------------
igual('null vira string vazia', parseAnsiToHtml(null), '');
igual('undefined vira string vazia', parseAnsiToHtml(undefined), '');
igual('string vazia', parseAnsiToHtml(''), '');
igual('texto puro passa intacto', parseAnsiToHtml('linha 1\nlinha 2'), 'linha 1\nlinha 2');

if (falhas) {
  console.error(`\n${falhas} falha(s) no parser ANSI do dashboard.`);
  process.exit(1);
}
console.log('parser ANSI do dashboard: OK');
