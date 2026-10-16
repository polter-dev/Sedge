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
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(LinkTokenResponse.self, from: data).link_token
}

func exchangePublicToken(_ publicToken: String) async throws {
    let url = URL(string: "http://localhost:8000/api/set_access_token")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = "public_token=\(publicToken)".data(using: .utf8)
    let (data, _) = try await URLSession.shared.data(for: request)
    print("Exchange response:", String(data: data, encoding: .utf8) ?? "")
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

/// Gets a link token from the quickstart server, then shows the Connect button.
struct ConnectBankScreen: View {
    let database: SedgeDatabase
    let onSynced: () -> Void
    @State private var linkToken: String?
    @State private var error: String?

    var body: some View {
        if let linkToken {
            ConnectBankView(linkToken: linkToken, database: database, onSynced: onSynced)
        } else if let error {
            ContentUnavailableView("Can't reach the bank server", systemImage: "network.slash", description: Text(error))
        } else {
            ProgressView()
                .task {
                    do {
                        linkToken = try await fetchLinkToken()
                    } catch {
                        self.error = error.localizedDescription
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
    
    var body: some View
    {
        Button("Connect Account")
        {
            isPresentingLink = true
        }
        .disabled(!isReady)
        .onAppear(perform: createSession)
        .sheet(isPresented: $isPresentingLink)
        {
            linkSession?.sheet()
        }
    }

    /// Saves everything from Plaid, then lets the screen show it.
    private func sync() async {
        do {
            try await syncTransactions(into: database)
            onSynced()
        } catch {
            print("Sync error:", error)
        }
    }
    //code from docs
    private func createSession() {
            let configuration = LinkTokenConfiguration(
                token: linkToken,
                onSuccess: { success in
                    // Send success.publicToken to your app server.
                    print("Public token:", success.publicToken)
                    Task {
                        do {
                            try await exchangePublicToken(success.publicToken)
                            await sync()
                        } catch {
                            print("Exchange error:", error)
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
                // Handle the error.
                print("Link session error:", error)
            }
        }
    }
