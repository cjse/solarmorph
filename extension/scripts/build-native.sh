#!/bin/bash
# Build the Swift helper and put it in assets/, where the extension finds it.
#
#   UNIVERSAL=1   build for arm64 and x86_64. This needs the full Xcode, so
#                 only the release package uses it. The default is the
#                 architecture of this Mac, which the command line tools can build.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$root/../helper"
output="$root/assets/morph"

# A release package has the helper but not its source.
if [ ! -d "$helper" ]; then
  if [ -x "$output" ]; then
    echo "Using the helper that came with the package."
    exit 0
  fi
  echo "The helper source and the helper binary are both missing." >&2
  exit 1
fi

flags=(-c release --package-path "$helper")
if [ "${UNIVERSAL:-0}" = "1" ]; then
  flags+=(--arch arm64 --arch x86_64)
fi

swift build "${flags[@]}"
# A new file, not a write into the old one: a daemon possibly runs from the old file.
rm -f "$output"
cp "$(swift build "${flags[@]}" --show-bin-path)/morph" "$output"
# The Info.plist in the binary is part of the signature, so sign after the copy.
codesign --force --sign - --identifier local.solarmorph.morph "$output" >/dev/null
chmod +x "$output"
