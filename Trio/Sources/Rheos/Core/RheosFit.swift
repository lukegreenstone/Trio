import Foundation

/// The user's Trio BG target, one value per clock hour, in mg/dL.
/// Built from the target schedule Trio already stores. Rheos does not write that schedule.
struct RheosTargetSchedule: Equatable {
    var byHour: [Double]

    static func flat(_ value: Double) -> RheosTargetSchedule {
        RheosTargetSchedule(byHour: Array(repeating: value, count: 24))
    }

    /// `minutes` is minutes from midnight, matching Trio's BG target `offset`.
    /// The reference is the middle of the low/high range. A flat 100/100 target stays 100.
    static func from(entries: [(minutes: Int, low: Double, high: Double)]) -> RheosTargetSchedule {
        let usable = entries.filter { $0.low.isFinite && $0.high.isFinite && $0.low > 0 && $0.high > 0 }
        guard !usable.isEmpty else { return RheosTargetSchedule(byHour: []) }
        let hours = (0 ..< 24).map { hour -> Double in
            let minute = hour * 60
            let active = usable.filter { $0.minutes <= minute }.max(by: { $0.minutes < $1.minutes })
                ?? usable.max(by: { $0.minutes < $1.minutes })
            let low = active?.low ?? usable[0].low
            let high = active?.high ?? usable[0].high
            return (low + high) / 2
        }
        return RheosTargetSchedule(byHour: hours)
    }

    var isComplete: Bool { byHour.count == 24 && byHour.allSatisfy { $0.isFinite && $0 > 0 } }

    func value(atHour hour: Int) -> Double {
        guard isComplete else { return RheosReference.missingTargetFallbackMgdl }
        return byHour[min(23, max(0, hour))]
    }
}

struct RheosMealPresetLearning: Equatable, Identifiable {
    var id: String
    var count: Int
    var medianDelta2h: Double?
    var medianDelta4h: Double?
    var medianAbsorptionHours: Double?
    var lateFatty4amRise: Double?
    /// Text only. Confirming it records a note. It is not a bolus.
    var suggestion: String
}

enum RheosFit {
    struct Observation {
        var day: Date
        var hour: Int
        var glucose: Double
        var target: Double
        var iob: Double
        var activeCarbs: Double
    }

    struct Model {
        var factors: RheosHourlyFactors
        /// mg/dL per unit of IOB. Zero when the fit had the wrong sign.
        var iobSlope: Double
        /// mg/dL per gram of still-active carbohydrate. Zero when the fit had the wrong sign.
        var carbSlope: Double
    }

    static func observations(
        dataset: RheosDataset,
        targets: RheosTargetSchedule,
        calendar: Calendar
    ) -> [Observation] {
        dataset.glucose.compactMap { point in
            guard point.mgdl.isFinite, point.mgdl > 0 else { return nil }
            let hour = calendar.component(.hour, from: point.date)
            let state = nearestState(at: point.date, states: dataset.states)
            return Observation(
                day: calendar.startOfDay(for: point.date),
                hour: hour,
                glucose: point.mgdl,
                target: targets.value(atHour: hour),
                iob: state.iob,
                activeCarbs: activeCarbs(at: point.date, meals: dataset.meals)
            )
        }
    }

    /// Ridge regression of (glucose − target) on IOB and still-active carbs,
    /// then a per-hour factor with shrinkage toward 1 and toward the neighbouring hours.
    static func fit(observations: [Observation], band: ClosedRange<Double>) -> Model {
        let slopes = slopes(observations)
        var residualByHour: [Int: [Double]] = [:]
        for observation in observations {
            let explained = slopes.iob * observation.iob + slopes.carb * observation.activeCarbs
            let residual = (observation.glucose - observation.target) - explained
            residualByHour[observation.hour, default: []].append(residual)
        }
        var basal = Array(repeating: 1.0, count: 24)
        var isf = Array(repeating: 1.0, count: 24)
        var counts = Array(repeating: 0, count: 24)
        for hour in 0 ..< 24 {
            guard let values = residualByHour[hour], values.count >= RheosReference.minimumSamplesPerHour,
                  let mean = RheosStats.mean(values) else { continue }
            let target = observations.first { $0.hour == hour }?.target ?? RheosReference.missingTargetFallbackMgdl
            let delta = mean / max(target, 1)
            basal[hour] = 1 + RheosReference.deviationGain * delta
            isf[hour] = 1 - RheosReference.deviationGain * delta
            counts[hour] = values.count
        }
        basal = smooth(shrink(basal, counts: counts), band: band)
        isf = smooth(shrink(isf, counts: counts), band: band)
        return Model(factors: RheosHourlyFactors(basal: basal, isf: isf, carbRatio: Array(repeating: 1, count: 24)), iobSlope: slopes.iob, carbSlope: slopes.carb)
    }

    static func predict(_ observation: Observation, model: Model) -> Double {
        let factor = model.factors.basal.count == 24 ? model.factors.basal[observation.hour] : 1
        let residual = (factor - 1) / RheosReference.deviationGain * observation.target
        let explained = model.iobSlope * observation.iob + model.carbSlope * observation.activeCarbs
        return observation.target + explained + residual
    }

    static func carbRatioFactors(
        dataset: RheosDataset,
        targets: RheosTargetSchedule,
        band: ClosedRange<Double>,
        calendar: Calendar
    ) -> [Double] {
        var raw = Array(repeating: 1.0, count: 24)
        var counts = Array(repeating: 0, count: 24)
        guard dataset.meals.count >= RheosReference.minimumMealsForCarbRatio else {
            return raw
        }
        var byHour: [Int: [Double]] = [:]
        for meal in dataset.meals {
            guard let before = RheosStats.nearest(dataset.glucose, to: meal.date, within: 45 * 60),
                  let after = RheosStats.nearest(dataset.glucose, to: meal.date.addingTimeInterval(3 * 3600), within: 45 * 60)
            else { continue }
            let hour = calendar.component(.hour, from: meal.date)
            let target = targets.value(atHour: hour)
            let delta = (after - before - RheosReference.expectedMealRiseMgdl) / max(target, 1)
            byHour[hour, default: []].append(1 - RheosReference.deviationGain * delta)
        }
        for hour in 0 ..< 24 {
            guard let values = byHour[hour], values.count >= 2, let median = RheosStats.median(values) else { continue }
            raw[hour] = median
            counts[hour] = values.count
        }
        return raw.enumerated().map { hour, value in
            let n = Double(counts[hour])
            guard n > 0 else { return 1 }
            let shrunk = (n * value + 2 * 1) / (n + 2)
            return min(max(shrunk, band.lowerBound), band.upperBound)
        }
    }

    static func mealPresets(
        dataset: RheosDataset,
        calendar: Calendar
    ) -> [RheosMealPresetLearning] {
        let outcomes = RheosAnalysis.mealOutcomes(dataset: dataset, calendar: calendar)
        let groups = Dictionary(grouping: outcomes, by: \.presetKey)
        return groups.map { key, meals in
            let rises = meals.compactMap(\.riseAt4am)
            let fatty = meals.filter { $0.fat + $0.protein > 0 && calendar.component(.hour, from: $0.date) >= 20 }
            let absorption = meals.compactMap { absorptionHours(for: $0, glucose: dataset.glucose) }
            let delta2 = RheosStats.median(meals.compactMap(\.delta2h))
            let delta4 = RheosStats.median(meals.compactMap(\.delta4h))
            let rise = RheosStats.median(rises)
            let suggestion: String
            if !fatty.isEmpty, let rise, rise > 20 {
                suggestion = "„\(key)“: nach später fettreicher Mahlzeit liegt der 4-Uhr-Anstieg im Median bei \(Int(rise)) mg/dL. Vorschlag, nur zur Kenntnis: den Eintrag in Trio über mehr Stunden verteilen. Rheos gibt keinen Bolus."
            } else if let delta4, delta4 > 40 {
                suggestion = "„\(key)“: nach 4 Stunden liegt die Glukose im Median noch \(Int(delta4)) mg/dL über dem Start. Ein aufgeteilter Eintrag wäre nur deine Entscheidung in Trio."
            } else {
                suggestion = "„\(key)“: \(meals.count) Mahlzeiten im Protokoll. Kein Dosierungsvorschlag."
            }
            return RheosMealPresetLearning(
                id: key,
                count: meals.count,
                medianDelta2h: delta2,
                medianDelta4h: delta4,
                medianAbsorptionHours: RheosStats.median(absorption),
                lateFatty4amRise: fatty.isEmpty ? nil : rise,
                suggestion: suggestion
            )
        }.sorted { $0.id < $1.id }
    }

    static func activeCarbs(at date: Date, meals: [RheosMealEvent]) -> Double {
        meals.reduce(0) { total, meal in
            let elapsed = date.timeIntervalSince(meal.date) / 3600
            guard elapsed >= 0 else { return total }
            let carbs = elapsed < 3 ? meal.carbs * (1 - elapsed / 3) : 0
            let delayed = elapsed < 6 ? (meal.fat + meal.protein) * 0.1 * (1 - elapsed / 6) : 0
            return total + carbs + delayed
        }
    }

    private static func nearestState(at date: Date, states: [RheosStatePoint]) -> (iob: Double, cob: Double) {
        guard let nearest = states.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
              abs(nearest.date.timeIntervalSince(date)) <= 20 * 60 else { return (0, 0) }
        return (max(0, nearest.iob ?? 0), max(0, nearest.cob ?? 0))
    }

    private static func slopes(_ observations: [Observation]) -> (iob: Double, carb: Double) {
        var sIOB = 0.0, sCarb = 0.0, sIOB2 = 0.0, sCarb2 = 0.0, sCross = 0.0, sYIOB = 0.0, sYCarb = 0.0
        for observation in observations {
            let y = observation.glucose - observation.target
            sIOB += observation.iob
            sCarb += observation.activeCarbs
            sIOB2 += observation.iob * observation.iob
            sCarb2 += observation.activeCarbs * observation.activeCarbs
            sCross += observation.iob * observation.activeCarbs
            sYIOB += y * observation.iob
            sYCarb += y * observation.activeCarbs
        }
        let lambda = 1.0
        let a = sIOB2 + lambda
        let b = sCross
        let c = sCarb2 + lambda
        let det = a * c - b * b
        guard abs(det) > 1e-8 else { return (0, 0) }
        var iob = (c * sYIOB - b * sYCarb) / det
        var carb = (a * sYCarb - b * sYIOB) / det
        if iob > 0 { iob = 0 }
        if carb < 0 { carb = 0 }
        return (iob, carb)
    }

    private static func shrink(_ values: [Double], counts: [Int]) -> [Double] {
        zip(values, counts).map { value, count in
            let n = Double(count)
            guard n > 0 else { return 1 }
            let prior = 4.0
            return (n * value + prior * 1) / (n + prior)
        }
    }

    private static func smooth(_ values: [Double], band: ClosedRange<Double>) -> [Double] {
        (0 ..< 24).map { hour in
            let left = values[(hour + 23) % 24]
            let right = values[(hour + 1) % 24]
            let mixed = 0.7 * values[hour] + 0.15 * left + 0.15 * right
            return min(max(mixed, band.lowerBound), band.upperBound)
        }
    }

    private static func absorptionHours(for meal: RheosMealOutcome, glucose: [RheosGlucosePoint]) -> Double? {
        guard let start = RheosStats.nearest(glucose, to: meal.date, within: 45 * 60) else { return nil }
        var best: Double?
        for step in 1 ... 8 {
            let at = meal.date.addingTimeInterval(Double(step) * 3600)
            guard let value = RheosStats.nearest(glucose, to: at, within: 30 * 60) else { continue }
            if abs(value - start) <= 20 {
                best = Double(step)
                break
            }
        }
        return best
    }
}
