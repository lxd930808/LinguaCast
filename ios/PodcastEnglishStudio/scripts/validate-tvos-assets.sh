#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
asset_root="$project_dir/PodcastEnglishStudio/Assets.xcassets/AppIconTV.brandassets"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

check_image() {
  local path="$1"
  local expected_width="$2"
  local expected_height="$3"
  local width
  local height

  [[ -f "$path" ]] || fail "Missing image: $path"
  width="$(sips -g pixelWidth "$path" 2>/dev/null | awk '/pixelWidth/ { print $2 }')"
  height="$(sips -g pixelHeight "$path" 2>/dev/null | awk '/pixelHeight/ { print $2 }')"

  [[ "$width" == "$expected_width" ]] || fail "$path width is $width; expected $expected_width"
  [[ "$height" == "$expected_height" ]] || fail "$path height is $height; expected $expected_height"
}

small_background="$asset_root/App Icon - Small.imagestack/Background.imagestacklayer/Content.imageset"
small_foreground="$asset_root/App Icon - Small.imagestack/Foreground.imagestacklayer/Content.imageset"
top_shelf="$asset_root/Top Shelf Image.imageset"
top_shelf_wide="$asset_root/Top Shelf Image Wide.imageset"

for metadata in \
  "$small_background/Contents.json" \
  "$small_foreground/Contents.json" \
  "$top_shelf/Contents.json" \
  "$top_shelf_wide/Contents.json"; do
  [[ -s "$metadata" ]] || fail "Missing or empty metadata: $metadata"
  plutil -p "$metadata" >/dev/null 2>&1 || fail "Invalid metadata: $metadata"
done

[[ "$(plutil -extract images.1.filename raw -o - "$small_background/Contents.json")" == "Background@2x.png" ]] \
  || fail "Small background 2x filename is not configured"
[[ "$(plutil -extract images.1.filename raw -o - "$small_foreground/Contents.json")" == "Foreground@2x.png" ]] \
  || fail "Small foreground 2x filename is not configured"

check_image "$small_background/Background.png" 400 240
check_image "$small_background/Background@2x.png" 800 480
check_image "$small_foreground/Foreground.png" 400 240
check_image "$small_foreground/Foreground@2x.png" 800 480
check_image "$top_shelf/TopShelf.png" 1920 720
check_image "$top_shelf/TopShelf@2x.png" 3840 1440
check_image "$top_shelf_wide/TopShelfWide.png" 2320 720
check_image "$top_shelf_wide/TopShelfWide@2x.png" 4640 1440

compile_dir="$(mktemp -d "${TMPDIR:-/tmp}/linguacast-tvos-assets.XXXXXX")"
trap 'rm -rf -- "$compile_dir"' EXIT

xcrun actool "$project_dir/PodcastEnglishStudio/Assets.xcassets" \
  --compile "$compile_dir" \
  --platform appletvos \
  --minimum-deployment-target 17.0 \
  --target-device tv \
  --app-icon AppIconTV \
  --output-partial-info-plist "$compile_dir/partial.plist" \
  --warnings \
  --errors \
  --notices \
  >/dev/null

[[ "$(plutil -extract TVTopShelfImage.TVTopShelfPrimaryImage raw -o - "$compile_dir/partial.plist")" == "Top Shelf Image" ]] \
  || fail "actool did not generate TVTopShelfPrimaryImage"
[[ "$(plutil -extract TVTopShelfImage.TVTopShelfPrimaryImageWide raw -o - "$compile_dir/partial.plist")" == "Top Shelf Image Wide" ]] \
  || fail "actool did not generate TVTopShelfPrimaryImageWide"

echo "PASS: tvOS app icon and Top Shelf assets are complete"
