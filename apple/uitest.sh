#!/bin/sh
# Runs the UI tests in the Simulator against two servers it starts on scratch databases:
# one in local mode with seeded items, one in token mode with a fresh pairing code.
#   apple/uitest.sh                    all tests on the iPhone 18 Pro
#   apple/uitest.sh "Pendenz iPad"     on another simulator
#   apple/uitest.sh "iPhone 18 Pro" testReminderFires     one test
# PENDENZ_UITEST_SIMULATOR names the simulator when no argument does. PENDENZ_UITEST_LOCAL_PORT
# and PENDENZ_UITEST_PAIRED_PORT move the two servers off 8792 and 8793. Two runs side by side
# need their own ports and their own simulator, since each removes the app from its simulator
# first, and their own checkout, since xcodebuild and cargo build in it.
# PENDENZ_UITEST_FRAMES=<dir> also saves a screenshot of the simulator about once a second into
# <dir> while the tests run. The recorder stops with the script, also when the script is killed,
# and after 1500 frames at most.
set -eu
cd "$(dirname "$0")/.."

device="${1:-${PENDENZ_UITEST_SIMULATOR:-iPhone 18 Pro}}"
only="${2:-}"
local_port="${PENDENZ_UITEST_LOCAL_PORT:-8792}"
paired_port="${PENDENZ_UITEST_PAIRED_PORT:-8793}"
for port in "$local_port" "$paired_port"; do
    case "$port" in
    '' | *[!0-9]*)
        echo "Not a port: $port" >&2
        exit 1
        ;;
    esac
done
if [ "$local_port" = "$paired_port" ]; then
    echo "The two servers need different ports, both are $local_port." >&2
    exit 1
fi
local_url="http://127.0.0.1:$local_port"
paired_url="http://127.0.0.1:$paired_port"
work="$(mktemp -d)"

cargo build --quiet --bin pendenz
bin="target/debug/pendenz"

# A server left on a port, or another run's, would answer for ours: the tests would then seed
# and run against it without noticing.
for port in "$local_port" "$paired_port"; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo "Port $port is in use. Set PENDENZ_UITEST_LOCAL_PORT and PENDENZ_UITEST_PAIRED_PORT to free ports." >&2
        exit 1
    fi
done

local_pid=""
paired_pid=""
recorder_pid=""
cleanup() {
    kill $recorder_pid $local_pid $paired_pid 2>/dev/null || true
    rm -rf "$work"
}
# EXIT alone does not run when the script is ended by a signal, which left the servers and a
# screenshot loop running after a killed run.
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

DATABASE_URL="sqlite://$work/local.db" PENDENZ_AUTH_MODE=local PENDENZ_BIND="127.0.0.1:$local_port" "$bin" >"$work/local.log" 2>&1 &
local_pid=$!
code="$(DATABASE_URL="sqlite://$work/paired.db" "$bin" pairing-code | sed 's/.*"code":"\([^"]*\)".*/\1/')"
DATABASE_URL="sqlite://$work/paired.db" PENDENZ_AUTH_MODE=token PENDENZ_BIND="127.0.0.1:$paired_port" "$bin" >"$work/paired.log" 2>&1 &
paired_pid=$!

# Ready only when our own processes listen: if another run took a port in the meantime, ours
# failed to bind and the other run's server would answer the health check.
listens() {
    [ "$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null)" = "$2" ]
}
up=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if listens "$local_port" "$local_pid" && listens "$paired_port" "$paired_pid" &&
        curl -fs "$local_url/healthz" >/dev/null 2>&1 && curl -fs "$paired_url/healthz" >/dev/null 2>&1; then
        up=yes
        break
    fi
    sleep 0.5
done
if [ -z "$up" ]; then
    echo "The test servers did not start on ports $local_port and $paired_port:" >&2
    cat "$work/local.log" "$work/paired.log" >&2
    exit 1
fi

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
seed items paragraphs '{"title": "Paragraphs"}'
# For the search. Its ID goes to the test, so the order of the seeds does not matter.
searched="$(curl -fs -X POST "$local_url/api/items" -H 'Content-Type: application/json' \
    -H 'Idempotency-Key: seed-search' \
    -d '{"title": "Lighthouse keeper", "description": "Bring the brass lantern", "tags": ["coastal"]}')"
search_id="$(printf '%s' "$searched" | sed 's/.*[{,]"id":\([0-9]*\).*/\1/')"
case "$search_id" in
'' | *[!0-9]*)
    echo "The search item was not seeded: $searched" >&2
    exit 1
    ;;
esac
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

# The recorder also checks that this script is still alive, so it ends even after a kill -9.
frames="${PENDENZ_UITEST_FRAMES:-}"
if [ -n "$frames" ]; then
    mkdir -p "$frames"
    script_pid=$$
    (
        i=0
        while [ "$i" -lt 1500 ] && kill -0 "$script_pid" 2>/dev/null; do
            i=$((i + 1))
            xcrun simctl io "$device" screenshot --type=jpeg "$frames/f$(printf %04d "$i").jpg" >/dev/null 2>&1 || true
            sleep 0.6
        done
    ) &
    recorder_pid=$!
fi

TEST_RUNNER_PENDENZ_LOCAL="$local_url" TEST_RUNNER_PENDENZ_PAIRED="$paired_url" TEST_RUNNER_PENDENZ_CODE="$code" \
    TEST_RUNNER_PENDENZ_SEARCH_ID="$search_id" \
    xcodebuild "$@"
