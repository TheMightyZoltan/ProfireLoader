#!/bin/zsh
# Build the ProFire loader app with the embedded ProFireOHCI dext.
# Usage:  ./build.sh            (ad-hoc, for SIP-disabled testing)
#         TEAM=ABCDE12345 ./build.sh   (team-signed, needs DriverKit PCI entitlement)
set -euo pipefail
cd "$(dirname "$0")"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode is required (DriverKit SDK + iig). Install it from the App Store, then run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi
xcodebuild -showsdks | grep -qi driverkit || { echo "DriverKit SDK not found in this Xcode."; exit 1; }
command -v xcodegen >/dev/null || brew install xcodegen

xcodegen generate -q

TEAM_ARGS=()
[[ -n "${TEAM:-}" ]] && TEAM_ARGS=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates)

xcodebuild -project ProFireDriver.xcodeproj -scheme ProFireLoader -configuration Debug \
  -derivedDataPath build "${TEAM_ARGS[@]}" build

APP=build/Build/Products/Debug/ProFireLoader.app
echo
echo "Built: $APP"
ls "$APP/Contents/Library/SystemExtensions/"
echo
echo "Install with:  rm -rf /Applications/ProFireLoader.app && cp -R $APP /Applications/ && open /Applications/ProFireLoader.app"
