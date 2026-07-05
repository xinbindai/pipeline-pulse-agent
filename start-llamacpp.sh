#!/usr/bin/env bash
# Start a llama.cpp server exposing an OpenAI-compatible API for the agent.
#
# Usage:
#   ./start-llamacpp.sh                        # uses the defaults below
#   LLAMA_BIN=/path/to/llama-server MODEL=/path/to/model.gguf PORT=8081 ./start-llamacpp.sh
#
# Then, in pipeline_pulse_agent/.env:
#   LLM_BASE_URL=http://127.0.0.1:8081/v1
#   LLM_MODEL=<the model filename shown at /v1/models, e.g. Qwen3-4B-Q4_K_M.gguf>
#
# --jinja is required so llama.cpp uses the model's chat template, which enables
# tool/function calling (the agent needs it to invoke MCP and local tools).
set -euo pipefail

LLAMA_BIN="${LLAMA_BIN:-~/project/llama.cpp/llama-b7622/llama-server}"
MODEL="${MODEL:-~/project/llama.cpp/models/Qwen3-4B-Q4_K_M.gguf}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8081}"
CTX="${CTX:-8192}"

exec "$LLAMA_BIN" -m "$MODEL" --host "$HOST" --port "$PORT" --jinja -c "$CTX"
