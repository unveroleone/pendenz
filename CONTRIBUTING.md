# Contributing to Pendenz

Thanks for helping. Pendenz is a small project with one maintainer, so the rules below are there to keep reviews short and the app coherent.

## Before you write code

- **Small fixes:** a bug, a typo, a missing check or a small improvement inside one feature. Open a pull request directly.
- **Anything bigger:** a new feature, a new screen, a new API route or MCP tool, a schema change, a new dependency, or a change to how sync, auth or push works. Start a thread in [Discussions](https://github.com/unveroleone/pendenz/discussions) first, or ask the maintainer. A pull request for a feature nobody agreed on may be closed, however good the code is, because every feature has to fit the [philosophy](README.md#philosophy) and the decisions in [docs/design.md](docs/design.md).
- **Bugs:** open an issue with the steps to reproduce, what you expected and what happened, and the versions of the app, the OS and the server.

Check [ROADMAP.md](ROADMAP.md) and the open issues before you start, so two people do not build the same thing.

## Pull requests

- **Keep it small and scoped.** One pull request does one thing. A fix does not carry a refactor, a rename or formatting changes elsewhere. If a change grows, split it.
- **Explain why.** The description says what the change does, why it is needed, and links the issue or discussion.
- **Show UI changes.** Every pull request that changes something you can see includes screenshots, or a short screen recording for motion or gestures, of before and after. Show each layout it touches: iPhone, iPad and Mac, and dark mode when it changes colors or a selected, filled or prominent control.
- **Test it yourself.** Run an app change in the Simulator or on your own device before you ask for a review, and say in the pull request where you ran it (device or simulator, and the OS version). A change that was only compiled is not ready.
- **Keep the checks green.** CI runs the same checks as these commands, and all of them have to pass:
  - `pnpm check`: clippy, `cargo fmt` and Prettier. `pnpm format` fixes the formatting.
  - `pnpm check:swift`: SwiftFormat on the app, with the rules in `.swiftformat`. `pnpm format:swift` fixes it.
  - The app has to build for the iOS Simulator and for the Mac without warnings.
- **Update the docs** in the same pull request when behavior changes: `docs/design.md`, `docs/self-hosting.md`, the README or the tool descriptions in `agent/mcp-tools.mjs`.

## Rules of the code base

[AGENTS.md](AGENTS.md) is the working guide for this repo, for people and coding agents alike. The rules that matter most:

- Every write to an item, comment, project or note goes through `write` in `server/src/items.rs`, and every read or write of an item or note goes through the hidden filter.
- A committed migration is never edited. A schema change is a new file in `server/migrations/`, tried on a copy of a database with rows in it.
- In the app, screens read from the `Store`, and every change goes through its outbox. No screen makes a request of its own.
- No agent token may approve or pair a device, and no agent sees a hidden row.
- The app is black and white, and color is kept for state.
- All code, names and comments are in English.

## Development setup

The README has the [development setup](README.md#development). A local server in local mode needs no token, and the app skips pairing with `-apiURL http://127.0.0.1:8080`.

## License of contributions

Pendenz is licensed under [FSL-1.1-ALv2](LICENSE.md). By opening a pull request you agree that your contribution is licensed under the same terms, including the change to the Apache License 2.0 two years after each release.

## Conduct

Everyone who takes part follows the [code of conduct](CODE_OF_CONDUCT.md). Be kind and specific, in issues, discussions and reviews, and criticize code and decisions, not people. Report a problem to info@unveroleone.com.
