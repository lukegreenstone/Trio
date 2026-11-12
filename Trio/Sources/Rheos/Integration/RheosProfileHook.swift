import Foundation

/// Single dosing hook.
///
/// Called only from `OpenAPS.createProfiles`, after the user's basal, ISF and
/// carb-ratio files have been decoded and before `ProfileGenerator` runs.
/// Preferences are not an argument. SMB, UAM, max SMB minutes, max IOB and the
/// autosens limits are therefore copied into the profile exactly as Trio set
/// them. Autosens min/max are read here only to keep the Rheos band inside them.
///
/// The returned schedules are copies. The JSON files the user edits are not written.
/// When the mode is not Scharf, or the model fell back, the original values are
/// returned unchanged so the generated profile matches Trio without Rheos.
enum RheosProfileHook {
    struct Schedules {
        var basal: [BasalProfileEntry]
        var isf: InsulinSensitivities
        var carbRatios: CarbRatios
    }

    static func applying(
        basal: [BasalProfileEntry],
        isf: InsulinSensitivities,
        carbRatios: CarbRatios,
        maxBasal: Decimal,
        autosensMin: Decimal,
        autosensMax: Decimal,
        now: Date
    ) -> Schedules {
        let original = Schedules(basal: basal, isf: isf, carbRatios: carbRatios)
        guard RheosModeStore.current == .scharf else { return original }

        let store = RheosStore.shared
        guard let decision = store.loadDecision(), decision.applied, decision.code == .applied else {
            log(
                store: store,
                applied: false,
                code: store.loadDecision()?.code ?? .fallbackInsufficientData,
                reason: store.loadDecision()?.reason ?? "Rückfall auf Trio. Kein geprüftes Rheos-Modell.",
                factors: .identity,
                bandMinimum: RheosReference.defaultMinimumMultiplier,
                bandMaximum: RheosReference.defaultMaximumMultiplier,
                now: now
            )
            return original
        }

        let band = store.loadBounds().effectiveRange(
            autosensMin: double(autosensMin),
            autosensMax: double(autosensMax)
        )
        let factors = decision.factors.clamped(to: band)
        log(
            store: store,
            applied: true,
            code: .applied,
            reason: decision.reason,
            factors: factors,
            bandMinimum: band.lowerBound,
            bandMaximum: band.upperBound,
            now: now
        )
        // Identity leaves the saved schedule shape untouched. A real scale is
        // expanded to one entry per hour so a flat profile still varies by hour.
        guard !factors.isIdentity,
              !basal.isEmpty,
              !isf.sensitivities.isEmpty,
              !carbRatios.schedule.isEmpty
        else { return original }

        let ceiling = double(maxBasal)
        let basalScaled = scaledHours(
            lookup: basal.map { (minutes: $0.minutes, value: double($0.rate)) },
            factors: factors.basal,
            kind: .basal,
            band: band,
            basalCeiling: ceiling
        )
        let isfScaled = scaledHours(
            lookup: isf.sensitivities.map { (minutes: $0.offset, value: double($0.sensitivity)) },
            factors: factors.isf,
            kind: .isf,
            band: band,
            basalCeiling: nil
        )
        let carbScaled = scaledHours(
            lookup: carbRatios.schedule.map { (minutes: $0.offset, value: double($0.ratio)) },
            factors: factors.carbRatio,
            kind: .carbRatio,
            band: band,
            basalCeiling: nil
        )

        let scaledBasal = basalScaled.enumerated().map { hour, rate in
            BasalProfileEntry(start: clockString(hour: hour), minutes: hour * 60, rate: decimal(rate))
        }
        let scaledISF = InsulinSensitivities(
            units: isf.units,
            userPreferredUnits: isf.userPreferredUnits,
            sensitivities: isfScaled.enumerated().map { hour, sensitivity in
                InsulinSensitivityEntry(
                    sensitivity: decimal(sensitivity),
                    offset: hour * 60,
                    start: clockString(hour: hour)
                )
            }
        )
        let scaledCarbs = CarbRatios(
            units: carbRatios.units,
            schedule: carbScaled.enumerated().map { hour, ratio in
                CarbRatioEntry(start: clockString(hour: hour), offset: hour * 60, ratio: decimal(ratio))
            }
        )
        return Schedules(basal: scaledBasal, isf: scaledISF, carbRatios: scaledCarbs)
    }

    private static func scaledHours(
        lookup entries: [(minutes: Int, value: Double)],
        factors: [Double],
        kind: RheosFactorKind,
        band: ClosedRange<Double>,
        basalCeiling: Double?
    ) -> [Double] {
        let values = (0 ..< 24).map { hour in
            RheosScheduleValue(minutes: hour * 60, value: value(atHour: hour, entries: entries))
        }
        return RheosApplicationPoint.scale(
            values: values,
            factors: factors,
            kind: kind,
            band: band,
            basalCeiling: basalCeiling
        )
    }

    /// Schedule value in force at the start of `hour`, including the overnight wrap
    /// Trio uses when the clock is before the first breakpoint.
    private static func value(atHour hour: Int, entries: [(minutes: Int, value: Double)]) -> Double {
        guard let earliest = entries.min(by: { $0.minutes < $1.minutes }) else { return 0 }
        let eligible = entries.filter { $0.minutes <= hour * 60 }
        if let active = eligible.max(by: { $0.minutes < $1.minutes }) {
            return active.value
        }
        return entries.max(by: { $0.minutes < $1.minutes })?.value ?? earliest.value
    }

    private static func clockString(hour: Int) -> String {
        String(format: "%02d:00:00", hour)
    }

    private static func log(
        store: RheosStore,
        applied: Bool,
        code: RheosDecisionCode,
        reason: String,
        factors: RheosHourlyFactors,
        bandMinimum: Double,
        bandMaximum: Double,
        now: Date
    ) {
        let hour = Calendar.current.component(.hour, from: now)
        store.appendApplication(
            RheosApplicationLog(
                date: now,
                applied: applied,
                code: code,
                reason: reason,
                hour: hour,
                basal: factors.multiplier(at: hour, factors.basal),
                isf: factors.multiplier(at: hour, factors.isf),
                carbRatio: factors.multiplier(at: hour, factors.carbRatio),
                bandMinimum: bandMinimum,
                bandMaximum: bandMaximum
            )
        )
        debug(
            .openAPS,
            "Rheos \(code.rawValue) hour \(hour) basal \(factors.multiplier(at: hour, factors.basal)) isf \(factors.multiplier(at: hour, factors.isf)) cr \(factors.multiplier(at: hour, factors.carbRatio)). \(reason)"
        )
    }

    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    private static func decimal(_ value: Double) -> Decimal {
        NSDecimalNumber(value: value).decimalValue
    }
}
