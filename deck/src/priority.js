export const PRIORITY = { needs_you: 0, error: 1, running: 2, done: 3, idle: 4 };

export function sortByPriority(sessions) {
  return [...sessions].sort((a, b) => {
    const pa = PRIORITY[a.state] ?? 99;
    const pb = PRIORITY[b.state] ?? 99;
    if (pa !== pb) return pa - pb;
    // empate: mais recente primeiro (updated_at desc), comparação ordinal determinística
    const ua = String(a.updated_at);
    const ub = String(b.updated_at);
    if (ub === ua) return 0;
    return ub < ua ? -1 : 1;
  });
}

export function paginate(sortedSessions, page, perPage = 8) {
  const pageCount = Math.max(1, Math.ceil(sortedSessions.length / perPage));
  const clamped = Math.min(Math.max(0, page | 0), pageCount - 1);
  const start = clamped * perPage;
  return {
    items: sortedSessions.slice(start, start + perPage),
    page: clamped,
    pageCount,
    hasPrev: clamped > 0,
    hasNext: clamped < pageCount - 1,
  };
}
