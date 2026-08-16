#!/usr/bin/env python3
import os
import subprocess
import sys

APP_DIR = "/opt/nexus"
PORT = 8000

def write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)

write(f"{APP_DIR}/requirements.txt", """fastapi==0.115.0
uvicorn[standard]==0.30.0
pydantic==2.9.0
httpx==0.28.1
websockets==13.1
""")

write(f"{APP_DIR}/src/models.py", """from __future__ import annotations
from typing import Any
from pydantic import BaseModel

class TaskStatus(str):
    pending = "pending"
    done = "done"
    failed = "failed"

class Subtask(BaseModel):
    id: str
    goal_id: str
    title: str
    status: str = TaskStatus.pending
    depends_on: list[str] = []
    result: str | None = None

class Goal(BaseModel):
    id: str
    title: str
    description: str
    success_criteria: list[str] = []
    deadline: str | None = None
    created_at: str | None = None
    status: str = TaskStatus.pending
""")

write(f"{APP_DIR}/src/world_model.py", """from __future__ import annotations
from typing import Any
from pydantic import BaseModel

class Device(BaseModel):
    id: str
    name: str
    type: str = "unknown"
    platform: str = "unknown"
    last_seen: str | None = None
    status: str = "offline"
    capabilities: list[str] = []

class WorldStore:
    def __init__(self) -> None:
        self.devices: dict[str, Device] = {}

    def snapshot(self) -> list[dict[str, Any]]:
        return [d.model_dump() for d in self.devices.values()]
""")

write(f"{APP_DIR}/src/sync.py", """from __future__ import annotations
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

@dataclass
class SyncOp:
    op_id: str
    op_type: str
    entity: str
    key: str
    value: Any
    source_device: str
    timestamp: str = field(default_factory=lambda: datetime.utcnow().isoformat())

class SyncState:
    def __init__(self) -> None:
        self.devices: dict[str, dict[str, Any]] = {}
        self.ops: list[SyncOp] = []

    def enqueue(self, op: SyncOp) -> None:
        self.ops.append(op)

    def pending_for(self, device_id: str) -> list[dict[str, Any]]:
        return [op.__dict__ for op in self.ops]
""")

write(f"{APP_DIR}/src/llm_backend.py", """from __future__ import annotations
import os
import httpx

SYSTEM_PROMPT = "Du bist Nexus, ein proaktiver Heimnetz-Assistent."

class LLMBackend:
    def __init__(self) -> None:
        self.enabled = False
        self.model = "gpt-4o-mini"
        self.api_key = os.getenv("LLM_API_KEY")
        self.base_url = os.getenv("LLM_BASE_URL", "https://api.openai.com/v1")

    async def complete(self, system: str, user: str) -> str:
        if not self.api_key:
            return "Ich habe das als Ziel erkannt. Aktuell laufe ich im Regel-Fallback."
        try:
            async with httpx.AsyncClient(timeout=30) as client:
                r = await client.post(
                    f"{self.base_url}/chat/completions",
                    headers={"Authorization": f"Bearer {self.api_key}"},
                    json={
                        "model": os.getenv("LLM_MODEL", self.model),
                        "messages": [
                            {"role": "system", "content": system},
                            {"role": "user", "content": user},
                        ],
                        "stream": False,
                    },
                )
                r.raise_for_status()
                data = r.json()
                return data["choices"][0]["message"]["content"]
        except Exception as exc:
            return f"LLM-Fehler: {exc}"
""")

write(f"{APP_DIR}/src/planner.py", """from __future__ import annotations
import uuid
from models import Goal, Subtask, TaskStatus

class GoalPlanner:
    def __init__(self, llm) -> None:
        self.llm = llm

    async def plan_goal(self, text: str) -> tuple[Goal, list[Subtask]]:
        goal = Goal(
            id=uuid.uuid4().hex[:8],
            title="User Goal",
            description=text,
            success_criteria=[text],
        )
        subs = [
            Subtask(id=uuid.uuid4().hex[:8], goal_id=goal.id, title="Kontext aufnehmen", depends_on=[]),
            Subtask(id=uuid.uuid4().hex[:8], goal_id=goal.id, title="Plan ausfuehren", depends_on=[subs[0].id]),
        ]
        return goal, subs
""")

write(f"{APP_DIR}/src/agent_core.py", """from __future__ import annotations
from typing import Any, TYPE_CHECKING
from pydantic import BaseModel

if TYPE_CHECKING:
    from planner import GoalPlanner

class AgentState(BaseModel):
    last_goal_id: str | None = None

class ProactiveAgent:
    def __init__(self, planner: "GoalPlanner | None" = None) -> None:
        self.planner = planner
        self.goals: dict[str, Any] = {}
        self.subtasks: dict[str, Any] = {}
        self.state = AgentState()

    def ingest_user_message(self, message: str) -> None:
        self.state.last_goal_id = list(self.goals.keys())[-1] if self.goals else None

    async def plan_goal(self, text: str):
        if self.planner:
            return await self.planner.plan_goal(text)
        raise RuntimeError("Planner nicht initialisiert")

    def tick(self) -> str | None:
        gid = self.state.last_goal_id
        if not gid:
            return None
        goal = self.goals.get(gid)
        if not goal or goal.get("status") == "done":
            return None
        for sub in self.subtasks.values():
            if sub.get("goal_id") == gid and sub.get("status") == "pending":
                deps = sub.get("depends_on", [])
                if all(self.subtasks.get(dep, {}).get("status") == "done" for dep in deps):
                sub["status"] = "done"
                    sub["result"] = f"Subtask \"{sub['title']}\" ausgefuehrt."
                    return f"Subtask \"{sub['title']}\" abgeschlossen."
        goal["status"] = "done"
        return f"Goal \"{goal.get('title', 'Goal')}\" abgeschlossen."
""")

write(f"{APP_DIR}/src/cron.py", """from __future__ import annotations
import asyncio
from dataclasses import dataclass
from typing import Any, Awaitable, Callable

@dataclass
class CronJob:
    name: str
    interval_seconds: int
    task: Callable[[], Any | Awaitable[Any]]

class Scheduler:
    def __init__(self) -> None:
        self.jobs: list[CronJob] = []
        self._running = False

    def add(self, job: CronJob) -> None:
        self.jobs.append(job)

    async def start(self) -> None:
        self._running = True
        while self._running:
            for job in self.jobs:
                result = job.task()
                if asyncio.iscoroutine(result):
                    await result
            await asyncio.sleep(min(j.interval_seconds for j in self.jobs))
""")

write(f"{APP_DIR}/src/persistence.py", """from __future__ import annotations
import json
from pathlib import Path

class Persistence:
    def __init__(self, base: Path) -> None:
        self.base = base
        self.base.mkdir(parents=True, exist_ok=True)

    def load(self, name: str) -> dict:
        p = self.base / f"{name}.json"
        if not p.exists():
            return {}
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}

    def save(self, name: str, data: dict) -> None:
        tmp = self.base / f"{name}.tmp"
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(self.base / f"{name}.json")
""")

write(f"{APP_DIR}/src/web_client.py", """from pathlib import Path
from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

CLIENT_DIR = Path("/opt/nexus/clients/web")

def mount_client(app: FastAPI) -> None:
    if CLIENT_DIR.exists():
        app.mount("/client", StaticFiles(directory=str(CLIENT_DIR), html=True), name="client")
        @app.get("/")
        def root() -> FileResponse:
            return FileResponse(str(CLIENT_DIR / "index.html"))
""")

write(f"{APP_DIR}/agent_server.py", """from __future__ import annotations
import uuid
from datetime import datetime
from typing import Any
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from agent_core import ProactiveAgent
from world_model import WorldStore, Device
from sync import SyncState, SyncOp
from llm_backend import LLMBackend, SYSTEM_PROMPT
from models import Goal, Subtask, TaskStatus
from planner import GoalPlanner
from cron import CronJob, Scheduler
from web_client import mount_client
import asyncio
import json
from pathlib import Path

class ChatIn(BaseModel):
    message: str
    device_id: str | None = None

class DeviceIn(BaseModel):
    device_id: str
    name: str
    type: str = "unknown"
    capabilities: list[str] = []

app = FastAPI(title="Nexus Goal Agent")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
mount_client(app)

llm = LLMBackend()
planner = GoalPlanner(llm)
agent = ProactiveAgent(planner=planner)
world = WorldStore()
sync_state = SyncState()
scheduler = Scheduler()
STORE_PATH = Path("/opt/nexus/data")
from persistence import Persistence
persistence = Persistence(STORE_PATH)

def _load(name: str) -> dict:
    return persistence.load(name)

def _save(name: str, data: dict) -> None:
    persistence.save(name, data)

def _persist_goals() -> None:
    _save("goals", {"goals": agent.goals, "subtasks": agent.subtasks})

def _persist_devices() -> None:
_save("devices", {k: v.model_dump() for k, v in world.devices.items()})

scheduler.add(CronJob(name="goal_tick", interval_seconds=60, task=agent.tick))

@app.on_event("startup")
async def startup() -> None:
    agent.goals = _load("goals").get("goals", {})
    agent.subtasks = _load("goals").get("subtasks", {})
    for k, v in _load("devices").items():
        try:
            world.devices[k] = Device(**v)
        except Exception:
            pass
    asyncio.create_task(scheduler.start())

@app.get("/health")
def health() -> dict:
    return {"status": "ok", "llm_enabled": str(llm.enabled), "model": llm.model}

@app.post("/device")
def register_device(device: DeviceIn) -> dict:
    d = Device(
        id=device.device_id,
        name=device.name,
        type=device.type,
        capabilities=device.capabilities,
    )
    world.devices[device.device_id] = d
    sync_state.enqueue(SyncOp(op_id=uuid.uuid4().hex, op_type="device_registered", entity="device", key=device.device_id, value=d.model_dump(), source_device=device.device_id))
    _persist_devices()
    return {"ok": True}

@app.get("/devices")
def list_devices() -> dict:
    return {"devices": [d.model_dump() for d in world.devices.values()]}

@app.post("/chat")
async def chat_http(payload: ChatIn) -> dict:
    user_message = payload.message
    agent_reply = await llm.complete(SYSTEM_PROMPT, user_message)
    message_lower = user_message.lower()
    agent_tick = None
    if any(k in message_lower for k in ["aufgabe", "todo", "task", "goal", "plane", "organisiere"]):
        goal, subs = await agent.plan_goal(user_message)
        agent.goals[goal.id] = goal.model_dump()
        for sub in subs:
            agent.subtasks[sub.id] = sub.model_dump()
        agent.state.last_goal_id = goal.id
        _persist_goals()
    agent.ingest_user_message(user_message)
    agent_tick = agent.tick()
    _persist_goals()
    sync_state.enqueue(SyncOp(op_id=uuid.uuid4().hex, op_type="chat", entity="conversation", key=datetime.utcnow().isoformat(), value={"message": user_message, "reply": agent_reply}, source_device=payload.device_id or "unknown"))
    return {"reply": agent_reply, "agent_tick": agent_tick, "world_snapshot": world.snapshot()}

@app.get("/goals")
def list_goals() -> dict:
    return {"goals": list(agent.goals.values()), "subtasks": list(agent.subtasks.values())}

@app.get("/sync/{device_id}")
def sync_pull(device_id: str) -> dict:
    return {"ops": sync_state.pending_for(device_id)}

@app.get("/tick")
def tick() -> dict:
    result = agent.tick()
    _persist_goals()
    return {"tick_result": result}

@app.websocket("/ws/chat")
async def chat_ws(ws: WebSocket) -> None:
    await ws.accept()
    try:
        while True:
            data = await ws.receive_json()
            text = data.get("message", "")
            device = data.get("device_id")
            reply = await llm.complete(SYSTEM_PROMPT, text)
            agent.ingest_user_message(text)
            agent_tick = agent.tick()
            _persist_goals()
            sync_state.enqueue(SyncOp(op_id=uuid.uuid4().hex, op_type="chat", entity="conversation", key=datetime.utcnow().isoformat(), value={"message": text, "reply": reply}, source_device=device or "unknown"))
            await ws.send_json({"reply": reply, "agent_tick": agent_tick})
    except WebSocketDisconnect:
        pass

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("agent_server:app", host="0.0.0.0", port=8000, reload=False)
""")

write(f"{APP_DIR}/clients/web/index.html", """<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Nexus</title>
<style>
  body { font-family: system-ui, sans-serif; background:#0f1115; color:#e6e8eb; margin:0; }
  #wrap { max-width: 860px; margin: 0 auto; padding: 24px; }
  #log { border: 1px solid #23272f; border-radius: 12px; padding: 16px; min-height: 260px; }
  .row { margin: 10px 0; padding: 8px 10px; border-radius: 10px; }
  .user { background:#1b2330; }
  .agent { background:#18211a; }
  .meta { font-size: 12px; opacity: 0.7; margin-top: 4px; }
  #tray { display:flex; gap:8px; margin-top:12px; }
  input[type=text] { flex:1; padding:12px; border-radius:10px; border:1px solid #2a2f38; background:#0f1115; color:#e6e8eb; }
  button { padding:12px 14px; border-radius:10px; border:0; background:#3b82f6; color:white; cursor:pointer; }
  #panels { display:grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; margin-top: 18px; }
  .panel { background:#11141a; border:1px solid #23272f; border-radius:12px; padding:12px; }
  .panel h3 { margin: 0 0 8px; font-size: 14px; opacity: 0.8; }
  .pill { display:inline-block; padding:4px 8px; border-radius:999px; background:#1f2937; font-size:12px; margin:2px; }
</style>
</head>
<body>
<div id="wrap">
  <h1>Nexus</h1>
  <div id="log"></div>
  <div id="tray">
    <input id="msg" type="text" placeholder="Sag etwas…" />
    <button id="send">Senden</button>
  </div>
  <div id="panels">
    <div class="panel"><h3>Geräte</h3><div id="devices">–</div></div>
    <div class="panel"><h3>Goals</h3><div id="goals">–</div></div>
    <div class="panel"><h3>Sync</h3><div id="sync">–</div></div>
  </div>
</div>
<script>
const API = window.location.origin;
const DEVICE = "web-" + Math.random().toString(36).slice(2,8);
const log = document.getElementById("log");
const devices = document.getElementById("devices");
const goals = document.getElementById("goals");
const sync = document.getElementById("sync");

function esc(s){ return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }

function add(role, text, meta){
  const row = document.createElement("div");
  row.className = "row " + role;
row.innerHTML = `<div>${esc(text)}</div><div class="meta">${esc(meta||"")}</div>`;
  log.appendChild(row);
  log.scrollTop = log.scrollHeight;
}

async function post(path, body){
  const r = await fetch(API + path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  if(!r.ok) throw new Error("HTTP " + r.status);
  return r.json();
}

async function get(path){
  const r = await fetch(API + path);
  if(!r.ok) throw new Error("HTTP " + r.status);
  return r.json();
}

async function refresh(){
  try {
    const d = await get("/devices");
    devices.innerHTML = d.devices.map(x => `<span class="pill">${esc(x.name)} (${esc(x.type)})</span>`).join("") || "–";
    const g = await get("/goals");
    if (g.goals && g.goals.length) {
      goals.innerHTML = g.goals.map(x => `<div class="pill">${esc(x.title)}: ${esc(x.status)}</div>`).join("") + (g.subtasks?.length ? `<div>${g.subtasks.map(s => `<div class="pill">↳ ${esc(s.title)} ${esc(s.status)}</div>`).join("")}</div>` : "");
    } else goals.innerHTML = "–";
    const s = await get("/sync/" + DEVICE);
    sync.innerHTML = (s.ops && s.ops.length) ? s.ops.map(o => `<div class="pill">${esc(o.op_type)}</div>`).join("") : "Keine offenen Ops";
  } catch(e){}
}

async function send(){
  const input = document.getElementById("msg");
  const text = input.value.trim();
  if(!text) return;
  input.value = "";
  add("user", text, new Date().toLocaleTimeString());
  try {
    const data = await post("/chat", { message: text, device_id: DEVICE });
    add("agent", data.reply, new Date().toLocaleTimeString());
    if(data.agent_tick) add("agent", "Tick: " + data.agent_tick);
    await refresh();
  } catch(e){
    add("agent", "Fehler: " + e.message);
  }
}

document.getElementById("send").addEventListener("click", send);
document.getElementById("msg").addEventListener("keydown", e => { if(e.key==="Enter") send(); });

(async ()=>{
await post("/device", { device_id: DEVICE, name: "Web-Client", type: "web", capabilities: ["browser"] });
  add("agent", "Willkommen bei Nexus. Ich bin dein proaktiver Agent.", new Date().toLocaleTimeString());
  await refresh();
  setInterval(refresh, 5000);
})();
</script>
</body>
</html>
""")

print("✅ Dateien erstellt")
print(f"📁 App-Verzeichnis: {APP_DIR}")
print(f"🌐 Port: {PORT}")

print("\n🐍 Erstelle Virtual Environment...")
os.makedirs(f"{APP_DIR}/.venv", exist_ok=True)
subprocess.run([sys.executable, "-m", "venv", f"{APP_DIR}/.venv"], check=True)

print("📥 Installiere Dependencies...")
subprocess.run([f"{APP_DIR}/.venv/bin/pip", "install", "--quiet", "--upgrade", "pip"], check=True)
subprocess.run([f"{APP_DIR}/.venv/bin/pip", "install", "--quiet", "-r", f"{APP_DIR}/requirements.txt"], check=True)

print("⚙️  Erstelle systemd-Service...")
service_content = f"""[Unit]
Description=Nexus Goal Agent
After=network.target

[Service]
Type=simple
WorkingDirectory={APP_DIR}
Environment="PATH={APP_DIR}/.venv/bin"
Environment="LLM_MODEL=gpt-4o-mini"
ExecStart={APP_DIR}/.venv/bin/uvicorn agent_server:app --host 0.0.0.0 --port {PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"""
with open("/etc/systemd/system/nexus.service", "w", encoding="utf-8", newline="\n") as f:
    f.write(service_content)

print("🔄 Lade systemd neu und starte Nexus...")
subprocess.run(["systemctl", "daemon-reload"], check=True)
subprocess.run(["systemctl", "enable", "--now", "nexus"], check=True)

print(f"\n✅ Nexus deployed!")
print(f"🌐 Web-Client: http://$(hostname -I | awk '{{print $1}}'):{PORT}/")
print(f"💡 Health-Check: http://localhost:{PORT}/health")
