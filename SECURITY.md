# Security

Pendenz holds private tasks and notes, and agents read them with tokens. Please report anything that could expose that data or let a token do more than its scopes allow.

## Reporting a vulnerability

Report it privately through [GitHub's private vulnerability reporting](https://github.com/unveroleone/pendenz/security/advisories/new). Do not open a public issue or discussion for it.

Include what an attacker can do, the steps or a request that shows it, and the version or commit you tested. You will get an answer within a week. Once a fix is released, the advisory is published with credit to you, unless you prefer to stay unnamed.

## What counts

Examples of what is in scope:

- An agent token that reads or changes an item or note hidden from agents, or reaches the image of one.
- A token that acts beyond its scopes, approves, pairs a device, or removes the lock of a note when it is not the owner's.
- Reaching the API without a valid token, or pairing a device without a valid code.
- The push relay sending anything other than its fixed "sync now" push, or to a topic other than its own.
- The app showing the text of a locked note without Face ID or Touch ID, or leaking a token outside the Keychain.

Out of scope: a server run in local mode, which accepts requests without a token by design and starts only on a loopback address; attacks that need the owner's unlocked device or the server's file system; and missing protections that [docs/design.md](docs/design.md) lists as left out on purpose for a single-person server, unless you show a concrete way to abuse them.

## Supported versions

Fixes go into `main`. Run the newest commit, as described in [docs/self-hosting.md](docs/self-hosting.md).
