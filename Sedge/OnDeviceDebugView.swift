//
//  OnDeviceDebugView.swift
//  Sedge
//

#if DEBUG
import Foundation
import SedgeCore
import SwiftUI

/// Debug only: asks one question with Apple's on-device model and shows the answer, until the
/// ask screen gets its own model switch. Turn it on with the launch arguments
/// `-persona maya -askOnDevice "How much did I spend at Netflix from January through June?"`
/// (Xcode: Product > Scheme > Edit Scheme > Arguments). The simulator uses the Mac's model.
struct OnDeviceDebugView: View {
    let question: String
    @State private var answer = "Asking Apple's on-device model…"

    var body: some View {
        VStack(spacing: 12) {
            Text(question).font(.headline)
            Text(answer)
            Label("On device", systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .task {
            if let reason = AppleBackend.unavailableReason() {
                answer = reason
                return
            }
            do {
                // The tools read the store names the organizer builds.
                try Organizer.organize(.app)
            } catch {
                answer = "Could not organize the data: \(error)"
                return
            }
            let trace = await Assistant(backend: AppleBackend(), database: .app).ask(question)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: (try? encoder.encode(trace)) ?? Data(), as: UTF8.self))
            answer = trace.finalAnswer?.answer ?? "No answer: \(trace.error ?? trace.text)"
        }
    }
}
#endif
