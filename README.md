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
- To give the data your own name, tap the title at the top of a tab and choose **Rename…**. A blank
  name goes back to the default (Maya, Bank, …). The name is kept in the app's settings, not in the data.

The three tabs:

- **Ask**: a chat about the chosen data, answered on the device by Qwen3.5-4B (4-bit, run with MLX);
  nothing leaves the phone. The first question asks to download the model once (about 3 GB, kept in
  Application Support); "Not now" shows a screen with Download instead of the chat. While the model
  works, the thinking row (a sprout and a short phrase) shows each step, and a question the model asks
  back shows as a quick check. The iOS Simulator can't run MLX, so there a scripted test model answers
  "This answer comes from the test model." A Mac with Apple silicon or an iPhone runs the real model.
  - The empty screen rotates through example questions.
  - Each question is saved with the data. **Previous chats** (clock icon, top left) lists them, opens
    one or deletes it; **New chat** (top right) starts over.
  - When a chat gets too long, it ends with a "This chat is full" card and a **Start new
    session** button. Nothing reaches the limit yet, so use `-demoTokenLimit YES` (below) to see it.
- **Trends**:
  - Every category added up, with the change from the month before. Swipe the chart sideways to
    page back four months at a time, or tap a month's bar to pick it, compared up to the same day
    of each month. The picked month is named for those days: "June so far" for today's month,
    "May 1 – 30" when they cut a past month short, else just "April".
  - The picked month as a mosaic of categories, and under it the category that changed most from
    the month before (none for the data's first month). A category's block (or that row) opens its
    page: its months, stores (and the store that changed most, when there are two or more), its
    transactions, and a question to take to Ask. **Other categories** lists every category of the
    month.
  - A **Cash flow** card for the picked month: money in, money out and what's left over, over the
    same days as its bar, posted transactions only. An earlier month adds checking's balance at the
    end of those days. With a bank account, today's month adds the projected checking balance for
    the next 30 days and opens the Cash flow screen (30, 60 or 90 days, with scenarios to switch on
    and off).
  - When there are any, the recent purchases **Worth a look**.
- **Accounts**:
  - **Transactions**: one month at a time (arrows step between months), split into income, spending
    and transfers and grouped by week. Tap one for its details and the store's history, whose
    change from last month reads as on Trends ("-$4 vs May", with "(so far)" until the month ends).
  - **About you**: what Sedge learned (income, rent, accounts and more). Tap a tile to correct it.
  - **Accounts**: whether each account is yours or shared, asked right on the screen for any not
    answered yet, and a name of your own for it.
  - **Saved answers**: your replies to Sedge's questions and your corrections. Tap to change, swipe to remove, or Delete all.

Launch arguments (Product > Scheme > Edit Scheme > Run > Arguments):

- `-persona daniel` opens on that data (`maya`, `daniel`, `jordan`, `elena` or `bank`).
- Debug builds only, mostly for UI tests and screenshots:
  - `-sampleChat YES` shows a sample conversation on Ask, with numbers worked out from the data.
  - `-demoThinking YES` holds a question on the thinking row; `-demoTokenLimit YES` shows the limit message.
  - `-slowThinking YES` holds each step of the test model 3 seconds instead of 0.3.
  - `-modelReady YES` starts as if the on-device model were downloaded; `-stubDownload ok` or `fail` shows a
    fake download that ends ready or stopped; `-fakeModel YES` answers with the test model outside the Simulator.
  - `-reduceMotion YES` makes Ask act as if Reduce Motion were on.
  - `-firstLaunch YES` forgets the chosen data, so the app opens on Welcome as on a fresh install.
  - `-emptyBank YES` uses a separate, empty bank file that never syncs, so the bank shows its sign-in screen
    whatever this phone synced before; after choosing the bank in the data picker, the sign-in screen is under
    Accounts > Transactions.
  - `-clearOwnerAnswers YES` clears the "Is this account yours?" answers.

Fresh install:

- Each data file is its own SQLite database in the app's storage. The app brings it up to the newest
  version of the tables (`v8`, in `Packages/SedgeCore/Sources/SedgeCore/SedgeDatabase.swift`) when it opens it.
- If a build changed an existing version instead of adding a new one, an older file won't pick that up.
  Delete the app from the simulator or phone and run it again. This also clears saved chats, answers,
  names and synced bank data; the sample people's data is loaded again on every launch anyway.

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
- **Connect bank** (on Welcome and in the data picker) uses Plaid Sandbox through
  the small server in `plaid-server/` (based on Plaid's quickstart) on `localhost:8000`. It needs your own
  Plaid Sandbox keys, which are not included. To run it (Node 20 or later):

  ```sh
  cd plaid-server
  cp .env.example .env    # then fill in PLAID_CLIENT_ID and PLAID_SECRET
  npm install && npm start
  ```

  Without it, the bank screen shows "Bank server not running" and a **Use a sample person** button.
  Everything else works.

## Project layout

```text
Sedge/               the iOS app (SwiftUI): screens, Plaid sign-in, bundled sample data
SedgeTests/          app unit tests (Swift Testing)
SedgeUITests/        UI tests that tap through the app
Packages/SedgeCore/  Swift package: database, organizer, profile, simulator, assistant tools
tools/               Python: fake data generator, sample data and question bank
plaid-server/        Node: the local Plaid Sandbox server the app's bank sign-in talks to
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
