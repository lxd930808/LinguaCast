# Security

LinguaCast is published as a source reference. There is no guaranteed support or response SLA.

## Reporting a vulnerability

Do not disclose exploitable details in a public issue. Use GitHub's private vulnerability reporting feature for this repository when available. Include affected files, reproduction steps, impact, and a suggested mitigation.

## Secret handling

- Never commit API keys, CloudKit credentials, signing identities, bearer tokens, or `.env` files.
- App API credentials are entered on-device and stored through the Keychain-backed settings path.
- The Apple TV QR setup page intentionally rejects all secret configuration keys. Its random link token expires after 10 minutes and is invalidated after a successful submission.
- The optional media service requires an `AUTH_TOKEN`; use a random value and TLS when traffic leaves a trusted LAN.

## Deployment notes

The default Xcode scheme has no CloudKit entitlement and works with local storage. CloudKit requires your own container, App ID, signing team, and explicit opt-in configuration.

The media service downloads and transforms third-party media. Operators are responsible for authorization, applicable law, platform terms, access control, retention, and network exposure.
