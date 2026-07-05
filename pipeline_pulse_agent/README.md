# pipeline_pulse_agent

A Google ADK agent that combines **multiple MCP servers** and **local tools**,
driven by any LLM — hosted (Anthropic / OpenAI / Gemini) or **self-hosted**
(llama.cpp, vLLM, Ollama, LM Studio).

```
pipeline_pulse_agent/          <- the agent package (importable name)
  agent.py                     <- defines root_agent, tools, model selection
  __init__.py
  .env                         <- your config (copy from .env.example)
  .env.example
```

The package lives at the repo root, so the repo root is the ADK AGENTS_DIR:
run a single agent with `adk run pipeline_pulse_agent`, or browse all agents in
the repo with `adk web .`.

## Setup

```bash
cp pipeline_pulse_agent/.env.example pipeline_pulse_agent/.env
# edit .env: set MCP_SERVER_URL, LLM_MODEL, and the matching API key
```

## Run

From the repo root:

```bash
# one-shot
adk run pipeline_pulse_agent "How many incidents are Open, and what time is it?"

# interactive REPL
adk run pipeline_pulse_agent

# browser UI (choose pipeline_pulse_agent in the dropdown)
adk web .
```

## Configuration (env / `.env`)

| Variable | Purpose |
|---|---|
| `MCP_SERVER_URL` | One or more MCP endpoints, **comma-separated**. The agent exposes the union of all their tools. |
| `LLM_MODEL` | `anthropic/claude-opus-4-8` (default), `openai/gpt-4.1`, `gemini-flash-latest`, or a self-hosted model name. |
| `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GOOGLE_API_KEY` | Key matching the chosen model. |
| `LLM_BASE_URL` | Optional. OpenAI-compatible endpoint of a self-hosted engine; when set, no real API key is required. |

### Self-hosted example (llama.cpp) — verified

Run the agent entirely on a local model, no cloud key required.

**1. Start the llama.cpp server** (serves an OpenAI-compatible API). A helper is
included; `--jinja` is required so the model can do tool/function calling:

```bash
# from the repo root
./start-llamacpp.sh
# -> http://127.0.0.1:8081/v1  (serving Qwen3-4B-Q4_K_M.gguf)

# equivalent raw command:
# llama-server -m models/Qwen3-4B-Q4_K_M.gguf --host 127.0.0.1 --port 8081 --jinja -c 8192
```

**2. Point the agent at it** — copy the ready-made env file:

```bash
cp pipeline_pulse_agent/.env.llamacpp.example pipeline_pulse_agent/.env
```

```ini
MCP_SERVER_URL=https://your-mcp-server/mcp
LLM_BASE_URL=http://127.0.0.1:8081/v1
LLM_MODEL=Qwen3-4B-Q4_K_M.gguf     # must match the id at GET /v1/models
```

**3. Run:**

```bash
adk run pipeline_pulse_agent "How many incidents are Open, and what time is it?"
```

The local Qwen3-4B model calls both the MCP `servicenow` tool (→ 5 open
incidents) and the local `get_current_time` tool, then answers — all offline
from any hosted LLM provider. (`LLM_MODEL` must equal the id llama.cpp reports at
`/v1/models`; for llama.cpp that's the `.gguf` filename.)

## Tools

- **MCP tools** — every tool exposed by each server in `MCP_SERVER_URL`.
- **`get_current_time`** — a local Python function tool returning the current
  date/time. Add more local tools by defining a typed, docstring'd function in
  `agent.py` and appending it to `root_agent`'s `tools` list.
