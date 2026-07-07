# Pipeline Pulse Agent (Chainlit)

A **Google ADK** agent — MCP tools + a local tool, driven by any LLM (hosted or
self-hosted) — with a **Chainlit** chat UI that runs the agent **in-process**.
No separate backend or protocol layer: **one container, one Cloud Run service**.

```
Browser ──▶ Chainlit (app.py)
                 │  ADK Runner (in-process)
                 ▼
            root_agent  (pipeline_pulse_agent/agent.py)
              ├─ MCP tools   ──▶ external MCP server
              └─ get_current_time (local)
                   │
                   ▼  LLM: hosted (Anthropic/OpenAI/Gemini) or self-hosted (llama.cpp…)
```

## Layout

| Path | What |
|---|---|
| [`app.py`](app.py) | Chainlit app — drives the ADK agent via `Runner`, streams text + tool steps. |
| [`pipeline_pulse_agent/`](pipeline_pulse_agent) | The ADK agent (`agent.py` builds `root_agent`: MCP toolsets, local tool, model selection). |
| [`Dockerfile`](Dockerfile) | The single image. |
| [`deploy/deploy.sh`](deploy/deploy.sh) | Deploy the one Cloud Run service. |

## Run locally

**Docker:**

```bash
cp pipeline_pulse_agent/.env.example pipeline_pulse_agent/.env   # set MCP_SERVER_URL, LLM_MODEL, key
docker build -t pp-chainlit .
docker run --rm -p 8000:8000 --env-file pipeline_pulse_agent/.env pp-chainlit
# open http://localhost:8000
```

**Without Docker** (Python 3.12):

```bash
uv venv && uv pip install -r requirements.txt
uv run chainlit run app.py -w         # http://localhost:8000
```

## Configuration

Environment variables (from `pipeline_pulse_agent/.env` locally, or passed at
runtime; never baked into the image):

- **`MCP_SERVER_URL`** — one or more MCP endpoints, comma-separated (union of tools).
- **LLM** — set `LLM_MODEL` (+ key), or `LLM_BASE_URL` for a self-hosted engine:

  | Goal | `LLM_MODEL` | Also set |
  |---|---|---|
  | Anthropic | `anthropic/claude-opus-4-8` | `ANTHROPIC_API_KEY` |
  | OpenAI | `openai/gpt-4.1` | `OPENAI_API_KEY` |
  | Gemini (API key) | `gemini-2.5-flash` | `GOOGLE_API_KEY` |
  | Self-hosted (llama.cpp, vLLM, …) | the served model name | `LLM_BASE_URL=http://host:8080/v1` |

- **RAG subagent (optional)** — set `CHROMA_HOST` (+ `CHROMA_PORT`, `CHROMA_SSL`,
  `CHROMA_COLLECTION`, `CHROMA_KB_DESCRIPTION`) to add a `rag_agent` that answers
  from a remote Chroma vector store via a stdio `chroma-mcp` server. `chroma-mcp`
  is installed isolated (it pins an older `mcp`); the Dockerfile handles that.

See [`pipeline_pulse_agent/README.md`](pipeline_pulse_agent/README.md) for agent
details (incl. running the agent standalone with `adk run`, and the llama.cpp setup).

## Deploy (one Cloud Run service)

```bash
cp deploy/agent.env.example deploy/agent.env   # edit: MCP_SERVER_URL, LLM_AUTH, LLM_MODEL, …
./deploy/deploy.sh
```

`PROJECT` defaults to your active `gcloud config`. LLM auth (`LLM_AUTH` in
`deploy/agent.env`):

- **`vertex`** (default) — Gemini via **keyless Vertex AI** (no key; the service
  account is used). `LLM_MODEL` must be a versioned Vertex id (e.g.
  `gemini-2.5-flash`), not a `-latest` alias; newest models are `global`-only
  (`VERTEX_LOCATION`, default `global`, independent of the Cloud Run region).
- **`apikey`** — any provider (incl. self-hosted via `LLM_BASE_URL`) with the key
  in **Secret Manager**.

The service deploys `--allow-unauthenticated --session-affinity` (Chainlit uses
WebSockets, so affinity keeps a browser pinned to one instance).
