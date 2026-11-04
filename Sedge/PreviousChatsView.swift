//
//  PreviousChatsView.swift
//  Sedge
//

import SedgeCore
import SwiftUI

/// Previous chats: every saved chat in this dataset, most recently used first, in a sheet over
/// Ask. Tap one to open it; swipe left (or Edit) to delete one.
struct PreviousChatsView: View {
    let database: SedgeDatabase
    /// Opens the tapped chat on the Ask screen.
    let open: (Chats.Chat) -> Void
    /// Told each deleted chat's id, so Ask can leave a chat that no longer exists.
    let deleted: (Int64) -> Void
    @State private var chats: [Chats.Chat] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(chats) { chat in
                        Button { open(chat); dismiss() } label: { row(chat) }
                    }
                    .onDelete(perform: delete)
                } footer: {
                    if !chats.isEmpty {
                        Text("Swipe left to remove a chat.")
                            .font(.row)
                            .foregroundStyle(Color.muted)
                            .frame(maxWidth: .infinity)
                    }
                }
                // The design has no rule under the footer.
                .listSectionSeparator(.hidden, edges: .bottom)
            }
            .listStyle(.plain)
            // The design's 56-point rows.
            .environment(\.defaultMinListRowHeight, 56)
            .overlay {
                if chats.isEmpty {
                    ContentUnavailableView("No previous chats", systemImage: "clock.arrow.circlepath",
                                           description: Text("Questions you ask are saved here."))
                }
            }
            .navigationTitle("Previous chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            do { chats = try Chats.list(in: database) } catch { print("Could not list the chats:", error) }
        }
    }

    /// The title, then when it was last used and a chevron. At the largest text sizes the date
    /// goes under the title, as the design notes ask.
    private func row(_ chat: Chats.Chat) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            Text(chat.title).font(.subheadline).foregroundStyle(Color.ink)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            HStack(spacing: 6) {
                Text(Self.when(chat.updated))
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .font(.row)
            .foregroundStyle(Color.muted)
        }
        .contentShape(Rectangle())
    }

    /// Deletes the swiped chats from the file, then from the list.
    private func delete(_ offsets: IndexSet) {
        do {
            for index in offsets {
                try Chats.delete(chats[index].id, in: database)
                deleted(chats[index].id)
            }
            chats.remove(atOffsets: offsets)
        } catch {
            print("Could not delete the chat:", error)
        }
    }

    /// "Today", "Yesterday", "3 days ago" within the week, then a short date such as "Jun 21".
    /// A label only: it compares with the clock, which data logic never does.
    static func when(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2..<7: return "\(days) days ago"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
