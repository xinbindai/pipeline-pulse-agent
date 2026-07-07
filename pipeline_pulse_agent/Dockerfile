# Agent image: the ADK agent + its FastAPI/AG-UI backend (server.py). The FastAPI
# app is the backend the CopilotKit UI talks to. Build context = THIS folder.
#
#   docker build -t pp-agent pipeline_pulse_agent
#   docker run --rm -p 8000:8000 --env-file pipeline_pulse_agent/.env pp-agent
#
# The UI is a separate image (../ui/Dockerfile).
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# RAG subagent's stdio server, in a DEDICATED venv so its mcp==1.6.0 pin can't
# clash with the agent's mcp>=1.28. CHROMA_MCP_CMD points the agent at it.
RUN python -m venv /opt/chroma-mcp \
    && /opt/chroma-mcp/bin/pip install --no-cache-dir chroma-mcp

# Copy the package into /app/pipeline_pulse_agent so it imports as that module.
COPY . ./pipeline_pulse_agent/

ENV PYTHONUNBUFFERED=1 \
    CHROMA_MCP_CMD=/opt/chroma-mcp/bin/chroma-mcp

EXPOSE 8000

# Cloud Run injects $PORT (8080); defaults to 8000 locally.
CMD ["sh", "-c", "uvicorn pipeline_pulse_agent.server:app --host 0.0.0.0 --port ${PORT:-8000}"]
