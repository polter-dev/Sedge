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
    /// The open database and the choice it was opened for, so the tabs never pair one
    /// person's database with another's name while switching.
    @State private var opened: (choice: String, database: SedgeDatabase)?
    @State private var error: String?
    /// True while the data picker is shown over the main tabs.
    @State private var picking = false

    var body: some View {
        Group {
            // A choice with no file (e.g. "" saved by an older version, or a mistyped launch
            // argument) shows the picker itself, since there is nothing to go back to.
            if SedgeDatabase.fileName(for: choice) == nil {
                DataPickerView(choose: { choice = $0 })
            } else if let opened, opened.choice == choice {
                // A new identity per choice: without it SwiftUI reuses the old tabs, and they
                // keep showing the previous data's transactions under the new name.
                MainView(database: opened.database, choice: choice) { picking = true }
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
            DataPickerView(cancel: { picking = false }) { choice = $0; picking = false }
        }
    }
}

/// Picks which data the app shows: one of the fake people, or a real (Sandbox) bank.
struct DataPickerView: View {
    /// Closes the picker without changing anything; nil when there is no data to go back to.
    var cancel: (() -> Void)?
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
                Section("About") {
                    Text("Not financial advice. Demo data is made up.")
                }
            }
            .navigationTitle("Choose data")
            .toolbar {
                if let cancel {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                }
            }
        }
    }
}

/// The main screens for one database.
struct MainView: View {
    let database: SedgeDatabase
    /// A persona's name or "bank", shown under each screen's title so it's clear whose data this is.
    let choice: String
    let changeData: () -> Void
    @State private var rows: [ListedTransaction] = []

    private var isBank: Bool { choice == SedgeDatabase.bankChoice }
    private var dataName: String { isBank ? "Bank" : choice.capitalized }

    var body: some View {
        TabView {
            Tab("Transactions", systemImage: "list.bullet") {
                NavigationStack {
                    Group {
                        if isBank && rows.isEmpty {
                            // Only the bank file is ever handed to the Plaid flow, so a sync
                            // can't write into a persona's file.
                            ConnectBankScreen(database: database, onSynced: reload, useSample: changeData)
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
                    .navigationSubtitle(dataName)
                    .toolbar { changeDataButton }
                }
            }
            Tab("Ask", systemImage: "questionmark.bubble") {
                NavigationStack {
                    AskView(database: database)
                        .navigationTitle("Ask")
                        .navigationSubtitle(dataName)
                        .toolbar { changeDataButton }
                }
            }
            Tab("Spending", systemImage: "chart.bar") {
                NavigationStack {
                    SpendingView(database: database)
                        .navigationTitle("Spending")
                        .navigationSubtitle(dataName)
                        .toolbar { changeDataButton }
                }
            }
            Tab("What if", systemImage: "chart.line.uptrend.xyaxis") {
                NavigationStack {
                    WhatIfView(database: database)
                        .navigationTitle("What if")
                        .navigationSubtitle(dataName)
                        .toolbar { changeDataButton }
                }
            }
            Tab("About you", systemImage: "person.text.rectangle") {
                NavigationStack {
                    ProfileView(database: database)
                        .navigationTitle("What Sedge learned")
                        .navigationSubtitle(dataName)
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
