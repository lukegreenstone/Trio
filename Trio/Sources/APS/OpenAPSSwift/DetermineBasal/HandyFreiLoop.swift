import Foundation

/// The same determine-basal the iPhone runs, callable from the watch package.
/// Rheos factors scale the profile inside the existing 0.70...1.20 band. Limits stay the user's.
public enum HandyFreiLoop {
    public struct Outcome: Equatable {
        public var deliver: Bool
        public var cancelTemp: Bool
        public var rate: Double
        public var minutes: Int
        public var smb: Double
        public var reason: String
        public var iob: Double
        public var maxIOB: Double
        public var maxBolus: Double
        public var maxBasal: Double
        public var cob: Double
        /// True only when determine-basal threw. A busy or throttled minute is not a failure.
        public var failed: Bool
    }

    public struct WatchCarb: Equatable {
        public var id: String
        public var date: Date
        public var grams: Double
        public var fat: Double
        public var protein: Double

        public init(id: String, date: Date, grams: Double, fat: Double = 0, protein: Double = 0) {
            self.id = id
            self.date = date
            self.grams = grams
            self.fat = fat
            self.protein = protein
        }
    }

    public struct Delivery: Equatable {
        public var kind: String
        public var units: Double
        public var minutes: Int
        public var date: Date

        public init(kind: String, units: Double, minutes: Int, date: Date) {
            self.kind = kind
            self.units = units
            self.minutes = minutes
            self.date = date
        }
    }

    public static func tick(
        files: [String: String],
        rheosBasal: [Double],
        rheosISF: [Double],
        rheosCarbRatio: [Double],
        glucose: [(date: Date, mgdl: Int)],
        deliveries: [Delivery],
        watchCarbs: [WatchCarb] = [],
        now: Date
    ) -> Outcome {
        let empty = Outcome(
            deliver: false, cancelTemp: false, rate: 0, minutes: 0, smb: 0,
            reason: "Schatten. Eingaben fehlen.", iob: 0, maxIOB: 0, maxBolus: 0, maxBasal: 0, cob: 0, failed: false
        )
        let points = combinedGlucose(files: files, watch: glucose)
        guard let newest = points.max(by: { $0.dateString < $1.dateString }) else { return empty }
        let glucoseIsStale = now.timeIntervalSince(newest.dateString) > 12 * 60
        do {
            let preferences: Preferences = try decode(files, "preferences", "Einstellungen")
            let settings: PumpSettings = try decode(files, "settings", "Pumpeneinstellungen")
            var basal: [BasalProfileEntry] = try decode(files, "basal", "Basalprofil")
            let targets: BGTargets = try decode(files, "targets", "Zielwerte")
            var isf: InsulinSensitivities = try decode(files, "isf", "ISF")
            var carbRatios: CarbRatios = try decode(files, "carbRatios", "KE-Faktor")
            let savedProfile: Profile? = {
                guard let raw = files["profile"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
                return try? JSONBridge.from(string: raw)
            }()
            let profile: Profile
            if let saved = savedProfile, let scaled = saved.basalprofile, !scaled.isEmpty {
                // The phone already applied Rheos and the temp target when it wrote this profile.
                // The watch does not run Rheos again.
                profile = saved
                basal = scaled
            } else {
                basal = scaleBasal(basal, rheosBasal, ceiling: settings.maxBasal)
                isf = scaleISF(isf, rheosISF)
                carbRatios = scaleCarb(carbRatios, rheosCarbRatio)
                let tempTargets: [TempTarget] = (try? JSONBridge.from(string: files["tempTargets"] ?? "")) ?? []
                profile = try ProfileGenerator.generate(
                    pumpSettings: settings,
                    bgTargets: targets,
                    basalProfile: basal,
                    isf: isf,
                    preferences: preferences,
                    carbRatios: carbRatios,
                    tempTargets: tempTargets,
                    clock: now
                )
            }
            var history = try pumpHistory(files).removingDuplicateSuspendResumeEvents()
            let known = Set(history.map(\.id))
            let fresh = deliveries.filter { !alreadyRecorded($0, history) }
            history.append(contentsOf: fresh.flatMap(events).filter { !known.contains($0.id) })
            var carbs: [CarbsEntry] = (try? JSONBridge.from(string: files["carbHistory"] ?? "[]")) ?? []
            let storedCarbs = carbs
            let knownCarbs = Set(storedCarbs.compactMap(\.id))
            carbs.append(contentsOf: watchCarbs.filter { item in
                if knownCarbs.contains(item.id) { return false }
                return !storedCarbs.contains { existing in
                    let when = existing.actualDate ?? existing.createdAt
                    return abs(when.timeIntervalSince(item.date)) < 180
                        && abs(NSDecimalNumber(decimal: existing.carbs).doubleValue - item.grams) < 0.1
                }
            }.map { item in
                CarbsEntry(
                    id: item.id,
                    createdAt: item.date,
                    actualDate: item.date,
                    carbs: Decimal(item.grams),
                    fat: item.fat > 0 ? Decimal(item.fat) : nil,
                    protein: item.protein > 0 ? Decimal(item.protein) : nil,
                    note: nil,
                    enteredBy: "watch",
                    isFPU: nil,
                    fpuID: nil
                )
            })
            let autosens: Autosens
            if files["autosens"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                autosens = try decode(files, "autosens", "Autosens")
            } else {
                autosens = Autosens(
                    ratio: 1,
                    newisf: nil,
                    deviationsUnsorted: nil,
                    timestamp: nil,
                    debugInfo: nil,
                    error: nil
                )
            }
            let iob = try IobGenerator.generate(history: history, profile: profile, clock: now, autosens: autosens)
            let currentIOB = NSDecimalNumber(decimal: iob.first?.iob ?? 0).doubleValue
            let meal = try MealGenerator.generate(
                pumpHistory: history,
                profile: profile,
                basalProfile: basal,
                clock: now,
                carbHistory: carbs,
                glucoseHistory: points
            )
            let currentCOB = NSDecimalNumber(decimal: meal?.mealCOB ?? 0).doubleValue
            if glucoseIsStale {
                var stale = empty
                stale.cancelTemp = true
                stale.iob = currentIOB
                stale.cob = currentCOB
                stale.maxIOB = NSDecimalNumber(decimal: preferences.maxIOB).doubleValue
                stale.maxBolus = NSDecimalNumber(decimal: settings.maxBolus).doubleValue
                stale.maxBasal = NSDecimalNumber(decimal: settings.maxBasal).doubleValue
                stale.reason = "Glukose älter als 12 Minuten. Kein Insulin." + autosensAge(autosens, now: now)
                return stale
            }
            let custom = trioVariables(files) ?? TrioCustomOrefVariables(
                average_total_data: 0, weightedAverage: 0, currentTDD: 0, past2hoursAverage: 0,
                date: now, overridePercentage: 100, useOverride: false, duration: 0, unlimited: false,
                overrideTarget: 0, smbIsOff: false, advancedSettings: false, isfAndCr: false,
                isf: false, cr: false, smbIsScheduledOff: false, start: 0, end: 0, smbMinutes: 0, uamMinutes: 0
            )
            let running = deliveries.last { $0.kind == "temp" && now.timeIntervalSince($0.date) < Double($0.minutes) * 60 }
            let current = TempBasal(
                duration: running.map { max(0, $0.minutes - Int(now.timeIntervalSince($0.date) / 60)) } ?? 0,
                rate: running.map { Decimal($0.units) } ?? 0,
                temp: .absolute,
                timestamp: running?.date ?? now
            )
            let determination = try DeterminationGenerator.generate(
                profile: profile,
                preferences: preferences,
                currentTemp: current,
                iobData: iob,
                mealData: meal ?? ComputedCarbs(
                    carbs: 0, mealCOB: 0, currentDeviation: 0, maxDeviation: 0, minDeviation: 0,
                    slopeFromMaxDeviation: 0, slopeFromMinDeviation: 0, allDeviations: [], lastCarbTime: 0
                ),
                autosensData: autosens,
                reservoirData: reservoir(files),
                glucose: points,
                microBolusAllowed: true,
                trioCustomOrefVariables: custom,
                currentTime: now
            )
            let rate = min(NSDecimalNumber(decimal: determination?.rate ?? 0).doubleValue, NSDecimalNumber(decimal: settings.maxBasal).doubleValue)
            let minutes = min(30, Int(NSDecimalNumber(decimal: determination?.duration ?? 0).doubleValue))
            var smb = NSDecimalNumber(decimal: determination?.units ?? 0).doubleValue
            let maxBolus = NSDecimalNumber(decimal: settings.maxBolus).doubleValue
            let maxIOB = NSDecimalNumber(decimal: preferences.maxIOB).doubleValue
            smb = min(smb, maxBolus)
            if currentIOB + smb > maxIOB { smb = 0 }
            let cancel = (determination?.rate ?? 0) == 0
            return Outcome(
                deliver: true,
                cancelTemp: cancel,
                rate: max(0, rate),
                minutes: max(0, minutes),
                smb: max(0, smb),
                reason: (determination?.reason ?? "Keine Bestimmung.") + autosensAge(autosens, now: now),
                iob: currentIOB,
                maxIOB: maxIOB,
                maxBolus: maxBolus,
                maxBasal: NSDecimalNumber(decimal: settings.maxBasal).doubleValue,
                cob: NSDecimalNumber(decimal: meal?.mealCOB ?? 0).doubleValue,
                failed: false
            )
        } catch {
            var failed = empty
            failed.failed = true
            failed.cancelTemp = false
            failed.reason = "Bestimmung fehlgeschlagen: \(brief(error))"
            return failed
        }
    }

    public static func snapshotReadings(_ files: [String: String]) -> [(date: Date, mgdl: Int)] {
        combinedGlucose(files: files, watch: []).compactMap { point in
            guard let mgdl = point.sgv ?? point.glucose else { return nil }
            return (date: point.dateString, mgdl: mgdl)
        }
    }

    /// Phone glucose is already the series the iPhone algorithm stored. A new watch
    /// value is added only when it is at least 3.5 minutes from every stored point,
    /// the same gap the iPhone uses when it backfills.
    private static func combinedGlucose(
        files: [String: String],
        watch: [(date: Date, mgdl: Int)]
    ) -> [BloodGlucose] {
        var points: [BloodGlucose] = []
        if let raw = files["glucoseHistory"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            points = (try? JSONBridge.from(string: raw)) ?? []
        }
        for sample in watch.sorted(by: { $0.date < $1.date }) {
            if points.contains(where: { abs($0.dateString.timeIntervalSince(sample.date)) < 3.5 * 60 }) { continue }
            points.append(BloodGlucose(
                id: "watch-\(Int(sample.date.timeIntervalSince1970))",
                sgv: sample.mgdl,
                direction: nil,
                date: Decimal(Int64(sample.date.timeIntervalSince1970 * 1000)),
                dateString: sample.date,
                unfiltered: nil,
                filtered: nil,
                noise: nil,
                glucose: sample.mgdl,
                type: "sgv"
            ))
        }
        return points.sorted { $0.dateString < $1.dateString }
    }

    private static func trioVariables(_ files: [String: String]) -> TrioCustomOrefVariables? {
        guard let raw = files["trioVariables"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return try? JSONBridge.from(string: raw)
    }

    private static func reservoir(_ files: [String: String]) -> Decimal {
        let raw = files["reservoir"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let number = raw.replacingOccurrences(of: "\"", with: "")
        return Decimal(string: number) ?? 50
    }

    private static func autosensAge(_ autosens: Autosens, now: Date) -> String {
        guard let timestamp = autosens.timestamp else { return " Autosens ohne Zeitstempel." }
        let minutes = max(0, Int(now.timeIntervalSince(timestamp) / 60))
        return " Autosens vor \(minutes) min."
    }

    /// Settings the meal screen needs. Missing keys keep the iPhone defaults.
    public static func mealSettings(_ files: [String: String]) -> (
        fpu: Bool, adjustment: Decimal, delay: Decimal, interval: Decimal,
        fatty: Bool, fattyFactor: Decimal, sweet: Bool, sweetFactor: Decimal, fraction: Decimal
    ) {
        struct Raw: Decodable {
            var useFPUconversion: Bool?
            var individualAdjustmentFactor: Decimal?
            var delay: Decimal?
            var minuteInterval: Decimal?
            var fattyMeals: Bool?
            var fattyMealFactor: Decimal?
            var sweetMeals: Bool?
            var sweetMealFactor: Decimal?
            var overrideFactor: Decimal?
        }
        let parsed: Raw? = {
            guard let raw = files["trioSettings"]?.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Raw.self, from: raw)
        }()
        return (
            parsed?.useFPUconversion ?? false,
            parsed?.individualAdjustmentFactor ?? Decimal(string: "0.5")!,
            parsed?.delay ?? 60,
            parsed?.minuteInterval ?? 30,
            parsed?.fattyMeals ?? false,
            parsed?.fattyMealFactor ?? Decimal(string: "0.7")!,
            parsed?.sweetMeals ?? false,
            parsed?.sweetMealFactor ?? 1,
            parsed?.overrideFactor ?? Decimal(string: "0.8")!
        )
    }

    public static func bolusContext(_ files: [String: String]) -> (
        isf: Double, carbRatio: Double, target: Double, basal: Double, maxIOB: Double, maxCOB: Double
    ) {
        let profile: Profile? = {
            guard let raw = files["profile"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return try? JSONBridge.from(string: raw)
        }()
        let preferences: Preferences? = {
            guard let raw = files["preferences"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return try? JSONBridge.from(string: raw)
        }()
        let settings: PumpSettings? = {
            guard let raw = files["settings"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return try? JSONBridge.from(string: raw)
        }()
        func number(_ value: Decimal?) -> Double {
            NSDecimalNumber(decimal: value ?? 0).doubleValue
        }
        return (
            number(profile?.sens),
            number(profile?.carbRatio),
            max(number(profile?.minBg), 0),
            number(profile?.currentBasal),
            number(preferences?.maxIOB),
            number(preferences?.maxCOB ?? 120)
        )
    }

    /// Same bolus sum as the iPhone calculator. Immediate carbs only; FPU stays in future COB.
    public static func recommendBolus(
        carbs: Double,
        glucose: Double,
        delta: Double,
        iob: Double,
        cob: Double,
        isf: Double,
        carbRatio: Double,
        target: Double,
        basal: Double,
        fraction: Double,
        fatty: Bool,
        fattyFactor: Double,
        sweet: Bool,
        sweetFactor: Double,
        maxBolus: Double,
        maxIOB: Double,
        maxCOB: Double,
        increment: Double,
        minPredBG: Double,
        lastLoop: Date,
        now: Date
    ) -> Double {
        guard isf > 0, carbRatio > 0, target > 0 else { return 0 }
        if glucose < 54 || minPredBG < 54 || now.timeIntervalSince(lastLoop) > 15 * 60 { return 0 }
        let targetInsulin = (glucose - target) / isf
        let trendInsulin = delta == 0 ? 0 : delta / isf
        let wholeCob = min(cob + carbs, maxCOB)
        let cobInsulin = wholeCob / carbRatio
        var total = targetInsulin - iob + cobInsulin + trendInsulin
        if total > 0 {
            total *= fraction
            if fatty { total *= fattyFactor }
        }
        if sweet { total += sweetFactor * basal }
        total = max(total, 0)
        total = min(total, maxBolus)
        total = min(total, max(0, maxIOB - iob))
        let step = increment > 0 ? increment : 0.05
        return (total / step).rounded(.down) * step
    }

    private static func decode<T: Decodable>(_ files: [String: String], _ key: String, _ name: String) throws -> T {
        let raw = files[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty {
            throw InputError.missing(name)
        }
        do {
            return try JSONBridge.from(string: raw)
        } catch {
            throw InputError.unreadable(name, brief(error))
        }
    }

    private static func pumpHistory(_ files: [String: String]) throws -> [PumpHistoryEvent] {
        let raw = files["pumpHistory"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || raw == "[]" { return [] }
        do {
            return try JSONBridge.from(string: raw)
        } catch {
            throw InputError.unreadable("Pumpenverlauf", brief(error))
        }
    }

    private static func brief(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let shown = text.isEmpty ? String(describing: error) : text
        return shown.count <= 180 ? shown : String(shown.prefix(180))
    }

    /// The phone history uses its own ids after hand-back. Match the dose itself so it is not counted twice.
    private static func alreadyRecorded(_ delivery: Delivery, _ history: [PumpHistoryEvent]) -> Bool {
        history.contains { event in
            guard abs(event.timestamp.timeIntervalSince(delivery.date)) < 180 else { return false }
            if delivery.kind == "bolus" {
                guard event.type == .bolus || event.type == .smb else { return false }
                let amount = NSDecimalNumber(decimal: event.amount ?? -1).doubleValue
                return abs(amount - delivery.units) < 0.051
            }
            guard event.type == .tempBasal else { return false }
            let rate = NSDecimalNumber(decimal: event.rate ?? -1).doubleValue
            return abs(rate - delivery.units) < 0.051
        }
    }

    /// The iPhone stores every temp as a duration entry plus a rate entry. One entry without the other makes IOB throw.
    private static func events(_ delivery: Delivery) -> [PumpHistoryEvent] {
        let id = "handyfrei-\(Int(delivery.date.timeIntervalSince1970))"
        if delivery.kind == "bolus" {
            return [PumpHistoryEvent(
                id: id,
                type: .bolus,
                timestamp: delivery.date,
                amount: Decimal(delivery.units),
                duration: 0,
                isSMB: true,
                isExternal: false
            )]
        }
        return [
            PumpHistoryEvent(
                id: id,
                type: .tempBasalDuration,
                timestamp: delivery.date,
                durationMin: max(0, delivery.minutes)
            ),
            PumpHistoryEvent(
                id: "_\(id)",
                type: .tempBasal,
                timestamp: delivery.date,
                rate: Decimal(delivery.units),
                temp: .absolute
            )
        ]
    }

    private enum InputError: LocalizedError {
        case missing(String)
        case unreadable(String, String)

        var errorDescription: String? {
            switch self {
            case let .missing(name):
                return "fehlt \(name)"
            case let .unreadable(name, detail):
                return "\(name): \(detail)"
            }
        }
    }

    private static func factor(_ factors: [Double], minutes: Int) -> Double {
        guard factors.count == 24 else { return 1 }
        let hour = min(23, max(0, minutes / 60))
        return min(1.2, max(0.7, factors[hour]))
    }

    private static func scaleBasal(_ entries: [BasalProfileEntry], _ factors: [Double], ceiling: Decimal) -> [BasalProfileEntry] {
        entries.map { entry in
            var rate = entry.rate * Decimal(factor(factors, minutes: entry.minutes))
            if ceiling > 0 { rate = min(rate, ceiling) }
            if rate <= 0 { rate = entry.rate }
            return BasalProfileEntry(start: entry.start, minutes: entry.minutes, rate: rate)
        }
    }

    private static func scaleISF(_ schedule: InsulinSensitivities, _ factors: [Double]) -> InsulinSensitivities {
        let values = schedule.sensitivities.map { entry in
            var value = entry.sensitivity * Decimal(factor(factors, minutes: entry.offset))
            if entry.sensitivity >= 5 { value = max(5, value) }
            if value <= 0 { value = entry.sensitivity }
            return InsulinSensitivityEntry(sensitivity: value, offset: entry.offset, start: entry.start)
        }
        return InsulinSensitivities(units: schedule.units, userPreferredUnits: schedule.userPreferredUnits, sensitivities: values)
    }

    private static func scaleCarb(_ schedule: CarbRatios, _ factors: [Double]) -> CarbRatios {
        let values = schedule.schedule.map { entry in
            var value = entry.ratio * Decimal(factor(factors, minutes: entry.offset))
            if entry.ratio >= 1, entry.ratio <= 150 { value = min(150, max(1, value)) }
            if value <= 0 { value = entry.ratio }
            return CarbRatioEntry(start: entry.start, offset: entry.offset, ratio: value)
        }
        return CarbRatios(units: schedule.units, schedule: values)
    }
}
