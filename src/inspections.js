const defaultSchema = { id: "routine-check", name: "Ronda de equipamento", fields: [{ id: "seal", label: "Integridade do selo", type: "select", options: ["Conforme", "Desvio", "Não verificado"] }, { id: "vibration", label: "Vibração observada", type: "number", options: [] }, { id: "notes", label: "Observações", type: "textarea", options: [] }] };
function normalizeSchema(raw) {
  if (!raw || typeof raw !== "object" || !Array.isArray(raw.fields)) return defaultSchema;
  const fields = raw.fields.slice(0, 30).filter(f => f && typeof f === "object").map((f, i) => ({
    id: typeof f.id === "string" && /^[a-z0-9_-]{1,48}$/i.test(f.id) ? f.id : `field_${i}`,
    label: typeof f.label === "string" ? f.label.slice(0, 80) : `Campo ${i+1}`,
    type: ["text", "number", "textarea", "select"].includes(f.type) ? f.type : "text",
    options: Array.isArray(f.options) ? f.options.filter(x => typeof x === "string").slice(0, 20).map(x => x.slice(0, 80)) : []
  }));
  return { id: typeof raw.id === "string" && /^[a-z0-9_-]{1,48}$/i.test(raw.id) ? raw.id : "field-form", name: typeof raw.name === "string" ? raw.name.slice(0, 80) : "Inspeção", fields };
}
let schema;
try { schema = normalizeSchema(JSON.parse(localStorage.getItem("inspection-schema") || "null")); } catch { schema = defaultSchema; }
const $ = (id) => document.getElementById(id);
const dbName = "offshore-inspections";
const storeName = "queue";
let db;

function openDb() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(dbName, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(storeName, { keyPath: "recordId" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
function transaction(mode, work) {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(storeName, mode);
    const result = work(tx.objectStore(storeName));
    tx.oncomplete = () => resolve(result?.result);
    tx.onerror = () => reject(tx.error);
  });
}
function render() {
  $("formName").value = schema.name;
  $("fields").innerHTML = schema.fields.map((f, i) => `<div class="order"><label>Rótulo<input data-label="${i}" value="${esc(f.label)}"></label><label>Tipo<select data-type="${i}"><option ${f.type === "text" ? "selected" : ""}>text</option><option ${f.type === "number" ? "selected" : ""}>number</option><option ${f.type === "textarea" ? "selected" : ""}>textarea</option><option ${f.type === "select" ? "selected" : ""}>select</option></select></label><button type="button" data-remove="${i}" class="secondary">Remover</button></div>`).join("");
  $("inspection").innerHTML = schema.fields.map((f) => f.type === "textarea"
    ? `<label>${esc(f.label)}<textarea data-answer="${f.id}" rows="3"></textarea></label>`
    : f.type === "select" ? `<label>${esc(f.label)}<select data-answer="${f.id}">${f.options.map(o => `<option>${esc(o)}</option>`).join("")}</select></label>`
    : `<label>${esc(f.label)}<input data-answer="${f.id}" type="${f.type}" ${f.type === "number" ? "step='any'" : ""}></label>`).join("");
  $("fields").querySelectorAll("[data-label]").forEach(el => el.addEventListener("change", () => schema.fields[el.dataset.label].label = el.value));
  $("fields").querySelectorAll("[data-type]").forEach(el => el.addEventListener("change", () => { schema.fields[el.dataset.type].type = el.value; render(); }));
  $("fields").querySelectorAll("[data-remove]").forEach(el => el.addEventListener("click", () => { schema.fields.splice(Number(el.dataset.remove),1); render(); }));
  pending();
}
function esc(s) { const e=document.createElement("span"); e.textContent=String(s); return e.innerHTML; }
async function pending() { $("pending").textContent = String((await transaction("readonly", store => store.getAll()) || []).length); }
async function sync() {
  if (!navigator.onLine) { $("inspectionMessage").textContent="Sem conexão. Registros permanecem no dispositivo."; return; }
  const token=$("adminToken").value.trim();
  const records=await transaction("readonly",store=>store.getAll()) || [];
  for(const record of records) {
    const response=await fetch("/api/inspections",{method:"POST",headers:{"Authorization":`Bearer ${token}`,"Content-Type":"application/json"},body:JSON.stringify(record)});
    if(!response.ok) { $("inspectionMessage").textContent=`Sincronização parou em ${record.assetTag}: HTTP ${response.status}`; return; }
    await transaction("readwrite",store=>store.delete(record.recordId));
  }
  $("inspectionMessage").textContent=`Sincronizados: ${records.length}`; await pending();
}
$("builder").addEventListener("submit",event=>{event.preventDefault();schema.name=$("formName").value.trim();localStorage.setItem("inspection-schema",JSON.stringify(schema));render();});
$("addField").addEventListener("click",()=>{schema.fields.push({id:`field_${crypto.randomUUID().slice(0,8)}`,label:"Novo campo",type:"text",options:[]});render();});
$("exportForm").addEventListener("click",()=>{const file=new Blob([JSON.stringify(schema,null,2)],{type:"application/json"});const a=document.createElement("a");a.href=URL.createObjectURL(file);a.download=`${schema.id}.json`;a.click();URL.revokeObjectURL(a.href);});
$("importForm").addEventListener("change",async event=>{try{schema=normalizeSchema(JSON.parse(await event.target.files[0].text()));render();}catch{$("inspectionMessage").textContent="Configuração JSON inválida."; }});
$("queueRecord").addEventListener("click",async()=>{const answers={};document.querySelectorAll("[data-answer]").forEach(el=>answers[el.dataset.answer]=el.value);const record={recordId:crypto.randomUUID(),formId:schema.id,assetTag:$("assetTag").value.trim().toUpperCase(),answers,capturedAt:new Date().toISOString()};if(!record.assetTag){$("inspectionMessage").textContent="Informe a tag do ativo.";return;}await transaction("readwrite",store=>store.put(record));$("inspectionMessage").textContent="Inspeção gravada localmente.";await pending();});
$("sync").addEventListener("click",sync);window.addEventListener("online",()=>{$("network").classList.add("online");$("networkText").textContent="Conectado";});window.addEventListener("offline",()=>{$("network").classList.remove("online");$("networkText").textContent="Offline";});
db=await openDb();render();$("networkText").textContent=navigator.onLine?"Conectado":"Offline";if(navigator.onLine)$("network").classList.add("online");