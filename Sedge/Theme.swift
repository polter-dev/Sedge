//
//  Theme.swift
//  Sedge
//

import SwiftUI

// The Paper (light) and Carbon Soft (dark) colors live in Assets.xcassets, one color set per
// design token with a light and a dark value. Xcode turns each set into a `Color`, so screens
// write `Color.ink`, `Color.muted`, `Color.group` and so on. The design's `accent` token is the
// app's AccentColor set (Xcode names it `Color.accent`), so it also colors every button and toggle.

/// The design's type scale on the system font. Each size is the nearest Dynamic Type text
/// style, so the text still grows and shrinks with the reader's text size setting.
extension Font {
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
