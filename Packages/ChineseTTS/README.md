# ChineseTTS

Local Chinese synthesis used by the iOS player. ChineseFrontend and ChineseSynthesis were moved from the validated V16 prototype. Smoke and DeviceProbe now import these same modules. KokoroPipeline is vendored unchanged from the pinned upstream revision in `tools/kokoro-zh/sources.lock.json`; licenses are retained in Licenses. Large model resources are not part of the Swift package.

The app gates use to iOS 18 and newer. The package deployment target remains 17 so the rest of the app remains buildable on iOS 17. tvOS has no synthesis import or UI entry.
