import Foundation

/// The only Rheos operation that can change insulin mathematics.
///
/// It returns scaled copies of basal, ISF and carb-ratio numbers. It does not
/// accept or return max IOB, max basal, max bolus, max SMB, UAM flags, or
/// autosens limits. Callers must keep those on Trio's own preference values.
/// SMB and UAM stay in Trio's determine-basal path and see the scaled profile
/// the same way they see any other profile.
enum RheosApplicationPoint {
    static func effect(of confirmation: RheosUserConfirmation) -> RheosConfirmationEffect {
        switch confirmation {
        case .mealObservation:
            return .none
        case let .contextMode(mode):
            return .suggestion(RheosContextInference.suggestion(forAnnouncement: mode.rawValue))
        }
    }

    /// Scales one schedule. `basalCeiling` is the user's existing max basal and is
    /// only used as a ceiling, never raised. ISF is kept at Trio's floor of 5
    /// when the original value was already at or above that floor.
    static func scale(
        values: [RheosScheduleValue],
        factors: [Double],
        kind: RheosFactorKind,
        band: ClosedRange<Double>,
        basalCeiling: Double?
    ) -> [Double] {
        values.map { entry in
            let factor = multiplier(minutes: entry.minutes, factors: factors, band: band)
            var scaled = entry.value * factor
            switch kind {
            case .basal:
                if let basalCeiling, basalCeiling > 0, entry.value <= basalCeiling {
                    scaled = min(scaled, basalCeiling)
                } else if let basalCeiling, basalCeiling > 0, entry.value > basalCeiling, factor > 1 {
                    scaled = entry.value
                }
                if scaled <= 0 {
                    scaled = entry.value
                }
            case .isf:
                if entry.value >= RheosReference.isfFloorMgdlPerUnit {
                    scaled = max(RheosReference.isfFloorMgdlPerUnit, scaled)
                }
                if scaled <= 0 {
                    scaled = entry.value
                }
            case .carbRatio:
                // Trio rejects a carb ratio outside 1...150 and then fails the profile.
                if entry.value >= 1, entry.value <= 150 {
                    scaled = min(150, max(1, scaled))
                }
                if scaled <= 0 {
                    scaled = entry.value
                }
            }
            return scaled
        }
    }

    static func multiplier(minutes: Int, factors: [Double], band: ClosedRange<Double>) -> Double {
        guard factors.count == 24 else { return 1 }
        let hour = min(23, max(0, minutes / 60))
        return min(max(factors[hour], band.lowerBound), band.upperBound)
    }
}
