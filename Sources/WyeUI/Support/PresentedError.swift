import SwiftUI

/// An error on its way to an alert.
struct PresentedError: Identifiable {
    let id = UUID()
    let message: String

    init(_ error: any Error) {
        message = error.localizedDescription
    }
}

extension View {
    /// Shows an alert while `error` is set, clearing it on dismissal.
    func alert(for error: Binding<PresentedError?>) -> some View {
        alert(
            "That Didn’t Work",
            isPresented: Binding { error.wrappedValue != nil } set: { if !$0 { error.wrappedValue = nil } },
            presenting: error.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }
}
