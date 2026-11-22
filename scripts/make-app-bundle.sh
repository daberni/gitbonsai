#!/bin/zsh
# Builds GitBonsai.app: release binary, Info.plist, the compiled app icon (Assets.car plus a classic .icns) and an ad-hoc signature.
# Usage: scripts/make-app-bundle.sh [output directory, default .build/app]
set -euo pipefail

root=${0:A:h:h}
out=${1:-$root/.build/app}
app=$out/GitBonsai.app
icon=$root/docs/design/app-icon/AppIcon.icon
version=0.1
build=$(git -C $root rev-list --count HEAD)
work=$(mktemp -d)
trap 'rm -rf $work' EXIT

echo "› swift build -c release --product GitBonsaiApp"
swift build --package-path $root -c release --product GitBonsaiApp
bin=$(swift build --package-path $root -c release --show-bin-path)

rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp $bin/GitBonsaiApp $app/Contents/MacOS/GitBonsai

# actool turns the layered Icon Composer document into Assets.car, which macOS 26 renders in every appearance.
echo "› actool AppIcon.icon"
xcrun actool $icon --compile $app/Contents/Resources --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist $work/icon.plist --errors --warnings >/dev/null

cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>GitBonsai</string>
	<key>CFBundleExecutable</key>
	<string>GitBonsai</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIconName</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>app.gitbonsai</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>GitBonsai</string>
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
swift $root/scripts/app-icon-iconset.swift $app $work/AppIcon.iconset
iconutil -c icns $work/AppIcon.iconset -o $app/Contents/Resources/AppIcon.icns

echo "› codesign (ad hoc)"
codesign --force --sign - --timestamp=none $app
codesign --verify --strict $app

echo $app
