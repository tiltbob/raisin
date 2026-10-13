import EarDiggerKit
import SwiftUI

/// Full-screen live picture with the battery, the tip light and snapshots.
struct ViewerView: View {
    @StateObject private var model: ViewerModel
    @Environment(\.scenePhase) private var scenePhase
    /// Called when the viewer should go away; the reason when it was not the user's doing.
    private let onClose: (String?) -> Void

    init(device: DeviceInfo, link: NetworkLink, onClose: @escaping (String?) -> Void) {
        _model = StateObject(wrappedValue: ViewerModel(info: device, link: link))
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraView(model: model, circular: model.autoRotate)
                .ignoresSafeArea()
            if let status = model.status {
                Text(status)
                    .font(.body)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(24)
            }
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                bottomBar
            }
            .padding(12)
        }
        .toast($model.toast)
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.stop()
        }
        .onChange(of: scenePhase) { phase in
            // Sockets do not survive the background; start over when the viewer returns.
            switch phase {
            case .background: model.stop()
            case .active: model.start()
            default: break
            }
        }
        .onChange(of: model.endedBecause) { reason in
            if let reason { onClose(reason) }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                onClose(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(Strings.close)
            Text(model.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(model.fps)
                .font(.caption.monospacedDigit())
            Text(model.battery)
                .font(.caption.monospacedDigit())
        }
        .foregroundColor(.white)
        .padding(10)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(Strings.light)
                Slider(value: $model.light, in: 0...100, step: 1, onEditingChanged: { editing in
                    model.lightEditing(editing)
                })
                Text(model.lightShown ? "\(Int(model.light))" : "")
                    .font(.body.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Button {
                    model.toggleRotation()
                } label: {
                    Text(model.autoRotate ? Strings.rotationAuto : Strings.rotationOff)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    model.snapshot()
                } label: {
                    Text(Strings.snapshot)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .foregroundColor(.white)
        .padding(10)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
