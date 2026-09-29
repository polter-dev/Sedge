//
//  ConnectBankView.swift
//  Sedge
//
//  Created by Marcus Ruth on 9/30/26.
//

import Foundation
import LinkKit
import SwiftUI


//creates the struct using JSON file from Plaid.
struct LinkTokenResponse: Decodable {
    let link_token: String
}

struct Transaction: Decodable, Identifiable {
    let transaction_id: String
    let account_id: String
    let name: String
    let amount: Double
    let date: String

    var id: String { transaction_id }
}

struct TransactionsResponse: Decodable {
    let latest_transactions: [Transaction]
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

func fetchTransactions() async throws -> [Transaction] {
    let url = URL(string: "http://localhost:8000/api/transactions")!
    let (data, _) = try await URLSession.shared.data(from: url)
    return try JSONDecoder().decode(TransactionsResponse.self, from: data).latest_transactions
}


//diplsay button for connecting a bank account
struct ConnectBankView: View
{
    let linkToken: String
    @State private var linkSession: PlaidLinkSession?
    @State private var isPresentingLink = false
    @State private var isReady = false
    @State private var transactions: [Transaction] = []
    
    var body: some View
    {
        if transactions.isEmpty
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
        else
        {
            List(transactions)
            { transaction in
                HStack
                {
                    VStack(alignment: .leading)
                    {
                        Text(transaction.name)
                        Text(transaction.date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(transaction.amount, format: .currency(code: "USD"))
                }
            }
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
                            let transactions = try await fetchTransactions()
                            for transaction in transactions {
                                print(transaction.date, transaction.name, transaction.amount)
                            }
                            self.transactions = transactions.reversed()
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
