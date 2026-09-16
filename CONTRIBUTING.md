# Contributing

This repository is a source-reference release, not a supported product roadmap. Issues and pull requests may not receive a response.

If you propose a change:

1. Keep credentials, personal identifiers, signing settings, and private endpoints out of the patch.
2. Add or update focused tests before changing behavior.
3. Run the Swift package tests, iOS/tvOS unsigned builds, Node service tests (`npm run typecheck && npm test && npm run build` in each `services/*` and the media tool), and the self-host Docker Compose validation described in the README.
4. Keep CloudKit optional and preserve a working local-only configuration.
5. Explain user-visible behavior and security implications in the pull request.

By contributing, you agree that your contribution is licensed under the MIT License.
