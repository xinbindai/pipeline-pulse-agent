# ui — CopilotKit + AG-UI interface

A web chat UI for the `pipeline_pulse_agent` ADK agent, using the **AG-UI
protocol** (event-based bridge) with a **CopilotKit** React frontend.

```
Browser ──▶ CopilotKit (Next.js, :3000)
                  │  /api/copilotkit  (CopilotRuntime + HttpAgent)
                  ▼
        AG-UI backend (FastAPI, :8000)   ← pipeline_pulse_agent/server.py
                  │  ag-ui-adk middleware
                  ▼
        ADK root_agent (pipeline_pulse_agent/agent.py)
             ├─ MCP tools (servicenow, calculate, …)
             └─ local get_current_time
```

The **agent service** lives in `pipeline_pulse_agent/` — the ADK agent
(`agent.py`) plus its FastAPI/AG-UI backend (`server.py`). This `ui/` folder is
the **frontend** (and these docs).

- **Backend** — `pipeline_pulse_agent/server.py` wraps `root_agent` with
  `ag-ui-adk` and serves the AG-UI protocol over Server-Sent Events.
- **Frontend** — this `ui/` folder is a Next.js CopilotKit app. Requires Node.js
  (not needed for the backend).

## 1. Run the backend (Python)

```bash
# from the repo root, in the project venv
uvicorn pipeline_pulse_agent.server:app --reload --port 8000
```

- `GET  /health` → `{"status":"ok","agent":"pipeline_pulse_agent"}`
- `POST /`       → AG-UI SSE event stream (what the frontend talks to)

The agent's LLM/MCP config comes from `pipeline_pulse_agent/.env`
(same file used by `adk run`), so a working `LLM_MODEL` + key (or `LLM_BASE_URL`
for a self-hosted model) is required.

### Quick check without the frontend

```bash
curl -N -X POST http://localhost:8000/ \
  -H "Content-Type: application/json" \
  -d '{"thread_id":"t1","run_id":"r1","state":{},
       "messages":[{"id":"m1","role":"user","content":"How many incidents are Open?"}],
       "tools":[],"context":[],"forwarded_props":{}}'
```

You'll see AG-UI events stream back: `RUN_STARTED`, `TOOL_CALL_*`,
`TEXT_MESSAGE_*`, `RUN_FINISHED`.

## 2. Run the frontend (Node.js required)

```bash
cd ui
npm install
cp .env.local.example .env.local     # optional; defaults to http://localhost:8000/
npm run dev                          # http://localhost:3000
```

Open http://localhost:3000 and chat — CopilotKit proxies through
`/api/copilotkit` to the AG-UI backend, which runs the ADK agent and streams
tool calls + responses back into the chat.

### Key files

| File | Role |
|---|---|
| `app/api/copilotkit/route.ts` | `CopilotRuntime` + `HttpAgent` → backend at `AGUI_BACKEND_URL` (default `:8000`). Agent key `pipeline_pulse`. |
| `app/page.tsx` | `<CopilotKit runtimeUrl="/api/copilotkit" agent="pipeline_pulse">` + `<CopilotChat>`. |

The agent key (`pipeline_pulse`) must match in both files.

## Docker — two images (agent + UI)

The agent and the UI are **separate images**:

| Image | Dockerfile | Context | Contains |
|---|---|---|---|
| `pp-agent` | [`pipeline_pulse_agent/Dockerfile`](../pipeline_pulse_agent/Dockerfile) | `pipeline_pulse_agent` | ADK agent + AG-UI backend (uvicorn) |
| `pp-ui` | [`Dockerfile`](Dockerfile) | `ui` | CopilotKit / Next.js UI |

Each listens on `$PORT` (Cloud Run injects it; defaults: agent 8000, UI 3000).
The UI reaches the agent, server-side, at `AGUI_BACKEND_URL`.

### Dev — docker compose

```bash
docker compose up --build          # UI -> http://localhost:3000
```

Only the UI port is published; the agent stays internal to the compose network
(the UI reaches it at `http://agent:8000/`). LLM config comes from
`pipeline_pulse_agent/.env` (passed to the agent as `env_file`, **not** baked in):

- hosted:      `LLM_MODEL=anthropic/claude-opus-4-8` + `ANTHROPIC_API_KEY=…`
               (or `gemini-flash-latest` + `GOOGLE_API_KEY=…`)
- self-hosted: `LLM_BASE_URL=http://host.docker.internal:8080/v1` + `LLM_MODEL=<served>`
  (the compose file adds the `host.docker.internal` mapping so the agent
  container can reach a llama.cpp server on the host)

### Deploy — two Cloud Run services

Two scripts in [`deploy/`](../deploy) build+push each image and deploy a service.
Put config in a per-script env file (git-ignored) so the calls take no args:

```bash
cp deploy/agent.env.example deploy/agent.env   # edit: MCP_SERVER_URL, LLM_AUTH, LLM_MODEL, …
cp deploy/ui.env.example    deploy/ui.env      # edit: (optional) PROJECT, AGENT_SERVICE, …

./deploy/deploy-agent.sh    # agent  — keyless Vertex (Gemini) or API key (any provider)
./deploy/deploy-ui.sh       # UI     — auto-discovers the agent URL, sets AGUI_BACKEND_URL
```

- `agent.env` chooses the LLM: `LLM_AUTH=vertex` (keyless Gemini) or `apikey`
  (Anthropic/OpenAI/self-hosted via a Secret Manager key).
- In the env file, **uncommented values take effect**; leave a line commented to
  fall back to an inline override (e.g. `PROJECT=staging ./deploy/deploy-agent.sh`)
  or the default. `PROJECT` defaults to `gcloud config get-value project`.

- **`LLM_AUTH=vertex`** (default): Gemini with no API key — the agent uses the
  Cloud Run service account (`GOOGLE_GENAI_USE_VERTEXAI=TRUE`); the script grants
  `roles/aiplatform.user`.
- **`LLM_AUTH=apikey`**: the key is read from Secret Manager (`--set-secrets`) and
  never placed in env config. Works for Anthropic/OpenAI and self-hosted
  (`LLM_BASE_URL`) engines.

Both services deploy `--allow-unauthenticated` for simplicity; see the comment in
`deploy-agent.sh` for locking the agent down with IAM + an identity token.

## Notes

- Frontend deps are pinned to a verified-compatible set: `@copilotkit/* @ 1.62.2`
  with `@ag-ui/client @ 0.0.57` (the version the runtime expects — an older
  `@ag-ui/client` breaks the build with a missing `Middleware` export).
  `npm install && npm run build` succeeds on Node 18.
- Node 18 emits `EBADENGINE` warnings for a couple of transitive deps that
  prefer Node ≥20; the build and dev server still work. Use Node 20+ to silence.
- CORS on the backend is open (`allow_origins=["*"]`) for local dev — tighten it
  for production.
