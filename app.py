"""
Chainlit chat UI that drives the ADK agent (pipeline_pulse_agent) directly.

No AG-UI, no separate backend — Chainlit runs the ADK Runner in-process and
streams the agent's text and tool calls into the chat. One process, one image.

Run locally:
    chainlit run app.py -w
"""

import uuid

import chainlit as cl
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types

from pipeline_pulse_agent.agent import root_agent

APP_NAME = "pipeline_pulse"

# One session service + runner for the process; one ADK session per chat.
_sessions = InMemorySessionService()
_runner = Runner(app_name=APP_NAME, agent=root_agent, session_service=_sessions)


@cl.on_chat_start
async def on_chat_start() -> None:
    user_id = str(uuid.uuid4())
    session = await _sessions.create_session(app_name=APP_NAME, user_id=user_id)
    cl.user_session.set("user_id", user_id)
    cl.user_session.set("session_id", session.id)


@cl.on_message
async def on_message(message: cl.Message) -> None:
    user_id = cl.user_session.get("user_id")
    session_id = cl.user_session.get("session_id")
    new_message = types.Content(role="user", parts=[types.Part(text=message.content)])

    answer = cl.Message(content="")
    steps: dict[str, cl.Step] = {}

    async for event in _runner.run_async(
        user_id=user_id, session_id=session_id, new_message=new_message
    ):
        for part in (event.content.parts if event.content else []) or []:
            if part.function_call:  # agent decided to call a tool
                fc = part.function_call
                step = cl.Step(name=fc.name, type="tool")
                step.input = dict(fc.args or {})
                await step.send()
                steps[fc.name] = step
            elif part.function_response:  # tool returned
                fr = part.function_response
                step = steps.get(fr.name)
                if step is not None:
                    step.output = fr.response
                    await step.update()
            elif part.text:  # model text → stream into the answer
                await answer.stream_token(part.text)

    await answer.send()
