#!/usr/bin/env bash
# Deploy the UI (CopilotKit / Next.js) to Cloud Run, pointed at the agent service.
#
# Optional (defaults shown):
#   PROJECT           GCP project id (defaults to `gcloud config get-value project`)
#   REGION=us-central1  REPO=pipeline-pulse  SERVICE=pp-ui  AGENT_SERVICE=pp-agent
#   AGENT_URL         agent base URL; auto-discovered from AGENT_SERVICE if unset
#
# Deploy the agent first (deploy-agent.sh), then:
#   PROJECT=my-proj ./deploy/deploy-ui.sh
set -euo pipefail

# Load deploy/ui.env (git-ignored) if present — put your config there instead of
# passing it inline. Uncommented values win; comment a line to use the default.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"   # build paths are anchored here, so the script runs from anywhere
# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/ui.env" ]] && source "$SCRIPT_DIR/ui.env"

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
[[ -n "$PROJECT" ]] || { echo "No project: pass PROJECT=… or run 'gcloud config set project <id>'." >&2; exit 1; }
REGION="${REGION:-us-central1}"
REPO="${REPO:-pipeline-pulse}"
SERVICE="${SERVICE:-pp-ui}"
AGENT_SERVICE="${AGENT_SERVICE:-pp-agent}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/ui:latest"

# Resolve the agent service URL (unless provided explicitly).
AGENT_URL="${AGENT_URL:-$(gcloud run services describe "$AGENT_SERVICE" \
  --project "$PROJECT" --region "$REGION" --format='value(status.url)' 2>/dev/null)}"
[[ -n "$AGENT_URL" ]] || { echo "Could not resolve the agent URL — deploy the agent first." >&2; exit 1; }
AGENT_URL="${AGENT_URL%/}/"    # ensure a single trailing slash

gcloud artifacts repositories describe "$REPO" --location "$REGION" --project "$PROJECT" >/dev/null 2>&1 \
  || gcloud artifacts repositories create "$REPO" --repository-format=docker \
       --location "$REGION" --project "$PROJECT"

# Build & push the UI image (frontend Dockerfile + context).
gcloud builds submit --project "$PROJECT" --tag "$IMAGE" "$REPO_ROOT/ui"

gcloud run deploy "$SERVICE" \
  --project "$PROJECT" --region "$REGION" \
  --image "$IMAGE" \
  --set-env-vars "AGUI_BACKEND_URL=${AGENT_URL}" \
  --cpu-boost \
  --allow-unauthenticated

echo
echo "UI deployed (agent = ${AGENT_URL}). URL:"
gcloud run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" \
  --format='value(status.url)'
