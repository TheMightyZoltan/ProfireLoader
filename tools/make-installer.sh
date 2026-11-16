#!/bin/zsh
# Build the release installer from the current build (run ./build.sh first):
#   tools/make-installer.sh 0.5
# Produces build/release/ProFire2626-<ver>.pkg (app + embedded driver, activates the
# driver after install) and ProFireControl-<ver>.zip (the app alone).
set -euo pipefail
cd "$(dirname "$0")/.."
VER=${1:?usage: make-installer.sh <version>}
APP=build/Build/Products/Debug/ProFireLoader.app
[[ -d $APP ]] || { echo "build first: ./build.sh"; exit 1; }
FULL=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
OUT=build/release; WORK=build/pkgwork
rm -rf $WORK; mkdir -p $WORK/root/Applications $WORK/root/Library/LaunchAgents $WORK/scripts $WORK/res $OUT
ditto "$APP" $WORK/root/Applications/ProFireLoader.app
# Opens ProFire Control when the driver reports a ProFire (see tools/profire-launch.swift).
cp tools/launchd/local.profire.autolaunch.plist $WORK/root/Library/LaunchAgents/
chmod 644 $WORK/root/Library/LaunchAgents/local.profire.autolaunch.plist

cat > $WORK/scripts/preinstall <<'EOF'
#!/bin/sh
pkill -x ProFireLoader 2>/dev/null
USER_ID=$(id -u "$(stat -f %Su /dev/console)")
launchctl bootout gui/$USER_ID/local.profire.autolaunch 2>/dev/null
exit 0
EOF

cat > $WORK/scripts/postinstall <<'EOF'
#!/bin/sh
# Driver extensions without an Apple-issued DriverKit entitlement only load with SIP
# disabled and system extension developer mode on.
if csrutil status | grep -q disabled; then
    systemextensionsctl developer on >/dev/null 2>&1 || true
fi
# Ask the system to activate the embedded driver, as the logged-in user.
USER_NAME=$(stat -f %Su /dev/console)
USER_ID=$(id -u "$USER_NAME")
# Auto-open agent: load it now for the logged-in user (later logins load it automatically).
chown root:wheel /Library/LaunchAgents/local.profire.autolaunch.plist
chmod 644 /Library/LaunchAgents/local.profire.autolaunch.plist
launchctl bootstrap gui/$USER_ID /Library/LaunchAgents/local.profire.autolaunch.plist 2>/dev/null || true
launchctl asuser "$USER_ID" sudo -u "$USER_NAME" open -n /Applications/ProFireLoader.app --args --activate || true
exit 0
EOF
chmod +x $WORK/scripts/*

pkgbuild --analyze --root $WORK/root $WORK/components.plist >/dev/null
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" $WORK/components.plist
pkgbuild --root $WORK/root --component-plist $WORK/components.plist --scripts $WORK/scripts \
  --identifier local.profire.pkg --version "$FULL" --install-location / $WORK/ProFire.pkg

cat > $WORK/res/welcome.html <<EOF
<html><body style="font-family: -apple-system; font-size: 13px">
<h2>ProFire 2626 driver $VER</h2>
<p>Installs <b>ProFire Control</b> (/Applications/ProFireLoader.app) with the embedded FireWire / audio
driver for the M-Audio ProFire 2626 on Apple silicon Macs (FireWire through a Thunderbolt dock with an
LSI FW643 controller, e.g. the Belkin Thunderbolt Express Dock).</p>
<p><b>Before installing:</b></p>
<ul>
<li>System Integrity Protection must be <b>disabled</b> (the driver is not signed by Apple).</li>
<li>The installer turns on system extension developer mode.</li>
</ul>
<p><b>After installing:</b> the Mac restarts so the new driver replaces the old one cleanly (macOS
cannot swap a running FireWire driver reliably). On a first install, approve the driver in System Settings ›
General › Login Items &amp; Extensions › Driver Extensions.</p>
</body></html>
EOF

cat > $WORK/distribution.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>ProFire 2626 Driver $VER</title>
    <welcome file="welcome.html"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <allowed-os-versions><os-version min="15.0"/></allowed-os-versions>
    <choices-outline><line choice="default"><line choice="local.profire.pkg"/></line></choices-outline>
    <choice id="default"/>
    <choice id="local.profire.pkg" visible="false"><pkg-ref id="local.profire.pkg"/></choice>
    <pkg-ref id="local.profire.pkg" version="$FULL" onConclusion="RequireRestart">ProFire.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild --distribution $WORK/distribution.xml --resources $WORK/res --package-path $WORK \
  $OUT/ProFire2626-$VER.pkg
rm -f $OUT/ProFireControl-$VER.zip
ditto -c -k --keepParent "$APP" $OUT/ProFireControl-$VER.zip
ls -la $OUT
