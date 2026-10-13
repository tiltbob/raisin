import SwiftUI
import UIKit

/// A rounded section on the connect screen.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A short message at the bottom of the screen that goes away by itself (Android's toast).
private struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.8), in: Capsule())
                        .padding(.horizontal, 24)
                        .padding(.bottom, 32)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: message)
            .task(id: message) {
                guard message != nil else { return }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if !Task.isCancelled { message = nil }
            }
    }
}

extension View {
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

/// The system share sheet, for the debug report.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A file to hand to the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}
