#!/usr/bin/env bash
# Deploy the Chainlit + ADK agent as a single Cloud Run service.
#
# LLM auth — choose with LLM_AUTH:
#   vertex  (default) Gemini via KEYLESS Vertex AI (no API key; service account).
#   apikey            Any provider via an API key in Secret Manager
#                     (Anthropic / OpenAI, or self-hosted via LLM_BASE_URL).
#
# Config: copy deploy/agent.env.example -> deploy/agent.env (git-ignored), edit,
# then run:  ./deploy/deploy.sh
#
# Required:  MCP_SERVER_URL
# Optional (defaults shown):
#   PROJECT (gcloud config)  REGION=us-central1  REPO=pipeline-pulse  SERVICE=pp-chainlit
#   LLM_MODEL=gemini-2.5-flash  LLM_AUTH=vertex  VERTEX_LOCATION=global
# apikey mode:  API_KEY_ENV  API_KEY_SECRET  [LLM_BASE_URL]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"   # build context; runs from anywhere
# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/agent.env" ]] && source "$SCRIPT_DIR/agent.env"

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
[[ -n "$PROJECT" ]] || { echo "No project: pass PROJECT=… or run 'gcloud config set project <id>'." >&2; exit 1; }
REGION="${REGION:-us-central1}"
REPO="${REPO:-pipeline-pulse}"
SERVICE="${SERVICE:-pp-chainlit}"
LLM_MODEL="${LLM_MODEL:-gemini-2.5-flash}"
LLM_AUTH="${LLM_AUTH:-vertex}"
VERTEX_LOCATION="${VERTEX_LOCATION:-global}"   # Vertex model location, separate from REGION
MCP_SERVER_URL="${MCP_SERVER_URL:?set MCP_SERVER_URL}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/chainlit:latest"

# Vertex needs a bare, versioned Gemini id (no provider prefix, no -latest alias).
if [[ "$LLM_AUTH" == "vertex" ]]; then
  shopt -s nocasematch
  if [[ "$LLM_MODEL" == */* || "$LLM_MODEL" != gemini* ]]; then
    echo "LLM_AUTH=vertex requires a bare Gemini model id (e.g. gemini-2.5-flash)." >&2
    echo "Got LLM_MODEL='$LLM_MODEL'. For non-Gemini or self-hosted models, use LLM_AUTH=apikey." >&2
    exit 1
  fi
  if [[ "$LLM_MODEL" == *latest* ]]; then
    echo "LLM_AUTH=vertex does not support '-latest' aliases (Developer-API-only)." >&2
    echo "Use a versioned Vertex id, e.g. gemini-2.5-flash. Got LLM_MODEL='$LLM_MODEL'." >&2
    exit 1
  fi
  shopt -u nocasematch
fi

# Artifact Registry repo (create if missing).
gcloud artifacts repositories describe "$REPO" --location "$REGION" --project "$PROJECT" >/dev/null 2>&1 \
  || gcloud artifacts repositories create "$REPO" --repository-format=docker \
       --location "$REGION" --project "$PROJECT"

# Build & push the single image (repo-root Dockerfile).
gcloud builds submit --project "$PROJECT" --tag "$IMAGE" "$REPO_ROOT"

ENV_VARS="MCP_SERVER_URL=${MCP_SERVER_URL},LLM_MODEL=${LLM_MODEL}"
DEPLOY_ARGS=()

case "$LLM_AUTH" in
  vertex)
    gcloud services enable aiplatform.googleapis.com --project "$PROJECT"
    ENV_VARS="${ENV_VARS},GOOGLE_GENAI_USE_VERTEXAI=TRUE,GOOGLE_CLOUD_PROJECT=${PROJECT},GOOGLE_CLOUD_LOCATION=${VERTEX_LOCATION}"
    PNUM="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
    gcloud projects add-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:${PNUM}-compute@developer.gserviceaccount.com" \
      --role="roles/aiplatform.user" --condition=None >/dev/null
    ;;
  apikey)
    : "${API_KEY_ENV:?set API_KEY_ENV (e.g. ANTHROPIC_API_KEY)}"
    : "${API_KEY_SECRET:?set API_KEY_SECRET (Secret Manager secret name)}"
    DEPLOY_ARGS+=(--set-secrets "${API_KEY_ENV}=${API_KEY_SECRET}:latest")
    [[ -n "${LLM_BASE_URL:-}" ]] && ENV_VARS="${ENV_VARS},LLM_BASE_URL=${LLM_BASE_URL}"
    ;;
  *)
    echo "LLM_AUTH must be 'vertex' or 'apikey' (got '$LLM_AUTH')" >&2; exit 1 ;;
esac

# --session-affinity keeps a browser pinned to one instance (Chainlit uses WebSockets).
gcloud run deploy "$SERVICE" \
  --project "$PROJECT" --region "$REGION" \
  --image "$IMAGE" \
  --set-env-vars "$ENV_VARS" \
  --allow-unauthenticated \
  --session-affinity \
  "${DEPLOY_ARGS[@]}"

echo
echo "Deployed. URL:"
gcloud run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" \
  --format='value(status.url)'
