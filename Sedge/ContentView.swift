//
//  ContentView.swift
//  Sedge
//
//  Created by Marcus Ruth on 9/28/26.
//

import SedgeCore
import SwiftUI

/// The app's root: the main tabs for the chosen data, with the data picker one tap away.
struct ContentView: View {
    /// A persona's name or "bank". It is remembered between launches, so the app opens straight
    /// onto the last chosen data, and Maya's until something else is chosen. The key is "persona"
    /// so launching with `-persona daniel` (Xcode: Edit Scheme > Arguments) picks Daniel too.
    @AppStorage("persona") private var choice = "maya"
    /// The same saved choice, but nil until data has been chosen once, so a fresh install shows Welcome.
    @AppStorage("persona") private var saved: String?
    /// The open database and the choice it was opened for, so the tabs never pair one
    /// person's database with another's name while switching.
    @State private var opened: (choice: String, database: SedgeDatabase)?
    @State private var error: String?
    /// True while the data picker is shown over the main tabs.
    @State private var picking = false
    @State private var tab = MainTab.ask

    var body: some View {
        Group {
            if saved == nil {
                // Nothing chosen yet, so `choice` is still Maya and the database opening below is hers.
                WelcomeView(maya: opened?.database) { choice = $0 }
            } else if SedgeDatabase.fileName(for: choice) == nil {
                // A choice with no file (e.g. "" saved by an older version, or a mistyped launch
                // argument) shows the picker itself, since there is nothing to go back to.
                DataPickerView(choose: { choice = $0 })
            } else if let opened, opened.choice == choice {
                // A new identity per choice: without it SwiftUI reuses the old tabs, and they
                // keep showing the previous data's transactions under the new name.
                MainView(database: opened.database, choice: choice, tab: $tab) { picking = true }
                    .id(choice)
            } else if let error {
                ContentUnavailableView {
                    Label("Couldn't open the data", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Choose other data") { picking = true }
                }
            } else {
                ProgressView()
            }
        }
        // Fills the screen behind the loading and error states; the tabs paint their own.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        // Runs at launch and again whenever the choice changes.
        .task(id: choice) {
            opened = nil
            error = nil
            guard SedgeDatabase.fileName(for: choice) != nil else { return }
            do {
                opened = (choice, try SedgeDatabase.open(choice))
            } catch {
                self.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $picking) {
            DataPickerView(cancel: { picking = false }, current: choice) { choice = $0; picking = false }
        }
    }
}

/// Picks which data the app shows: one of the fake people, or a real (Sandbox) bank.
struct DataPickerView: View {
    /// Closes the picker without changing anything; nil when there is no data to go back to.
    var cancel: (() -> Void)?
    /// The data shown now, marked with a checkmark; nil when nothing is open yet.
    var current: String?
    let choose: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Persona.all, id: \.self) { persona in
                        row(persona.capitalized, systemImage: "person.crop.circle", choice: persona)
                    }
                } header: {
                    Text("Sample people")
                } footer: {
                    Text("Fake data, with today as \(Persona.asOf.displayDate()).").foregroundStyle(.secondary)
                }
                .listRowBackground(Color.group)
                Section {
                    row("Connect bank", systemImage: "building.columns", choice: SedgeDatabase.bankChoice)
                } footer: {
                    Text("Bank data is kept in its own file, apart from the sample people.").foregroundStyle(.secondary)
                }
                .listRowBackground(Color.group)
                Section("About") {
                    Label("Not financial advice. Demo data is made up.", systemImage: "info.circle")
                }
                .listRowBackground(Color.group)
            }
            .themedBackground()
            .navigationTitle("Choose data")
            .toolbar {
                if let cancel {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                }
            }
        }
    }

    /// One choice, with a checkmark when it is the data shown now (as in Settings lists).
    private func row(_ title: String, systemImage: String, choice: String) -> some View {
        Button { choose(choice) } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if choice == current {
                    // VoiceOver hears "Selected" from the trait below instead of "checkmark".
                    Image(systemName: "checkmark").fontWeight(.semibold).accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(choice == current ? .isSelected : [])
    }
}

/// The three tabs, so the open tab can be kept when the data changes.
enum MainTab { case ask, trends, accounts }

/// The main screens for one database, in three tabs: Ask, Trends and Accounts.
struct MainView: View {
    let database: SedgeDatabase
    /// A persona's name or "bank", shown under each screen's title so it's clear whose data this is.
    let choice: String
    /// The open tab. It lives in ContentView, so picking other data from Accounts comes back to Accounts.
    @Binding var tab: MainTab
    let changeData: () -> Void
    /// The Ask box's text. It lives here so Trends can type a question into it before switching tabs.
    @State private var question = ""
    /// The person's own name for this data, kept in the app's settings (one per choice), never in a database.
    @AppStorage private var nickname: String
    /// True while the rename alert is showing; `draft` is what is typed in it.
    @State private var renaming = false
    @State private var draft = ""

    init(database: SedgeDatabase, choice: String, tab: Binding<MainTab>, changeData: @escaping () -> Void) {
        self.database = database
        self.choice = choice
        _tab = tab
        self.changeData = changeData
        // The settings key depends on the choice, so it is set here rather than on the property.
        _nickname = AppStorage(wrappedValue: "", "nickname.\(choice)")
    }

    private var dataName: String { Self.dataName(choice: choice, nickname: nickname) }

    /// The nickname trimmed and capped at 24 characters, or the default name when it is blank.
    static func dataName(choice: String, nickname: String) -> String {
        // Trimmed again after the cap, so a cut at a space doesn't leave one at the end.
        let cleaned = String(nickname.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            .trimmingCharacters(in: .whitespaces)
        if !cleaned.isEmpty { return cleaned }
        return choice == SedgeDatabase.bankChoice ? "Bank" : choice.capitalized
    }

    /// The item in the menu under each tab's title (tap the title to open it).
    private var renameMenu: some View {
        Button("Rename…", systemImage: "pencil") {
            draft = dataName
            renaming = true
        }
    }

    var body: some View {
        // The tab icons are the design's own drawings, kept as template images so they take the tab colors.
        TabView(selection: $tab) {
            Tab("Ask", image: "tab-ask", value: .ask) {
                NavigationStack {
                    AskView(database: database, question: $question) { tab = $0 }
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationSubtitle(dataName)
                        .toolbarTitleMenu { renameMenu }
                }
            }
            Tab("Trends", image: "tab-trends", value: .trends) {
                NavigationStack {
                    SpendingView(database: database) {
                        question = $0
                        tab = .ask
                    }
                        .navigationTitle("Spending")
                        // Inline because iOS shows the title menu only on an inline title.
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationSubtitle(dataName)
                        .toolbarTitleMenu { renameMenu }
                }
            }
            Tab("Accounts", image: "tab-accounts", value: .accounts) {
                NavigationStack {
                    AccountsView(database: database, isBank: choice == SedgeDatabase.bankChoice,
                                 dataName: dataName, changeData: changeData)
                        .navigationTitle("Accounts")
                        // Inline because iOS shows the title menu only on an inline title.
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationSubtitle(dataName)
                        .toolbarTitleMenu { renameMenu }
                        .toolbar { Button("Change data", systemImage: "person.2", action: changeData).symbolRenderingMode(.monochrome) } // One color for both figures: the app's two-color foregroundStyle would paint them in its two theme colors, which fade on the dark top bar.
                }
            }
        }
        .modifier(AccountChecksAfterConnecting(database: database))
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $draft)
            // Saved as typed; dataName(choice:nickname:) trims and caps it wherever it is shown.
            Button("Save") { nickname = draft }
            Button("Use default name") { nickname = "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A blank name goes back to the default.")
        }
    }
}

/// The Accounts tab: the transactions, what Sedge learned about the person, and the saved
/// answers, with the data picker in its toolbar.
struct AccountsView: View {
    let database: SedgeDatabase
    let isBank: Bool
    let dataName: String
    let changeData: () -> Void
    @State private var rows: [ListedTransaction] = []
    @State private var accounts: [ListedAccount] = []
    @State private var resetDone = false
    /// The transaction screen's saved choice to hide its spending note, which this tab can undo.
    @AppStorage("hideSpendingNote") private var noteHidden = false
    /// True while the "Delete all saved answers?" question is showing, so a stray tap can't wipe them.
    @State private var confirmingReset = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    Group {
                        if isBank && rows.isEmpty {
                            // Only the bank file is ever handed to the Plaid flow, so a sync
                            // can't write into a persona's file.
                            ConnectBankScreen(database: database, onSynced: reload, useSample: changeData)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.background)
                        } else {
                            TransactionsView(rows: rows, database: database)
                                .refreshable {
                                    // Pull down to sync again with the same bank login.
                                    guard isBank else { return }
                                    await syncAndReload()
                                }
                        }
                    }
                    .navigationTitle("Transactions")
                    .navigationSubtitle(dataName)
                } label: {
                    Label("Transactions", systemImage: "list.bullet")
                }
                NavigationLink {
                    ProfileView(database: database)
                        .navigationTitle("What Sedge learned")
                        .navigationSubtitle(dataName)
                } label: {
                    Label("About you", systemImage: "person.text.rectangle")
                }
                if !accounts.isEmpty {
                    let unanswered = accounts.count { $0.owner == nil }
                    NavigationLink {
                        YourAccountsView(database: database)
                            .navigationTitle("Your accounts")
                            .navigationSubtitle(dataName)
                    } label: {
                        LabeledContent {
                            Text("\(accounts.count)").foregroundStyle(.secondary)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Your accounts")
                                    if unanswered > 0 {
                                        Text("\(unanswered) still to answer").font(.row).foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "creditcard")
                            }
                        }
                    }
                    .accessibilityLabel("Your accounts")
                    .accessibilityValue(unanswered > 0 ? "\(accounts.count), \(unanswered) still to answer" : "\(accounts.count)")
                }
            }
            .listRowBackground(Color.group)
            Section {
                NavigationLink {
                    SavedAnswersView(database: database)
                        .navigationTitle("Saved answers")
                } label: {
                    Label("Saved answers", systemImage: "tray.full")
                }
                if noteHidden {
                    Button { noteHidden = false } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show the spending note again").foregroundStyle(Color.ink)
                                Text("You hid it on a transaction").font(.row).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "eye")
                        }
                    }
                }
                Button("Reset saved questions", systemImage: "arrow.counterclockwise", role: .destructive) {
                    confirmingReset = true
                }
                // A destructive button colors only its text; this makes the icon match.
                .foregroundStyle(.red)
                // Deleting can't be undone, so ask first. An alert always shows its Cancel button.
                .alert("Delete all saved answers?", isPresented: $confirmingReset) {
                    Button("Delete", role: .destructive) {
                        resetDone = (try? AskUser.reset(database)) != nil
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This can't be undone.")
                }
            } footer: {
                Text(resetDone ? "Saved answers cleared." : "Answers to quick questions are saved, so each is asked only once.")
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.group)
        }
        .themedBackground()
        .task { reload() }
    }

    private func reload() {
        do {
            rows = try ListedTransaction.all(in: database)
            accounts = try ListedAccount.all(in: database)
        } catch {
            print("Could not read transactions or accounts:", error)
        }
    }

    private func syncAndReload() async {
        do {
            try await syncTransactions(into: database)
            reload()
        } catch {
            // localizedDescription is a fixed sentence, never the server's reply.
            print("Sync error:", error.localizedDescription)
        }
    }
}

#Preview("Data picker") {
    DataPickerView { print("Chose", $0) }
}
