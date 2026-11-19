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
        /// A delayed fat-protein row. Its date is the time it starts counting as carbs.
        public var isFPU: Bool
        public var fpuID: String?

        public init(
            id: String,
            date: Date,
            grams: Double,
            fat: Double = 0,
            protein: Double = 0,
            isFPU: Bool = false,
            fpuID: String? = nil
        ) {
            self.id = id
            self.date = date
            self.grams = grams
            self.fat = fat
            self.protein = protein
            self.isFPU = isFPU
            self.fpuID = fpuID
        }
    }

    public struct Delivery: Equatable {
        public var kind: String
        public var units: Double
        public var minutes: Int
        public var date: Date
        /// Shown in the history. Empty keeps the old "bolus" or "temp" wording.
        public var label: String

        public init(kind: String, units: Double, minutes: Int, date: Date, label: String = "") {
            self.kind = kind
            self.units = units
            self.minutes = minutes
            self.date = date
            self.label = label
        }
    }

    public struct HistoryLine: Identifiable, Equatable {
        public var id: String
        public var date: Date
        public var title: String
        public var detail: String
        public var isFPU: Bool

        public init(id: String, date: Date, title: String, detail: String, isFPU: Bool = false) {
            self.id = id
            self.date = date
            self.title = title
            self.detail = detail
            self.isFPU = isFPU
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
            var preferences: Preferences = try decode(files, "preferences", "Einstellungen")
            let settings: PumpSettings = try decode(files, "settings", "Pumpeneinstellungen")
            let mode = dosingMode(files)
            preferences = clampedPreferences(preferences, mode: mode)
            if files["tddSufficient"] == "false", preferences.useNewFormula {
                preferences.useNewFormula = false
                preferences.sigmoid = false
            }
            if preferences.lowTemptargetLowersSensitivity, preferences.autosensMax <= 1 {
                preferences.lowTemptargetLowersSensitivity = false
            }
            let activeTargets = liveTempTargets(files, now: now)
            if let active = activeTargets
                .filter({ NSDecimalNumber(decimal: $0.duration).doubleValue > 0 })
                .max(by: { $0.createdAt < $1.createdAt }),
                let stored = active.halfBasalTarget, stored > 0
            {
                preferences.halfBasalExerciseTarget = stored
            }
            var basal: [BasalProfileEntry] = try decode(files, "basal", "Basalprofil")
            let targets: BGTargets = try decode(files, "targets", "Zielwerte")
            var isf: InsulinSensitivities = try decode(files, "isf", "ISF")
            var carbRatios: CarbRatios = try decode(files, "carbRatios", "KE-Faktor")
            let saved = savedSchedules(files, basal: basal, isf: isf, carbRatios: carbRatios, rheosBasal: rheosBasal, rheosISF: rheosISF, rheosCarbRatio: rheosCarbRatio, maxBasal: settings.maxBasal)
            basal = saved.basal
            isf = saved.isf
            carbRatios = saved.carbRatios
            var profile = try ProfileGenerator.generate(
                pumpSettings: settings,
                bgTargets: targets,
                basalProfile: basal,
                isf: isf,
                preferences: preferences,
                carbRatios: carbRatios,
                tempTargets: activeTargets,
                clock: now
            )
            profile.suspendOnly = mode == "basalTesting"
            let rates = supportedRates(files)
            if !rates.isEmpty { profile.supportedBasalRates = rates }
            var history = try pumpHistory(files).removingDuplicateSuspendResumeEvents()
            history = history.filter { now.timeIntervalSince($0.timestamp) <= 24 * 3600 }
            let known = Set(history.map(\.id))
            let fresh = deliveries.filter { !alreadyRecorded($0, history) }
            history.append(contentsOf: fresh.flatMap(events).filter { !known.contains($0.id) })
            var carbs: [CarbsEntry] = (try? JSONBridge.from(string: files["carbHistory"] ?? "[]")) ?? []
            let storedCarbs = carbs
            let knownCarbs = Set(storedCarbs.compactMap(\.id))
            carbs.append(contentsOf: watchCarbs.filter { item in
                guard item.grams >= 1, !knownCarbs.contains(item.id) else { return false }
                // Same id is already in the file. A hand-back copy has a new id but the same minute and grams.
                return !storedCarbs.contains { existing in
                    let when = existing.actualDate ?? existing.createdAt
                    return abs(when.timeIntervalSince(item.date)) < 45
                        && abs(NSDecimalNumber(decimal: existing.carbs).doubleValue - item.grams) < 0.1
                }
            }.map { carbEntry($0) })
            let dayAgo = now.addingTimeInterval(-24 * 3600)
            carbs = carbs.filter { ($0.actualDate ?? $0.createdAt) >= dayAgo }
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
            let mealHours = NSDecimalNumber(decimal: preferences.maxMealAbsorptionTime).doubleValue + 0.5
            let mealPoints = points.filter { now.timeIntervalSince($0.dateString) <= mealHours * 3600 }
            let meal = try MealGenerator.generate(
                pumpHistory: history,
                profile: profile,
                basalProfile: basal,
                clock: now,
                carbHistory: carbs,
                glucoseHistory: mealPoints
            )
            let currentCOB = NSDecimalNumber(decimal: meal?.mealCOB ?? 0).doubleValue
            if glucoseIsStale {
                var stale = empty
                stale.cancelTemp = mode != "open"
                stale.iob = currentIOB
                stale.cob = currentCOB
                stale.maxIOB = NSDecimalNumber(decimal: preferences.maxIOB).doubleValue
                stale.maxBolus = NSDecimalNumber(decimal: settings.maxBolus).doubleValue
                stale.maxBasal = NSDecimalNumber(decimal: settings.maxBasal).doubleValue
                stale.reason = "Glukose älter als 12 Minuten. Kein Insulin." + autosensAge(autosens, now: now) + reservoir(files).note
                return stale
            }
            let custom = withWatchInsulin(
                expiredOverride(trioVariables(files), now: now) ?? TrioCustomOrefVariables(
                    average_total_data: 0, weightedAverage: 0, currentTDD: 0, past2hoursAverage: 0,
                    date: now, overridePercentage: 100, useOverride: false, duration: 0, unlimited: false,
                    overrideTarget: 0, smbIsOff: false, advancedSettings: false, isfAndCr: false,
                    isf: false, cr: false, smbIsScheduledOff: false, start: 0, end: 0, smbMinutes: 0, uamMinutes: 0
                ),
                deliveries: deliveries,
                basal: basal,
                now: now
            )
            let current = currentTemp(history: history, deliveries: deliveries, now: now)
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
                reservoirData: reservoir(files).units,
                glucose: mealPoints,
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
            let enact = mode != "open"
            return Outcome(
                deliver: enact,
                cancelTemp: enact && cancel,
                rate: max(0, rate),
                minutes: max(0, minutes),
                smb: max(0, smb),
                reason: (determination?.reason ?? "Keine Bestimmung.") + autosensAge(autosens, now: now) + reservoir(files).note,
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
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        // Newest first, the same order the iPhone fetch uses. Meal COB walks the array in that order.
        return points.filter { $0.dateString >= dayAgo }.sorted { $0.dateString > $1.dateString }
    }

    /// Writes the watch meal into the carb file the loop already reads. A later tick still
    /// passes the same rows; matching ids are not added twice.
    public static func rememberCarbs(_ files: inout [String: String], _ items: [WatchCarb]) {
        var existing: [CarbsEntry] = (try? JSONBridge.from(string: files["carbHistory"] ?? "[]")) ?? []
        let ids = Set(existing.compactMap(\.id))
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        existing = existing.filter { ($0.actualDate ?? $0.createdAt) >= dayAgo }
        for item in items where item.grams >= 1 && !ids.contains(item.id) {
            existing.append(carbEntry(item))
        }
        files["carbHistory"] = encodeModel(existing)
    }

    /// Same shape as the iPhone's `mapToCarbsEntry`: the event time is both dates.
    /// A fat-protein row's event time is in the future, so it joins COB only when that time arrives.
    private static func carbEntry(_ item: WatchCarb) -> CarbsEntry {
        CarbsEntry(
            id: item.id,
            createdAt: item.date,
            actualDate: item.date,
            carbs: Decimal(algorithmValue: item.grams),
            fat: item.fat > 0 ? Decimal(algorithmValue: item.fat) : 0,
            protein: item.protein > 0 ? Decimal(algorithmValue: item.protein) : 0,
            note: nil,
            enteredBy: CarbsEntry.local,
            isFPU: item.isFPU,
            fpuID: item.fpuID
        )
    }

    private static func trioVariables(_ files: [String: String]) -> TrioCustomOrefVariables? {
        guard let raw = files["trioVariables"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return try? JSONBridge.from(string: raw)
    }

    /// A temp target counts only until its duration ends. A cancel entry (duration 0) stays.
    private static func liveTempTargets(_ files: [String: String], now: Date) -> [TempTarget] {
        let all: [TempTarget] = (try? JSONBridge.from(string: files["tempTargets"] ?? "")) ?? []
        return all.filter { target in
            guard target.enabled != false else { return false }
            let minutes = NSDecimalNumber(decimal: target.duration).doubleValue
            guard minutes > 0 else { return true }
            return now < target.createdAt.addingTimeInterval(minutes * 60)
        }
    }

    /// Rolls the snapshot TDD forward. The phone's figure covers the 24 hours before the copy.
    /// As those hours fall out of the window, their share is removed and replaced by watch doses
    /// plus the basal schedule. This is not the pump manager's gap inference.
    private static func withWatchInsulin(
        _ variables: TrioCustomOrefVariables,
        deliveries: [Delivery],
        basal: [BasalProfileEntry],
        now: Date
    ) -> TrioCustomOrefVariables {
        var copy = variables
        let elapsedHours = max(0, now.timeIntervalSince(variables.date) / 3600)
        let kept = max(0, (24 - elapsedHours) / 24)
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        let twoHours = now.addingTimeInterval(-2 * 3600)
        func insulin(_ dose: Delivery, after: Date) -> Decimal {
            guard dose.date >= after else { return 0 }
            if dose.kind == "bolus" { return NSDecimalNumber(value: dose.units).decimalValue }
            let hours = min(Double(dose.minutes) * 60, max(0, now.timeIntervalSince(dose.date))) / 3600
            return NSDecimalNumber(value: dose.units * max(0, hours)).decimalValue
        }
        let recent = deliveries.reduce(Decimal(0)) { $0 + insulin($1, after: max(variables.date, dayAgo)) }
        let lastTwo = deliveries.reduce(Decimal(0)) { $0 + insulin($1, after: twoHours) }
        let basalDay = dailyBasal(basal)
        copy.currentTDD = variables.currentTDD * NSDecimalNumber(value: kept).decimalValue + recent + basalDay * NSDecimalNumber(value: 1 - kept).decimalValue
        copy.past2hoursAverage = variables.past2hoursAverage * NSDecimalNumber(value: max(0, (2 - elapsedHours) / 2)).decimalValue + lastTwo
        return copy
    }

    private static func dailyBasal(_ entries: [BasalProfileEntry]) -> Decimal {
        guard !entries.isEmpty else { return 0 }
        var total = Decimal(0)
        for (index, entry) in entries.enumerated() {
            let end = index + 1 < entries.count ? entries[index + 1].minutes : 24 * 60
            let hours = NSDecimalNumber(value: max(0, end - entry.minutes)).decimalValue / 60
            total += entry.rate * hours
        }
        return total
    }

    /// An override with an end time stops when that time is reached. An unlimited one stays.
    private static func expiredOverride(_ variables: TrioCustomOrefVariables?, now: Date) -> TrioCustomOrefVariables? {
        guard var variables else { return nil }
        guard variables.useOverride, !variables.unlimited else { return variables }
        let minutes = NSDecimalNumber(decimal: variables.duration).doubleValue
        guard minutes > 0, now.timeIntervalSince(variables.date) >= minutes * 60 else { return variables }
        variables.useOverride = false
        variables.overridePercentage = 100
        variables.overrideTarget = 0
        variables.smbIsOff = false
        return variables
    }

    private static var rememberedReservoir: Decimal?

    /// A missing reservoir file does not become 50 U. The last real reading is kept and named.
    private static func reservoir(_ files: [String: String]) -> (units: Decimal, note: String) {
        let raw = files["reservoir"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let number = raw.replacingOccurrences(of: "\"", with: "")
        if let value = Decimal(string: number), value > 0 {
            rememberedReservoir = value
            return (value, "")
        }
        if let rememberedReservoir {
            return (rememberedReservoir, " Reservoir letzte Lesung.")
        }
        return (0, " Reservoir unbekannt.")
    }

    public static func autosensAgeMinutes(_ files: [String: String], now: Date) -> Int? {
        guard let raw = files["autosens"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let autosens: Autosens = try? JSONBridge.from(string: raw),
              let timestamp = autosens.timestamp else { return nil }
        return max(0, Int(now.timeIntervalSince(timestamp) / 60))
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
        guard let data = files["trioSettings"]?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (false, Decimal(string: "0.5")!, 60, 30, false, Decimal(string: "0.7")!, false, 1, Decimal(string: "0.8")!)
        }
        func decimal(_ key: String, fallback: Decimal) -> Decimal {
            if let number = object[key] as? NSNumber { return number.decimalValue }
            if let text = object[key] as? String, let value = Decimal(string: text) { return value }
            return fallback
        }
        func flag(_ key: String) -> Bool {
            if let value = object[key] as? Bool { return value }
            if let number = object[key] as? NSNumber { return number.boolValue }
            return false
        }
        return (
            flag("useFPUconversion"),
            decimal("individualAdjustmentFactor", fallback: Decimal(string: "0.5")!),
            decimal("delay", fallback: 60),
            decimal("minuteInterval", fallback: 30),
            flag("fattyMeals"),
            decimal("fattyMealFactor", fallback: Decimal(string: "0.7")!),
            flag("sweetMeals"),
            decimal("sweetMealFactor", fallback: 1),
            decimal("overrideFactor", fallback: Decimal(string: "0.8")!)
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
            let window: TimeInterval = delivery.kind == "bolus" ? 10 * 60 : 180
            guard abs(event.timestamp.timeIntervalSince(delivery.date)) < window else { return false }
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
                isSMB: delivery.label != "Bolus",
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

    public struct SavedOverride: Equatable, Codable {
        public var name: String
        public var percentage: Double
        public var durationMinutes: Double
        public var indefinite: Bool
        public var target: Double
        public var smbIsOff: Bool
        public var isf: Bool
        public var cr: Bool
        public var isfAndCr: Bool
        public var advancedSettings: Bool
        public var smbMinutes: Double
        public var uamMinutes: Double
        public var start: Double
        public var end: Double
        public var smbIsScheduledOff: Bool
    }

    public struct SavedTempTarget: Equatable, Codable {
        public var name: String
        public var target: Double
        public var durationMinutes: Double
        public var halfBasalTarget: Double
    }

    public static func savedOverrides(_ files: [String: String]) -> [SavedOverride] {
        guard let data = files["overridePresets"]?.data(using: .utf8),
              let rows = try? JSONDecoder().decode([SavedOverride].self, from: data) else { return [] }
        return rows
    }

    public static func savedTempTargets(_ files: [String: String]) -> [SavedTempTarget] {
        guard let data = files["tempTargetPresets"]?.data(using: .utf8),
              let rows = try? JSONDecoder().decode([SavedTempTarget].self, from: data) else { return [] }
        return rows
    }

    /// Writes an override into the snapshot variables. The loop applies percentage, ISF/CR and SMB flags from there.
    public static func startOverride(_ files: inout [String: String], _ preset: SavedOverride, now: Date) {
        var base = trioVariables(files) ?? TrioCustomOrefVariables(
            average_total_data: 0, weightedAverage: 1, currentTDD: 0, past2hoursAverage: 0,
            date: now, overridePercentage: 100, useOverride: false, duration: 0, unlimited: false,
            overrideTarget: 0, smbIsOff: false, advancedSettings: false, isfAndCr: false,
            isf: false, cr: false, smbIsScheduledOff: false, start: 0, end: 0, smbMinutes: 30, uamMinutes: 30
        )
        base.date = now
        base.useOverride = true
        base.overridePercentage = NSDecimalNumber(value: preset.percentage).decimalValue
        base.duration = NSDecimalNumber(value: preset.durationMinutes).decimalValue
        base.unlimited = preset.indefinite
        base.overrideTarget = NSDecimalNumber(value: preset.target).decimalValue
        base.smbIsOff = preset.smbIsOff
        base.isf = preset.isf
        base.cr = preset.cr
        base.isfAndCr = preset.isfAndCr
        base.advancedSettings = preset.advancedSettings
        base.smbIsScheduledOff = preset.smbIsScheduledOff
        base.start = NSDecimalNumber(value: preset.start).decimalValue
        base.end = NSDecimalNumber(value: preset.end).decimalValue
        if preset.smbMinutes > 0 { base.smbMinutes = NSDecimalNumber(value: preset.smbMinutes).decimalValue }
        if preset.uamMinutes > 0 { base.uamMinutes = NSDecimalNumber(value: preset.uamMinutes).decimalValue }
        files["trioVariables"] = encodeModel(base)
    }

    public static func stopOverride(_ files: inout [String: String], now: Date) {
        guard var base = trioVariables(files) else { return }
        base.date = now
        base.useOverride = false
        base.overridePercentage = 100
        base.overrideTarget = 0
        base.smbIsOff = false
        base.unlimited = false
        base.duration = 0
        files["trioVariables"] = encodeModel(base)
    }

    public static func startTempTarget(
        _ files: inout [String: String],
        name: String,
        target: Double,
        minutes: Int,
        halfBasal: Double,
        now: Date
    ) {
        var all: [TempTarget] = (try? JSONBridge.from(string: files["tempTargets"] ?? "")) ?? []
        all.append(TempTarget(
            name: name,
            createdAt: now,
            targetTop: NSDecimalNumber(value: target).decimalValue,
            targetBottom: NSDecimalNumber(value: target).decimalValue,
            duration: NSDecimalNumber(value: minutes).decimalValue,
            enteredBy: TempTarget.local,
            reason: name,
            isPreset: false,
            enabled: true,
            halfBasalTarget: NSDecimalNumber(value: halfBasal).decimalValue
        ))
        files["tempTargets"] = encodeModel(all)
    }

    public static func stopTempTarget(_ files: inout [String: String], now: Date) {
        var all: [TempTarget] = (try? JSONBridge.from(string: files["tempTargets"] ?? "")) ?? []
        all.append(TempTarget.cancel(at: now))
        files["tempTargets"] = encodeModel(all)
    }

    /// Same two-window autosens as the iPhone. Returns nil when there is not enough glucose.
    public static func recomputeAutosens(
        files: [String: String],
        glucose: [(date: Date, mgdl: Int)],
        deliveries: [Delivery],
        watchCarbs: [WatchCarb],
        now: Date
    ) -> String? {
        let points = combinedGlucose(files: files, watch: glucose)
        guard points.count >= 72 else { return nil }
        let preferences: Preferences
        let settings: PumpSettings
        let basal: [BasalProfileEntry]
        let isf: InsulinSensitivities
        let carbRatios: CarbRatios
        let targets: BGTargets
        do {
            var decoded: Preferences = try decode(files, "preferences", "Einstellungen")
            decoded = clampedPreferences(decoded, mode: dosingMode(files))
            if files["tddSufficient"] == "false", decoded.useNewFormula {
                decoded.useNewFormula = false
                decoded.sigmoid = false
            }
            preferences = decoded
            settings = try decode(files, "settings", "Pumpeneinstellungen")
            let rawBasal: [BasalProfileEntry] = try decode(files, "basal", "Basalprofil")
            let rawISF: InsulinSensitivities = try decode(files, "isf", "ISF")
            let rawRatios: CarbRatios = try decode(files, "carbRatios", "KE-Faktor")
            let saved = savedSchedules(
                files, basal: rawBasal, isf: rawISF, carbRatios: rawRatios,
                rheosBasal: [], rheosISF: [], rheosCarbRatio: [], maxBasal: settings.maxBasal
            )
            basal = saved.basal
            isf = saved.isf
            carbRatios = saved.carbRatios
            targets = try decode(files, "targets", "Zielwerte")
        } catch {
            return nil
        }
        let profile: Profile
        do {
            profile = try ProfileGenerator.generate(
                pumpSettings: settings,
                bgTargets: targets,
                basalProfile: basal,
                isf: isf,
                preferences: preferences,
                carbRatios: carbRatios,
                tempTargets: liveTempTargets(files, now: now),
                clock: now
            )
        } catch {
            return nil
        }
        var history = (try? pumpHistory(files).removingDuplicateSuspendResumeEvents()) ?? []
        history = history.filter { now.timeIntervalSince($0.timestamp) <= 24 * 3600 }
        let known = Set(history.map(\.id))
        history.append(contentsOf: deliveries.filter { !alreadyRecorded($0, history) }.flatMap(events).filter { !known.contains($0.id) })
        var carbs: [CarbsEntry] = (try? JSONBridge.from(string: files["carbHistory"] ?? "[]")) ?? []
        let knownCarbs = Set(carbs.compactMap(\.id))
        carbs.append(contentsOf: watchCarbs.filter { $0.grams >= 1 && !knownCarbs.contains($0.id) }.map { carbEntry($0) })
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        carbs = carbs.filter { ($0.actualDate ?? $0.createdAt) >= dayAgo }
        let treatments = try? IobHistory.calcTempTreatments(
            history: history.map { $0.computedEvent() },
            profile: profile,
            clock: now,
            autosens: nil,
            zeroTempDuration: nil
        )
        guard let ratio8 = try? AutosensGenerator.generate(
            glucose: points, pumpHistory: history, basalProfile: basal, profile: profile, carbs: carbs,
            tempTargets: liveTempTargets(files, now: now), maxDeviations: 96, clock: now, precomputedTreatments: treatments
        ), let ratio24 = try? AutosensGenerator.generate(
            glucose: points, pumpHistory: history, basalProfile: basal, profile: profile, carbs: carbs,
            tempTargets: liveTempTargets(files, now: now), maxDeviations: 288, clock: now, precomputedTreatments: treatments
        ) else { return nil }
        var chosen = ratio8.ratio < ratio24.ratio ? ratio8 : ratio24
        chosen.timestamp = now
        return encodeModel(chosen)
    }

    /// Insulin lines for the watch history. Snapshot pump history plus doses given on the watch.
    public static func insulinLines(files: [String: String], deliveries: [Delivery], now: Date) -> [HistoryLine] {
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let events = ((try? pumpHistory(files)) ?? []).filter { $0.timestamp >= cutoff }
        let fresh = deliveries.filter { $0.date >= cutoff && !alreadyRecorded($0, events) }
        var lines = events.compactMap { insulinLine($0) }
        lines.append(contentsOf: fresh.map { dose in
            let title = dose.label.isEmpty ? (dose.kind == "temp" ? "Temp" : "Bolus") : dose.label
            let detail = dose.kind == "temp"
                ? String(format: "%.2f U/h · %d min", dose.units, dose.minutes)
                : String(format: "%.2f U", dose.units)
            return HistoryLine(id: "watch-\(dose.kind)-\(Int(dose.date.timeIntervalSince1970))", date: dose.date, title: title, detail: detail)
        })
        return Array(lines.sorted { $0.date > $1.date }.prefix(60))
    }

    /// Meal lines, including delayed fat-protein rows, newest time first.
    public static func mealLines(files: [String: String], carbs: [WatchCarb], now: Date) -> [HistoryLine] {
        let cutoff = now.addingTimeInterval(-24 * 3600)
        var rows: [CarbsEntry] = (try? JSONBridge.from(string: files["carbHistory"] ?? "[]")) ?? []
        let ids = Set(rows.compactMap(\.id))
        rows.append(contentsOf: carbs.filter { !ids.contains($0.id) }.map { carbEntry($0) })
        let lines: [HistoryLine] = rows.compactMap { entry in
            let when = entry.actualDate ?? entry.createdAt
            guard when >= cutoff else { return nil }
            let grams = NSDecimalNumber(decimal: entry.carbs).doubleValue
            let fat = NSDecimalNumber(decimal: entry.fat ?? 0).doubleValue
            let protein = NSDecimalNumber(decimal: entry.protein ?? 0).doubleValue
            if entry.isFPU == true {
                return HistoryLine(
                    id: entry.id ?? UUID().uuidString,
                    date: when,
                    title: "FPU",
                    detail: String(format: "%.0f g KH, verzögert", grams),
                    isFPU: true
                )
            }
            guard grams > 0 || fat > 0 || protein > 0 else { return nil }
            return HistoryLine(
                id: entry.id ?? UUID().uuidString,
                date: when,
                title: "Mahlzeit",
                detail: String(format: "%.0f g KH · %.0f g Fett · %.0f g Eiweiß", grams, fat, protein)
            )
        }
        return Array(lines.sorted { $0.date > $1.date }.prefix(60))
    }

    private static func insulinLine(_ event: PumpHistoryEvent) -> HistoryLine? {
        switch event.type {
        case .bolus, .smb:
            let units = NSDecimalNumber(decimal: event.amount ?? 0).doubleValue
            guard units >= 0.01 else { return nil }
            let smb = event.type == .smb || event.isSMB == true
            return HistoryLine(id: event.id, date: event.timestamp, title: smb ? "SMB" : "Bolus", detail: String(format: "%.2f U", units))
        case .tempBasal:
            if event.isScheduledBasal == true { return nil }
            let rate = NSDecimalNumber(decimal: event.rate ?? 0).doubleValue
            let minutes = event.durationMin ?? event.duration ?? 0
            return HistoryLine(id: event.id, date: event.timestamp, title: "Temp", detail: String(format: "%.2f U/h · %d min", rate, minutes))
        case .pumpSuspend:
            return HistoryLine(id: event.id, date: event.timestamp, title: "Stopp", detail: "Basal aus")
        case .pumpResume:
            return HistoryLine(id: event.id, date: event.timestamp, title: "Weiter", detail: "Basal an")
        default:
            return nil
        }
    }

    private static func encodeModel<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .customISO8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Open Loop must not change the pump. Every other mode may.
    public static func enactsInsulin(_ files: [String: String]) -> Bool {
        dosingMode(files) != "open"
    }

    /// Closed is the default so an old snapshot that has no mode still doses.
    private static func dosingMode(_ files: [String: String]) -> String {
        guard let data = files["trioSettings"]?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["dosingMode"] as? String, !raw.isEmpty else { return "closed" }
        return raw
    }

    /// Same limits the iPhone applies for Low Glucose Suspend and Basal Testing. The stored settings stay unchanged.
    private static func clampedPreferences(_ preferences: Preferences, mode: String) -> Preferences {
        var clamped = preferences
        switch mode {
        case "lowGlucoseSuspend":
            clamped.maxIOB = 0
        case "basalTesting":
            clamped.maxIOB = 0
            clamped.autosensMin = 1
            clamped.autosensMax = 1
            clamped.useNewFormula = false
            clamped.sigmoid = false
            if clamped.threshold_setting < 72 { clamped.threshold_setting = 72 }
        default:
            break
        }
        return clamped
    }

    /// The phone profile already contains the Rheos hourly basal, ISF and carb ratio.
    /// A snapshot without that profile falls back to the factor arrays.
    private static func savedSchedules(
        _ files: [String: String],
        basal: [BasalProfileEntry],
        isf: InsulinSensitivities,
        carbRatios: CarbRatios,
        rheosBasal: [Double],
        rheosISF: [Double],
        rheosCarbRatio: [Double],
        maxBasal: Decimal
    ) -> (basal: [BasalProfileEntry], isf: InsulinSensitivities, carbRatios: CarbRatios) {
        let saved: Profile? = {
            guard let raw = files["profile"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return try? JSONBridge.from(string: raw)
        }()
        if let scaled = saved?.basalprofile, scaled.count > 1 {
            var chosenISF = isf
            if let profileISF = saved?.isfProfile?.toInsulinSensitivities(), !profileISF.sensitivities.isEmpty {
                chosenISF = profileISF
            }
            var chosenRatios = carbRatios
            if let profileRatios = saved?.carbRatios, !profileRatios.schedule.isEmpty {
                chosenRatios = profileRatios
            }
            return (scaled, chosenISF, chosenRatios)
        }
        return (
            scaleBasal(basal, rheosBasal, ceiling: maxBasal),
            scaleISF(isf, rheosISF),
            scaleCarb(carbRatios, rheosCarbRatio)
        )
    }

    private static func supportedRates(_ files: [String: String]) -> [Decimal] {
        guard let data = files["supportedBasalRates"]?.data(using: .utf8) else { return [] }
        if let numbers = try? JSONDecoder().decode([Double].self, from: data) {
            return numbers.map { Decimal($0) }
        }
        if let numbers = try? JSONDecoder().decode([Decimal].self, from: data) {
            return numbers
        }
        return []
    }

    /// The temp still running on the pump. A watch dose wins when it is newer than the copied history.
    private static func currentTemp(history: [PumpHistoryEvent], deliveries: [Delivery], now: Date) -> TempBasal {
        let idle = TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now)
        let fromDelivery: (date: Date, temp: TempBasal)? = deliveries.last(where: {
            $0.kind == "temp" && now.timeIntervalSince($0.date) < Double(max($0.minutes, 0)) * 60
        }).map { dose in
            let elapsed = Int(now.timeIntervalSince(dose.date) / 60)
            return (dose.date, TempBasal(duration: max(0, dose.minutes - elapsed), rate: Decimal(dose.units), temp: .absolute, timestamp: now))
        }
        let fromHistory = history
            .filter { $0.type == .tempBasal && $0.isScheduledBasal != true }
            .max(by: { $0.timestamp < $1.timestamp })
            .flatMap { event -> (date: Date, temp: TempBasal)? in
                let duration = history.first {
                    $0.type == .tempBasalDuration && abs($0.timestamp.timeIntervalSince(event.timestamp)) < 2
                }?.durationMin ?? event.durationMin ?? event.duration ?? 0
                let elapsed = Int(now.timeIntervalSince(event.timestamp) / 60)
                let left = duration - elapsed
                guard left > 0 else { return nil }
                return (event.timestamp, TempBasal(duration: left, rate: event.rate ?? 0, temp: .absolute, timestamp: now))
            }
        switch (fromDelivery, fromHistory) {
        case let (delivery?, copied?):
            return delivery.date >= copied.date ? delivery.temp : copied.temp
        case let (delivery?, nil):
            return delivery.temp
        case let (nil, copied?):
            return copied.temp
        default:
            return idle
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
