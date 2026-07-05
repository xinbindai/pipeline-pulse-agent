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
COPY --from=build /ui/node_modules ./node_modules
COPY --from=build /ui/.next ./.next
COPY --from=build /ui/package.json ./package.json
COPY --from=build /ui/next.config.mjs ./next.config.mjs

EXPOSE 3000

# Cloud Run injects $PORT (8080); defaults to 3000 locally.
CMD ["sh", "-c", "node_modules/.bin/next start -H 0.0.0.0 -p ${PORT:-3000}"]
