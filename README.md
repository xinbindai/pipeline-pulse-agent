# Pipeline Pulse Agent

A **Google ADK** agent — with MCP tools and local tools, driven by any LLM
(hosted or self-hosted) — exposed over the **AG-UI protocol** and fronted by a
**CopilotKit** web chat UI. Runs locally with Docker Compose and deploys to
**Cloud Run** as two services.

The agent answers questions about ServiceNow-style incidents by calling an
external **MCP server** (e.g. a `search_incidents` tool) and a couple of local
tools, in an agentic loop.

## Architecture

```
Browser
  │
  ▼  CopilotKit chat                         ui/  (Next.js)
  ├─ POST /api/copilotkit ──▶ CopilotRuntime + HttpAgent
  │                                   │  AG-UI protocol (SSE), AGUI_BACKEND_URL
  ▼                                   ▼
  UI service (:3000)          Agent service (:8000)         pipeline_pulse_agent/
                              FastAPI + ag-ui-adk  ─────▶  server.py  (AG-UI backend)
                                                            agent.py   (root_agent)
                                                              ├─ MCP tools  ──▶ external MCP server
                                                              └─ get_current_time (local)
                                                                   │
                                                                   ▼  LLM
                                              hosted (Anthropic/OpenAI/Gemini) or self-hosted (llama.cpp…)
```

The browser only ever talks to the UI. The UI's server-side route proxies to the
agent over the AG-UI protocol; the agent runs the ADK loop and streams tool calls
and tokens back.

## Repository layout

| Path | What |
|---|---|
| [`pipeline_pulse_agent/`](pipeline_pulse_agent) | The agent service: ADK agent (`agent.py`) + its FastAPI/AG-UI backend (`server.py`), `Dockerfile`, `requirements.txt`. |
| [`ui/`](ui) | CopilotKit / Next.js frontend + its `Dockerfile`. |
| [`deploy/`](deploy) | Cloud Run deploy scripts (`deploy-agent.sh`, `deploy-ui.sh`) + per-script config templates. |
| [`docker-compose.yml`](docker-compose.yml) | Dev: build & run both services, wired together. |

Deeper docs: [`pipeline_pulse_agent/README.md`](pipeline_pulse_agent/README.md)
(agent) and [`ui/README.md`](ui/README.md) (UI + AG-UI integration).

## Quick start (Docker Compose)

**Prerequisites:** Docker + Docker Compose. An MCP server URL. An LLM — an API
key for a hosted provider, or a self-hosted OpenAI-compatible endpoint.

```bash
# 1. Configure the agent (MCP endpoint, model, key)
cp pipeline_pulse_agent/.env.example pipeline_pulse_agent/.env
#   edit: MCP_SERVER_URL, LLM_MODEL, and the matching API key (or LLM_BASE_URL)

# 2. Build & run both services
docker compose up --build
```

Open **http://localhost:3000** and chat (e.g. *"How many incidents are Open, and
what time is it?"*). Only the UI port is published; the agent stays internal to
the compose network and the UI reaches it at `http://agent:8000/`.

## Configuration

All agent config is environment variables (from `pipeline_pulse_agent/.env`
locally, or passed at runtime in Docker / Cloud Run — never baked into the image).

**MCP servers** — `MCP_SERVER_URL` accepts one or more endpoints, comma-separated;
the agent exposes the union of all their tools:

```
MCP_SERVER_URL=https://server-a/mcp,https://server-b/mcp
```

**LLM** — set `LLM_MODEL` (and, for self-hosted, `LLM_BASE_URL`):

| Goal | `LLM_MODEL` | Also set |
|---|---|---|
| Anthropic | `anthropic/claude-opus-4-8` | `ANTHROPIC_API_KEY` |
| OpenAI | `openai/gpt-4.1` | `OPENAI_API_KEY` |
| Gemini (API key) | `gemini-2.5-flash` | `GOOGLE_API_KEY` |
| Self-hosted (llama.cpp, vLLM, Ollama, …) | the served model name | `LLM_BASE_URL=http://host:8080/v1` |

For a self-hosted model running on your host machine, point the agent at
`http://host.docker.internal:8080/v1` (the compose file adds that mapping).

**RAG subagent (optional)** — set `CHROMA_HOST` (+ `CHROMA_PORT`, `CHROMA_SSL`,
`CHROMA_COLLECTION`) to add a `rag_agent` that answers from a remote Chroma vector
store via a stdio `chroma-mcp` server. See
[`pipeline_pulse_agent/README.md`](pipeline_pulse_agent/README.md#rag-subagent-remote-chroma)
(note: `chroma-mcp` must be installed isolated — it pins an older `mcp`).

## Running without Docker (optional)

**Agent** (Python 3.12, [`uv`](https://docs.astral.sh/uv/)):

```bash
uv venv && uv pip install -r pipeline_pulse_agent/requirements.txt
uv run uvicorn pipeline_pulse_agent.server:app --reload --port 8000   # AG-UI backend
# or drive the agent directly in a terminal:
uv run adk run pipeline_pulse_agent "How many incidents are Open?"
```

**UI** (Node 18+):

```bash
cd ui && npm install && npm run dev        # http://localhost:3000
```

## Deploy to Cloud Run (two services)

Each service deploys from its own config file (git-ignored), so the calls take no
arguments:

```bash
cp deploy/agent.env.example deploy/agent.env   # edit: MCP_SERVER_URL, LLM_AUTH, LLM_MODEL, …
cp deploy/ui.env.example    deploy/ui.env      # optional overrides

./deploy/deploy-agent.sh    # builds+pushes the agent image, deploys the agent service
./deploy/deploy-ui.sh       # deploys the UI, auto-pointing AGUI_BACKEND_URL at the agent
```

`PROJECT` defaults to your active `gcloud config` project.

**LLM auth for the agent** (`LLM_AUTH` in `deploy/agent.env`):

- **`vertex`** (default) — Gemini via **keyless Vertex AI**. No API key; the
  Cloud Run service account is used. `LLM_MODEL` must be a *versioned* Vertex id
  (e.g. `gemini-2.5-flash` / `gemini-3.5-flash`), not a `-latest` alias. The
  newest models are served on the `global` endpoint — set via `VERTEX_LOCATION`
  (default `global`), which is independent of the Cloud Run region.
- **`apikey`** — any provider (Anthropic / OpenAI / self-hosted via `LLM_BASE_URL`)
  with the key stored in **Secret Manager** (`--set-secrets`), not in plain env.

See [`deploy/agent.env.example`](deploy/agent.env.example) for all knobs, and
[`deploy/deploy-agent.sh`](deploy/deploy-agent.sh) for the fail-fast validation
and IAM notes.

> Both services deploy `--allow-unauthenticated` for simplicity. To lock the
> agent down, drop that flag and have the UI attach a Cloud Run identity token
> (see the note in `deploy-agent.sh`).
