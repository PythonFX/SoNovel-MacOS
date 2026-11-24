#!/bin/bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$project_dir")
output_dir="$project_dir/dist"

cd -- "$project_dir"
swift build --configuration release --product SoNovel
bin_dir=$(swift build --configuration release --show-bin-path)

mkdir -p "$output_dir"
staging=$(mktemp -d "$output_dir/.app-build.XXXXXXXX")
trap 'rm -rf -- "$staging"' EXIT

app="$staging/SoNovel.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources/SourceRules" "$staging/AppIcon.iconset"
install -m 755 "$bin_dir/SoNovel" "$contents/MacOS/SoNovel"
install -m 644 "$project_dir/Packaging/Info.plist" "$contents/Info.plist"
install -m 644 "$repo_dir/bundle/rules/"*.json "$contents/Resources/SourceRules/"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$repo_dir/assets/logo.png" \
        --out "$staging/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$repo_dir/assets/logo.png" \
        --out "$staging/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$staging/AppIcon.iconset" --output "$contents/Resources/AppIcon.icns"

plutil -lint "$contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

if [[ -e "$output_dir/SoNovel.app" ]]; then
    mv -- "$output_dir/SoNovel.app" "$staging/Previous.app"
fi
if ! mv -- "$app" "$output_dir/SoNovel.app"; then
    if [[ -e "$staging/Previous.app" ]]; then
        mv -- "$staging/Previous.app" "$output_dir/SoNovel.app"
    fi
    exit 1
fi
printf '\n%s\n' "$output_dir/SoNovel.app"
