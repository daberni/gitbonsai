#!/bin/zsh
# Brings Localizable.xcstrings in line with the code: builds the app, which extracts every String(localized:defaultValue:) and LocalizedStringResource(_:defaultValue:) into .stringsdata files, then lets xcstringstool
# - add new keys with the English from defaultValue (no German yet),
# - update the English of a key whose defaultValue changed and mark its German as needing review,
# - mark keys no longer used as stale.
# Afterwards it lists what needs work: translate new keys, review changed German, delete stale keys. LocalizationTests fails until then.
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

jq -r '.strings | to_entries[] | select(.value.shouldTranslate != false) |
    if .value.extractionState == "stale" then "stale, delete:       \(.key)"
    elif (.value.localizations.de // null) == null then "translate:           \(.key)"
    elif ([.value.localizations.de | .. | .state? // empty] | any(. != "translated")) then "review German:       \(.key)"
    else empty end' $catalog
