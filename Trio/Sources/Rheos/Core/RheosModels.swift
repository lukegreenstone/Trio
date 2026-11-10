import Foundation

/// User-configurable Rheos band. Defaults match Trio's autosens defaults (0.7–1.2).
///
/// The band that is actually applied is the intersection of this configuration with
/// the autosens min/max Trio is already using. Rheos cannot widen those limits.
struct RheosBounds: Codable, Equatable {
    var minimumMultiplier: Double = RheosReference.defaultMinimumMultiplier
    var maximumMultiplier: Double = RheosReference.defaultMaximumMultiplier
    var maxDailyChange: Double = RheosReference.defaultMaxDailyChange
    var minimumDays: Int = 14
    var minimumGlucoseSamples: Int = 500
    var minimumImprovement: Double = 0.02

    func sanitized() -> RheosBounds {
        var copy = self
        if !copy.minimumMultiplier.isFinite { copy.minimumMultiplier = RheosReference.defaultMinimumMultiplier }
        if !copy.maximumMultiplier.isFinite { copy.maximumMultiplier = RheosReference.defaultMaximumMultiplier }
        if copy.minimumMultiplier > copy.maximumMultiplier {
            swap(&copy.minimumMultiplier, &copy.maximumMultiplier)
        }
        let daily = copy.maxDailyChange.isFinite ? copy.maxDailyChange : RheosReference.defaultMaxDailyChange
        copy.maxDailyChange = min(max(daily, 0.01), 0.10)
        copy.minimumDays = max(copy.minimumDays, 7)
        copy.minimumGlucoseSamples = max(copy.minimumGlucoseSamples, 200)
        let improvement = copy.minimumImprovement.isFinite ? copy.minimumImprovement : 0.02
        copy.minimumImprovement = min(max(improvement, 0), 0.5)
        return copy
    }

    /// Intersection of the configured band with Trio's current autosens window.
    func effectiveRange(autosensMin: Double, autosensMax: Double) -> ClosedRange<Double> {
        var low = autosensMin
        var high = autosensMax
        if !low.isFinite || !high.isFinite || low <= 0 || high <= 0 {
            low = RheosReference.defaultMinimumMultiplier
            high = RheosReference.defaultMaximumMultiplier
        }
        if low > high {
            swap(&low, &high)
        }
        let configuredLow = minimumMultiplier.isFinite ? minimumMultiplier : RheosReference.defaultMinimumMultiplier
        let configuredHigh = maximumMultiplier.isFinite ? maximumMultiplier : RheosReference.defaultMaximumMultiplier
        let lower = min(max(min(configuredLow, configuredHigh), low), high)
        let upper = min(max(max(configuredLow, configuredHigh), low), high)
        return lower ... upper
    }
}

/// Per-hour multipliers. 1.0 leaves the user's profile value unchanged.
/// Basal is multiplied directly. ISF and carb ratio use the same stored multiplier
/// on the profile number (a value below 1 lowers ISF or the carb ratio).
struct RheosHourlyFactors: Codable, Equatable {
    var basal: [Double]
    var isf: [Double]
    var carbRatio: [Double]

    static let identity = RheosHourlyFactors(
        basal: Array(repeating: 1, count: 24),
        isf: Array(repeating: 1, count: 24),
        carbRatio: Array(repeating: 1, count: 24)
    )

    var isIdentity: Bool {
        guard basal.count == 24, isf.count == 24, carbRatio.count == 24 else { return false }
        return (basal + isf + carbRatio).allSatisfy { abs($0 - 1) < 0.000_000_1 }
    }

    func clamped(to band: ClosedRange<Double>) -> RheosHourlyFactors {
        guard basal.count == 24, isf.count == 24, carbRatio.count == 24 else { return .identity }
        func clampList(_ values: [Double]) -> [Double] {
            values.map { min(max($0, band.lowerBound), band.upperBound) }
        }
        return RheosHourlyFactors(
            basal: clampList(basal),
            isf: clampList(isf),
            carbRatio: clampList(carbRatio)
        )
    }

    func stepped(from last: RheosHourlyFactors, maxStep: Double, band: ClosedRange<Double>) -> RheosHourlyFactors {
        let base = last.clamped(to: band)
        let target = clamped(to: band)
        func step(_ from: [Double], _ toward: [Double]) -> [Double] {
            zip(from, toward).map { current, goal in
                let delta = goal - current
                let limited = current + min(max(delta, -maxStep), maxStep)
                return min(max(limited, band.lowerBound), band.upperBound)
            }
        }
        return RheosHourlyFactors(
            basal: step(base.basal, target.basal),
            isf: step(base.isf, target.isf),
            carbRatio: step(base.carbRatio, target.carbRatio)
        )
    }

    func multiplier(at hour: Int, _ values: [Double]) -> Double {
        guard values.count == 24, hour >= 0, hour < 24 else { return 1 }
        return values[hour]
    }
}

struct RheosAppliedState: Codable, Equatable {
    var factors: RheosHourlyFactors
    var appliedAt: Date
}

struct RheosWalkForwardResult: Codable, Equatable {
    var passed: Bool
    var modelMAE: Double?
    var baselineMAE: Double?
    var dayCount: Int
    var sampleCount: Int
    var reason: String
}

struct RheosProfileDecision: Codable, Equatable {
    var mode: RheosMode
    var code: RheosDecisionCode
    var applied: Bool
    var reason: String
    var factors: RheosHourlyFactors
    /// Rate-limited glucose model before today's context nudge. Nil in older files.
    var slowFactors: RheosHourlyFactors?
    var learnedFactors: RheosHourlyFactors
    var walkForward: RheosWalkForwardResult
    var evaluatedAt: Date
    var bandMinimum: Double
    var bandMaximum: Double

    static func inactive(mode: RheosMode, reason: String, now: Date) -> RheosProfileDecision {
        let code: RheosDecisionCode = mode == .aus ? .off : .shadow
        return RheosProfileDecision(
            mode: mode,
            code: code,
            applied: false,
            reason: reason,
            factors: .identity,
            slowFactors: .identity,
            learnedFactors: .identity,
            walkForward: RheosWalkForwardResult(
                passed: false,
                modelMAE: nil,
                baselineMAE: nil,
                dayCount: 0,
                sampleCount: 0,
                reason: reason
            ),
            evaluatedAt: now,
            bandMinimum: RheosReference.defaultMinimumMultiplier,
            bandMaximum: RheosReference.defaultMaximumMultiplier
        )
    }
}

struct RheosGlucosePoint: Codable, Equatable {
    var date: Date
    var mgdl: Double
}

struct RheosInsulinEvent: Codable, Equatable {
    var date: Date
    var units: Double
    var kind: String
}

struct RheosMealEvent: Codable, Equatable, Identifiable {
    var id: String
    var date: Date
    var carbs: Double
    var fat: Double
    var protein: Double
    var note: String
    var acknowledged: Bool
}

struct RheosStatePoint: Codable, Equatable {
    var date: Date
    var iob: Double? = nil
    var cob: Double? = nil
}

struct RheosAdjustmentInterval: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var kind: String
    var start: Date
    var end: Date? = nil
    var percent: Double? = nil
    var targetMgdl: Double? = nil
}

struct RheosNote: Codable, Equatable {
    var date: Date
    var text: String
}

struct RheosWearableDay: Codable, Equatable, Identifiable {
    var id: String { day.timeIntervalSince1970.description }
    var day: Date
    var restingHeartRate: Double? = nil
    var heartRate: Double? = nil
    var hrvSDNN: Double? = nil
    var respiratoryRate: Double? = nil
    var oxygenSaturation: Double? = nil
    var wristTemperature: Double? = nil
    var steps: Double? = nil
    var activeEnergy: Double? = nil
    var workoutMinutes: Double? = nil
    var sleepHours: Double? = nil
}

struct RheosWorkout: Codable, Equatable, Identifiable {
    var id: String
    var activity: String
    var start: Date
    var durationMinutes: Double
    var averageHeartRate: Double? = nil
    var activeEnergy: Double? = nil
}

struct RheosSleepInterval: Codable, Equatable, Identifiable {
    var id: String
    var start: Date
    var end: Date
    var stage: String
}

struct RheosBodyInputs: Codable, Equatable {
    var ageYears: Double? = nil
    var weightKg: Double? = nil
    var heightCm: Double? = nil
}

struct RheosApplicationLog: Codable, Equatable, Identifiable {
    var id: String { "\(date.timeIntervalSince1970)-\(hour)-\(code.rawValue)" }
    var date: Date
    var applied: Bool
    var code: RheosDecisionCode
    var reason: String
    var hour: Int
    var basal: Double
    var isf: Double
    var carbRatio: Double
    var bandMinimum: Double
    var bandMaximum: Double
}

struct RheosDataset: Codable, Equatable {
    var glucose: [RheosGlucosePoint] = []
    var insulin: [RheosInsulinEvent] = []
    var meals: [RheosMealEvent] = []
    var states: [RheosStatePoint] = []
    var adjustments: [RheosAdjustmentInterval] = []
    var notes: [RheosNote] = []
    var wearableDays: [RheosWearableDay] = []
    var workouts: [RheosWorkout] = []
    var sleep: [RheosSleepInterval] = []
    var body: RheosBodyInputs = RheosBodyInputs()
}

struct RheosStability: Equatable {
    var sampleCount: Int
    var timeInTightRange: Double?
    var timeInRange: Double?
    var coefficientOfVariationPercent: Double?
    var summary: String
}

struct RheosHourlyGlucose: Equatable, Identifiable {
    var id: Int { hour }
    var hour: Int
    var medianMgdl: Double
    var count: Int
}

struct RheosDawnObservation: Equatable {
    var lateMealCount: Int
    var nightsCompared: Int
    var nightsWithRiseOver20: Int
    var medianRiseMgdl: Double?
    var summary: String
}

struct RheosMealOutcome: Equatable, Identifiable {
    var id: String
    var date: Date
    var carbs: Double
    var fat: Double
    var protein: Double
    var note: String
    var presetKey: String
    var delta2h: Double?
    var delta4h: Double?
    var riseAt4am: Double?
    var acknowledged: Bool
}

enum RheosContextMode: String, Codable, CaseIterable, Equatable, Identifiable {
    case showtime
    case urlaub
    case krank
    case fasten
    case sport

    var id: String { rawValue }

    /// Name of the Trio preset the user must already have created with their team.
    /// Rheos never invents a percentage or a glucose target for it.
    var presetName: String {
        switch self {
        case .showtime: return "Showtime"
        case .urlaub: return "Urlaub"
        case .krank: return "Krank"
        case .fasten: return "Fasten"
        case .sport: return "Sport"
        }
    }

    var title: String { presetName }
}

struct RheosContextProposal: Equatable, Identifiable {
    var id: String { mode.rawValue }
    var mode: RheosContextMode
    var reason: String
    var presetName: String
}

struct RheosSignalRelevance: Equatable, Identifiable {
    var id: String { signal }
    var signal: String
    var proposed: Bool
    var reason: String
    var correlation: Double?
    var baselineMAE: Double?
    var modelMAE: Double?
}

struct RheosBodyDraft: Equatable {
    /// Always nil in this version. Body data never becomes an insulin number.
    var suggestedDailyInsulin: Double?
    var summary: String
}

struct RheosReport: Equatable {
    var stability: RheosStability
    var hourly: [RheosHourlyGlucose]
    var dawn: RheosDawnObservation
    var meals: [RheosMealOutcome]
    var decision: RheosProfileDecision
    var contexts: [RheosInferredContext]
    var proposals: [RheosContextProposal]
    var signals: [RheosSignalRelevance]
    var body: RheosBodyDraft
}

enum RheosUserConfirmation: Equatable {
    case contextMode(RheosContextMode)
    case mealObservation(id: String)
}

/// Result of an optional announcement. It never delivers insulin and never enables a preset.
enum RheosConfirmationEffect: Equatable {
    case none
    case suggestion(String)
}

struct RheosScheduleValue: Equatable {
    var minutes: Int
    var value: Double
}

enum RheosFactorKind: Equatable {
    case basal
    case isf
    case carbRatio
}
