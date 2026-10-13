import EarDiggerKit
import SwiftUI

/// One scope in the nearby list: heard now, remembered, or both.
struct NearbyRow: View {
    let camera: NearbyCamera
    let onOpen: () -> Void
    /// Long press on a remembered scope.
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(camera.displayName.isEmpty ? camera.ssid : camera.displayName)
                    .font(.headline)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(Strings.open, action: onOpen)
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(uiColor: .separator))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(camera.heard ? 1 : 0.7)
        .onTapGesture(perform: onOpen)
        .modifier(ForgetMenu(enabled: camera.remembered, onForget: onForget))
    }

    private var details: String {
        var parts: [String] = []
        // The raw SSID still tells two units of one model apart.
        if camera.ssid.caseInsensitiveCompare(camera.displayName) != .orderedSame { parts.append(camera.ssid) }
        parts.append(camera.heard ? Strings.seenBluetooth : Strings.rememberedTag)
        parts.append(Strings.security(camera.security))
        if camera.heard, let rssi = camera.rssi { parts.append("\(rssi) dBm") }
        if let ms = camera.lastJoinedMs, ms > 0 {
            let when = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            parts.append(Strings.lastUsed(RelativeDateTimeFormatter().localizedString(for: when, relativeTo: Date())))
        }
        return parts.joined(separator: " · ")
    }
}

private struct ForgetMenu: ViewModifier {
    let enabled: Bool
    let onForget: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                Button(role: .destructive, action: onForget) {
                    Label(Strings.forget, systemImage: "trash")
                }
            }
        } else {
            content
        }
    }
}
