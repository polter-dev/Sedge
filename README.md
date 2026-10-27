# Sedge

Sedge is an iOS app that answers questions about a person's own bank data: transactions,
spending, a "what if" simulator and a profile of what it learned. Four sample people with
made-up data are built in, so it runs without a bank account.

## Setup and run

Requirements:

- macOS with Xcode 27 (tested with 27.1) and an iOS 27 simulator.
- `uv` and Python 3.12, only for the scripts in `tools/` (see `tools/README.md`). The app does not need them.

Open the project:

```sh
open Sedge.xcodeproj
```

- In Xcode, pick the `Sedge` scheme and any iPhone simulator, then press Run (Cmd-R).
- Swift packages (GRDB, Plaid LinkKit) download on the first build.
- The app opens on Maya, a sample person. Tap the people icon (**Change data**, top right)
  to pick another one under **Sample people**.

Bank sign-in (optional):

- `Secrets.xcconfig` holds local settings and is not included. The build reads it only if it
  exists, so the app builds and runs without it.
- **Connect bank** uses Plaid Sandbox through Plaid's quickstart server on `localhost:8000`,
  which needs Plaid keys and is not included. Without it, the bank screen shows
  "Bank server not running" and a **Use a sample person** button. Everything else works.

## Project layout

```text
Sedge/               the iOS app (SwiftUI): screens, Plaid sign-in, bundled sample data
SedgeTests/          app unit tests (Swift Testing)
SedgeUITests/        UI tests that tap through the app
Packages/SedgeCore/  Swift package: database, organizer, profile, simulator, assistant tools
tools/               Python: fake data generator, sample data and question bank
docs/                database diagram and business rules
```

## Tests and known limits

Package tests (no simulator needed):

```sh
swift test --package-path Packages/SedgeCore
```

App and UI tests (list simulators with `xcrun simctl list devices available`, then use one's name):

```sh
xcodebuild -project Sedge.xcodeproj -scheme Sedge -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd test
```

- Business rules and known limits: [docs/assumptions.md](docs/assumptions.md).
- Database diagram: [docs/erd.md](docs/erd.md).

## Model

TODO (Marcus)

## Results

TODO (Marcus)
