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
  nothing leaves the phone. The first question brings up a screen to download the model once (about 3 GB,
  kept in Application Support), with Download and "Not now"; Stop ends a download. While the model
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

Ask runs `mlx-community/Qwen3.5-4B-MLX-4bit` (Qwen3.5-4B, 4-bit) on the phone with MLX Swift. The code is in
`Packages/SedgeCore/Sources/SedgeCore/Qwen.swift` (the model), `Assistant.swift` (the question loop) and
`Sedge/OnDeviceModel.swift` (download and loading).

- **Download.** The weights are not in the app. The first question offers a one-time download of about
  3 GB from Hugging Face, pinned to one revision. The files are kept in Application Support and left out
  of backups. The download screen has "Not now", and Stop while it runs.
- **Settings.** They mirror the benchmark notebook's Qwen row without Jev:
  - temperature 0 (greedy), with thinking off in the chat template;
  - 11 tools: Sedge's 9 tools, `ask_user` and `final_answer`;
  - at most 8 steps per question, one tool call per step;
  - at most 512 new tokens per step;
  - a context cap of 16,384 tokens (prompt plus reply), with one compaction when a chat overflows;
  - a step stops at the tokenizer's end token (`<|im_end|>`) or as soon as one tool call is complete.
- **Where it runs.** The iOS Simulator can't run MLX, so there a scripted test model answers. Real answers
  need an iPhone with enough memory: a step starts only when the phone has room for it. The app has the
  Increased Memory Limit entitlement (`Config/Sedge.entitlements`). On a Mac with Apple silicon, the
  real-model tests below run the same model.
- **Build.** MLX's Metal shaders need Xcode's Metal Toolchain: Xcode > Settings > Components > Metal
  Toolchain, or `xcodebuild -downloadComponent MetalToolchain`.
- **Real-model tests (opt-in, Mac with Apple silicon).** First download the weights into the Hugging Face
  cache (`hf download mlx-community/Qwen3.5-4B-MLX-4bit`). `swift test` can't load MLX's Metal library, so
  run them with xcodebuild from `Packages/SedgeCore`:

  ```sh
  TEST_RUNNER_SEDGE_REAL_MODEL=1 xcodebuild test -scheme SedgeCore -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath ../../build/dd-core -only-testing:SedgeCoreTests/RealModel
  ```

  `-only-testing:SedgeCoreTests/QwenLoadErrors` runs the load-error tests the same way.
- **Why this model.** It runs entirely on the phone, and it had the best accuracy of the on-device models
  without Jev in the validation run below (23 of 40, against 19 for MiniCPM5-2B and 15 for Apple's model).
  Qwen + Jev scored one more (24), but Jev is a cloud call, and Ask keeps every question on the phone.

## Results

The benchmark runs every configuration on the same questions with the same loop and tools. Numbers are
copied exactly from each run's `summary.csv` (accuracy is a fraction of 1; "correct" is the lenient count).
The results folders are not part of this repository.

**Validation split, run `2026-11-06_0753`** (40 questions, median of 3 runs each). The small models ran at
the temperatures in that run's `temperatures.json`: Apple 0.8, Qwen 0.4, MiniCPM 0.0. The app uses 0.

| Configuration | Correct (of 40) | Strict accuracy | Lenient accuracy | Median latency (s) | Dollars per run (median) |
|---|---|---|---|---|---|
| Apple on-device | 15 | 0.075 | 0.375 | 9.644 | 0.0 |
| Qwen3.5-4B | 23 | 0.375 | 0.575 | 4.3995 | 0.0 |
| MiniCPM5-2B | 19 | 0.15 | 0.475 | 2.713 | 0.0 |
| Apple + Jev | 13 | 0.075 | 0.325 | 7.7915 | 0.0014462700000000002 |
| Qwen + Jev | 24 | 0.4 | 0.6 | 3.9284999999999997 | 0.0014462700000000002 |
| MiniCPM + Jev | 18 | 0.15 | 0.45 | 2.7895000000000003 | 0.0014462700000000002 |
| Haiku 5.5 | 32 | 0.8 | 0.8 | 3.0175 | 0.0539752 |
| Haiku 5.5 strict | 28 | 0.675 | 0.7 | 3.637 | 0.0629669 |
| Sonnet 5.5 | 34 | 0.85 | 0.85 | 3.8840000000000003 | 1.020924 |
| Sonnet 5.5 strict | 32 | 0.8 | 0.8 | 4.6695 | 1.21084 |
| Sonnet 5.5, long context | 30 | 0.725 | 0.75 | 3.3150000000000004 | 1.521508 |

**Test splits** (one run each; `test` is the held-out set of 47 questions, `gen_test` the generated set of
1,172). These are the test rows saved in a `summary.csv`:

| Configuration | Run | Split | Correct | Median latency (s) | Dollars |
|---|---|---|---|---|---|
| Qwen3.5-4B, long context | `2026-11-07_2241` | test | 8 of 47 | 7.632 | 0.0 |
| Qwen3.5-4B, long context | `2026-11-07_2241` | gen_test | 362 of 1172 | 7.8045 | 0.0 |
| MiniCPM5-2B, long context | `2026-11-07_2241` | test | 16 of 47 | 8.823 | 0.0 |
| MiniCPM5-2B, long context | `2026-11-07_2241` | gen_test | 325 of 1172 | 8.849499999999999 | 0.0 |
| Sonnet 5.5, no reconciliation | `2026-11-07_1646` | test | 35 of 47 | 3.645 | 1.267458 |
| Sonnet 5.5, no reconciliation | `2026-11-07_1646` | gen_test | 915 of 1172 | 3.2220000000000004 | 29.684450000000002 |

- **Ablations.** Only the reconciliation ablation (`useReconciliation` off) has a saved summary: the last two
  rows above. The graph ablation (`useGraph` off) has no `summary.csv`.
- The test run of the other configurations (`2026-11-06_1441`) saved per-question scores (`scores.csv`)
  but no `summary.csv`, so its totals are not repeated here.
