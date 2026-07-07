"""
ADK agent app: multi-MCP tools + local tools, over any (incl. self-hosted) LLM.

Exposes `root_agent`, so it runs with the ADK CLI (from the repo root):
    adk run pipeline_pulse_agent
    adk run pipeline_pulse_agent "How many incidents are Open, and what time is it?"
    adk web .            # browser UI (pick pipeline_pulse_agent)

Configuration (env / a local .env file next to this module):

    MCP_SERVER_URL   One or more MCP endpoints, comma-separated. The agent
                     connects to all of them and sees the union of their tools.
                     e.g. https://server-a/mcp,https://server-b/mcp

    LLM_MODEL        Which model to drive:
                       anthropic/claude-opus-4-8  -> ANTHROPIC_API_KEY  (default)
                       openai/gpt-4.1             -> OPENAI_API_KEY
                       gemini-flash-latest        -> GOOGLE_API_KEY  (native)

    LLM_BASE_URL     Optional. OpenAI-compatible endpoint of a self-hosted engine
                     (llama.cpp, vLLM, Ollama, LM Studio). When set, LLM_MODEL is
                     the model that server serves and no real API key is needed.
                       LLM_BASE_URL=http://localhost:8080/v1
                       LLM_MODEL=llama-3.1-8b-instruct

    CHROMA_HOST      Optional. When set, a RAG subagent ('rag_agent') is added
    CHROMA_PORT      that queries a remote Chroma server through a stdio
    CHROMA_SSL       `chroma-mcp` process. host/port/ssl are the Chroma HTTP
    CHROMA_COLLECTION connection; the subagent searches this collection.
    CHROMA_KB_DESCRIPTION  What the knowledge base holds (drives the subagent's
                     description/instruction and the root's delegation).
"""

import logging
import os
import warnings
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv
from google.adk.agents.llm_agent import LlmAgent
from google.adk.tools.mcp_tool import McpToolset
from google.adk.tools.mcp_tool.mcp_session_manager import (
    StdioConnectionParams,
    StdioServerParameters,
    StreamableHTTPConnectionParams,
)

# Load a .env sitting next to this module (works under `adk run`/`adk web` too).
load_dotenv(Path(__file__).with_name(".env"))

# Silence two benign google-adk notices (neither affects the agent):
#   - UserWarning: "[EXPERIMENTAL] feature ... is enabled"
#   - log line:    "mTLS was requested but AsyncAuthorizedSession channel is not mTLS"
warnings.filterwarnings("ignore", message=r"\[EXPERIMENTAL\]", category=UserWarning)
logging.getLogger(
    "google_adk.google.adk.tools.mcp_tool.mcp_session_manager"
).setLevel(logging.ERROR)


# ── Configuration ─────────────────────────────────────────────────────────────
# MCP_SERVER_URL may list several endpoints, comma-separated.
SERVER_URLS = [
    u.strip()
    for u in os.environ.get("MCP_SERVER_URL", "http://localhost:8080/mcp").split(",")
    if u.strip()
]

LLM_MODEL = os.environ.get("LLM_MODEL", "anthropic/claude-opus-4-8")

# OpenAI-compatible base URL for a self-hosted engine (llama.cpp, vLLM, Ollama…).
LLM_BASE_URL = os.environ.get("LLM_BASE_URL")

# Remote Chroma server for the RAG subagent (via a stdio chroma-mcp process).
# The RAG subagent is added only when CHROMA_HOST is set.
CHROMA_HOST = os.environ.get("CHROMA_HOST")
CHROMA_PORT = os.environ.get("CHROMA_PORT", "8000")
CHROMA_SSL = os.environ.get("CHROMA_SSL", "false")
CHROMA_COLLECTION = os.environ.get("CHROMA_COLLECTION", "")
# chroma-mcp pins mcp==1.6.0, which conflicts with ADK's mcp>=1.28 — so install it
# ISOLATED from this env (`uv tool install chroma-mcp`, or a dedicated venv) and
# point CHROMA_MCP_CMD at that executable. Default assumes it's on PATH.
CHROMA_MCP_CMD = os.environ.get("CHROMA_MCP_CMD", "chroma-mcp")
# What the knowledge base contains — drives the RAG subagent's description and
# instruction (and the root agent's delegation), so keep it in config, not code.
CHROMA_KB_DESCRIPTION = os.environ.get(
    "CHROMA_KB_DESCRIPTION", "a knowledge base of documents"
)


# ── Model selection (hosted, or self-hosted OpenAI-compatible) ────────────────
def _build_model(model_str: str):
    """Build the model ADK drives.

    - LLM_BASE_URL set → a self-hosted OpenAI-compatible server; drive it through
      LiteLLM's openai provider pointed at that base URL (no real key needed).
    - '<provider>/<model>' → wrapped in LiteLlm.
    - bare id → native Gemini, passed as-is.
    """
    if LLM_BASE_URL:
        from google.adk.models.lite_llm import LiteLlm

        # LiteLLM needs the "openai/" prefix to use the OpenAI-compatible path.
        model = model_str if "/" in model_str else f"openai/{model_str}"
        return LiteLlm(
            model=model,
            api_base=LLM_BASE_URL,
            api_key=os.environ.get("OPENAI_API_KEY", "sk-no-key-required"),
        )
    if "/" in model_str:
        from google.adk.models.lite_llm import LiteLlm

        return LiteLlm(model=model_str)
    return model_str


# ── Local tools ───────────────────────────────────────────────────────────────
def get_current_time() -> dict:
    """Return the current local date and time.

    Use this whenever the user asks what time or date it is now. Takes no
    arguments.
    """
    now = datetime.now().astimezone()
    return {
        "iso": now.isoformat(),
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%H:%M:%S"),
        "timezone": now.tzname(),
    }


# ── RAG subagent (remote Chroma via a stdio MCP server) ───────────────────────
def _chroma_toolset() -> McpToolset:
    """MCP toolset backed by a stdio `chroma-mcp` process that talks to a remote
    Chroma server (HTTP client). Exposes Chroma's query/collection tools."""
    return McpToolset(
        connection_params=StdioConnectionParams(
            server_params=StdioServerParameters(
                command=CHROMA_MCP_CMD,
                args=[
                    "--client-type", "http",
                    "--host", CHROMA_HOST,
                    "--port", str(CHROMA_PORT),
                    "--ssl", str(CHROMA_SSL).lower(),
                ],
            ),
            timeout=30,
        ),
    )


def _build_rag_agent() -> LlmAgent:
    """A subagent that answers from the Chroma knowledge base via semantic search."""
    return LlmAgent(
        model=_build_model(LLM_MODEL),
        name="rag_agent",
        description=(
            f"Answers questions about {CHROMA_KB_DESCRIPTION}, stored in a Chroma "
            "vector store, via semantic search."
        ),
        instruction=(
            f"You answer questions from a knowledge base containing "
            f"{CHROMA_KB_DESCRIPTION}. Use the chroma query tools to search the "
            f"'{CHROMA_COLLECTION}' collection for documents relevant to the "
            "question, then answer grounded strictly in what you retrieve. If "
            "nothing relevant is found, say so."
        ),
        tools=[_chroma_toolset()],
    )


# ── Agent ─────────────────────────────────────────────────────────────────────
# One toolset per MCP server; the agent sees the union of all their tools plus
# any local Python functions (ADK wraps a plain function as a FunctionTool).
_toolsets = [
    McpToolset(connection_params=StreamableHTTPConnectionParams(url=url))
    for url in SERVER_URLS
]

# Add the RAG subagent only when a Chroma host is configured.
_sub_agents = [_build_rag_agent()] if CHROMA_HOST else []
_rag_hint = (
    f" For questions about {CHROMA_KB_DESCRIPTION}, delegate to the 'rag_agent'."
    if _sub_agents
    else ""
)

root_agent = LlmAgent(
    model=_build_model(LLM_MODEL),
    name="pipeline_pulse_agent",
    instruction=(
        "You are a helpful assistant. Use the available tools to answer the "
        "user's question — MCP tools for server data, and the local "
        "'get_current_time' tool for the current date/time." + _rag_hint +
        " Be concise."
    ),
    tools=[*_toolsets, get_current_time],
    sub_agents=_sub_agents,
)
