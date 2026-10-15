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
    init() {
        // Open the database now, so its path is printed at launch.
        _ = SedgeDatabase.app
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let question = UserDefaults.standard.string(forKey: "askOnDevice") {
                OnDeviceDebugView(question: question)
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}

extension SedgeDatabase {
    /// The app's database file, opened once at launch.
    ///
    /// Launching with the argument `-persona maya` (Xcode: Product > Scheme >
    /// Edit Scheme > Arguments) opens a separate file and loads that fake
    /// persona into it, so fake data never mixes with the Plaid data.
    static let app: SedgeDatabase = {
        // Launch arguments like `-persona maya` show up in UserDefaults automatically.
        let persona = UserDefaults.standard.string(forKey: "persona")
        let fileName = persona.map { "sedge-\($0).sqlite" } ?? "sedge.sqlite"
        do {
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            // percentEncoded: false keeps the space in "Application Support" as a space.
            let path = URL.applicationSupportDirectory.appending(path: fileName).path(percentEncoded: false)
            #if DEBUG
            print("Database:", path) // open this file in DB Browser for SQLite
            #endif
            let database = try SedgeDatabase(path: path)
            if let persona {
                // The files in Sedge/PersonaData are links to tools/data, copied into the app at build time.
                guard let accounts = Bundle.main.url(forResource: "\(persona).accounts", withExtension: "json"),
                      let transactions = Bundle.main.url(forResource: "\(persona).transactions", withExtension: "json")
                else { fatalError("No bundled data for persona \(persona)") }
                try Persona.load(accounts: accounts, transactions: transactions, into: database)
            }
            return database
        } catch {
            // Without its database the app can't do anything useful, so stop loudly.
            fatalError("Could not open the database: \(error)")
        }
    }()
}
