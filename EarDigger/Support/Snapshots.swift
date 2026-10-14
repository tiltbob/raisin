import EarDiggerKit
import Foundation
import Photos

/// Writes a JPEG frame, exactly as the camera sent it, to the photo library.
enum Snapshots {
    /// Returns a message for the user.
    static func save(_ jpeg: Data) async -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        let name = "eardigger_\(f.string(from: Date())).jpg"
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else {
            DebugLog.log("Snapshot", "photo library access: \(access.rawValue)")
            return Strings.snapshotDenied
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = name
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpeg, options: options)
            }
            return Strings.snapshotSaved(name)
        } catch {
            DebugLog.log("Snapshot", "save failed", error)
            return Strings.snapshotFailed
        }
    }
}
