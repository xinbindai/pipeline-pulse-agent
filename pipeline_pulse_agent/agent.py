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


# ── Agent ─────────────────────────────────────────────────────────────────────
# One toolset per MCP server; the agent sees the union of all their tools plus
# any local Python functions (ADK wraps a plain function as a FunctionTool).
_toolsets = [
    McpToolset(connection_params=StreamableHTTPConnectionParams(url=url))
    for url in SERVER_URLS
]

root_agent = LlmAgent(
    model=_build_model(LLM_MODEL),
    name="pipeline_pulse_agent",
    instruction=(
        "You are a helpful assistant. Use the available tools to answer the "
        "user's question — MCP tools for server data, and the local "
        "'get_current_time' tool for the current date/time. Be concise."
    ),
    tools=[*_toolsets, get_current_time],
)
