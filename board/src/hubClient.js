export function createHubClient({ hubBaseUrl, token, fetchImpl = fetch }) {
  const h = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  async function req(method, path, body) {
    const res = await fetchImpl(`${hubBaseUrl}${path}`, {
      method, headers: h, body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) throw new Error(`${method} ${path}: HTTP ${res.status}`);
    if (res.status === 204) return null;
    return res.json();
  }
  return {
    async listTasks() { return (await req('GET', '/board')).tasks || []; },
    async createTask(t) { return req('POST', '/board/tasks', t); },
    async moveTask(id, column) { return req('PATCH', `/board/tasks/${id}`, { column }); },
    async patchTask(id, patch) { return req('PATCH', `/board/tasks/${id}`, patch); },
    async addComment(id, author, text) { return req('POST', `/board/tasks/${id}/comments`, { author, text }); },
    async archive() { return (await req('GET', '/board/archive')).weeks || []; },
    async closeWeek() { return req('POST', '/board/close', {}); },
  };
}
