#!/bin/bash
# Builds Glass Rail for the App Store and, when App Store Connect credentials are configured,
# uploads it to TestFlight. See TESTFLIGHT.md.
#
# No Mac, certificates or provisioning profiles are needed. The archive is ad-hoc signed (which
# embeds the App Group entitlement without any certificate), and Xcode signs it for distribution
# during export with a cloud-managed certificate, using the App Store Connect API key.
#
# Environment:
#   BUILD_NUMBER                  required, e.g. "12.1" (must grow with every upload)
#   APPLE_TEAM_ID, ASC_KEY_ID,    optional; without all four the script stops after a dry-run
#   ASC_ISSUER_ID, ASC_KEY_P8     archive. ASC_KEY_P8 is the text of the AuthKey_XXXX.p8 file.
set -euo pipefail

OUT="${RUNNER_TEMP:-/tmp}/testflight"
ARCHIVE="$OUT/GlassRail.xcarchive"
rm -rf "$OUT"
mkdir -p "$OUT"

if [ ! -d GlassRail.xcodeproj ]; then
  bash .github/scripts/generate-project.sh
fi

prefix=$(sed -n 's/^GLASSRAIL_BUNDLE_ID_PREFIX *= *//p' Config/Shared.xcconfig | tr -d '[:space:]')
app_id="$prefix.GlassRail"
group="group.$prefix.GlassRail"

echo "▶ Archiving Glass Rail $app_id, build $BUILD_NUMBER"
if ! xcodebuild archive \
    -project GlassRail.xcodeproj \
    -scheme GlassRail \
    -configuration Release \
    -destination generic/platform=iOS \
    -archivePath "$ARCHIVE" \
    -skipPackagePluginValidation \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    PROVISIONING_PROFILE_SPECIFIER= \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" > "$OUT/archive.log" 2>&1; then
  bash .github/scripts/annotate-errors.sh "$OUT/archive.log" "App Store archive"
  echo "::error::The App Store build failed. See the errors above."
  exit 1
fi
grep -E "warning:" "$OUT/archive.log" | sort -u | head -20 || true

# The export keeps whatever entitlements the archive carries, so check them now.
app="$ARCHIVE/Products/Applications/GlassRail.app"
widget="$app/PlugIns/GlassRailWidgets.appex"
if [ ! -d "$widget" ]; then
  echo "::error::The widget extension is not embedded in the app ($widget is missing)."
  exit 1
fi
for bundle in "$app" "$widget"; do
  entitlements=$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null || true)
  echo "Entitlements of ${bundle##*/}: $(echo "$entitlements" | plutil -convert json -o - - 2>/dev/null || echo "$entitlements")"
  if [[ "$entitlements" != *"$group"* ]]; then
    echo "::error::${bundle##*/} is missing the App Group $group, so the widget couldn't share the destination with the app."
    exit 1
  fi
done
echo "::notice title=App Store archive::Both bundles carry the App Group $group."
# iPhone only: an iPad-capable bundle must support every orientation, which this app does not.
family=$(plutil -extract UIDeviceFamily json -o - "$app/Info.plist" 2>/dev/null || true)
if [ "$family" != "[1]" ]; then
  echo "::error::The app declares device family ${family:-none}; it must be [1] (iPhone only)."
  exit 1
fi
# App Store Connect rejects a bundle without this key (error 90474), so catch it here.
if ! plutil -extract UISupportedInterfaceOrientations json -o - "$app/Info.plist" >/dev/null 2>&1; then
  echo "::error::Info.plist has no UISupportedInterfaceOrientations, which App Store Connect rejects."
  exit 1
fi
plutil -p "$app/Info.plist" | grep -E '"CFBundleIdentifier"|"CFBundleDisplayName"|"CFBundleShortVersionString"|"CFBundleVersion"|ITSAppUsesNonExemptEncryption|"MinimumOSVersion"' || true
plutil -p "$widget/Info.plist" | grep -E '"CFBundleIdentifier"|NSExtensionPointIdentifier' || true

if [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ] || [ -z "${ASC_KEY_P8:-}" ]; then
  echo "::notice::App Store build OK. Nothing was uploaded: add the App Store Connect secrets (see TESTFLIGHT.md) to send builds to TestFlight."
  exit 0
fi

key="$OUT/AuthKey_$ASC_KEY_ID.p8"
# Accept the .p8 text however it was pasted: Windows line endings, or without the BEGIN/END lines.
p8=$(printf '%s' "$ASC_KEY_P8" | tr -d '\r')
if [[ "$p8" != *"BEGIN PRIVATE KEY"* ]]; then
  p8=$(printf -- '-----BEGIN PRIVATE KEY-----\n%s\n-----END PRIVATE KEY-----' "$(printf '%s' "$p8" | tr -d ' \n' | fold -w 64)")
fi
(umask 077 && printf '%s\n' "$p8" > "$key")
unset p8
trap 'rm -f "$key"' EXIT

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$APPLE_TEAM_ID</string>
	<key>testFlightInternalTestingOnly</key>
	<true/>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
EOF

echo "▶ Signing and uploading to App Store Connect"
if ! xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/export" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$key" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" > "$OUT/export.log" 2>&1; then
  tail -n 60 "$OUT/export.log"
  log=$(cat "$OUT/export.log")
  hint="See TESTFLIGHT.md."
  case "$log" in
    *"No suitable application records"*|*"Cannot determine the Apple ID from Bundle ID"*)
      hint="The App Store Connect app record for $app_id was not found. Check the bundle ID matches exactly." ;;
    *"com.apple.security.application-groups"*|*"App Group"*)
      hint="Turn on the App Group $group for both $app_id and $app_id.Widgets on developer.apple.com." ;;
    *"NOT_AUTHORIZED"*|*"not authorized"*|*"credentials are missing or invalid"*|*"loud signing permission"*|*"does not have permission"*|*"invalid key"*|*"Invalid key"*)
      hint="Check the API key: it needs the Admin role, and ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 must all come from that key." ;;
    *"bundle version must be higher"*)
      hint="That build number was already used. Run the workflow again to get a new one." ;;
  esac
  echo "::error::Upload to TestFlight failed. $hint"
  exit 1
fi
grep -iE "upload|success|export" "$OUT/export.log" | tail -n 5 || true
echo "::notice::Uploaded Glass Rail build $BUILD_NUMBER. It shows up in TestFlight once Apple finishes processing it, usually within 5-30 minutes."
