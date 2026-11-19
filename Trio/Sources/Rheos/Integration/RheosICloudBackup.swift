import Foundation

/// Optional iCloud Drive copy of `rheos-state.json`.
///
/// `url(forUbiquityContainerIdentifier:)` is nil unless the App ID has iCloud
/// Documents and the installed profile contains the entitlement. In that case
/// this returns nil and Rheos keeps the local file only. No entitlement is
/// shipped here, so a Browser Build does not fail before that capability exists.
enum RheosICloudBackup {
    static func directory() -> URL? {
        #if os(iOS)
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let directory = container.appendingPathComponent("Documents/Rheos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
        #else
        return nil
        #endif
    }
}
