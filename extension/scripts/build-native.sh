#!/bin/bash
# Build the Swift helper and put it in assets/, where the extension finds it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$root/../helper"

swift build -c release --package-path "$helper"
cp "$helper/.build/release/morph" "$root/assets/morph"
# The Info.plist in the binary is part of the signature, so sign after the copy.
codesign --force --sign - --identifier local.solarmorph.morph "$root/assets/morph" >/dev/null
chmod +x "$root/assets/morph"
