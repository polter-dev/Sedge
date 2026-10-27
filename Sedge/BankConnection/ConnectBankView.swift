//
//  ConnectBankView.swift
//  Sedge
//
//  Created by Marcus Ruth on 9/30/26.
//

import Foundation
import LinkKit
import SedgeCore
import SwiftUI


//creates the struct using JSON file from Plaid.
struct LinkTokenResponse: Decodable {
    let link_token: String
}

/// What the local quickstart server's /api/all_transactions route returns.
/// The module name is spelled out because LinkKit also has an `Account` type
/// and SwiftUI also has a `Transaction` type.
struct AllTransactionsResponse: Decodable {
    let accounts: [SedgeCore.Account]
    let transactions: [SedgeCore.Transaction]
}

//function to grab link token and returns it as as tring
func fetchLinkToken() async throws -> String {
    let url = URL(string: "http://localhost:8000/api/create_link_token")! //force crash if the link doesnt exist
    
    //make and return the request
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    // Give up after 10 seconds instead of the default 60, so the bank screen never just spins.
    request.timeoutInterval = 10
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(LinkTokenResponse.self, from: data).link_token
}

func exchangePublicToken(_ publicToken: String) async throws {
    let url = URL(string: "http://localhost:8000/api/set_access_token")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = "public_token=\(publicToken)".data(using: .utf8)
    // The reply holds the access token, so it is ignored here and never printed.
    _ = try await URLSession.shared.data(for: request)
}

/// Downloads every transaction and account from the quickstart server, saves them into
/// `database` (always the bank file, never a persona's) and rebuilds the store names.
/// Safe to run again: the database updates rows it already has instead of adding copies.
// shortcut: a transaction Plaid later drops entirely (e.g. a cancelled pending charge)
// stays in the database; handle Plaid's `removed` list once sync becomes incremental.
func syncTransactions(into database: SedgeDatabase) async throws {
    let url = URL(string: "http://localhost:8000/api/all_transactions")!
    let (data, _) = try await URLSession.shared.data(from: url)
    let response = try JSONDecoder().decode(AllTransactionsResponse.self, from: data)
    // Plaid data has no fixed "today", so use its newest transaction date rather than the clock.
    guard let asOf = response.transactions.map(\.date).max() else {
        print("Plaid returned no transactions yet")
        return
    }
    try database.save(accounts: response.accounts, transactions: response.transactions, asOf: asOf)
    try Organizer.organize(database)
}

/// The line the bank screen shows when Plaid connected but the transactions didn't arrive.
let bankSyncFailedMessage = "Your bank connected, but its transactions couldn't be downloaded. Try connecting again."

/// Runs after Plaid Link succeeds: swaps the public token on the server, then downloads.
/// Returns nil when it worked, or the line to show on screen when it didn't. The two steps
/// are parameters so a test can make one fail without the quickstart server.
func finishConnecting(
    publicToken: String,
    database: SedgeDatabase,
    exchange: (String) async throws -> Void = exchangePublicToken,
    sync: (SedgeDatabase) async throws -> Void = syncTransactions(into:)
) async -> String? {
    do {
        try await exchange(publicToken)
        try await sync(database)
        return nil
    } catch {
        // localizedDescription is a fixed sentence like "Could not connect to the server.",
        // never the server's reply, so no token can end up in the console.
        print("Bank sync error:", error.localizedDescription)
        return bankSyncFailedMessage
    }
}

/// Gets a link token from the quickstart server, then shows the Connect button. If the server
/// can't be reached, says so in one plain line and offers the sample people instead.
struct ConnectBankScreen: View {
    let database: SedgeDatabase
    let onSynced: () -> Void
    /// Opens the data picker, so a demo can carry on with a sample person.
    let useSample: () -> Void
    @State private var linkToken: String?
    @State private var failed = false

    var body: some View {
        if let linkToken {
            ConnectBankView(linkToken: linkToken, database: database, onSynced: onSynced)
        } else if failed {
            ContentUnavailableView {
                Label("Bank server not running", systemImage: "network.slash")
            } description: {
                Text("The Plaid quickstart server isn't running, so a bank can't be connected.")
            } actions: {
                Button(action: useSample) {
                    // The button's fill is the accent, so its text takes the color made to sit on it.
                    // Left alone it would take the app-wide ink color, which is as dark as the fill in light mode.
                    Text("Use a sample person").foregroundStyle(Color.contrast)
                }
                .buttonStyle(.borderedProminent)
                // Showing the spinner again runs its .task, which asks the server again.
                Button("Try again") { failed = false }
            }
        } else {
            ProgressView()
                .task {
                    do {
                        linkToken = try await fetchLinkToken()
                    } catch {
                        // Only logged: the plain message above covers every way this can fail.
                        // localizedDescription is a fixed sentence, never the server's reply.
                        print("Link token error:", error.localizedDescription)
                        failed = true
                    }
                }
        }
    }
}


//diplsay button for connecting a bank account
struct ConnectBankView: View
{
    let linkToken: String
    /// The bank file. Plaid data is only ever saved here.
    let database: SedgeDatabase
    /// Called after a sync, so the screen can show the new transactions.
    let onSynced: () -> Void
    @State private var linkSession: PlaidLinkSession?
    @State private var isPresentingLink = false
    @State private var isReady = false
    /// The plain line shown under the button when the download after connecting failed.
    @State private var syncFailure: String?

    var body: some View
    {
        VStack(spacing: 12) {
            Button("Connect Account")
            {
                isPresentingLink = true
            }
            .disabled(!isReady)
            if let syncFailure {
                Text(syncFailure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .onAppear(perform: createSession)
        .sheet(isPresented: $isPresentingLink)
        {
            linkSession?.sheet()
        }
    }

    //code from docs
    private func createSession() {
            let configuration = LinkTokenConfiguration(
                token: linkToken,
                onSuccess: { success in
                    // Send success.publicToken to the server. It is never printed.
                    Task {
                        syncFailure = await finishConnecting(publicToken: success.publicToken, database: database)
                        if syncFailure == nil {
                            // The main tabs then ask "Is this account yours?" for each new account.
                            UserDefaults.standard.set(true, forKey: AccountChecksAfterConnecting.pendingKey)
                            onSynced()
                        }
                    }
                    isPresentingLink = false
                },
                onExit: { _ in
                    isPresentingLink = false
                },
                onEvent: { event in
                    // Optionally handle Link events.
                },
                onLoad: {
                    isReady = true
                }
            )

            do {
                linkSession = try Plaid.createPlaidLinkSession(configuration: configuration)
            } catch {
                // Only the error's type: LinkKit's invalid-token error carries a message
                // that may quote the link token.
                print("Link session error:", type(of: error))
            }
        }
    }
