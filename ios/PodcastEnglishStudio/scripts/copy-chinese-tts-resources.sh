#!/bin/bash
set -euo pipefail
case "${PLATFORM_NAME}" in
  iphoneos|iphonesimulator) ;;
  *) exit 0 ;;
esac
resources="${SRCROOT}/../../tools/kokoro-zh/.work/device-resources"
destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/ChineseVoice"
if [ -f "${resources}/validation-identity.json" ]; then
  rm -rf "${destination}"
  /usr/bin/ditto "${resources}" "${destination}"
  /usr/bin/ditto "${SRCROOT}/../../Packages/ChineseTTS/Licenses" "${destination}/Licenses"
  (
    cd "${SRCROOT}/../../Packages/ChineseTTS"
    /usr/bin/find Sources -type f -name '*.swift' -exec /usr/bin/shasum -a 256 {} \; | LC_ALL=C /usr/bin/sort | /usr/bin/shasum -a 256
  ) > "${destination}/synthesis-source.sha256"
else
  rm -rf "${destination}"
  echo "warning: Chinese voice resources are not prepared; Chinese playback will be unavailable. See tools/kokoro-zh/README.md."
fi
