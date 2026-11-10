import Foundation

/// Operating mode of the Rheos learning layer.
///
/// `aus` is the default and leaves Trio byte-for-byte on its normal profile.
/// `schatten` learns and shows proposals only.
/// `scharf` may scale ISF, carb ratio and basal through `RheosApplicationPoint`.
/// It never issues a bolus and never edits SMB, UAM or Trio's safety limits.
enum RheosMode: String, Codable, CaseIterable, Equatable {
    case aus
    case schatten
    case scharf
}

enum RheosDecisionCode: String, Codable, Equatable {
    /// Mode is off. The loop profile is the user's profile.
    case off
    /// Learning only. Factors are not applied.
    case shadow
    /// Scharf applied a bounded hourly scale. SMB and UAM still run in Trio.
    case applied
    /// Scharf is on, but there is not enough data. Profile is unchanged.
    case fallbackInsufficientData
    /// Scharf is on, but walk-forward failed or Trio's limits leave no room.
    case fallbackWalkForward
}

/// Constants that are descriptive, not therapy settings.
enum RheosReference {
    /// Center used only to describe hourly glucose deviation, in mg/dL.
    /// This is not written into Trio's glucose targets.
    static let glucoseAnchorMgdl = 110.0
    /// Trio's profile generator rejects an ISF below this (mg/dL per unit).
    static let isfFloorMgdlPerUnit = 5.0
    static let retentionDays = 45
    static let minimumSamplesPerHour = 4
    static let walkForwardTestDays = 3
    /// How strongly a glucose deviation moves a multiplier before the band clamps it.
    static let deviationGain = 0.5
    static let expectedMealRiseMgdl = 40.0
    static let minimumMealsForCarbRatio = 8
    /// Default band, matching Trio's default autosens min/max (`Preferences`).
    static let defaultMinimumMultiplier = 0.7
    static let defaultMaximumMultiplier = 1.2
    static let defaultMaxDailyChange = 0.05
}
