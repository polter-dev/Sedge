//
//  SedgeApp.swift
//  Sedge
//
//  Created by Marcus Ruth on 9/28/26.
//

import Foundation
import SedgeCore
import SwiftUI

@main
struct SedgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // The theme's text colors for the whole app: plain text is `ink`, and any text
                // styled `.secondary` takes the second color here, `muted`. Section footers
                // would turn `ink` too, so each footer asks for `.secondary` itself.
                .foregroundStyle(Color.ink, Color.muted)
                // Set by hand because, in dark mode, the system swaps a gray AccentColor for its blue.
                .tint(Color.accent)
        }
    }
}

extension SedgeDatabase {
    /// What the data picker stores for the Plaid bank data.
    static let bankChoice = "bank"

    /// The file for one choice: each persona has its own file, and Plaid data has its own
    /// file that no persona ever uses. Nil for anything else (e.g. a mistyped launch argument).
    static func fileName(for choice: String) -> String? {
        if choice == bankChoice {
            #if DEBUG
            // UI tests launch with `-emptyBank YES` to get a bank file that never syncs, so they
            // see the connect screen whatever this simulator synced before. Debug builds only.
            if UserDefaults.standard.bool(forKey: "emptyBank") { return "sedge-empty-bank.sqlite" }
            #endif
            return "sedge.sqlite"
        }
        return Persona.all.contains(choice) ? "sedge-\(choice).sqlite" : nil
    }

    /// Opens the file for `choice` and gets it ready to read. A persona's file is (re)loaded
    /// from the bundled fake data, so it always has `as_of` 2026-06-30. The bank file keeps
    /// whatever the last Plaid sync saved. Both are organized so store names and kinds exist.
    static func open(_ choice: String) throws -> SedgeDatabase {
        guard let fileName = fileName(for: choice) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        // percentEncoded: false keeps the space in "Application Support" as a space.
        let path = URL.applicationSupportDirectory.appending(path: fileName).path(percentEncoded: false)
        #if DEBUG
        print("Database:", path) // open this file in DB Browser for SQLite
        #endif
        let database = try SedgeDatabase(path: path)
        if choice != bankChoice {
            // The files in Sedge/PersonaData are links to tools/data, copied into the app at build time.
            guard let accounts = Bundle.main.url(forResource: "\(choice).accounts", withExtension: "json"),
                  let transactions = Bundle.main.url(forResource: "\(choice).transactions", withExtension: "json")
            else { throw CocoaError(.fileNoSuchFile) }
            // Saving is matched by id, so loading again on every launch doesn't add copies.
            try Persona.load(accounts: accounts, transactions: transactions, into: database)
        }
        try Organizer.organize(database)
        return database
    }
}
