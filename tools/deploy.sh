#!/bin/zsh
# Install the freshly built loader + dext, activate it, and get the new dext
# running without a replug (old instance is asked to restart via pfctl).
# Prints the driver log of the new instance.
set -u
cd "$(dirname "$0")/.."
APP=build/Build/Products/Debug/ProFireLoader.app
DEXT="$APP/Contents/Library/SystemExtensions/local.profire.Loader.ProFireOHCI.dext"
NEW=$(codesign -dvvv "$DEXT" 2>&1 | sed -n 's/^CDHash=//p')
VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEXT/Info.plist")
running() { ioreg -l -w0 -r -n 'pci11c1,5901@0' 2>/dev/null | sed -n 's/.*IOUserServerCDHash"="\([0-9a-f]*\)".*/\1/p' | head -1; }

echo "deploying $VER ($NEW), running: $(running)"
pkill -x ProFireLoader; sleep 1
rm -rf /Applications/ProFireLoader.app && cp -R "$APP" /Applications/
open /Applications/ProFireLoader.app --args --activate
for i in {1..30}; do
  systemextensionsctl list 2>/dev/null | grep -q "ProFireOHCI ($VER/.*activated enabled" && break
  sleep 1
done
systemextensionsctl list 2>/dev/null | grep ProFireOHCI

START=$(date '+%Y-%m-%d %H:%M:%S')
if [[ -n "$(running)" && "$(running)" != "$NEW" ]]; then
  echo "asking old instance to restart"
  build/pfctl restart || true
fi
for i in {1..40}; do
  [[ "$(running)" == "$NEW" ]] && break
  sleep 0.5
done
if [[ "$(running)" == "$NEW" ]]; then echo "NEW DRIVER RUNNING"; else echo "new driver NOT attached (running: $(running))"; fi
sleep ${SETTLE:-4}
/usr/bin/log show --start "$START" --style compact \
  --predicate 'eventMessage BEGINSWITH "ProFireOHCI: " OR (process == "kernel" AND eventMessage CONTAINS "ProFireOHCI")' 2>/dev/null \
  | sed -E 's/^[0-9-]+ ([0-9:.]+) [A-Za-z]+ +[^ ]+ (\(\) )?/\1 /' | grep -v '^Timestamp' | tail -${LINES_OUT:-80}
