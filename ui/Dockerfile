# UI image: CopilotKit / Next.js frontend. Build context = this folder.
#
#   docker build -t pp-ui ui
#   docker run --rm -p 3000:3000 -e AGUI_BACKEND_URL=http://host:8000/ pp-ui
#
# The agent is a SEPARATE image (../pipeline_pulse_agent/Dockerfile). This UI
# reaches it, server-side, at AGUI_BACKEND_URL.

# ---------- build ----------
FROM node:20-slim AS build
WORKDIR /ui
COPY package.json package-lock.json ./
RUN npm ci
COPY . ./
RUN npm run build

# ---------- run ----------
FROM node:20-slim AS run
WORKDIR /ui
ENV NODE_ENV=production \
    COPILOTKIT_TELEMETRY_DISABLED=true \
    AGUI_BACKEND_URL=http://localhost:8000/
# Next.js standalone output: a minimal server + only the node_modules it traced.
COPY --from=build /ui/.next/standalone ./
COPY --from=build /ui/.next/static ./.next/static

EXPOSE 3000

# server.js is emitted by the standalone build; it honors PORT and HOSTNAME.
# Cloud Run injects $PORT (8080); defaults to 3000 locally.
CMD ["sh", "-c", "HOSTNAME=0.0.0.0 PORT=${PORT:-3000} node server.js"]
