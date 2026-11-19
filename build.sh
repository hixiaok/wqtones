#!/bin/sh
# Build an unsigned WQTones.ipa on macOS with Xcode installed.
# No Xcode project, no xcodegen needed — just clang + the iPhoneOS SDK.
#
#   ./build.sh
#
# Result: WQTones-unsigned.ipa  (sign it with AltStore / SideStore / Impala)
set -e

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
APP="Payload/WQTones.app"

rm -rf build WQTones-unsigned.ipa
mkdir -p "$APP"

echo "→ compiling for arm64 (iOS 16.0+)"
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -isysroot "$SDK" \
  -mios-version-min=16.0 \
  -fobjc-arc \
  -O2 \
  -framework UIKit -framework Foundation -framework Security \
  -o "$APP/WQTones" Sources/main.m

cp Resources/* "$APP/"

cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleDisplayName</key><string>WQ Tones</string>
	<key>CFBundleExecutable</key><string>WQTones</string>
	<key>CFBundleIdentifier</key><string>com.wqtones.app</string>
	<key>CFBundleName</key><string>WQTones</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSRequiresIPhoneOS</key><true/>
	<key>MinimumOSVersion</key><string>16.0</string>
	<key>UILaunchScreen</key><dict/>
	<key>UIFileSharingEnabled</key><true/>
	<key>LSSupportsOpeningDocumentsInPlace</key><true/>
	<key>UISupportedInterfaceOrientations</key>
	<array><string>UIInterfaceOrientationPortrait</string></array>
	<key>UISupportedInterfaceOrientations~ipad</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationPortraitUpsideDown</string>
	</array>
</dict>
</plist>
PLIST

echo "→ packaging"
zip -qry WQTones-unsigned.ipa Payload
rm -rf Payload
echo "✓ WQTones-unsigned.ipa"
