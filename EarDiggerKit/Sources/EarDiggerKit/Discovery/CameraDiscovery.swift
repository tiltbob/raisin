import Foundation

/// Runs every protocol's discovery concurrently. The scope's own network has exactly one
/// camera on it, so the first discovery to find anything ends the scan; the rest are
/// cancelled rather than waited out.
public enum CameraDiscovery {
    public static func scan(
        binding: SocketBinding,
        extraHosts: [String] = [],
        timeout: TimeInterval = 2.5,
        includeDefaults: Bool = true
    ) async -> [DeviceInfo] {
        let started = Clock.ms()
        DebugLog.log("Discovery", "scan: extraHosts=\(extraHosts) timeout=\(Int(timeout * 1000))ms via \(binding)")
        let cancel = CancelFlag()
        let result = await withTaskCancellationHandler {
            await withTaskGroup(of: [DeviceInfo].self) { group -> [DeviceInfo] in
                group.addTask {
                    await IO.run {
                        TubeDiscovery.probe(
                            binding: binding, extraHosts: extraHosts, timeout: timeout,
                            stopAtFirst: true, includeDefaults: includeDefaults, cancel: cancel
                        )
                    }
                }
                group.addTask {
                    await IO.run {
                        MlDiscovery.probe(binding: binding, extraHosts: extraHosts, includeDefault: includeDefaults, cancel: cancel)
                    }
                }
                if includeDefaults {
                    group.addTask {
                        await IO.run { TubeDiscovery.listenForBeacons(binding: binding, timeout: timeout, cancel: cancel) }
                    }
                }
                var found: [DeviceInfo] = []
                for await list in group where !list.isEmpty {
                    found = list
                    break
                }
                cancel.cancel()
                group.cancelAll()
                return found
            }
        } onCancel: {
            cancel.cancel()
        }
        let summary = result.map { "\($0.host)/\($0.cameraProtocol.rawValue)/\($0.model ?? "-")" }
        DebugLog.log("Discovery", "scan: \(result.count) camera(s) after \(Clock.ms() - started)ms: \(summary)")
        return result
    }
}
