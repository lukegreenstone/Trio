import Foundation

/// A situation Rheos noticed from glucose or from Health data that has already arrived.
///
/// `insulinNeed` below 1 means less insulin (more sensitive). It never leaves 0.90...1.10.
/// HealthKit is not live: workouts count only after they have ended, sleep only after
/// the interval has ended, steps only once the day is mostly done.
struct RheosInferredContext: Equatable, Identifiable {
    var id: String
    var title: String
    var summary: String
    var insulinNeed: Double
    var from: Date
    var until: Date
}

enum RheosContextInference {
    static let maximumNudge = 0.10

    static func infer(dataset: RheosDataset, now: Date, calendar: Calendar) -> [RheosInferredContext] {
        var found: [RheosInferredContext] = []
        found.append(contentsOf: workouts(dataset.workouts, now: now))
        if let steps = steps(dataset.wearableDays, now: now, calendar: calendar) { found.append(steps) }
        if let pulse = restingHeart(dataset.wearableDays, now: now, calendar: calendar) { found.append(pulse) }
        if let sleep = shortSleep(dataset.sleep, now: now, calendar: calendar) { found.append(sleep) }
        if let rise = unannouncedRise(dataset: dataset, now: now, calendar: calendar) { found.append(rise) }
        if routineIsUnsettled(dataset: dataset, now: now, calendar: calendar) {
            found = found.map { context in
                var copy = context
                copy.insulinNeed = 1 + (context.insulinNeed - 1) * 0.5
                return copy
            }
            found.append(
                RheosInferredContext(
                    id: "routine",
                    title: "Unruhiger Tagesablauf",
                    summary: "Schlaf oder Schritte weichen stark vom Üblichen ab. Rheos dämpft die Kontext-Anpassung und wartet auf mehr Daten. Eine Ankündigung ist nicht nötig.",
                    insulinNeed: 1,
                    from: now,
                    until: now.addingTimeInterval(6 * 3600)
                )
            )
        }
        return found
    }

    static func insulinNeedByHour(_ contexts: [RheosInferredContext], now: Date, calendar: Calendar) -> [Double] {
        let start = calendar.startOfDay(for: now)
        return (0 ..< 24).map { hour in
            guard let slot = calendar.date(byAdding: .hour, value: hour, to: start) else { return 1 }
            let slotEnd = slot.addingTimeInterval(3600)
            var need = 1.0
            for context in contexts where abs(context.insulinNeed - 1) > 0.000_1 {
                if context.from < slotEnd, context.until > slot {
                    need *= context.insulinNeed
                }
            }
            return min(max(need, 1 - maximumNudge), 1 + maximumNudge)
        }
    }

    /// Basal moves with insulin need. ISF and carb ratio move the other way
    /// (a higher need lowers the mg/dL-per-unit and the grams-per-unit).
    static func combine(slow: RheosHourlyFactors, insulinNeed: [Double], band: ClosedRange<Double>) -> RheosHourlyFactors {
        func mix(_ values: [Double], invert: Bool) -> [Double] {
            guard values.count == 24, insulinNeed.count == 24 else { return values }
            return zip(values, insulinNeed).map { value, need in
                let safeNeed = need > 0 ? need : 1
                let multiplier = invert ? (1 / safeNeed) : safeNeed
                return min(max(value * multiplier, band.lowerBound), band.upperBound)
            }
        }
        return RheosHourlyFactors(
            basal: mix(slow.basal, invert: false),
            isf: mix(slow.isf, invert: true),
            carbRatio: mix(slow.carbRatio, invert: true)
        )
    }

    static func suggestion(forAnnouncement kind: String) -> String {
        switch kind {
        case "meal":
            return "Ankündigung gespeichert. Das ist nur ein früher Hinweis: einen Bolus kannst du in Trio selbst prüfen. Rheos gibt ihn nicht. Ohne Ankündigung erkennt Rheos den Anstieg später an der Glukose und passt höchstens ISF, KH-Faktor und Basal im Band an."
        default:
            return "Ankündigung gespeichert. Sie ist freiwillig. Scharf passt ISF, KH-Faktor und Basal an, sobald Training, Puls oder Schlaf in Health stehen. Rheos aktiviert kein Preset und gibt keinen Bolus."
        }
    }

    private static func workouts(_ workouts: [RheosWorkout], now: Date) -> [RheosInferredContext] {
        workouts.compactMap { workout in
            guard workout.durationMinutes >= 20 else { return nil }
            let end = workout.start.addingTimeInterval(workout.durationMinutes * 60)
            guard end <= now, now.timeIntervalSince(end) <= 18 * 3600 else { return nil }
            let name = workout.activity.lowercased()
            let intense = name.contains("hiit") || (workout.averageHeartRate ?? 0) >= 150
            let strength = name.contains("kraft") || name.contains("strength")
            let need = intense ? 1.04 : (strength ? 0.96 : 0.90)
            let title = intense ? "Intensives Training" : (strength ? "Krafttraining" : "Training")
            return RheosInferredContext(
                id: "workout-\(workout.id)",
                title: title,
                summary: "\(workout.activity) ist beendet. HealthKit liefert das nicht live, deshalb zählt erst das Ende. Die nächsten Stunden ändern nur ISF, KH-Faktor und Basal im Band. SMB und UAM laufen weiter.",
                insulinNeed: need,
                from: end,
                until: end.addingTimeInterval(18 * 3600)
            )
        }
    }

    private static func steps(_ days: [RheosWearableDay], now: Date, calendar: Calendar) -> RheosInferredContext? {
        guard calendar.component(.hour, from: now) >= 16 else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let current = days.first(where: { calendar.startOfDay(for: $0.day) == today })?.steps else { return nil }
        let history = days.compactMap { day -> Double? in
            guard calendar.startOfDay(for: day.day) < today else { return nil }
            return day.steps
        }
        guard history.count >= 5, let usual = RheosStats.median(history), usual > 0, current > usual * 1.5 else { return nil }
        return RheosInferredContext(
            id: "steps",
            title: "Viel Bewegung",
            summary: "Die Schritte von heute liegen schon über dem üblichen ganzen Tag. Kein Live-Auslöser.",
            insulinNeed: 0.95,
            from: now,
            until: calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(8 * 3600)
        )
    }

    private static func restingHeart(_ days: [RheosWearableDay], now: Date, calendar: Calendar) -> RheosInferredContext? {
        let today = calendar.startOfDay(for: now)
        guard let current = days.first(where: { calendar.startOfDay(for: $0.day) == today })?.restingHeartRate else { return nil }
        let history = days.compactMap { day -> Double? in
            guard calendar.startOfDay(for: day.day) < today else { return nil }
            return day.restingHeartRate
        }
        guard history.count >= 5, let usual = RheosStats.median(history), current > usual + 10 else { return nil }
        return RheosInferredContext(
            id: "rhr",
            title: "Ruhepuls erhöht",
            summary: "Der heutige Ruhepuls liegt über der eigenen Basis. Das ist ein Tageswert, kein Schlag-für-Schlag-Signal.",
            insulinNeed: 1.08,
            from: today,
            until: calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(12 * 3600)
        )
    }

    private static func shortSleep(_ sleep: [RheosSleepInterval], now: Date, calendar: Calendar) -> RheosInferredContext? {
        let recent = sleep.filter { $0.end <= now && now.timeIntervalSince($0.end) <= 20 * 3600 }
        let hours = recent.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) / 3600 }
        guard hours > 0, hours < 6 else { return nil }
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: today) ?? today
        let until = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: today) ?? from.addingTimeInterval(6 * 3600)
        return RheosInferredContext(
            id: "sleep",
            title: "Kurze Nacht",
            summary: "Die letzte abgeschlossene Nacht war unter 6 Stunden. Schlaf kommt erst nach dem Aufwachen in Health an.",
            insulinNeed: 1.06,
            from: from,
            until: until
        )
    }

    private static func unannouncedRise(dataset: RheosDataset, now: Date, calendar: Calendar) -> RheosInferredContext? {
        let windowStart = now.addingTimeInterval(-2 * 3600)
        let recent = dataset.glucose.filter { $0.date >= windowStart && $0.date <= now && $0.mgdl > 0 }
        guard let latest = recent.max(by: { $0.date < $1.date }) else { return nil }
        let targetTime = latest.date.addingTimeInterval(-60 * 60)
        guard let earlier = recent.min(by: { abs($0.date.timeIntervalSince(targetTime)) < abs($1.date.timeIntervalSince(targetTime)) }),
              abs(earlier.date.timeIntervalSince(targetTime)) <= 30 * 60 else { return nil }
        let rise = latest.mgdl - earlier.mgdl
        let usual = hourlyMedian(dataset.glucose, hour: calendar.component(.hour, from: latest.date), calendar: calendar)
            - hourlyMedian(dataset.glucose, hour: calendar.component(.hour, from: earlier.date), calendar: calendar)
        let carbs = dataset.meals.contains { $0.carbs > 0 && $0.date >= windowStart && $0.date <= now }
        guard rise > 40, rise > usual + 25, !carbs else { return nil }
        return RheosInferredContext(
            id: "unannounced-rise",
            title: "Anstieg ohne Eintrag",
            summary: "Die Glukose ist stärker gestiegen als in dieser Stunde üblich, ohne Kohlenhydrat-Eintrag. Trio korrigiert über SMB und UAM. Rheos gibt keinen Bolus.",
            insulinNeed: 1.06,
            from: now,
            until: now.addingTimeInterval(3 * 3600)
        )
    }

    private static func routineIsUnsettled(dataset: RheosDataset, now: Date, calendar: Calendar) -> Bool {
        guard calendar.component(.hour, from: now) >= 18 else { return false }
        let today = calendar.startOfDay(for: now)
        guard let current = dataset.wearableDays.first(where: { calendar.startOfDay(for: $0.day) == today })?.steps else { return false }
        let history = dataset.wearableDays.compactMap { day -> Double? in
            guard calendar.startOfDay(for: day.day) < today else { return nil }
            return day.steps
        }
        guard history.count >= 5, let usual = RheosStats.median(history), usual > 0 else { return false }
        return current > usual * 2 || current < usual * 0.4
    }

    private static func hourlyMedian(_ glucose: [RheosGlucosePoint], hour: Int, calendar: Calendar) -> Double {
        let values = glucose.compactMap { point -> Double? in
            guard calendar.component(.hour, from: point.date) == hour else { return nil }
            return point.mgdl
        }
        return RheosStats.median(values) ?? RheosReference.glucoseAnchorMgdl
    }
}
