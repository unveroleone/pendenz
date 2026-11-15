#!/usr/bin/env bash
# Builds the Mac app signed with Developer ID, puts it in a notarized DMG, publishes the DMG as
# the GitHub release mac-v<version> and adds it to the Sparkle feed apple/appcast.xml on main.
#
#   apple/release-mac.sh <version> <release notes.md>
#
# Runs on the Mac that holds the Developer ID certificate and the Sparkle key, never in CI.
# It reads the team and the App Store Connect API key from the environment:
#
#   PENDENZ_TEAM        the team ID
#   ASC_KEY_ID          the API key's ID
#   ASC_ISSUER_ID       the API key's issuer
#   ASC_KEY_PATH        the .p8 file (default ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8)
#   SPARKLE_ACCOUNT     the Keychain account of the Sparkle key (default pendenz)
#   PENDENZ_BUNDLE_ID   the app's bundle ID (default ch.roadtofinal.pendenz)
#   APP_PROFILE         the app's Developer ID provisioning profile (default "Pendenz Developer ID")
#   WIDGETS_PROFILE     the widget extension's (default "Pendenz Widgets Developer ID")
#
# The API key cannot make Developer ID profiles, so both are made by hand in the developer
# portal (Profiles, Developer ID, Mac) and installed in
# ~/Library/Developer/Xcode/UserData/Provisioning Profiles under their UUID.
#
# The build number is the number of commits on main, so every release from a later commit has
# a higher one, which is what Sparkle compares.
set -euo pipefail

usage() {
    echo "usage: apple/release-mac.sh <version> <release notes.md>" >&2
    exit 64
}

fail() {
    echo "release-mac: $*" >&2
    exit 1
}

[[ $# -eq 2 ]] || usage
version=$1
notes=$2
tag="mac-v$version"

[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the version must look like 1.2.3"
[[ -s $notes ]] || fail "no release notes at $notes"
[[ $notes == *.md ]] || fail "the release notes must be a .md file"

: "${PENDENZ_TEAM:?set PENDENZ_TEAM to the team ID}"
: "${ASC_KEY_ID:?set ASC_KEY_ID to the App Store Connect API key ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID to the API key issuer}"
key_path=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
account=${SPARKLE_ACCOUNT:-pendenz}
bundle_id=${PENDENZ_BUNDLE_ID:-ch.roadtofinal.pendenz}
app_profile=${APP_PROFILE:-Pendenz Developer ID}
widgets_profile=${WIDGETS_PROFILE:-Pendenz Widgets Developer ID}
[[ -f $key_path ]] || fail "no API key at $key_path"

# Both paths are used after the script moves to the top of the repository.
key_path=$(cd "$(dirname "$key_path")" && pwd)/$(basename "$key_path")
notes=$(cd "$(dirname "$notes")" && pwd)/$(basename "$notes")
here=$(cd "$(dirname "$0")" && pwd)
cd "$(git rev-parse --show-toplevel)"

# The release is built from main as it is on GitHub, so the tag names the code that was built.
[[ $(git rev-parse --abbrev-ref HEAD) == main ]] || fail "check out main first"
[[ -z $(git status --porcelain) ]] || fail "the working tree has changes"
git fetch --quiet origin main --tags
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || fail "main is not the same as origin/main"
! git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null || fail "the tag $tag exists already"

repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
commit=$(git rev-parse HEAD)
build=$(git rev-list --count HEAD)

feed=apple/appcast.xml
if [[ -f $feed ]]; then
    last=$(grep -o '<sparkle:version>[0-9]*' "$feed" | grep -o '[0-9]*$' | sort -n | tail -1 || true)
    if [[ -n $last ]] && ((build <= last)); then
        fail "build $build is not above $last, the newest in the feed: commit something first"
    fi
fi

identity=$(security find-identity -v -p codesigning \
    | grep "\"Developer ID Application: .*($PENDENZ_TEAM)\"" \
    | head -1 | awk '{print $2}' || true)
[[ -n $identity ]] || fail "no Developer ID Application certificate of $PENDENZ_TEAM in the Keychain"

auth=(
    -allowProvisioningUpdates
    -authenticationKeyPath "$key_path"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

work=$(mktemp -d "${TMPDIR:-/tmp}/pendenz-release.XXXXXX")
echo "Working in $work"

echo "==> Archiving Pendenz $version ($build)"
xcodebuild archive \
    -project apple/Pendenz.xcodeproj \
    -scheme Pendenz \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$work/Pendenz.xcarchive" \
    -derivedDataPath "$work/DerivedData" \
    -onlyUsePackageVersionsFromResolvedFile \
    "${auth[@]}" \
    DEVELOPMENT_TEAM="$PENDENZ_TEAM" \
    PENDENZ_MAC_SIGNING=developerid \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build" \
    -quiet

# An update signed with another key than the one in the app is refused by every installed
# copy, and generate_appcast only warns about it.
bin="$work/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x $bin/generate_appcast ]] || fail "the Sparkle tools are missing from $bin"
archived_app="$work/Pendenz.xcarchive/Products/Applications/Pendenz.app"
app_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$archived_app/Contents/Info.plist")
keychain_key=$("$bin/generate_keys" --account "$account" -p 2>/dev/null || true)
[[ -n $app_key && $app_key == "$keychain_key" ]] \
    || fail "the Sparkle key of account $account does not match SUPublicEDKey in the app"

echo "==> Exporting with Developer ID"
cat >"$work/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>teamID</key>
	<string>$PENDENZ_TEAM</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$bundle_id</key>
		<string>$app_profile</string>
		<key>$bundle_id.widgets</key>
		<string>$widgets_profile</string>
	</dict>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
    -archivePath "$work/Pendenz.xcarchive" \
    -exportPath "$work/export" \
    -exportOptionsPlist "$work/ExportOptions.plist" \
    -quiet
app="$work/export/Pendenz.app"

echo "==> Checking the app's signature"
codesign --verify --deep --strict "$app"
# -dvv: the Authority lines need the second level of detail.
signature=$(codesign -dvv "$app" 2>&1)
grep -q "^Authority=Developer ID Application: .*($PENDENZ_TEAM)$" <<<"$signature" \
    || fail "the app is not signed with Developer ID"
grep -q 'flags=.*runtime' <<<"$signature" || fail "the app has no hardened runtime"
codesign -d --entitlements - --xml "$app" >"$work/entitlements.plist" 2>/dev/null
entitlement() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$work/entitlements.plist" 2>/dev/null || true
}
[[ $(entitlement com.apple.developer.aps-environment) == production ]] \
    || fail "push is not set to production in the app's entitlements"
[[ $(entitlement com.apple.security.get-task-allow) != true ]] || fail "the app can still be debugged"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist") == "$build" ]] \
    || fail "the app's build number is not $build"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist") == "$version" ]] \
    || fail "the app's version is not $version"

echo "==> Making the DMG"
mkdir -p "$work/updates"
dmg="$work/updates/Pendenz-$version.dmg"
"$here/dmg/make-dmg.sh" "$app" "$dmg"
codesign --sign "$identity" --timestamp "$dmg"

echo "==> Notarizing (this takes a few minutes)"
xcrun notarytool submit "$dmg" \
    --key "$key_path" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    --wait --output-format json >"$work/notary.json"
status=$(plutil -extract status raw -o - "$work/notary.json")
if [[ $status != Accepted ]]; then
    id=$(plutil -extract id raw -o - "$work/notary.json")
    xcrun notarytool log "$id" --key "$key_path" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" >&2 || true
    fail "notarization ended with $status"
fi
xcrun stapler staple -q "$dmg"
spctl -a -t open --context context:primary-signature -vv "$dmg"
spctl -a -t exec -vv "$app"

echo "==> Writing the feed"
if [[ -f $feed ]]; then
    cp "$feed" "$work/updates/appcast.xml"
fi
cp "$notes" "$work/updates/Pendenz-$version.md"
"$bin/generate_appcast" \
    --account "$account" \
    --download-url-prefix "https://github.com/$repo/releases/download/$tag/" \
    --embed-release-notes \
    --maximum-deltas 0 \
    --maximum-versions 0 \
    "$work/updates"
signature_path="//*[local-name()='item'][*[local-name()='version' and text()='$build']]"
signature_path+="/*[local-name()='enclosure']/@*[local-name()='edSignature']"
xmllint --xpath "string($signature_path)" "$work/updates/appcast.xml" 2>/dev/null | grep -q . \
    || fail "the feed has no signed entry for build $build"

# The build took a while: main, the tag and the working tree must still be as they were.
git fetch --quiet origin main --tags
[[ $(git rev-parse origin/main) == "$commit" ]] || fail "origin/main moved during the build; nothing was published"
[[ $(git rev-parse HEAD) == "$commit" ]] || fail "HEAD moved during the build; nothing was published"
[[ -z $(git status --porcelain) ]] || fail "the working tree changed during the build; nothing was published"
[[ -z $(git ls-remote --tags origin "refs/tags/$tag") ]] || fail "the tag $tag exists on GitHub already"

echo
echo "Ready to publish Pendenz for Mac $version (build $build) from $commit:"
echo "  - the GitHub release $tag in $repo, with $(basename "$dmg")"
echo "  - the feed $feed, committed and pushed to main"
read -r -p "Publish? [y/N] " answer
[[ $answer == [yY] ]] || fail "nothing was published; the build is in $work"

# The DMG goes up before the feed names it, so no copy of the app looks for a missing file.
gh release create "$tag" "$dmg" \
    --repo "$repo" \
    --target "$commit" \
    --title "Pendenz for Mac $version" \
    --notes-file "$notes" \
    --latest=false

cp "$work/updates/appcast.xml" "$feed"
git add "$feed"
git commit --quiet -m "chore: publish Pendenz for Mac $version"
git push --quiet origin main \
    || fail "the release $tag is public, but the feed did not reach main: run git pull --rebase origin main && git push origin main"

echo "Published https://github.com/$repo/releases/tag/$tag"
echo "Keep $work/Pendenz.xcarchive for its symbols, then delete $work."
