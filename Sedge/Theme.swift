//
//  Theme.swift
//  Sedge
//

import SwiftUI

// The Paper (light) and Carbon Soft (dark) colors live in Assets.xcassets, one color set per
// design token with a light and a dark value. Xcode turns each set into a `Color`, so screens
// write `Color.ink`, `Color.muted`, `Color.group` and so on. The design's `accent` token is the
// app's AccentColor set (Xcode names it `Color.accent`), so it also colors every button and toggle.
//
// The Marsh chart colors work the same way, one color set each:
// - `chartNow`: this month's bar, the second mosaic block and the cash-flow line. `chartPast`: the earlier months' bars.
// - `chartPick`: an earlier month page's bar, the shown page's dot and the cash-flow low point.
// - `amountNow`: the big total above the chart.
// - `nodeCategory` and `onNodeCategory`: the biggest mosaic block in Connected spending and the text on the two biggest.
// - `nodeStore`: the other mosaic blocks. `graphLine`: the chart's zero line.
// - `moneySpent` and `moneyBack`: Trends' biggest change when spending rose (red) or fell (green).
// The Ask screen reuses them: `chartNow` for the breakdown bars and the "Sedge" label, `nodeStore`
// for the bar tracks, and `nodeCategory` with `onNodeCategory` text for the first quick-check button.
//
// About you adds its own sets: a fill per kind of tile (`tileIncome`, `tileHousing`, `tileLoan`,
// `tileTuition`, `tileAccounts`), money back and spent (`moneyBack`, `moneySpent`), a fill per
// account type (`accountChecking`, `accountSavings`, `accountCard`) and the text on them (`onAccount`).
//
// The category colors on All months, one color set each: `catHousing`, `catUtilities`,
// `catPhoneInternet`, `catTransport`, `catSubscriptions`, `catEducation` and `catCoffee`.
// `Color.category` picks one by name; categories without a hue of their own use `second`,
// and All months folds them into one "Other" row.

extension Color {
    /// The categories with a hue of their own, by the name the screens show (e.g. "Phone internet").
    static let categoryColors: [String: Color] = [
        "Housing": .catHousing, "Utilities": .catUtilities, "Phone internet": .catPhoneInternet, "Transport": .catTransport,
        "Subscriptions": .catSubscriptions, "Education": .catEducation, "Coffee": .catCoffee,
    ]

    /// A category's color in charts, by the name the screens show; `second` when it has no hue of its own.
    static func category(_ title: String) -> Color { categoryColors[title] ?? .second }

    /// An account's color by its type (the bank's subtype, else its type): cards, savings, and
    /// every other account as checking. About you's tiles and the account check share it.
    static func account(_ type: String?) -> Color {
        type?.contains("credit") == true ? .accountCard : type == "savings" ? .accountSavings : .accountChecking
    }
}

/// The design's type scale on the system font. Each size is the nearest Dynamic Type text
/// style, so the text still grows and shrinks with the reader's text size setting.
extension Font {
    /// The income tile's figure on About you, the biggest number on that screen (34 pt semibold, the large title size).
    static let heroValue = Font.largeTitle.weight(.semibold)
    /// The figure on About you's smaller tiles: loans, tuition and housing (20 pt semibold).
    static let tileValue = Font.title3.weight(.semibold)
    /// The big dollar figure at the top of a card (28 pt semibold in the design).
    static let bigValue = Font.title.weight(.semibold)
    /// A card's title, e.g. "Food & dining" (14 pt semibold).
    static let cardTitle = Font.subheadline.weight(.semibold)
    /// Answers and other running text (16 pt).
    static let answer = Font.callout
    /// Links that lead to another screen, e.g. "See trends & merchants →" (13 pt medium).
    static let link = Font.footnote.weight(.medium)
    /// Rows and small labels (12 pt).
    static let row = Font.caption
    /// Captions under a figure and other fine print (11 pt).
    static let note = Font.caption2
}

extension View {
    /// Shows a List or Form on the theme's screen color instead of the system's gray, so it
    /// matches the design in light and dark. Each section sets `.listRowBackground(Color.group)`
    /// for its rows, because a List can't set that for all of its rows at once.
    func themedBackground() -> some View {
        scrollContentBackground(.hidden).background(Color.background)
    }
}
