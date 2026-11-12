import CoreML
import Foundation

/// Packages a short time window as a Core ML multi-array.
/// The temporal network and the ridge baseline are trained on this iPhone from
/// this dataset only. Wearable channels are absent until they are accepted.
enum RheosCoreMLAdapter {
    static func sequence(_ window: [[Double]]) -> MLMultiArray? {
        guard let width = window.first?.count, width > 0,
              let array = try? MLMultiArray(shape: [
                  NSNumber(value: window.count),
                  NSNumber(value: width)
              ], dataType: .double) else { return nil }
        for time in window.indices {
            for feature in 0 ..< width {
                array[[NSNumber(value: time), NSNumber(value: feature)]] = NSNumber(value: window[time][feature])
            }
        }
        return array
    }

    static func statusLine(_ status: RheosShadowStatus) -> String {
        let card = RheosModelCard.line(
            trained: status.trained,
            networkMAE: status.networkMAE,
            ridgeMAE: status.ridgeMAE,
            source: status.source
        )
        guard status.trained, status.networkMAE != nil || status.ridgeMAE != nil else {
            return "\(card) Signale kommen nur nach einem Ja in das Dosismodell. Sonst bleibt der Median."
        }
        let window = Array(repeating: Array(repeating: 0.0, count: RheosCoreModel.baseFeatureCount), count: 3)
        let packaged = sequence(window) == nil ? "ohne Zeitfenster" : "mit Core-ML-Zeitfenster"
        return "\(card) \(packaged). Signale kommen nur nach einem Ja in das Dosismodell. Sonst bleibt der Median."
    }
}
