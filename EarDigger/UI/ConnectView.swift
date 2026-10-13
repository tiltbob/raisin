import EarDiggerKit
import SwiftUI

/// The connect screen: scopes heard nearby and remembered, the fallbacks, and the debug
/// card a rage shake reveals.
struct ConnectView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var forgetCandidate: NearbyCamera?
    @State private var sharedFile: SharedFile?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Strings.appName)
                            .font(.largeTitle.bold())
                        Text(Strings.tagline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                    nearbyCard
                    if model.debugVisible {
                        debugCard.id("debug")
                    }
                    Text(Strings.privacyNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .onChange(of: model.debugVisible) { visible in
                if visible { withAnimation { proxy.scrollTo("debug", anchor: .top) } }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .toast($model.toast)
        .fullScreenCover(item: $model.viewerDevice) { device in
            ViewerView(device: device, link: model.link) { reason in model.viewerClosed(reason) }
        }
        .alert(
            forgetCandidate.map { Strings.forgetTitle($0.displayName.isEmpty ? $0.ssid : $0.displayName) } ?? "",
            isPresented: Binding(get: { forgetCandidate != nil }, set: { if !$0 { forgetCandidate = nil } }),
            presenting: forgetCandidate
        ) { camera in
            Button(Strings.forget, role: .destructive) { model.forget(camera) }
            Button(Strings.cancel, role: .cancel) {}
        } message: { _ in
            Text(Strings.forgetMessage)
        }
        .sheet(item: $sharedFile) { file in
            ShareSheet(items: [file.url])
        }
        .onAppear { model.screenShown() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: if model.viewerDevice == nil { model.screenShown() }
            case .background: model.screenHidden()
            default: break
            }
        }
    }

    private var nearbyCard: some View {
        Card {
            HStack {
                Text(Strings.sectionNearby)
                    .font(.headline)
                Spacer()
                Button(Strings.findNearby) { model.findNearby() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
            }
            Text(Strings.nearbyHelp)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            HStack(spacing: 8) {
                if model.busy { ProgressView() }
                Text(model.status)
                    .font(.subheadline)
            }
            .padding(.top, 12)
            if !model.notes.isEmpty {
                Text(model.notes.joined(separator: "\n"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            VStack(spacing: 8) {
                ForEach(model.listing) { camera in
                    NearbyRow(camera: camera, onOpen: { model.connectAndOpen(camera) }, onForget: { forgetCandidate = camera })
                        .disabled(model.pendingJoin)
                }
            }
            .padding(.top, 8)
            VStack(alignment: .trailing, spacing: 4) {
                Button(Strings.pickWifi) { model.joinByPrefix() }
                Button(Strings.joinedInSettings) { model.findOnCurrentWifi() }
            }
            .font(.subheadline)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 8)
            .disabled(model.pendingJoin)
        }
    }

    private var debugCard: some View {
        Card {
            Text(Strings.sectionDebug)
                .font(.headline)
            Text(Strings.debugHelp)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ScrollView(.horizontal) {
                Text(model.debugTail)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.top, 8)
            HStack(spacing: 8) {
                Button(Strings.shareLog) {
                    if let url = model.shareReportFile() { sharedFile = SharedFile(url: url) }
                }
                .buttonStyle(.borderedProminent)
                Button(Strings.copyLog) { model.copyReport() }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button(Strings.clearLog) { model.clearLog() }
                Button(Strings.hideLog) { model.hideDebug() }
            }
            .padding(.top, 8)
        }
    }
}
