#!/bin/bash
# Make dist/solarmorph-<version>.zip: the Raycast extension with a universal
# helper binary, for people who do not have the Swift toolchain.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
extension="$root/extension"
version="$(node -p "require('$extension/package.json').version")"
name="solarmorph-$version"
stage="$root/dist/$name"

(cd "$root/helper" && swift test)
(cd "$extension" && npm ci && UNIVERSAL=1 npm run build && npx tsc --noEmit)

rm -rf "$stage" "$root/dist/$name.zip"
mkdir -p "$stage"
cp -R "$extension"/{package.json,package-lock.json,tsconfig.json,src,assets,scripts} "$stage/"
cp "$root"/{README.md,LICENSE,THIRD_PARTY_NOTICES.md,CHANGELOG.md} "$stage/"

# ditto keeps the executable bit. Without the extended attributes, unzip does
# not make ._ files. The signature is in the binary, so it stays.
(cd "$root/dist" && ditto -c -k --norsrc --noextattr --keepParent "$name" "$name.zip")
rm -rf "$stage"

echo "dist/$name.zip"
lipo -archs "$extension/assets/morph"
shasum -a 256 "$root/dist/$name.zip"
