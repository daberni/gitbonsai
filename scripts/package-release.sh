#!/bin/zsh
# Packages a built app bundle as DMG and zip, and notarizes and staples both when notary credentials are present.
# Usage: scripts/package-release.sh <path to .app> [output directory, default: next to the app]
# Environment (all optional; without them the packages are built but not notarized):
#   GITBONSAI_SIGN_IDENTITY   signs the DMG with the same identity as the app; unset or "-" leaves the DMG unsigned
#   GITBONSAI_KEYCHAIN        keychain that holds the identity
#   Notary credentials, one of:
#     NOTARY_KEYCHAIN_PROFILE                         a profile stored with `xcrun notarytool store-credentials`
#     NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER    an App Store Connect API key (.p8)
#     NOTARY_APPLE_ID, NOTARY_PASSWORD, NOTARY_TEAM_ID an Apple ID with an app-specific password
# Prints the paths of the DMG and the zip, one per line, as its last output.
set -euo pipefail

app=${1:?usage: package-release.sh <app> [output directory]}
app=${app:A}
out=${2:-${app:h}}
out=${out:A}
mkdir -p $out
name=${app:t:r}
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
base="$out/${name// /-}-$version"
dmg="$base.dmg"
zip="$base.zip"
identity=${GITBONSAI_SIGN_IDENTITY:--}
work=$(mktemp -d)
trap 'rm -rf $work' EXIT

notary=()
if [[ -n ${NOTARY_KEYCHAIN_PROFILE:-} ]]; then
	notary=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n ${NOTARY_KEY_PATH:-} && -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_ISSUER:-} ]]; then
	notary=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [[ -n ${NOTARY_APPLE_ID:-} && -n ${NOTARY_PASSWORD:-} && -n ${NOTARY_TEAM_ID:-} ]]; then
	notary=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
fi
if (( ${#notary} )) && [[ $identity == - ]]; then
	echo "error: notarization needs a Developer ID signature; set GITBONSAI_SIGN_IDENTITY" >&2
	exit 1
fi

echo "› hdiutil create $dmg:t"
mkdir $work/dmg
ditto "$app" "$work/dmg/${app:t}"
ln -s /Applications $work/dmg/Applications
rm -f "$dmg"
hdiutil create -volname "$name" -srcfolder $work/dmg -fs APFS -format ULFO -ov "$dmg" >/dev/null
if [[ $identity != - ]]; then
	codesign --force --sign "$identity" ${GITBONSAI_KEYCHAIN:+--keychain "$GITBONSAI_KEYCHAIN"} --timestamp "$dmg"
fi

if (( ${#notary} )); then
	# The DMG's ticket covers the app inside it, so one submission lets both be stapled.
	echo "› notarytool submit $dmg:t"
	xcrun notarytool submit "$dmg" $notary --wait --timeout 30m --output-format json > $work/notary.json
	notary_status=$(plutil -extract status raw $work/notary.json)
	if [[ $notary_status != Accepted ]]; then
		cat $work/notary.json >&2
		xcrun notarytool log "$(plutil -extract id raw $work/notary.json)" $notary >&2 || true
		exit 1
	fi
	xcrun stapler staple "$dmg"
	xcrun stapler staple "$app"
	spctl --assess --type execute --verbose "$app"
else
	echo "› not notarized: no notary credentials (Gatekeeper will block the download until the user allows it in System Settings)"
fi

echo "› ditto $zip:t"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

echo "$dmg"
echo "$zip"
