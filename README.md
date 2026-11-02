# Sedge

Sedge is an iOS app that answers questions about a person's own bank data: spending, a cash-flow
projection with scenarios to switch on and off, transactions and a profile of what it learned. Four
sample people with made-up data are built in, so it runs without a bank account.

## Setup and run

Requirements:

- macOS with Xcode 27 (tested with 27.2) and an iOS 27 simulator.
- `uv` and Python 3.12, only for the scripts in `tools/` (see `tools/README.md`). The app does not need them.

Open the project:

```sh
open Sedge.xcodeproj
```

- In Xcode, pick the `Sedge` scheme and any iPhone simulator, then press Run (Cmd-R).
- Swift packages (GRDB, Plaid LinkKit) download on the first build.
- The app opens on the **Welcome** screen. Tap **Explore sample data**, then pick a person under
  **Sample people**. The app remembers the choice and opens on it next time.
- To pick other data later, open the **Accounts** tab and tap the people icon (**Change data**, top right).

The three tabs:

- **Ask**: a chat about the chosen data. No assistant is connected yet, so a typed question gets
  "The assistant isn't connected yet." To see a sample conversation, add the launch argument
  `-sampleChat YES` (Product > Scheme > Edit Scheme > Run > Arguments; Debug builds only).
- **Trends**: **Spending** by month and category. **Cash flow** (top right) projects the checking
  balance and has scenarios to switch on and off.
- **Accounts**: **Transactions**, **About you** (what Sedge learned), **Your accounts** and **Saved answers**.

Run on an iPhone:

- Connect the phone (iOS 27 or later) and pick it as the run destination at the top of Xcode.
- Under the `Sedge` target's **Signing & Capabilities**, set **Team** to your own. If Xcode says the
  bundle ID `none.Sedge` is taken, change it to something unique, e.g. `com.yourname.Sedge`.
- On the phone, turn on Developer Mode (Settings > Privacy & Security > Developer Mode; the switch
  appears once the phone has been connected to Xcode) and restart.
- After the first install, trust your developer profile (Settings > General > VPN & Device Management).
- Bank sign-in doesn't work on a phone yet: the bank server address is `localhost`, which is the phone
  itself. Use the sample people instead.

Bank sign-in (optional, simulator only):

- `Secrets.xcconfig` holds local settings and is not included. The build reads it only if it
  exists, so the app builds and runs without it.
- **Connect with Plaid** (Welcome) and **Connect bank** (in the data picker) use Plaid Sandbox through
  Plaid's quickstart server on `localhost:8000`, which needs Plaid keys and is not included. Without it,
  the bank screen shows "Bank server not running" and a **Use a sample person** button. Everything else works.

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
