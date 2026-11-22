---
name: verify
description: Check a change to Pendenz before it is committed or handed in. Says which checks to run for what changed, how to run the change for real, which repo rules the diff triggers, and how to report what was verified. Use after each step of a change (quick) and once before a pull request (full).
---

# Verify a change

The checks show that the code builds and the tests pass. Running the change shows that it works. A change is handed in with both, or with a plain statement of what was not checked and why.

## The checks

- `.claude/skills/verify/run.sh quick` after each step of a change.
- `.claude/skills/verify/run.sh full` once before the pull request, and again after fixes from a review.

The script compares the branch with its merge base on `origin/main` (`--base <ref>` for another base) and runs only what the changed files need:

| Changed | quick | full adds |
| --- | --- | --- |
| anything | Prettier | |
| `server/`, `Cargo.*`, `rust-toolchain.toml` | `cargo fmt`, clippy, `cargo test` (with the agent fixtures) | |
| `apple/`, `.swiftformat` | SwiftFormat, iOS Simulator build | Mac build, `apple/uitest.sh` |

`--all` runs every part. `--ipad "<simulator>"` adds the UI tests on an iPad simulator; use it when a change touches the sidebar layout. The UI tests wait for another run on the same machine, unless `PENDENZ_UITEST_SIMULATOR` and the port variables of `apple/uitest.sh` give this run its own simulator and ports.

Every check runs, also after one failed. The script prints a table, shows the last lines of each failure, and writes a record to `verify/last-quick` or `verify/last-full` in the worktree's git directory: the commit, whether the tree had uncommitted changes, and each command with its result. It exits with 1 when a check failed.

A missing tool is a failure, not a skip. Install it or report it.

## When a check fails

- Fix the cause and run again. After three rounds on the same check, stop and report the check, its last output and what was tried.
- Never skip or disable a test, add a sleep, or run it again until it passes. A test that fails now and then has a cause. Find it, or remove the test and say why in the pull request.
- Agent fixtures are recorded again only when what an agent sees changes on purpose: `PENDENZ_RECORD_FIXTURES=1 cargo test --test agent`, read the diff, then run the tests again without the variable.

## Run the change

- **Server.** Start a scratch server on a port of its own: `DATABASE_URL=sqlite://$(mktemp -d)/verify.db PENDENZ_AUTH_MODE=local PENDENZ_BIND=127.0.0.1:<port> cargo run --bin pendenz`, then call the changed route with `curl`. Not `pnpm dev:api`: it binds port 8080 and uses `data/pendenz.db`, which another run may use.
- **App.** Launch a Debug build in the Simulator with `-apiURL http://127.0.0.1:<port>` and the launch arguments that open the screen (`-tab`, `-place`, `-item`, `-note`, `-quickAdd`, see AGENTS.md). On the iPhone layout `-tab tasks` shows the lists, not their items; `-item <id>` opens one item. Take screenshots in dark mode only, after `xcrun simctl ui <simulator> appearance dark`, with `xcrun simctl io <simulator> screenshot <file>`. iPhone and iPad when the layout changed. The iPad is used in landscape: rotate its simulator to landscape before the screenshots and the checks by hand, and look at portrait only when a change is about rotation. Right after a launch or a switch of appearance a screenshot can come out blank or half drawn: look at each one, and take it again until it shows the screen. Use a simulator other than the one the UI tests run on, and set the appearance back to light afterwards.
- **Mac.** Build with `PENDENZ_BUNDLE_ID=<id>.dev` and a `-derivedDataPath` of its own, so it does not share the sandbox of a copy in daily use.
- **Not checked.** A push reaches only a real device. A widget needs a scratch server in token mode, not `-apiURL`. Whatever could not be run goes under "Not checked" with the reason.

## Rules the diff triggers

Check each line whose trigger the diff matches. The rule and its reason are in AGENTS.md.

- New file in `server/migrations/`: tried on a copy of a database with rows, and the pull request says how. No committed migration changed (`git diff --name-only --diff-filter=MD <base> -- server/migrations` is empty).
- SQL that lists or checks projects: `AND deleted = 0`.
- Queries for open items: the literals `status <> 'done' AND trashed = 0 AND archived = 0`.
- A write to an item, comment, project or note: through `write` in `server/src/items.rs`. A read or write of an item or note: through the hidden filter.
- `server/src/files.rs` or a file lookup: the item's hidden filter, and the file looked up by its ID together with the item's ID.
- `server/src/agent/tools.json`: the tool in `tools.rs` and `cli.rs`, a check in `schema.rs` for a new pattern, steps in `server/tests/agent.rs`, no names in descriptions, no approve scope and no hidden rows for agents.
- The app sends a new route, method or field: `ServerVersion.minimum` raised.
- A new field on `StoredItem` or `StoredNote`: a default value and `LocalStore.format` raised with a pass in `load`.
- A new selected, filled or prominent control: dark mode on iPhone, iPad and Mac.
- A yes or no question in the app: an `alert` with the red action and Cancel, not `confirmationDialog`.
- Text of a note on a new screen: `NoteLock.shared.isOpen` asked first for a locked note.
- `relay/`: tried against a stand-in for APNs; payload and topic stay out of the caller's hands.
- A decision recorded in `docs/design.md` changes: the owner agreed before the code, and the document changes in the same pull request.

## Report

In the report and under "How it was tested" in the pull request:

- The table from `run.sh` and the commit it ran on.
- What was run for real and where (simulator and OS, or the server), with the screenshots attached.
- Not checked: what and why.
- One line: `Verified: full at <commit>`, `Verified: quick at <commit>` or `Verified: none (<why>)`.

A pull request that changes this skill, `run.sh`, tests or fixtures says so, because those are what the change is checked with.
