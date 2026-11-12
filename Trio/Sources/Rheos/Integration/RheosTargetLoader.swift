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

/// Read-only copy of the Trio settings Rheos is allowed to explain. Nothing here is written back.
enum RheosTrioSettingsReader {
    static func reading(resolver: Resolver) -> RheosTrioReading {
        let manager = resolver.resolve(SettingsManager.self)
        let preferences = manager?.preferences
        let settings = manager?.settings
        let percent = NSDecimalNumber(decimal: settings?.overrideFactor ?? 0.8).doubleValue
        let smbOn = preferences?.enableSMBAlways == true
            || preferences?.enableSMBWithCOB == true
            || preferences?.enableSMBWithTemptarget == true
            || preferences?.enableSMBAfterCarbs == true
            || preferences?.enableSMB_high_bg == true
        let schedule = RheosTargetLoader.schedule(resolver: resolver)
        let targets = schedule.isComplete
            ? "\(Int(schedule.byHour.min() ?? 0))–\(Int(schedule.byHour.max() ?? 0)) mg/dL"
            : "kein gespeicherter Plan"
        return RheosTrioReading(
            bolusPercent: percent,
            maxSMBMinutes: NSDecimalNumber(decimal: preferences?.maxSMBBasalMinutes ?? 30).doubleValue,
            maxIOB: NSDecimalNumber(decimal: preferences?.maxIOB ?? 0).doubleValue,
            smbOn: smbOn,
            uamOn: preferences?.enableUAM == true,
            autosensMin: NSDecimalNumber(decimal: preferences?.autosensMin ?? 0.7).doubleValue,
            autosensMax: NSDecimalNumber(decimal: preferences?.autosensMax ?? 1.2).doubleValue,
            targets: targets,
            dynamicISFOn: preferences?.useNewFormula == true,
            closedLoop: settings?.dosingMode == .closed
        )
    }

    static func note(resolver: Resolver) -> String {
        RheosSettingsStory.explain(reading(resolver: resolver))
    }
}
