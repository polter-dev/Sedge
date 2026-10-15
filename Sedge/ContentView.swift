//
//  ContentView.swift
//  Sedge
//
//  Created by Marcus Ruth on 9/28/26.
//

import SedgeCore
import SwiftUI

/// The app's root: the data picker until something is chosen, then the main tabs.
struct ContentView: View {
    /// A persona's name, "bank", or "" before anything is chosen. It is remembered between
    /// launches, so the chosen database opens at launch. The key is "persona" so launching
    /// with `-persona maya` (Xcode: Edit Scheme > Arguments) picks Maya too.
    @AppStorage("persona") private var choice = ""
    @State private var database: SedgeDatabase?
    @State private var error: String?

    var body: some View {
        Group {
            if choice.isEmpty {
                DataPickerView { choice = $0 }
            } else if let database {
                MainView(database: database, isBank: choice == SedgeDatabase.bankChoice) { choice = "" }
            } else if let error {
                ContentUnavailableView("Couldn't open the data", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        // Runs at launch and again whenever the choice changes.
        .task(id: choice) {
            database = nil
            error = nil
            guard !choice.isEmpty else { return }
            do {
                database = try SedgeDatabase.open(choice)
            } catch {
                self.error = "\(error)"
            }
        }
    }
}

/// Picks which data the app shows: one of the fake people, or a real (Sandbox) bank.
struct DataPickerView: View {
    let choose: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Persona.all, id: \.self) { persona in
                        Button(persona.capitalized, systemImage: "person.crop.circle") { choose(persona) }
                    }
                } header: {
                    Text("Sample people")
                } footer: {
                    Text("Fake data, with today as \(Persona.asOf).")
                }
                Section {
                    Button("Connect bank", systemImage: "building.columns") { choose(SedgeDatabase.bankChoice) }
                } footer: {
                    Text("Bank data is kept in its own file, apart from the sample people.")
                }
            }
            .navigationTitle("Choose data")
        }
    }
}

/// The two main screens for one database.
struct MainView: View {
    let database: SedgeDatabase
    let isBank: Bool
    let changeData: () -> Void
    @State private var rows: [ListedTransaction] = []

    var body: some View {
        TabView {
            Tab("Transactions", systemImage: "list.bullet") {
                NavigationStack {
                    Group {
                        if isBank && rows.isEmpty {
                            // Only the bank file is ever handed to the Plaid flow, so a sync
                            // can't write into a persona's file.
                            ConnectBankScreen(database: database, onSynced: reload)
                        } else {
                            TransactionsView(rows: rows)
                                .refreshable {
                                    // Pull down to sync again with the same bank login.
                                    guard isBank else { return }
                                    await syncAndReload()
                                }
                        }
                    }
                    .navigationTitle("Transactions")
                    .toolbar { changeDataButton }
                }
            }
            Tab("Ask", systemImage: "questionmark.bubble") {
                NavigationStack {
                    AskView(database: database)
                        .navigationTitle("Ask")
                        .toolbar { changeDataButton }
                }
            }
        }
        .task { reload() }
    }

    private var changeDataButton: some View {
        Button("Change data", systemImage: "person.2", action: changeData)
    }

    private func reload() {
        do {
            rows = try ListedTransaction.all(in: database)
        } catch {
            print("Could not read transactions:", error)
        }
    }

    private func syncAndReload() async {
        do {
            try await syncTransactions(into: database)
            reload()
        } catch {
            print("Sync error:", error)
        }
    }
}

#Preview("Data picker") {
    DataPickerView { print("Chose", $0) }
}
