//
//  SedgeTests.swift
//  SedgeTests
//
//  Created by Marcus Ruth on 9/28/26.
//

import SedgeCore
import Testing
@testable import Sedge

struct SedgeTests {
    /// Each persona and the bank get their own file, and nothing else opens a file.
    @Test func eachChoiceHasItsOwnFile() {
        #expect(SedgeDatabase.fileName(for: "bank") == "sedge.sqlite")
        #expect(SedgeDatabase.fileName(for: "maya") == "sedge-maya.sqlite")
        let personaFiles = Set(Persona.all.compactMap(SedgeDatabase.fileName(for:)))
        #expect(personaFiles.count == Persona.all.count)
        #expect(!personaFiles.contains("sedge.sqlite"))
        #expect(SedgeDatabase.fileName(for: "../maya") == nil)
        #expect(SedgeDatabase.fileName(for: "") == nil)
    }

    /// Opening a persona loads its data with the fixed "today" and organizes it, so the list
    /// shows clean store names next to the raw statement names.
    @Test func openingMayaShowsStoreNames() throws {
        let database = try SedgeDatabase.open("maya")
        #expect(try database.asOf() == Persona.asOf)
        let rows = try ListedTransaction.all(in: database)
        let netflix = rows.filter { $0.name == "NETFLIX.COM" }
        #expect(netflix.count == 6)
        #expect(netflix.allSatisfy { $0.store == "Netflix" && $0.kind == "spending" })
        #expect(rows.contains { $0.kind == "income" })
    }
}
