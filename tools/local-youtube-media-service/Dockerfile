# syntax=docker/dockerfile:1
FROM node:24-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03 AS build

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:24-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03 AS runtime

RUN apt-get update \
  && apt-get install -y --no-install-recommends ffmpeg ca-certificates curl python3 python3-pip python3-venv \
  && rm -rf /var/lib/apt/lists/* \
  && python3 -m pip install --break-system-packages -U \
       "yt-dlp[default]==2026.8.19" \
       "bgutil-ytdlp-pot-provider==1.3.2" \
  && yt-dlp --version

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY --from=build /app/dist/src ./dist/src

ENV NODE_ENV=production \
  HOST=0.0.0.0 \
  PORT=3210 \
  DOWNLOAD_ENGINE=ytdlp \
  YT_DLP_BIN=/usr/local/bin/yt-dlp \
  YT_DLP_JS_RUNTIME=node \
  PREFERRED_HEIGHT=720 \
  MAX_CONCURRENT_JOBS=1 \
  JOB_TTL_MS=2700000 \
  REQUIRE_MEDIA_AUTH=true \
  MEDIA_ROOT=/data/media

VOLUME ["/data/media"]
EXPOSE 3210
CMD ["node", "dist/src/server.js"]
