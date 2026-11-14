#!/bin/sh
# Runs the UI tests in the Simulator against two servers it starts on scratch databases:
# one in local mode with seeded items, one in token mode with a fresh pairing code.
#   apple/uitest.sh                    all tests on the iPhone 18 Pro
#   apple/uitest.sh "Pendenz iPad"     on another simulator
#   apple/uitest.sh "iPhone 18 Pro" testReminderFires     one test
set -eu
cd "$(dirname "$0")/.."

device="${1:-iPhone 18 Pro}"
only="${2:-}"
work="$(mktemp -d)"
local_url="http://127.0.0.1:8792"
paired_url="http://127.0.0.1:8793"

cargo build --quiet --bin pendenz
bin="target/debug/pendenz"

local_pid=""
paired_pid=""
cleanup() {
    kill $local_pid $paired_pid 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

DATABASE_URL="sqlite://$work/local.db" PENDENZ_AUTH_MODE=local PENDENZ_BIND=127.0.0.1:8792 "$bin" >"$work/local.log" 2>&1 &
local_pid=$!
code="$(DATABASE_URL="sqlite://$work/paired.db" "$bin" pairing-code | sed 's/.*"code":"\([^"]*\)".*/\1/')"
DATABASE_URL="sqlite://$work/paired.db" PENDENZ_AUTH_MODE=token PENDENZ_BIND=127.0.0.1:8793 "$bin" >"$work/paired.log" 2>&1 &
paired_pid=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fs "$local_url/healthz" >/dev/null 2>&1 && curl -fs "$paired_url/healthz" >/dev/null 2>&1 && break
    sleep 0.5
done

seed() {
    curl -fs -X POST "$local_url/api/$1" -H 'Content-Type: application/json' \
        -H "Idempotency-Key: seed-$2" -d "$3" >/dev/null
}
seed projects project '{"name": "Testproject"}'
# For the trash and for deleting a project. The items are seeded first, so they sort below the
# rows that the drag test moves. The projects sort after Testproject by name: the iPad test
# drags a row onto Testproject, and its long press also opens the row's menu. With Testproject
# further down in the sidebar the simulated finger ended on "Complete" in that menu.
seed projects unused '{"name": "Unused project"}'
seed projects vacant '{"name": "Vacant project"}'
seed items unused-item '{"title": "Project item", "project_id": "unused-project"}'
seed items trashed '{"title": "Trashed item", "trashed": true}'
seed notes trashed-note '{"body": "Trashed note", "trashed": true}'
n=0
for title in "Drag A" "Drag B" "Drag C" "Swipe left" "Swipe right"; do
    n=$((n + 1))
    seed items "$n" "{\"title\": \"$title\"}"
done

# The app starts without stored rows. The two servers get a new database on every run under
# the same address, and a cursor left by an earlier run could lie below the new head: the app
# would then keep the old rows and miss some of the seeded ones.
xcrun simctl bootstatus "$device" -b >/dev/null 2>&1 || true
xcrun simctl uninstall "$device" ch.roadtofinal.pendenz>/dev/null 2>&1 || true

set -- test -project apple/Pendenz.xcodeproj -scheme Pendenz -destination "platform=iOS Simulator,name=$device"
if [ -n "$only" ]; then
    set -- "$@" "-only-testing:PendenzUITests/PendenzUITests/$only"
fi
TEST_RUNNER_PENDENZ_LOCAL="$local_url" TEST_RUNNER_PENDENZ_PAIRED="$paired_url" TEST_RUNNER_PENDENZ_CODE="$code" \
    xcodebuild "$@"
