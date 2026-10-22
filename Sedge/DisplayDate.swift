//
//  DisplayDate.swift
//  Sedge
//

import Foundation

extension String {
    /// A stored "YYYY-MM-DD" date written for people, e.g. "Jun 30, 2026" (or the phone's own
    /// order and language). Only what's shown changes: the data keeps its "YYYY-MM-DD" text.
    /// Text that isn't such a date is returned unchanged.
    func displayDate(_ style: Date.FormatStyle = .dateTime.month(.abbreviated).day().year()) -> String {
        guard let date = try? Date(self, strategy: Date.ISO8601FormatStyle().year().month().day()) else { return self }
        // The date is read as midnight UTC, so it is shown in UTC too; otherwise a phone west of
        // London would show the day before.
        var style = style
        style.timeZone = .gmt
        return date.formatted(style)
    }
}
