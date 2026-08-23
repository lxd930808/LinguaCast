# LinguaCast local media service

An optional self-hosted HTTP service that uses yt-dlp and FFmpeg to prepare MP4 or HLS media for LinguaCast on iOS/tvOS. The app does not require this service for its default playback paths.

You must only process media you are authorized to access. Review platform terms, copyright, privacy, and applicable law before deployment.

## Docker quick start

```bash
cp .env.example .env
# Set a random AUTH_TOKEN and the reachable PUBLIC_BASE_URL.
docker compose up --build
curl http://127.0.0.1:3210/health
```

The compose stack starts the media API and a bgutil PO-token sidecar. Pin image digests and review the supply chain before a production deployment.

## Local Node development

Requirements: Node.js 24, FFmpeg/ffprobe, and yt-dlp.

```bash
npm ci
npm run check-env
npm test
npm run typecheck
npm run build
AUTH_TOKEN=replace-with-a-random-token \
PUBLIC_BASE_URL=http://127.0.0.1:3210 \
npm start
```

Use `npm run dev` instead of `npm start` while editing TypeScript.

## API

- `GET /health` — public process/dependency health
- `POST /v1/videos/{videoId}/prepare` — create a job; Bearer authentication required
- `GET /v1/jobs/{jobId}` — job status
- `DELETE /v1/jobs/{jobId}` — cancel a job and remove its media
- `GET /media/{jobId}/output.mp4` — byte-range media response
- `GET /media/{jobId}/audio.m4a`
- `GET /media/{jobId}/master.m3u8`

Media routes require the configured token when `REQUIRE_MEDIA_AUTH=true` (the default).

## Important environment variables

| Variable | Purpose |
| --- | --- |
| `AUTH_TOKEN` | Bearer token; use a random secret |
| `PUBLIC_BASE_URL` | URL reachable by the Apple device |
| `MEDIA_ROOT` | Working/output directory |
| `PREFERRED_HEIGHT` | Default output height |
| `MAX_CONCURRENT_JOBS` | Job concurrency limit |
| `JOB_TTL_MS` | Completed-job retention |
| `MIN_FREE_BYTES` | Disk-space guardrail |
| `REQUIRE_MEDIA_AUTH` | Keep `true` outside isolated tests |
| `DOWNLOAD_ENGINE` | `ytdlp` (default) or experimental `sabr` |

R2 variables are optional. Leave them unset to serve files from the local host.

## App configuration

Set the service URL and bearer token on the Apple device. The Apple TV QR page accepts the URL and playback mode but intentionally does not accept bearer tokens.

Debug environment equivalents are:

```text
YT_PLAYBACK_BACKEND=local-service
YT_LOCAL_MEDIA_BASE_URL=https://media.example.com
YT_LOCAL_MEDIA_TOKEN=<token>
YT_LOCAL_MEDIA_MODE=mp4
YT_LOCAL_MEDIA_PREFERRED_HEIGHT=720
```

Use HTTPS beyond a trusted LAN. Add firewall rules, monitoring, rate limits, disk quotas, retention, and token rotation before exposing the service.
