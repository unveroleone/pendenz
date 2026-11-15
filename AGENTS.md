# Pendenz

Tasks, reminders and notes for one person, with a server that agents can work from and a native app for iPhone, iPad and Mac. This is the working guide for the repo, for people and coding agents alike.

## Read first

- `README.md` for what Pendenz is and how to run it.
- `docs/design.md` for how it works and why. Its section on what was left out on purpose lists protections a single-person server does without. Do not add those back without a discussion first.
- `docs/self-hosting.md` for deployment, tokens, backups and the clients.
- `CONTRIBUTING.md` for how changes are proposed and reviewed.

## Stack

- Server: Rust 1.100 (edition 2024, pinned in `rust-toolchain.toml`), Axum, SQLite through sqlx, in `server/`.
- MCP server and agent CLI: Rust, in the same binary, in `server/src/agent/`.
- Tooling: Node 24 and pnpm 12 for Prettier, the push relay and the icon scripts.
- Apps: `apple/Pendenz.xcodeproj`, one SwiftUI target for iPhone, iPad and native Mac and one widget extension inside it, Xcode 27, Swift 6 with the main actor as the default. Check Liquid Glass and other new API names against the current SDK before using them.
- Push relay: a Cloudflare Worker in plain JavaScript, in `relay/`.
- Hosting: two containers with Docker Compose, in `deploy/`.

## Working on the server

- Run it locally with `pnpm dev:api` (loopback only; a request without a token acts as the owner). `pnpm check` runs clippy and the format checks and `pnpm test` the tests, and CI runs the same on every push.
- A server belongs to one person, the owner, whose actor ID is `owner` (`auth::OWNER`; the first migration called it `leo`, and `0006` renamed it). Use the constant in code, and write "the owner" in texts for people and agents, never a name. `pendenz set-owner-name` sets the name that `workspace.actors` shows.
- Every write to an item, comment, project or note goes through `write` in `server/src/items.rs`: one writer, one `BEGIN IMMEDIATE` transaction, an idempotency key. Every read or write of an item or note goes through the hidden filter (`visible_item`, `visible_note` or the same SQL condition). Keep both when adding routes.
- The device routes in `server/src/devices.rs` are the exception: they take the writer lock and `BEGIN IMMEDIATE` themselves and use no idempotency key. `POST /api/pair` is the only API route without a token; it is added to the router after the auth layer on purpose. The device routes need a human token with the approve scope (`require_owner`).
- A token without the `read` scope gets a receipt from a write, never the stored row.
- The push token routes in `server/src/push.rs` are device routes too: `PUT` and `DELETE /api/push-token` take the writer lock themselves, use no idempotency key and need a paired device. The one sender task there is woken by `write` after its commit (`state.push.changed`). Any other code that changes what the apps sync has to wake it as well. Without `PENDENZ_PUSH_RELAY` the server sends nothing; to see a push locally, start a stand-in for the relay that answers `{"results": [{"status": "sent"}]}` per device.
- The image routes are in `server/src/images.rs`. Each checks the item with the hidden filter and looks the image up by its ID and the item's ID together; an image must never be read or deleted by its ID alone, or an agent reaches the image of a hidden item through an item it may see. The upload is decoded and checked in `images::prepare` before `write` takes the writer lock, and its SHA-256 stands for the body in the idempotency fingerprint. `items.images` is the only copy of the metadata and no PATCH can write it.
- `locked` on a note is not an access rule: `visible_note` and the hidden filter do not look at it, and they should not start to. Anyone may set it, only the owner's tokens may clear it (`guard_unlock` in `server/src/notes.rs`).
- A note is appended to with `{"append": "text"}` on its PATCH route, which takes no version. Use it wherever an agent adds to a note: a PATCH with a whole body and a version can overwrite what the owner typed in between.
- A deleted project keeps its row with `deleted` set. Add `AND deleted = 0` to every SQL query that lists or checks projects. `DELETE /api/projects/<id>` moves its items and notes to the inbox in the same transaction, and `settle_project` sends a later write that still names it to the inbox too. The ID of a deleted project is never given to a new one.
- Queries that should use the partial indexes for open items have to repeat `status <> 'done' AND trashed = 0 AND archived = 0` as SQL literals.
- The telegram scope belongs to the agent ID `telegram-bridge` alone, which gets no other scope.

## Releases

- CI builds the server image for `linux/amd64` and `linux/arm64` with Docker's reusable workflow (`docker/github-builder`, `.github/workflows/build.yml`), for every push to `main` and every tag `v*`. `update.sh` checks the labels `org.opencontainers.image.source` and `org.opencontainers.image.revision` that it sets; keep `set-meta-labels`.
- To release, raise `version` in `server/Cargo.toml` on `main`, then tag that commit `v<version>` and push the tag. CI refuses a tag that does not match the version, publishes the tags `<version>`, `<major>.<minor>` and `latest`, and creates the GitHub release. A version with a hyphen (`1.3.0-rc.1`) becomes a pre-release and moves neither `latest` nor `<major>.<minor>`.

## Migrations

- A committed migration is never edited: every schema change is a new file in `server/migrations/`. sqlx compares each file's SHA-384 with the one in `_sqlx_migrations`, and a server with an edited migration does not start on any database made before the edit.
- sqlx runs a SQLite migration in one transaction, where `PRAGMA foreign_keys` cannot be switched off. To make a table again that other tables point at, do it as `0002_project_delete.sql` does: `PRAGMA defer_foreign_keys = ON`, copy the rows aside, drop the table, create it, and put the rows back before the migration ends. `0006_owner.sql` shows how to change a key that other tables point at, and how to lift the activity log's append-only guard for one change.
- Try a new migration on a copy of a database with rows in it before it is committed, and say in the pull request how.

## Agent tools

- A new MCP tool goes into `server/src/agent/tools.json` (name, description, input schema, annotations) and `tools.rs` (what it does), with the same call in `cli.rs`. A tool with `readOnlyHint` needs the read scope, any other the write scope. The tool descriptions and `instructions.txt` are what an agent reads, so keep them short, exact and free of names.
- `schema.rs` checks the arguments against the input schemas. It knows the keywords and the patterns that `tools.json` uses; a new pattern needs its check there, or the tool list refuses to load.
- The protocol is rmcp's (`server.rs`): do not answer MCP methods by hand. `hosted.rs` guards the door before rmcp and hands the caller to it in the request's extensions.
- The hosted endpoint calls the API router in process with the caller's token (`Client::local`). Keep it that way: a tool that reads the database itself would skip the scope checks and the hidden filter.
- `server/tests/agent.rs` runs every tool, the hosted endpoint's HTTP rules, the stdio server and the CLI against a scratch server and compares each answer with `server/tests/fixtures/`. Add steps for a new tool. When what an agent should see changes on purpose, record again with `PENDENZ_RECORD_FIXTURES=1 cargo test --test agent` and read the fixture diff before committing it.
- No agent token may approve or pair a device, and no agent sees a hidden row. Keep it that way in every new tool.

## The push relay

- `relay/` is plain JavaScript without runtime dependencies. It can only send the fixed "sync now" push: keep the payload and the topic out of the caller's hands.
- It reaches APNs only when deployed, not under `wrangler dev`, because the local runtime speaks no HTTP/2. Locally, point `APNS_ORIGIN` and `APNS_SANDBOX_ORIGIN` in `relay/.dev.vars` at a stand-in.

## Working on the app

### Building

- Swift is formatted with SwiftFormat (the rules are in `.swiftformat`). Run `pnpm format:swift` before a commit; CI runs `swiftformat --lint .` and builds the app for the iOS Simulator and the Mac without signing (`.github/workflows/apple.yml`).
- Build with `xcodebuild -project apple/Pendenz.xcodeproj -scheme Pendenz -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build`, and with `-destination 'platform=macOS'` for the Mac. A new Swift file under `apple/Pendenz/` joins the app by itself, one under `apple/PendenzWidgets/` the widget extension, and one under `apple/Shared/` both; the project file is only edited for build settings. Both targets have the main actor as the default, so a type in `Shared/` means the same in each.
- The team stays out of the project file. Pass `DEVELOPMENT_TEAM=<team>` on the command line or set it in Xcode locally.
- Do not pass `CODE_SIGN_ENTITLEMENTS` or `PRODUCT_BUNDLE_IDENTIFIER` on the command line: a setting given there reaches both targets, and the widget extension would get the app's entitlements or the app's bundle ID. Use the project's own settings: `PENDENZ_BUNDLE_ID`, from which the extension's ID (`<id>.widgets`) and the app group (`group.<id>`) follow, and `PENDENZ_MAC_SIGNING` (`adhoc` or `team`).
- A Mac build is signed ad hoc unless `PENDENZ_MAC_SIGNING=team`. That one setting switches both targets to "Apple Development" and gives each its Mac entitlements file (`Config/PendenzMac.entitlements`, `Config/PendenzWidgetsMac.entitlements`): push for the app, and the app group that the app and its widget share. An ad hoc build with those entitlements does not launch, which is why they are off by default.
- An ad hoc build is a new app to the Keychain after every rebuild, so a paired ad hoc build asks for the login password on its first launch and shows no window until it is answered. A build signed with a team keeps its identity. Develop on the Mac with `-apiURL`, and delete a test pairing with `security delete-generic-password -s <bundle id>.pairing`.
- To try a Mac build next to a copy you use day to day, give it another bundle ID (`PENDENZ_BUNDLE_ID=<id>.dev`) and its own `-derivedDataPath`. Under the same bundle ID a build shares the sandbox with the other copy, and launched with `-apiURL` for another server it empties that copy's local store, waiting changes included.
- For a real device, the app group has to be registered for your team in the developer portal and turned on for both app IDs; `xcodebuild` with an API key does neither. Without it, a device build fails with "doesn't match the entitlements file's value for the com.apple.security.application-groups entitlement". The Simulator and an ad hoc Mac build need nothing registered.
- The app icon is the Icon Composer document `apple/Pendenz/AppIcon.icon`. `node apple/icon/generate.mjs` redraws its layers and keeps `icon.json`; `--json` rewrites `icon.json` too, which discards glass settings changed in Icon Composer. `node apple/icon/render.mjs` renders the appearances into `apple/icon/out/`, which is not committed. `docs/icon.png` is the README's copy of `out/Default.png` at 256 pixels; renew it when the icon changes. In `icon.json`, the appearance `tinted` is the mono look behind both the clear and the tinted icons, and dark layers vanish there, so every ink layer gets a white fill for it.

### Launch arguments

- The app uses the server it is paired with. Launched with `-apiURL <url>` it skips pairing and talks to that server without a token, which only a server in local mode accepts. To pair with the local server, enter `http://127.0.0.1:8080` and a code from `cargo run --bin pendenz -- pairing-code`.
- `-tab reminders|tasks|notes|search` opens the iPhone layout on that tab, `-place reminders|inbox|notes|completed|trash` opens the sidebar layout on that list (`-place trash` or `-place completed` next to `-tab tasks` opens that list on the iPhone), `-note <id>` opens a note, `-quickAdd YES` opens the iPhone quick add and `-item <id>` opens an item's detail on every layout, which helps for screenshots with `xcrun simctl io booted screenshot`. `-projectOrder name|added|edited` sets the order of the projects and `-projectsExpanded NO` folds them in the sidebar.
- The tab of the iPhone layout is kept per window in `@SceneStorage`. The launch argument `-tab` is read from the argument domain into a state of its own (`launchTab` in `TabShell`): a value written to scene storage at launch is overwritten when the scene is restored. The Tasks tab keeps its open list in `@SceneStorage` (`tasksPlace`) and restores it after the first draw; a window launched with `-tab` neither restores nor saves it.

### Store, sync and the outbox

- Screens read from the `Store`, never from a request of their own. Every change goes through the outbox in `Store` (`enqueue`), never straight to the API, so it also works without a connection.
- A local ID (below zero) is given to an item or note until the server answers. Never reuse one within a launch: `serverIDs` and `noteServerIDs` keep leading the old ID to the row it became.
- A project has no local ID: the app makes its ID from the name (`Project.makeID`) and sends it along, and the server accepts it. A project is drawn with `store.symbol(for:)` or `project.symbol`. Read projects through `store.projects`, which leaves deleted ones out and is sorted by name; the sidebar and the Tasks tab list `store.orderedProjects`, which follows the chosen order.
- Finished items are not in memory at launch. `store.loadCompleted()` reads them from disk when Completed opens, as `loadTrash()` does for the trash. The order of a list is `store.itemOrder(for:)`, kept per list in UserDefaults under `itemOrders`.
- A new field on the stored rows (`StoredItem`, `StoredNote`) gets a default value, and `LocalStore.format` is raised with a pass in `load` that fills it in for the rows already on disk.
- Keys in API JSON are snake case, keys on disk are plain. Do not put a key strategy on the disk encoder: names such as `itemID` do not survive the round trip.
- Use `url.path(percentEncoded: false)` for `FileManager` calls. `url.path()` encodes the space in "Application Support", and the file then looks missing.
- An image waits for its upload as a JPEG in `Application Support/WaitingImages`, written before its outbox entry and deleted only after the entry is gone from disk (`finish`). Copies of the server's images lie in `Caches/Images` under their SHA-256. Screens get both through `store.imageFile`.
- The pairing lives in `Session`, which owns the `Store`: no pairing, no store, and the app shows `PairingView`. The token is in the Keychain (`Keychain.swift`), never in UserDefaults or on disk. Only `Session` and `SettingsView` talk to the device routes.
- Deploy a server before an app build that needs a new route: a request the old server does not know stays in the outbox and holds back every change behind it.

### Reminders, notifications and push

- `Reminders.schedule` takes `isCurrent` (`store.isCurrent`): only with it does it remove a notification that is already shown, because an item that is missing from a store that is still loading may be open on the server.
- An action on a notification is carried out by `Session` (`carryOut`), which sets `Reminders.shared.onAction` in its `init`: the system can start the app in the background for an action, where no view exists. Schedule the reminders before the sync there, because the app may be ended right after the handler returns.
- A push and the push token reach the app through the app delegate in `Push.swift`, which hands them to `Push.shared`; `Session` sets `onToken` and `onPush` in its `init`, for the same reason as `onAction`. The token registration is not a write of the outbox. The Simulator gives no push token, and `simctl push` refuses a push without visible content, so the push path can only be tried on a real device. Apple delivers a silent push when it suits the device, which can take minutes.

### Locked notes

- Every screen that shows text of a note has to ask `NoteLock.shared.isOpen` first for a locked one: the row shows no preview, the search matches the title only, and the editor shows the placeholder.
- `NoteLock` closes when the app leaves the front, and ignores that while the system asks for the face or the finger, because its sheet takes the front too. In the Simulator the system may ask for a passcode that a script cannot type; to see the opened state there, add a temporary launch-argument hook that sets `isOpen`, and remove it before committing.

### Widgets

- The widget extension reads one file and nothing else: `Widgets.json` in the app group's folder (`WidgetFile` in `Shared/`). `Store.feedWidgets` writes it at the end of `publish` and when an order changes, and `WidgetFeed` skips the write and the reload when nothing changed, because a reload asked for in the background counts against the widgets' daily budget. Whatever a widget should show goes into `WidgetSnapshot`; never give the extension a token or a request of its own. `Session` removes the file when the pairing ends.
- The tick on a widget's row is `CompleteItemIntent` in `Shared/`. It runs in the app's process (`allowedExecutionTargets` is `.main`), where `Session` carries it out through `WidgetActions.complete`. It carries the due date its row showed: for a repeating item `Session` syncs first and completes it only when that is still the item's date, because completing moves such an item on and a widget can be behind. A row with an ID below zero gets no tick and no link. Keep both when a widget gets another action.
- To try the widget in the Simulator, pair the app with a scratch server in token mode. With `-apiURL` it does not work, because the system starts the app for a tick without launch arguments. After a build, install the app with `xcrun simctl install`, since `xcodebuild test` only installs it when a test launches it. The system lists a newly installed extension's widgets about ten seconds after the install.

### Siri, Shortcuts, Spotlight and the control

- The actions are in `apple/Pendenz/Intents/`. They reach the store through `Session.current`, which the app makes at launch, also a launch in the background. An action that reads or acts on rows takes the store from `Session.freshIntentStore()`, which syncs once for a few seconds when the launch has not synced yet, and one that changes something ends with `Session.settleIntent`, which waits for the server for eight seconds at most. Keep both, and keep every change on the outbox.
- Entities and queries are `nonisolated`, so their properties are `@ComputedProperty` over plain `let` fields: `@Property` cannot be used in a `nonisolated` struct. An intent with `@Parameter` cannot be marked `nonisolated`, and a type that conforms to `AppEntity`, `EntityQuery` or `AppIntentTimelineProvider` has to be. Use the full type names `EntityQueryProperties` and `EntityQuerySortingOptions` in `ItemQuery`.
- An entity offered to a picker or a search has an ID above zero, since a shortcut may keep it. A note entity carries no text that Shortcuts can read, so the lock holds.
- What an action wants shown goes through `OpenRequest`, and `RootView.takeRequests` carries it out. On the Mac only the window with `appearsActive` takes a request. On the iPhone layout a list asked for from outside goes through `navigation.requestedPlace`, never `navigation.place`.
- `SpotlightFeed` runs every call to the index in one queue. A locked note is indexed by its title alone, and until `store.isCurrent` only locks are passed on. The push handler, the notification actions and `settleIntent` call `flush` before they return. Empty the index when a pairing ends (`clear`).
- The control's intent `NewItemIntent` is in `apple/Shared/`, because the control is declared in the widget extension and carried out in the app.
- The menu of the app's icon is `UIApplicationShortcutItems` in `Config/Info.plist`, and the type of each entry is a case of `QuickActions.Action`. The system hands a chosen action to the scene delegate only, so the app delegate names `SceneDelegate` for every scene. On the sidebar layout quick add waits half a second first: a popover that opens before its toolbar button exists crashes.
- To try an action without a finger, add a temporary function that sets the intent's parameters and calls `perform()`, call it from a `.task` in `RootView` behind a launch argument, and write what it finds to `Documents/probe.txt`. `Metadata.appintents/extract.actionsdata` in the built app lists the actions, entities and phrases the system will see. Remove the hook before committing.

### Look and feel

- The app is black and white. Color is kept for state: red for overdue, one more for the agent later.
- The tint is white in dark mode and the system draws selected or filled controls with white text. Check every new selected, filled or prominent control in dark mode on iPhone, iPad and Mac.
- The app asks only before what cannot be taken back (unpairing, revoking a device, deleting a project, removing an image), and always with an `alert` that has the red action and Cancel. The trash never asks, because "Put Back" undoes it. Do not use `confirmationDialog` for a yes or no: since iOS 26 it is a bubble that grows out of the view it is attached to, without Cancel. It is for a choice between several ways to go on, attached to the control that asks.

### Trying things without a finger

- To exercise the store without taps, add a temporary `.task` in `RootView` that calls it from a launch argument, check the result with `curl` and `sqlite3` on the simulator's `default.store`, and remove the hook before committing.
- SwiftUI text fields on the Mac do not take a value set through accessibility. To fill the pairing form from a script, use a temporary launch-argument hook.
- Do not send keystrokes to the Mac with System Events: they go to whichever app is in front. Use accessibility actions aimed at the process (`tell process "Pendenz" to click menu item ...`), and note that a popover closes when the app is not in front.

## UI tests

- `apple/uitest.sh` builds the server, starts one in local mode with seeded items on port 8792 and one in token mode with a fresh pairing code on 8793, and runs the `PendenzUITests` target in the Simulator. `apple/uitest.sh "Pendenz iPad"` runs it on an iPad simulator of that name, and a second argument names one test. Without the script's environment every test is skipped, so a plain `xcodebuild test` does nothing.
- On the iPhone they cover swipes, the long-press menu, reordering the inbox by drag, a reminder that fires as a notification, a note turned into an item, pairing, the device list and unpairing, the trash, and deleting a project. On the iPad: a row dragged onto a project and onto Reminders in the sidebar.
- While a context menu is open the simulator never reports the app as idle, so every step of a test waits a minute there. Keep such a test to one tap in the open menu, and do not tap "Complete": that is also the label of every row's circle.
- Not covered: text dropped from another app between two rows, and everything on the Mac, where the test target does not build.
- The UI tests are slow. Run them once at the end of a change, not after every edit.

## Rules

- Agent tokens never get the approve scope, and an agent never sees a hidden row.
- Ask before changing a decision recorded in `docs/design.md`, and update it in the same change when a decision does change.
- All code, names and comments are in English.
