const COLS = ['a_fazer', 'em_progresso', 'feito', 'em_revisao', 'concluido'];
const LABEL = { a_fazer: 'A fazer', em_progresso: 'Em progresso', feito: 'Feito', em_revisao: 'Em revisão', concluido: 'Concluído' };

export const commands = {
  async add(cli, title, { desc = '' } = {}) {
    const t = await cli.client.createTask({
      title,
      group: cli.identity.group,
      session: cli.identity.session,
      type: cli.identity.type || '',
      role: cli.identity.role || '',
      description: desc,
    });
    cli.out(`✓ criado ${t.id} em "A fazer": ${title}${cli.identity.role ? ` (${cli.identity.role})` : ''}`);
  },
  async comment(cli, id, text) {
    await cli.client.addComment(id, cli.identity.role || cli.identity.type || '?', text);
    cli.out(`✓ comentário adicionado em ${id} por ${cli.identity.role || cli.identity.type || '?'}`);
  },
  async desc(cli, id, text) {
    await cli.client.patchTask(id, { description: text });
    cli.out(`✓ descrição atualizada em ${id}`);
  },
  async list(cli) {
    const all = await cli.client.listTasks();
    const mine = all.filter((t) => t.group === cli.identity.group && t.session === cli.identity.session);
    cli.out(`Board de ${cli.identity.group}/${cli.identity.session} (${mine.length}):`);
    for (const col of COLS) {
      const items = mine.filter((t) => t.column === col);
      if (!items.length) continue;
      cli.out(`\n${LABEL[col]}:`);
      for (const t of items) cli.out(`  ${t.id}  ${t.title}`);
    }
  },
  async move(cli, id, column) {
    if (!COLS.includes(column)) throw new Error(`coluna inválida: ${column} (use: ${COLS.join(', ')})`);
    await cli.client.moveTask(id, column);
    cli.out(`✓ ${id} → ${LABEL[column]}`);
  },
};
