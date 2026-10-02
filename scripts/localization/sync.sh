#!/bin/zsh
# Builds app localization output, selects app-owned data safely, then regenerates and validates English.
set -euo pipefail

repo_root="${0:A:h:h:h}"
source_strings="$repo_root/Sources/CompositorPro/Resources/Localization/en.lproj/Localizable.strings"
scratch_path="${SCRATCH_PATH:-$repo_root/.build}"

cd "$repo_root"
# No -emit-localized-strings flags: the build already emits stringsdata for the app target, and
# passing an output path makes the toolchain write somewhere the scan below does not read.
swift build --scratch-path "$scratch_path"

stringsdata_arguments=()
app_stringsdata_list="$(mktemp)"
trap 'rm -f "$app_stringsdata_list"' EXIT
node scripts/localization/sync.mjs \
  --list-app-stringsdata "$scratch_path/out" > "$app_stringsdata_list"
while IFS= read -r data; do
  stringsdata_arguments+=(--stringsdata "$data")
done < "$app_stringsdata_list"

node scripts/localization/sync.mjs \
  --output "$source_strings" \
  "${stringsdata_arguments[@]}"
node scripts/localization/check.mjs "$@"
