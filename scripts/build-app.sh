#!/bin/zsh
# Builds a release Slideways.app bundle into ./build.
# Universal (Apple Silicon + Intel) so it runs on any Mac you share it with;
# pass --native for a quicker build for this Mac only.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Slideways"
BUNDLE="build/${APP_NAME}.app"

ARCHS=(--arch arm64 --arch x86_64)
[[ "${1:-}" == "--native" ]] && ARCHS=()

swift build -c release --product SlicksMac "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/SlicksMac"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/${APP_NAME}"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>com.example.slideways</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.racing-games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>GCSupportsControllerUserInteraction</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>${APP_NAME} finds and hosts online races with players on your network.</string>
    <key>NSBonjourServices</key><array><string>_slideways._udp</string></array>
    <key>UTExportedTypeDeclarations</key>
    <array><dict>
        <key>UTTypeIdentifier</key><string>com.slideways.track</string>
        <key>UTTypeDescription</key><string>Slideways Track</string>
        <key>UTTypeConformsTo</key><array><string>public.json</string></array>
        <key>UTTypeTagSpecification</key><dict>
            <key>public.filename-extension</key><array><string>slideways-track</string></array>
            <key>public.mime-type</key><string>application/vnd.slideways.track+json</string>
        </dict>
    </dict></array>
    <key>CFBundleDocumentTypes</key>
    <array><dict>
        <key>CFBundleTypeName</key><string>Slideways Track</string>
        <key>CFBundleTypeRole</key><string>Viewer</string>
        <key>LSHandlerRank</key><string>Owner</string>
        <key>LSItemContentTypes</key><array><string>com.slideways.track</string></array>
    </dict></array>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper lets it run locally.
codesign --force --sign - "$BUNDLE" >/dev/null
echo "Built $BUNDLE ($(lipo -archs "$BUNDLE/Contents/MacOS/${APP_NAME}"))"
