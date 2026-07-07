#!/usr/bin/env bash
# Deploy the AGENT (ADK agent over AG-UI, FastAPI) to Cloud Run.
#
# LLM auth — choose with LLM_AUTH:
#   vertex  (default) Gemini via KEYLESS Vertex AI — no API key; uses the
#                     service account identity. Best for Gemini on GCP.
#   apikey            Any provider via an API key stored in Secret Manager:
#                     Anthropic / OpenAI, or a self-hosted OpenAI-compatible
#                     server (e.g. llama.cpp) reached over LLM_BASE_URL.
#
# Required:
#   MCP_SERVER_URL    MCP endpoint(s), comma-separated
# Optional (defaults shown):
#   PROJECT           GCP project id (defaults to `gcloud config get-value project`)
#   REGION=us-central1  REPO=pipeline-pulse  SERVICE=pp-agent   (REGION = Cloud Run region)
#   LLM_MODEL=gemini-2.5-flash   LLM_AUTH=vertex
#   VERTEX_LOCATION=global   Vertex model location (separate from REGION; newest models are global-only)
#   MEMORY=2Gi  CPU=1        (RAG's chroma-mcp embedding model needs >512Mi)
# if LLM_AUTH is in apikey mode:
#   API_KEY_ENV       env var the agent reads (ANTHROPIC_API_KEY | OPENAI_API_KEY | GOOGLE_API_KEY)
#   API_KEY_SECRET    Secret Manager secret holding the key (create it first, see below)
#   LLM_BASE_URL      (optional) OpenAI-compatible base URL for a self-hosted engine
#
# Create a secret once (apikey mode):
#   echo -n "sk-ant-..." | gcloud secrets create anthropic-key --data-file=- --project PROJECT
#
# Config file (recommended): copy deploy/agent.env.example -> deploy/agent.env
# (git-ignored), edit it, then just run:  ./deploy/deploy-agent.sh
#
# Or pass everything inline:
#   PROJECT=my-proj MCP_SERVER_URL=https://.../mcp ./deploy/deploy-agent.sh              # Gemini (Vertex)
#   PROJECT=my-proj MCP_SERVER_URL=https://.../mcp LLM_AUTH=apikey \
#     LLM_MODEL=anthropic/claude-opus-4-8 API_KEY_ENV=ANTHROPIC_API_KEY \
#     API_KEY_SECRET=anthropic-key ./deploy/deploy-agent.sh                              # API key
set -euo pipefail

# Load deploy/agent.env (git-ignored) if present — put your config there instead
# of passing it inline. Uncommented values win; comment a line to use the default.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"   # build paths are anchored here, so the script runs from anywhere
# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/agent.env" ]] && source "$SCRIPT_DIR/agent.env"

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
[[ -n "$PROJECT" ]] || { echo "No project: pass PROJECT=… or run 'gcloud config set project <id>'." >&2; exit 1; }
REGION="${REGION:-us-central1}"          # Cloud Run service region
REPO="${REPO:-pipeline-pulse}"
SERVICE="${SERVICE:-pp-agent}"
LLM_MODEL="${LLM_MODEL:-gemini-2.5-flash}"
LLM_AUTH="${LLM_AUTH:-vertex}"
# Vertex model location — SEPARATE from the Cloud Run REGION. `global` has the
# newest models and best availability (the latest ones are global-only).
VERTEX_LOCATION="${VERTEX_LOCATION:-global}"
MCP_SERVER_URL="${MCP_SERVER_URL:?set MCP_SERVER_URL}"
# The RAG subagent's chroma-mcp loads an embedding model (hundreds of MB), so the
# 512Mi default OOMs. 2Gi gives headroom; raise if you use larger embeddings.
MEMORY="${MEMORY:-2Gi}"
CPU="${CPU:-1}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/agent:latest"

# Fail fast on an incompatible combo. Keyless Vertex only works via the agent's
# native google-genai path, which needs a BARE Gemini model id (no provider
# prefix). A prefixed id (anthropic/… or even gemini/…, which routes through
# LiteLLM) or a non-Gemini name would fail at runtime — catch it before building.
if [[ "$LLM_AUTH" == "vertex" ]]; then
  shopt -s nocasematch
  if [[ "$LLM_MODEL" == */* || "$LLM_MODEL" != gemini* ]]; then
    echo "LLM_AUTH=vertex requires a bare Gemini model id (e.g. gemini-2.5-flash)." >&2
    echo "Got LLM_MODEL='$LLM_MODEL'. For non-Gemini or self-hosted models, use LLM_AUTH=apikey." >&2
    exit 1
  fi
  # Vertex uses versioned ids; the "-latest" aliases are Developer-API-only and 404 on Vertex.
  if [[ "$LLM_MODEL" == *latest* ]]; then
    echo "LLM_AUTH=vertex does not support '-latest' aliases (those are AI Studio / Developer API)." >&2
    echo "Use a versioned Vertex id, e.g. gemini-2.5-flash. Got LLM_MODEL='$LLM_MODEL'." >&2
    exit 1
  fi
  shopt -u nocasematch
fi

# Artifact Registry repo (create if missing).
gcloud artifacts repositories describe "$REPO" --location "$REGION" --project "$PROJECT" >/dev/null 2>&1 \
  || gcloud artifacts repositories create "$REPO" --repository-format=docker \
       --location "$REGION" --project "$PROJECT"

# Build & push the agent image (pipeline_pulse_agent/Dockerfile + context).
gcloud builds submit --project "$PROJECT" --tag "$IMAGE" "$REPO_ROOT/pipeline_pulse_agent"

# Join env vars with '|' — values like MCP_SERVER_URL (multi-endpoint) and
# CHROMA_KB_DESCRIPTION may contain commas. Passed with gcloud's ^|^ delimiter.
ENV_VARS="MCP_SERVER_URL=${MCP_SERVER_URL}|LLM_MODEL=${LLM_MODEL}"
DEPLOY_ARGS=()

case "$LLM_AUTH" in
  vertex)
    gcloud services enable aiplatform.googleapis.com --project "$PROJECT"
    ENV_VARS="${ENV_VARS}|GOOGLE_GENAI_USE_VERTEXAI=TRUE|GOOGLE_CLOUD_PROJECT=${PROJECT}|GOOGLE_CLOUD_LOCATION=${VERTEX_LOCATION}"
    # The runtime service account needs roles/aiplatform.user. We grant it to the
    # default compute SA here; for least privilege use a dedicated SA and pass
    # --service-account to `gcloud run deploy` below.
    PNUM="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
    gcloud projects add-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:${PNUM}-compute@developer.gserviceaccount.com" \
      --role="roles/aiplatform.user" --condition=None >/dev/null
    ;;
  apikey)
    : "${API_KEY_ENV:?set API_KEY_ENV (e.g. ANTHROPIC_API_KEY)}"
    : "${API_KEY_SECRET:?set API_KEY_SECRET (Secret Manager secret name)}"
    DEPLOY_ARGS+=(--set-secrets "${API_KEY_ENV}=${API_KEY_SECRET}:latest")
    [[ -n "${LLM_BASE_URL:-}" ]] && ENV_VARS="${ENV_VARS}|LLM_BASE_URL=${LLM_BASE_URL}"
    ;;
  *)
    echo "LLM_AUTH must be 'vertex' or 'apikey' (got '$LLM_AUTH')" >&2; exit 1 ;;
esac

# RAG subagent: pass the remote Chroma connection + KB description if configured.
if [[ -n "${CHROMA_HOST:-}" ]]; then
  ENV_VARS="${ENV_VARS}|CHROMA_HOST=${CHROMA_HOST}|CHROMA_PORT=${CHROMA_PORT:-8000}|CHROMA_SSL=${CHROMA_SSL:-false}|CHROMA_COLLECTION=${CHROMA_COLLECTION:-}"
  [[ -n "${CHROMA_KB_DESCRIPTION:-}" ]] && ENV_VARS="${ENV_VARS}|CHROMA_KB_DESCRIPTION=${CHROMA_KB_DESCRIPTION}"
fi

# --allow-unauthenticated keeps the demo simple. To lock it down: drop this flag,
# then grant the UI's service account roles/run.invoker on this service and have
# the UI attach an identity token to AGUI_BACKEND_URL requests.
gcloud run deploy "$SERVICE" \
  --project "$PROJECT" --region "$REGION" \
  --image "$IMAGE" \
  --set-env-vars "^|^${ENV_VARS}" \
  --memory "$MEMORY" \
  --cpu "$CPU" \
  --allow-unauthenticated \
  "${DEPLOY_ARGS[@]}"

echo
echo "Agent deployed. URL:"
gcloud run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" \
  --format='value(status.url)'
