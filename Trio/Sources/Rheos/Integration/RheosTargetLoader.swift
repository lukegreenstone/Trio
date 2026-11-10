import Foundation
import Swinject

/// Reads Trio's saved BG target schedule. Does not write it.
enum RheosTargetLoader {
    static func schedule(resolver: Resolver) -> RheosTargetSchedule {
        guard let storage = resolver.resolve(FileStorage.self),
              let targets = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self),
              !targets.targets.isEmpty else {
            return RheosTargetSchedule(byHour: [])
        }
        return RheosTargetSchedule.from(entries: targets.targets.map { entry in
            (
                minutes: entry.offset,
                low: NSDecimalNumber(decimal: entry.low).doubleValue,
                high: NSDecimalNumber(decimal: entry.high).doubleValue
            )
        })
    }
}
