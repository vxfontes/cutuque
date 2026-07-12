export const PRIORITY = { needs_you: 0, error: 1, running: 2, done: 3, idle: 4 };

export function sortByPriority(sessions) {
  return [...sessions].sort((a, b) => {
    const pa = PRIORITY[a.state] ?? 99;
    const pb = PRIORITY[b.state] ?? 99;
    if (pa !== pb) return pa - pb;
    // empate: mais recente primeiro (updated_at desc)
    return String(b.updated_at).localeCompare(String(a.updated_at));
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
