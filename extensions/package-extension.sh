#!/bin/bash
# Opt-in packaging only: never installs a system extension or changes network settings.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/AILock.app}"
: "${AILOCK_HOST_PROFILE:?Set AILOCK_HOST_PROFILE to the approved host provisioning profile}"
MODE="${2:-filter}"
if [[ "$MODE" == 'filter' ]]; then
    : "${AILOCK_FILTER_PROFILE:?Set AILOCK_FILTER_PROFILE to the approved filter provisioning profile}"
    EXTENSION_PROFILE="$AILOCK_FILTER_PROFILE"; TARGET=FilterPrototype
elif [[ "$MODE" == 'audit' ]]; then
    : "${AILOCK_AUDIT_PROFILE:?Set AILOCK_AUDIT_PROFILE to the approved audit provisioning profile}"
    EXTENSION_PROFILE="$AILOCK_AUDIT_PROFILE"; TARGET=AuditPrototype
else
    echo 'Unknown extension mode' >&2; exit 1
fi
: "${SIGN_ID:?Set SIGN_ID to the matching Developer ID signing identity}"
[[ -d "$APP/Contents" ]] || { echo 'Build the application first.' >&2; exit 1; }
[[ "$SIGN_ID" != '-' ]] || { echo 'System extensions require a real signing identity.' >&2; exit 1; }
PACKAGE_DIR="$(mktemp -d /tmp/ailock-filter-package.XXXXXX)"
trap 'rm -rf "$PACKAGE_DIR"' EXIT
chmod 700 "$PACKAGE_DIR"
security cms -D -i "$AILOCK_HOST_PROFILE" > "$PACKAGE_DIR/host.plist"
security cms -D -i "$EXTENSION_PROFILE" > "$PACKAGE_DIR/filter.plist"
python3 - "$PACKAGE_DIR" "$MODE" "$APP" <<'PY'
import datetime, pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1]); mode = sys.argv[2]; teams = []
for name, identifier in [('host','com.laogu.ailock'),('filter','com.laogu.ailock.'+('filterprototype' if mode == 'filter' else 'auditprototype'))]:
    with (root/(name+'.plist')).open('rb') as f: profile = plistlib.load(f)
    expiry = profile.get('ExpirationDate')
    if not expiry or expiry <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
        raise SystemExit(name+': provisioning profile is expired or lacks expiration')
    ent = profile.get('Entitlements', {}); team = ent.get('com.apple.developer.team-identifier')
    if not team or team not in profile.get('TeamIdentifier', []): raise SystemExit(name+': invalid team')
    app_id = ent.get('com.apple.application-identifier', ent.get('application-identifier'))
    if app_id != team+'.'+identifier: raise SystemExit(name+': profile must match the exact bundle identifier')
    if (mode == 'filter' or (name == 'host' and pathlib.Path(sys.argv[3]+'/Contents/Library/SystemExtensions/FilterPrototype.systemextension').exists())) and 'content-filter-provider-systemextension' not in ent.get('com.apple.developer.networking.networkextension', []):
        raise SystemExit(name+': profile lacks content filter capability')
    if name == 'host' and ent.get('com.apple.developer.system-extension.install') is not True:
        raise SystemExit('host: profile lacks system extension installation capability')
    if name == 'filter' and mode == 'audit' and ent.get('com.apple.developer.endpoint-security.client') is not True:
        raise SystemExit('audit: profile lacks approved Endpoint Security capability')
    if mode == 'filter' or (name == 'host' and pathlib.Path(sys.argv[3]+'/Contents/Library/SystemExtensions/FilterPrototype.systemextension').exists()):
        group = team+'.com.laogu.ailock.filterprototype'
        if group not in ent.get('com.apple.security.application-groups', []):
            raise SystemExit(name+': profile lacks filter IPC application group '+group)
    teams.append(team)
    selected = {key:value for key,value in ent.items() if key in ['com.apple.application-identifier','application-identifier','com.apple.developer.team-identifier','com.apple.developer.networking.networkextension','com.apple.developer.system-extension.install','com.apple.developer.endpoint-security.client','com.apple.security.application-groups']}
    with (root/(name+'.entitlements')).open('wb') as f: plistlib.dump(selected,f)
if len(set(teams)) != 1: raise SystemExit('Host and filter must belong to the same team')
(root/'team').write_text(teams[0])
PY
TEAM_ID="$(cat "$PACKAGE_DIR/team")"
xcodebuild -project AILock.xcodeproj -scheme "$TARGET" -configuration Release \
    -derivedDataPath "$PACKAGE_DIR/derived" CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM="$TEAM_ID" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build > "$PACKAGE_DIR/build.log" 2>&1 || {
    tail -35 "$PACKAGE_DIR/build.log" >&2; exit 1;
}
EXTENSION="$PACKAGE_DIR/derived/Build/Products/Release/$TARGET.systemextension"
cp "$EXTENSION_PROFILE" "$EXTENSION/Contents/embedded.provisionprofile"
if [[ "$MODE" == 'audit' ]]; then
    /usr/libexec/PlistBuddy -c "Set :NSEndpointSecurityMachServiceName $TEAM_ID.com.laogu.ailock.auditprototype" "$EXTENSION/Contents/Info.plist"
else
    /usr/libexec/PlistBuddy -c "Set :NetworkExtension:NEMachServiceName $TEAM_ID.com.laogu.ailock.filterprototype" "$EXTENSION/Contents/Info.plist"
fi
codesign --force --options runtime --timestamp --entitlements "$PACKAGE_DIR/filter.entitlements" --sign "$SIGN_ID" "$EXTENSION"
codesign --verify --strict "$EXTENSION"
# Ensure the actual signing certificate is authorized by each profile.
codesign --display --extract-certificates "$PACKAGE_DIR/cert-" "$EXTENSION" 2>/dev/null
python3 - "$PACKAGE_DIR" <<'PY'
import pathlib, plistlib, sys
root=pathlib.Path(sys.argv[1]); certificate=(root/'cert-0').read_bytes()
for name in ['host','filter']:
    profile=plistlib.loads((root/(name+'.plist')).read_bytes())
    if certificate not in profile.get('DeveloperCertificates', []): raise SystemExit(name+': signing certificate is not authorized by profile')
PY
mkdir -p "$APP/Contents/Library/SystemExtensions"
# Copy only after validation succeeds; final signing failure remains an explicit build failure.
/usr/bin/ditto "$EXTENSION" "$APP/Contents/Library/SystemExtensions/$TARGET.systemextension"
cp "$AILOCK_HOST_PROFILE" "$APP/Contents/embedded.provisionprofile"
codesign --force --options runtime --timestamp --entitlements "$PACKAGE_DIR/host.entitlements" --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "Packaged and signed $MODE extension. No installation or activation performed."
