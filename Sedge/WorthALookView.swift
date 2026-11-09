//
//  WorthALookView.swift
//  Sedge
//

import SedgeCore
import SwiftUI

/// The "Worth a look" sheet, opened from the row at the bottom of Trends: the recent purchases
/// `WorthALook.flagged` finds, each opening its Transaction screen. Answering "Does this look
/// familiar?" there takes it off the list when coming back.
struct WorthALookView: View {
    let database: SedgeDatabase
    @State private var flags: [WorthALook.Flag]? // nil until loaded, so "Nothing left" never flashes on open
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(flags ?? [], id: \.transaction_id) { flag in
                            if flag.transaction_id != flags?.first?.transaction_id { Rectangle().fill(Color.line).frame(height: 1) }
                            row(flag)
                        }
                    }
                    .background(Color.group, in: .rect(cornerRadius: 14))
                    // Reached only by answering the last one here; Trends hides its row at 0.
                    if flags?.isEmpty == true {
                        Text("Nothing left to look at.").font(.answer).foregroundStyle(Color.ink).padding(.top, 14)
                    }
                    Text("A spending observation, not a judgment.")
                        .font(.row)
                        .foregroundStyle(Color.muted)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color.background)
            .navigationTitle("Worth a look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            // Runs on open and again on coming back from a transaction, so an answered one leaves the list.
            .task {
                do {
                    flags = try WorthALook.flagged(in: database)
                } catch {
                    print("Could not read purchases worth a look:", error)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// One purchase: store, date and reason on the left, amount and › on the right.
    private func row(_ flag: WorthALook.Flag) -> some View {
        // Side by side normally; stacked at the largest text sizes so the store name isn't squeezed.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
        return NavigationLink {
            TransactionDetailView(database: database, id: flag.transaction_id)
        } label: {
            HStack(spacing: 12) {
                layout {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flag.store).font(.answer).foregroundStyle(Color.ink)
                        Text(flag.date.displayDate(.dateTime.month(.abbreviated).day()) + " · " + flag.reason)
                            .font(.row)
                            .foregroundStyle(Color.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(flag.amount, format: .currency(code: "USD"))
                        .font(.answer.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink)
                }
                Image(systemName: "chevron.right")
                    .font(.row)
                    .foregroundStyle(Color.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // VoiceOver reads the row as one item: store, date and reason, amount.
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    WorthALookView(database: try! .open("maya"))
}
