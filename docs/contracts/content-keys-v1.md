# V10 Content Keys and Idempotency (content-keys-v1)

> Contract version: v1 (frozen with WP0). Changes require updating this
> document, the golden fixtures and both sides' contract tests.

## 1. Content Key

The content key stably identifies the source content. It contains no titles,
emails or other personally identifiable plaintext.

### 1.1 Podcast episode

```
contentKey = "podcast:" + feedHash + ":" + episodeHash
feedHash    = sha256hex(normalizedFeedUrl)[0:16]
episodeHash = sha256hex(nfc(trim(episodeGuid)))[0:16]
```

Normalized feed URL:

1. Parse as URL; reject non-HTTP(S).
2. Lowercase scheme and host.
3. Remove the default port (80 for http, 443 for https).
4. Remove the fragment.
5. Strip a single trailing `/` from the path (keep `/` root).
6. NFC-normalize the path and query.

If the feed URL is unavailable, the enclosure URL host + path is used as the
feed identity fallback and the derivation is recorded in the job source.

### 1.2 Video

```
contentKey = "video:" + platform + ":" + nfc(trim(videoId))
```

- `platform` is lowercase (`youtube` for v1).
- `videoId` keeps its original case (YouTube IDs are case-sensitive).

## 2. Generation Variant

A generation variant is the tuple:

```
(contentType, contentKey, sourceLanguage, targetLanguage, translationQuality, pipelineVersion)
```

The same source artifact (audio + ASR segments) is shared across target
languages; each variant gets its own translation products.

## 3. Server-Side Dedupe Key

```
dedupeKey = sha256hex(join("\n", [
  ownerScope,
  contentType,
  contentKey,
  sourceLanguage,
  targetLanguage,
  translationQuality,
  pipelineVersion
]))
```

- `ownerScope` is derived from the authenticated Bearer token (v1 self-hosted
  single-user deployments use a single configured scope, e.g. `selfhost`).
- Language tags are NFC-normalized; region/script case is preserved as sent
  (BCP 47). `translationQuality` and `pipelineVersion` are exact strings.
- The dedupe key maps to at most one non-expired job. Concurrent creates with
  the same dedupe key return the same job (200 reused=true).

## 4. Idempotency-Key Header

- Optional, opaque, max 128 chars, scoped to the owner.
- When present and already seen, the stored request fingerprint (hash of the
  normalized create body) must match; otherwise the server returns
  `409 IDEMPOTENCY_CONFLICT`.
- The header never overrides the server-derived dedupe key; it only protects
  against client-side double submission of identical payloads.

## 5. Unicode and Stability Requirements

- All normalization uses Unicode NFC before hashing.
- Redirected feed/enclosure URLs: the client derives the key from the URL it
  submitted; the server re-derives from the same submitted values, not from
  post-redirect URLs.
- Key derivation MUST be identical in TypeScript and Swift. The shared test
  vectors live in
  `services/content-pipeline/fixtures/contract/content-key-vectors.json` and
  are mirrored into the iOS test fixtures.
