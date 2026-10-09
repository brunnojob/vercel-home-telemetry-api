let token = '';
const byId = id => document.getElementById(id);
const project = byId('project');
const notice = (text, error = false) => { byId('notice').textContent = text; byId('notice').className = error ? 'error' : ''; };
const names = [];
const downloads = [];
function clearDownloads() { for (const url of downloads.splice(0)) URL.revokeObjectURL(url); }
async function request(path, options = {}) {
  const response = await fetch(path, { ...options, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, ...options.headers } });
  const data = await response.json();
  if (!response.ok) {
    if (response.status === 401) disconnect();
    throw new Error(data.error ?? 'Request failed');
  }
  return data;
}
function disconnect() {
  clearDownloads();
  token = ''; byId('load').disabled = true; byId('save').disabled = true;
  byId('logout').hidden = true; byId('reports').replaceChildren();
}
async function load() {
  const data = await request(`/api/runs?project=${encodeURIComponent(project.value)}`);
  byId('reports').replaceChildren();
  clearDownloads();
  for (const row of data.items) {
    const article = document.createElement('article');
    const title = document.createElement('h2'); title.textContent = `${row.kind} · ${new Date(row.created_at).toLocaleString()}`;
    const pre = document.createElement('pre'); pre.textContent = JSON.stringify(row.result, null, 2);
    const link = document.createElement('a'); link.textContent = 'Download JSON';
    const url = URL.createObjectURL(new Blob([pre.textContent], { type: 'application/json' }));
    downloads.push(url);
    link.href = url; link.download = `${row.project_id}-${row.id}.json`;
    link.addEventListener('click', () => setTimeout(() => URL.revokeObjectURL(url), 1000), { once: true });
    article.append(title, pre, link); byId('reports').append(article);
  }
  notice(`${data.items.length} persisted report(s).`);
}
byId('login').addEventListener('submit', async event => {
  event.preventDefault(); const button = event.currentTarget.querySelector('button'); button.disabled = true;
  try {
    const session = await request('/api/session', { method: 'POST', body: JSON.stringify({ email: byId('email').value, password: byId('password').value, action: byId('auth-action').value }) });
    if (session.confirmationRequired) { notice('Check your email to confirm your account, then sign in.'); return; }
    token = session.accessToken; byId('password').value = ''; byId('load').disabled = false; byId('save').disabled = false; byId('logout').hidden = false;
    await load();
  } catch (error) { notice(error.message, true); } finally { button.disabled = false; }
});
byId('logout').addEventListener('click', () => { disconnect(); notice('Signed out.'); });
byId('filters').addEventListener('submit', event => { event.preventDefault(); load().catch(error => notice(error.message, true)); });
byId('import').addEventListener('submit', async event => {
  event.preventDefault(); const file = byId('file').files[0];
  if (!file || file.size > 196608) { notice('Select a JSON file smaller than 192 KiB.', true); return; }
  byId('save').disabled = true;
  try {
    const result = JSON.parse(await file.text());
    if (!result || Array.isArray(result) || typeof result !== 'object') throw new Error('A JSON object is required.');
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify({ project: project.value, kind: byId('kind').value, result })));
    const clientKey = [...new Uint8Array(digest)].map(value => value.toString(16).padStart(2, '0')).join('');
    await request('/api/runs', { method: 'POST', body: JSON.stringify({ project: project.value, kind: byId('kind').value, clientKey, result }) });
    await load();
  } catch (error) { notice(error.message, true); } finally { byId('save').disabled = !token; }
});
fetch('/projects.json').then(r => r.json()).then(items => {
  for (const name of items) { const option = document.createElement('option'); option.value = name; option.textContent = name; project.append(option); names.push(name); }
  const selected = new URLSearchParams(location.search).get('project'); if (names.includes(selected)) project.value = selected;
}).catch(() => notice('Project catalog unavailable.', true));
byId('copy-token').addEventListener('click', async () => {
  if (!token) return notice('Sign in first.', true);
  try { await navigator.clipboard.writeText(token); notice('Session token copied. Use it only in your own client.'); }
  catch { notice('Clipboard access unavailable.', true); }
});
