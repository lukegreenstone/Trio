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
        now: Date
    ) -> Outcome {
        let empty = Outcome(
            deliver: false, cancelTemp: false, rate: 0, minutes: 0, smb: 0,
            reason: "Schatten. Eingaben fehlen.", iob: 0, maxIOB: 0, maxBolus: 0, maxBasal: 0, cob: 0
        )
        guard let newest = glucose.max(by: { $0.date < $1.date }) else { return empty }
        if now.timeIntervalSince(newest.date) > 12 * 60 {
            var stale = empty
            stale.cancelTemp = true
            stale.reason = "Glukose älter als 12 Minuten. Kein Insulin."
            return stale
        }
        do {
            let preferences: Preferences = try JSONBridge.from(string: files["preferences"] ?? "")
            let settings: PumpSettings = try JSONBridge.from(string: files["settings"] ?? "")
            var basal: [BasalProfileEntry] = try JSONBridge.from(string: files["basal"] ?? "")
            let targets: BGTargets = try JSONBridge.from(string: files["targets"] ?? "")
            var isf: InsulinSensitivities = try JSONBridge.from(string: files["isf"] ?? "")
            var carbRatios: CarbRatios = try JSONBridge.from(string: files["carbRatios"] ?? "")
            basal = scaleBasal(basal, rheosBasal, ceiling: settings.maxBasal)
            isf = scaleISF(isf, rheosISF)
            carbRatios = scaleCarb(carbRatios, rheosCarbRatio)
            let profile = try ProfileGenerator.generate(
                pumpSettings: settings,
                bgTargets: targets,
                basalProfile: basal,
                isf: isf,
                preferences: preferences,
                carbRatios: carbRatios,
                tempTargets: [],
                clock: now
            )
            var history: [PumpHistoryEvent] = (try? JSONBridge.from(string: files["pumpHistory"] ?? "[]")) ?? []
            history.append(contentsOf: deliveries.map(event))
            let carbs: [CarbsEntry] = (try? JSONBridge.from(string: files["carbHistory"] ?? "[]")) ?? []
            let points = glucose.map { item in
                BloodGlucose(
                    id: UUID().uuidString,
                    sgv: item.mgdl,
                    direction: nil,
                    date: Decimal(item.date.timeIntervalSince1970 * 1000),
                    dateString: item.date,
                    unfiltered: nil,
                    filtered: nil,
                    noise: nil,
                    glucose: item.mgdl
                )
            }
            let autosensJSON = (files["autosens"]?.isEmpty == false) ? files["autosens"]! : "{\"ratio\":1}"
            guard let autosens = try JSONBridge.autosens(from: autosensJSON) else {
                throw DeterminationError.missingInputs
            }
            let iob = try IobGenerator.generate(history: history, profile: profile, clock: now, autosens: autosens)
            let meal = try MealGenerator.generate(
                pumpHistory: history,
                profile: profile,
                basalProfile: basal,
                clock: now,
                carbHistory: carbs,
                glucoseHistory: points
            )
            let custom = TrioCustomOrefVariables(
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
                reservoirData: 50,
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
            let currentIOB = NSDecimalNumber(decimal: iob.first?.iob ?? 0).doubleValue
            smb = min(smb, maxBolus)
            if currentIOB + smb > maxIOB { smb = 0 }
            let cancel = (determination?.rate ?? 0) == 0
            return Outcome(
                deliver: true,
                cancelTemp: cancel,
                rate: max(0, rate),
                minutes: max(0, minutes),
                smb: max(0, smb),
                reason: determination?.reason ?? "Keine Bestimmung.",
                iob: currentIOB,
                maxIOB: maxIOB,
                maxBolus: maxBolus,
                maxBasal: NSDecimalNumber(decimal: settings.maxBasal).doubleValue,
                cob: NSDecimalNumber(decimal: meal?.mealCOB ?? 0).doubleValue
            )
        } catch {
            var failed = empty
            failed.reason = "Bestimmung fehlgeschlagen. Kein Insulin."
            failed.cancelTemp = true
            return failed
        }
    }

    private static func event(_ delivery: Delivery) -> PumpHistoryEvent {
        if delivery.kind == "bolus" {
            return PumpHistoryEvent(
                id: "handyfrei-\(delivery.date.timeIntervalSince1970)",
                type: .smb,
                timestamp: delivery.date,
                amount: Decimal(delivery.units),
                isSMB: true
            )
        }
        return PumpHistoryEvent(
            id: "handyfrei-\(delivery.date.timeIntervalSince1970)",
            type: .tempBasal,
            timestamp: delivery.date,
            duration: delivery.minutes,
            rate: Decimal(delivery.units),
            temp: .absolute
        )
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
