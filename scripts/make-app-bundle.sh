#!/bin/zsh
# Builds the app bundle: release binary, its resource bundle with the compiled String Catalog, Info.plist, the compiled app icon (Assets.car plus a classic .icns) and a signature.
# Usage: scripts/make-app-bundle.sh [--release] [output directory, default .build/app]
#   Without --release it builds "GitBonsai Dev.app" with bundle id app.gitbonsai.dev, so a bundle built for trying out never shares defaults, open tabs or settings with an installed release.
#   --release builds GitBonsai.app with bundle id app.gitbonsai.
# Environment:
#   GITBONSAI_VERSION   marketing version; default: the tag on HEAD (v1.2.3 → 1.2.3), else the latest tag, else 0.1
#   GITBONSAI_BUILD     build number; default: the commit count of HEAD
#   GITBONSAI_SIGN_IDENTITY  codesign identity ("Developer ID Application: …" or its SHA-1); signs with hardened runtime and a secure timestamp. Unset or "-" signs ad hoc.
#   GITBONSAI_KEYCHAIN  keychain that holds the identity (CI uses a temporary one)
set -euo pipefail

root=${0:A:h:h}
variant=dev
if [[ ${1:-} == --release ]]; then variant=release; shift; fi
out=${1:-$root/.build/app}
if [[ $variant == release ]]; then
	name=GitBonsai
	bundle_id=app.gitbonsai
else
	name="GitBonsai Dev"
	bundle_id=app.gitbonsai.dev
fi
app="$out/$name.app"
icon=$root/docs/design/app-icon/AppIcon.icon

tag=$(git -C $root describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null || git -C $root describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)
version=${GITBONSAI_VERSION:-${${tag#v}:-0.1}}
build=${GITBONSAI_BUILD:-$(git -C $root rev-list --count HEAD)}
identity=${GITBONSAI_SIGN_IDENTITY:--}
work=$(mktemp -d)
trap 'rm -rf $work' EXIT

echo "› $name $version ($build), $bundle_id"
echo "› swift build -c release --product GitBonsaiApp"
swift build --package-path $root -c release --product GitBonsaiApp
bin=$(swift build --package-path $root -c release --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp $bin/GitBonsaiApp "$app/Contents/MacOS/GitBonsai"
# Bundle.module looks for SwiftPM's resource bundle in Contents/Resources; it holds en.lproj and de.lproj compiled from Localizable.xcstrings.
cp -R $bin/GitBonsai_GitBonsaiApp.bundle "$app/Contents/Resources/"

# actool turns the layered Icon Composer document into Assets.car, which macOS 26 renders in every appearance.
echo "› actool AppIcon.icon"
xcrun actool $icon --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist $work/icon.plist --errors --warnings >/dev/null

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>$name</string>
	<key>CFBundleExecutable</key>
	<string>GitBonsai</string>
	<key>CFBundleLocalizations</key>
	<array>
$(for lproj in "$app"/Contents/Resources/GitBonsai_GitBonsaiApp.bundle/Contents/Resources/*.lproj; do echo "		<string>${lproj:t:r}</string>"; done)
	</array>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Folder</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>None</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.folder</string>
			</array>
		</dict>
	</array>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIconName</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$bundle_id</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$name</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$build</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

# actool's own AppIcon.icns holds only 16 and 128 pt; replace it with every classic size rendered from the compiled icon.
echo "› AppIcon.icns"
swift $root/scripts/app-icon-iconset.swift "$app" $work/AppIcon.iconset
iconutil -c icns $work/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"

if [[ $identity == - ]]; then
	echo "› codesign (ad hoc)"
	codesign --force --sign - --timestamp=none "$app"
else
	# Hardened runtime and a secure timestamp are what notarization requires; the app needs no entitlements, since running /usr/bin/git is allowed under the hardened runtime.
	echo "› codesign ($identity, hardened runtime)"
	codesign --force --sign "$identity" ${GITBONSAI_KEYCHAIN:+--keychain "$GITBONSAI_KEYCHAIN"} --options runtime --timestamp "$app"
fi
codesign --verify --deep --strict "$app"

echo "$app"
