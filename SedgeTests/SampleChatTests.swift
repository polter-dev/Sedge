//
//  SampleChatTests.swift
//  SedgeTests
//

import Testing
@testable import Sedge

/// The sample conversation compares the same days of earlier months, cut short when a month is.
@Test func monthToDateKeepsTheSameDays() {
    #expect(ChatTurn.monthToDate("2026-06-30", monthsBack: 0) == ("2026-06-01", "2026-06-30"))
    #expect(ChatTurn.monthToDate("2026-06-30", monthsBack: 1) == ("2026-05-01", "2026-05-30"))
    #expect(ChatTurn.monthToDate("2026-03-31", monthsBack: 1) == ("2026-02-01", "2026-02-28"))
    #expect(ChatTurn.monthToDate("2026-01-15", monthsBack: 3) == ("2025-10-01", "2025-10-15"))
}
