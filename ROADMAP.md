# Roadmap

What is planned and not built yet, roughly in order. Each entry gets a GitHub issue with the label `planned` once work on it can start; the issue is where the details live. To propose something that is not here, start a [discussion](https://github.com/unveroleone/pendenz/discussions/categories/ideas).

## For self-hosters and the App Store

- **An open push relay.** Today the public relay only accepts its maintainer's server. Before it opens to every server it needs its own hostname, a total budget against floods, and possibly a grant per installation that can be taken back.
- **Version negotiation.** The App Store updates the app by itself, while each server is updated by its owner. The server will say what it can do, and the app will hide the rest and say that the server needs an update. Today a request the server does not know waits in the outbox and holds back the changes behind it.
- **The App Store**, with a demo server for App Review, a privacy policy and TestFlight before that.

## The app as it is

- **A share extension**, to send a link, text or image from another app to the inbox.
- **Images in quick add.** Items and notes can carry images already.
- **Agent tools for the files of notes.** `get_note` lists them, but only the HTTP routes read or remove them.
- **A reminder at the due time for a device that has not synced it.** A reminder made on another device shortly before it is due can come late today, because each device schedules its own.
- **An Apple Watch app.**
- **More UI tests:** text dropped from another app, the actions on a notification, images, locking a note, and the Mac, where the test target does not run yet.

## Left out on purpose

Some protections and features are not planned, because a server has one person. [docs/design.md](docs/design.md) lists them with what can go wrong and the way up if it starts to hurt. Examples are narrower scopes for agent tokens, a rate limit on pairing, encrypting the text of a locked note, colors per project and ordering the projects by hand.
