# syntax=docker/dockerfile:1

FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
COPY migrations ./migrations
COPY tests ./tests
COPY fixtures ./fixtures
RUN npm run build && npm prune --omit=dev

FROM node:22-bookworm-slim AS runtime
ENV NODE_ENV=production
# ffmpeg/ffprobe for media probing and MP3 normalization (WP4).
# Pinned to the version verified in production on bookworm; bump when rebuilding
# on a newer base image.
ARG FFMPEG_VERSION=7:5.1.9-0+deb12u1
RUN apt-get update \
  && apt-get install -y --no-install-recommends "ffmpeg=${FFMPEG_VERSION}" \
  && rm -rf /var/lib/apt/lists/*
# Data/tmp directories owned by the runtime user; fresh named volumes inherit
# this ownership on first mount, so the service can open its SQLite database.
RUN mkdir -p /var/lib/linguacast-content/data /var/lib/linguacast-content/tmp \
  && chown -R node:node /var/lib/linguacast-content
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY migrations ./migrations
COPY package.json ./
USER node
EXPOSE 3220
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3220/v1/content-health/live').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/src/server.js"]
