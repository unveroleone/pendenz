#!/bin/bash
# Runs the checks for what a change touches and writes a record of them.
#   .claude/skills/verify/run.sh quick            after each step of a change
#   .claude/skills/verify/run.sh full             once before the pull request
#   --base <ref>     compare with this ref instead of the merge base with origin/main
#   --all            run the checks of every part, whatever changed
#   --ipad <name>    full only: also run the UI tests on the iPad simulator of that name
# Every check runs, also after one has failed. The record goes to verify/last-<tier> in the
# worktree's git directory (git rev-parse --git-path verify), the output of each check next to it.
# The UI tests take a lock so that two runs on one machine wait for each other, unless
# PENDENZ_UITEST_SIMULATOR or the port variables of apple/uitest.sh give this run its own.
set -u
cd "$(git rev-parse --show-toplevel)"
export CARGO_TERM_COLOR=never

tier="${1:-}"
case "$tier" in
quick | full) shift ;;
*)
    echo "Usage: $0 quick|full [--base <ref>] [--all] [--ipad <simulator>]" >&2
    exit 2
    ;;
esac

base=""
all=""
ipad=""
while [ $# -gt 0 ]; do
    case "$1" in
    --base)
        base="${2:?--base needs a ref}"
        shift 2
        ;;
    --all)
        all=yes
        shift
        ;;
    --ipad)
        ipad="${2:?--ipad needs a simulator name}"
        shift 2
        ;;
    *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$base" ]; then
    base="$(git merge-base HEAD origin/main 2>/dev/null)" || {
        echo "No merge base with origin/main. Fetch it, or pass --base <ref>." >&2
        exit 2
    }
fi
base="$(git rev-parse --verify --quiet "$base^{commit}")" || {
    echo "Not a commit: $base" >&2
    exit 2
}

changed="$(
    git diff --name-only "$base"
    git ls-files --others --exclude-standard
)"
rust=""
apple=""
if [ -n "$all" ]; then
    rust=yes
    apple=yes
else
    printf '%s\n' "$changed" | grep -Eq '^(server/|Cargo\.(toml|lock)$|rust-toolchain\.toml$)' && rust=yes
    printf '%s\n' "$changed" | grep -Eq '^(apple/|\.swiftformat$)' && apple=yes
fi
if [ -z "$all" ] && [ -z "$changed" ]; then
    echo "Nothing changed against $base. Pass --all to check everything."
    exit 0
fi

dir="$(git rev-parse --git-path verify)"
mkdir -p "$dir/logs"
rm -f "$dir/logs/$tier-"*
record="$dir/last-$tier"
commit="$(git rev-parse HEAD)"
dirty=no
[ -n "$(git status --porcelain)" ] && dirty=yes
simulator="${PENDENZ_UITEST_SIMULATOR:-iPhone 18 Pro}"

{
    echo "commit $commit"
    echo "dirty $dirty"
    echo "tier $tier"
    echo "base $base"
    echo "started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$record.tmp"

failed=0
n=0
# check <name> <command...>: runs the command, keeps its output, records pass or fail.
check() {
    name="$1"
    shift
    n=$((n + 1))
    log="$dir/logs/$tier-$n-$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '-').log"
    printf '%-28s ' "$name"
    start=$SECONDS
    if "$@" >"$log" 2>&1; then
        status=pass
    else
        status=fail
        failed=$((failed + 1))
    fi
    took=$((SECONDS - start))
    echo "$status ${took}s"
    printf 'check\t%s\t%ss\t%s\t%s\n' "$status" "$took" "$name" "$*" >>"$record.tmp"
    if [ "$status" = fail ]; then
        echo "--- last lines of $log"
        tail -n 30 "$log"
        echo "---"
    fi
}

xcode_build() {
    xcodebuild -project apple/Pendenz.xcodeproj -scheme Pendenz -destination "$1" \
        -configuration Debug -quiet CODE_SIGNING_ALLOWED=NO build
}

ui_tests() {
    if [ -n "${PENDENZ_UITEST_SIMULATOR:-}${PENDENZ_UITEST_LOCAL_PORT:-}${PENDENZ_UITEST_PAIRED_PORT:-}" ]; then
        apple/uitest.sh "$1"
    else
        echo "Waiting for other UI test runs on this machine."
        tmp="${TMPDIR:-/tmp}"
        lockf -k "${tmp%/}/pendenz-uitest.lock" apple/uitest.sh "$1"
    fi
}

echo "Checking $tier against $(git rev-parse --short "$base"): rust=${rust:-no} apple=${apple:-no}"

if [ ! -x node_modules/.bin/prettier ]; then
    check "pnpm install" pnpm install --frozen-lockfile
fi
check "prettier" pnpm exec prettier --check .

if [ -n "$rust" ]; then
    check "cargo fmt" cargo fmt --check -- --color never
    check "cargo clippy" cargo clippy --locked --all-targets -- -D warnings
    check "cargo test" cargo test --locked
fi

if [ -n "$apple" ]; then
    check "swiftformat" swiftformat --lint .
    check "build iOS Simulator" xcode_build "platform=iOS Simulator,name=$simulator"
    if [ "$tier" = full ]; then
        check "build Mac" xcode_build "platform=macOS"
        check "UI tests $simulator" ui_tests "$simulator"
        [ -n "$ipad" ] && check "UI tests $ipad" ui_tests "$ipad"
    fi
fi

if [ "$failed" -eq 0 ]; then
    echo "result pass" >>"$record.tmp"
else
    echo "result fail" >>"$record.tmp"
fi
mv "$record.tmp" "$record"

echo
echo "Record: $record"
if [ "$failed" -eq 0 ]; then
    echo "All $n checks passed at $(git rev-parse --short HEAD)$([ "$dirty" = yes ] && echo ' with uncommitted changes')."
else
    echo "$failed of $n checks failed. Logs: $dir/logs"
    exit 1
fi
