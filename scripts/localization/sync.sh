#!/bin/zsh
# Builds app localization output, selects app-owned data safely, then regenerates and validates English.
set -euo pipefail

repo_root="${0:A:h:h:h}"
source_strings="$repo_root/Sources/PalmierPro/Resources/Localization/en.lproj/Localizable.strings"
temporary_directory="$(mktemp -d /private/tmp/palmier-localization.XXXXXX)"
trap 'rm -rf "$temporary_directory"' EXIT

cd "$repo_root"
swift build \
  -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path \
  -Xswiftc "$temporary_directory"

stringsdata_arguments=()
app_stringsdata_list="$temporary_directory/app-stringsdata"
node scripts/localization/sync.mjs \
  --list-app-stringsdata "$temporary_directory" > "$app_stringsdata_list"
while IFS= read -r data; do
  stringsdata_arguments+=(--stringsdata "$data")
done < "$app_stringsdata_list"

node scripts/localization/sync.mjs \
  --output "$source_strings" \
  "${stringsdata_arguments[@]}"
node scripts/localization/check.mjs "$@"
