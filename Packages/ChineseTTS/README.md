# ChineseTTS

Local Chinese synthesis used by the iOS player. ChineseFrontend and ChineseSynthesis were moved from the validated V16 prototype. Smoke and DeviceProbe now import these same modules. KokoroPipeline is vendored unchanged from the pinned upstream revision recorded in `sources.lock.json`; licenses are retained in Licenses. Large model resources are not part of the Swift package.

The app gates use to iOS 18 and newer. The package deployment target remains 17 so the rest of the app remains buildable on iOS 17. tvOS has no synthesis import or UI entry.

Model weights are not bundled. The app enables local synthesis only when compatible Kokoro Core ML assets have been provisioned; without them, the rest of the app remains available. The source lock records upstream provenance and the Licenses directory retains third-party license texts.

For an iOS build, the resource-copy step looks for a prepared resource directory at `tools/kokoro-zh/.work/device-resources` relative to the repository root, including `validation-identity.json`. The model conversion toolchain and prepared resource bundle are outside this snapshot. No resource directory is required to build or use the other app features.
