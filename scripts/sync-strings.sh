#!/bin/zsh
# Brings Localizable.xcstrings in line with the code: builds the app, which extracts every String(localized:) and LocalizedStringResource literal into .stringsdata files,
# then adds new keys (English source text, no German yet) and marks keys no longer used as stale. Translate the new keys and delete stale ones afterwards; LocalizationTests fails until then.
# Usage: scripts/sync-strings.sh
set -euo pipefail

root=${0:A:h:h}
catalog=$root/Sources/GitBonsaiApp/Resources/Localizable.xcstrings

swift build --package-path $root --product GitBonsaiApp >/dev/null
# The build system leaves one .stringsdata per source file next to the object files; a file deleted since the last clean build may leave a stale one behind.
stringsdata=($root/.build/out/Intermediates.noindex/GitBonsai.build/Debug/GitBonsaiApp*.build/Objects-normal/*/*.stringsdata(N))
if (( ${#stringsdata} == 0 )); then
    echo "No .stringsdata found under .build/out; the build system no longer puts them where this script looks." >&2
    exit 1
fi
xcrun xcstringstool sync $catalog --stringsdata $stringsdata
echo "Synced ${#stringsdata} files into ${catalog#$root/}"
