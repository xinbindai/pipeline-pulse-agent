import {
  CopilotRuntime,
  ExperimentalEmptyAdapter,
  copilotRuntimeNextJSAppRouterEndpoint,
} from "@copilotkit/runtime";
import { HttpAgent } from "@ag-ui/client";
import { NextRequest } from "next/server";

// The AG-UI agent drives the LLM itself, so the runtime needs no LLM adapter.
const serviceAdapter = new ExperimentalEmptyAdapter();

// Bridge CopilotKit to the Python AG-UI backend (ag_ui_backend/server.py).
// The agent key "pipeline_pulse" must match the `agent` prop in page.tsx.
const runtime = new CopilotRuntime({
  agents: {
    pipeline_pulse: new HttpAgent({
      url: process.env.AGUI_BACKEND_URL ?? "http://localhost:8000/",
    }),
  },
});

export const POST = async (req: NextRequest) => {
  const { handleRequest } = copilotRuntimeNextJSAppRouterEndpoint({
    runtime,
    serviceAdapter,
    endpoint: "/api/copilotkit",
  });

  return handleRequest(req);
};
