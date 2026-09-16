# syntax=docker/dockerfile:1

ARG YTDLP_VERSION=2025.10.14

FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
COPY migrations ./migrations
RUN npm run build && npm prune --omit=dev

FROM node:22-bookworm-slim AS runtime
ARG YTDLP_VERSION
ENV NODE_ENV=production
# ripgrep comes from Debian bookworm. Fail the build if major < 13.
# Do not install shell completions, browsers, Cookie tools, or extra search wrappers.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates python3 curl ripgrep \
  && curl -fsSL "https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp" -o /usr/local/bin/yt-dlp \
  && chmod a+rx /usr/local/bin/yt-dlp \
  && rg --version \
  && python3 -c "import re,subprocess,sys; out=subprocess.check_output(['rg','--version'], text=True); m=re.search(r'ripgrep\\s+(\\d+)', out); sys.exit(0 if m and int(m.group(1))>=13 else 1)" \
  && apt-get purge -y curl \
  && apt-get autoremove -y \
  && rm -rf /var/lib/apt/lists/*
RUN mkdir -p \
    /var/lib/linguacast-assistant/data \
    /var/lib/linguacast-assistant/tmp \
    /var/lib/linguacast-assistant/pi \
    /var/lib/linguacast-assistant/workspaces \
    /var/lib/linguacast-assistant/global-memory \
    /var/lib/linguacast-assistant/shared-versions \
  && chown -R node:node /var/lib/linguacast-assistant
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY migrations ./migrations
COPY prompts ./prompts
COPY skills ./skills
# Compiled registry resolves ../../skills from dist/src/skills → dist/skills.
COPY skills ./dist/skills
COPY package.json ./
USER node
EXPOSE 3230
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3230/v1/assistant-health/live').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/src/server.js"]
