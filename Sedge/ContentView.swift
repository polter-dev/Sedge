//
//  ContentView.swift
//  Sedge
//
//  Created by Marcus Ruth on 9/28/26.
//

import SwiftUI

struct ContentView: View {
    @State private var linkToken: String?

    var body: some View {
        if let linkToken {
            ConnectBankView(linkToken: linkToken)
        } else {
            ProgressView()
                .task {
                    do {
                        linkToken = try await fetchLinkToken()
                    } catch {
                        print("Link token error:", error)
                    }
                }
        }
    }
}

#Preview {
    ContentView()
}
