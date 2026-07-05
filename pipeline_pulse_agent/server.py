"""
FastAPI / AG-UI backend for the `pipeline_pulse_agent` ADK agent.

Part of the agent package: it wraps the ADK `root_agent` (agent.py) with the
`ag-ui-adk` middleware and serves it over the AG-UI protocol, so a CopilotKit
(or any AG-UI) frontend can talk to it.

Run (from the repo root):
    uvicorn pipeline_pulse_agent.server:app --reload --port 8000

The AG-UI endpoint is then:
    POST http://localhost:8000/          (Server-Sent Events stream)
"""

from ag_ui_adk import ADKAgent, add_adk_fastapi_endpoint
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .agent import root_agent

# Bridge the ADK agent to the AG-UI protocol. In-memory session/artifact/memory
# services are fine for a demo; swap them out for persistent ones in production.
adk_agent = ADKAgent(
    adk_agent=root_agent,
    app_name="pipeline_pulse",
    user_id="demo-user",
    use_in_memory_services=True,
)

app = FastAPI(title="pipeline_pulse AG-UI backend")

# Let the CopilotKit dev server (http://localhost:3000) call this backend.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Expose the AG-UI agent at POST /
add_adk_fastapi_endpoint(app, adk_agent, path="/")


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "agent": root_agent.name}
