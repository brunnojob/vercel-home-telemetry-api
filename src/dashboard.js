const $ = (id) => document.getElementById(id);
let token = "";
const message = (text) => { $("message").textContent = text; };
const auth = () => ({ Authorization: `Bearer ${token}`, "Content-Type": "application/json" });

async function refresh() {
  if (!token) return;
  const response = await fetch("/api/operations", { headers: auth() });
  if (!response.ok) throw new Error(response.status === 401 ? "Token do operador inválido." : "Falha ao consultar operação.");
  const data = await response.json();
  $("telemetry").innerHTML = data.telemetry.map((x) => `<tr><td>${escapeHtml(x.device_id)}</td><td>${fmt(x.temperature_c)}</td><td>${fmt(x.humidity_pct)}</td><td>${fmt(x.soil_moisture)}</td><td>${new Date(x.event_at).toLocaleString()}</td></tr>`).join("") || "<tr><td colspan='5'>Sem leituras recebidas.</td></tr>";
  $("orders").innerHTML = data.workOrders.map((x) => `<div class="order"><div><strong>${escapeHtml(x.asset_tag)}</strong> · ${escapeHtml(x.title)}<br><small>${new Date(x.created_at).toLocaleString()}</small></div><div><span class="badge ${x.priority}">${x.priority}</span> <span class="badge">${x.status}</span> ${x.status !== "closed" ? `<button data-id="${x.id}" data-next="${x.status === "open" ? "acknowledged" : "closed"}">${x.status === "open" ? "Reconhecer" : "Concluir"}</button>` : ""}</div></div>`).join("") || "<p class='muted'>Nenhuma ordem de serviço.</p>";
  $("orders").querySelectorAll("button[data-id]").forEach((button) => button.addEventListener("click", () => transition(button.dataset.id, button.dataset.next)));
  $("connection").classList.add("online"); $("connectionText").textContent = "Conectado";
}
function fmt(v) { return v === null || v === undefined ? "—" : Number(v).toFixed(1); }
function escapeHtml(value) { const node = document.createElement("span"); node.textContent = String(value); return node.innerHTML; }

async function transition(id, status) {
  const response = await fetch("/api/operations", { method: "POST", headers: auth(), body: JSON.stringify({ action: "transition", id, status }) });
  if (!response.ok) { message("A ordem mudou em outra sessão. Atualize a tela."); return; }
  await refresh();
}
$("connect").addEventListener("click", async () => {
  token = $("token").value.trim();
  try { await refresh(); $("login").classList.add("hidden"); $("overview").classList.remove("hidden"); message(""); }
  catch (error) { token = ""; $("connectionText").textContent = "Desconectado"; message(error.message); }
});
$("refresh").addEventListener("click", () => refresh().catch((e) => message(e.message)));
$("workForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = new FormData(event.currentTarget);
  const response = await fetch("/api/operations", { method: "POST", headers: auth(), body: JSON.stringify({ assetTag: form.get("assetTag").toString().toUpperCase(), priority: form.get("priority"), title: form.get("title") }) });
  if (!response.ok) { message("Não foi possível criar a ordem."); return; }
  event.currentTarget.reset(); message("Ordem criada."); await refresh();
});
setInterval(() => refresh().catch((e) => { $("connection").classList.remove("online"); $("connectionText").textContent = "Sem conexão"; message(e.message); }), 15000);