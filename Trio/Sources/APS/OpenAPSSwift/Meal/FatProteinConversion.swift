import Foundation

/// The iPhone fat-protein conversion. `CarbsStorage` and Handy-frei both call this.
public enum FatProteinConversion {
    public static let adjustmentBounds = (lower: Decimal(string: "0.1")!, upper: Decimal(string: "1.2")!)
    public static let delayBounds = (lower: Decimal(15), upper: Decimal(120))
    public static let intervalBounds = (lower: Decimal(30), upper: Decimal(60))

    public static func futureEntries(
        fat: Decimal,
        protein: Decimal,
        createdAt: Date,
        actualDate: Date?,
        fpuID: String?,
        adjustment: Decimal,
        delayMinutes: Decimal,
        intervalMinutes: Decimal
    ) -> [CarbsEntry] {
        guard fat > 0 || protein > 0 else { return [] }
        let adjustment = adjustment.clamp(lowerBound: adjustmentBounds.lower, upperBound: adjustmentBounds.upper)
        let delayMinutes = delayMinutes.clamp(lowerBound: delayBounds.lower, upperBound: delayBounds.upper)
        let spreadInterval = intervalMinutes.clamp(lowerBound: intervalBounds.lower, upperBound: intervalBounds.upper)

        let maxTotalGrams = 99
        let maxEntries = 3
        let maxPerEntry = 33
        let minPerEntry = 10
        let spacing = TimeInterval(NSDecimalNumber(decimal: spreadInterval).doubleValue * 60)

        let kcal = protein * 4 + fat * 9
        let rawEquivalents = Int(truncating: NSDecimalNumber(decimal: (kcal / 10) * adjustment))
        let totalGrams = min(maxTotalGrams, max(0, rawEquivalents))
        guard totalGrams >= minPerEntry else { return [] }

        let amounts = splitIntoCarbEquivalents(
            total: totalGrams,
            maxEntries: maxEntries,
            maxPerEntry: maxPerEntry,
            minPerEntry: minPerEntry
        )
        let baseDate = actualDate ?? createdAt
        let delaySeconds = TimeInterval(NSDecimalNumber(decimal: delayMinutes).doubleValue * 60)
        let start = baseDate.addingTimeInterval(delaySeconds)
        let sharedID = fpuID ?? UUID().uuidString

        return amounts.enumerated().map { index, grams in
            CarbsEntry(
                id: UUID().uuidString,
                createdAt: createdAt,
                actualDate: start.addingTimeInterval(TimeInterval(index) * spacing),
                carbs: Decimal(grams),
                fat: 0,
                protein: 0,
                note: nil,
                enteredBy: CarbsEntry.local,
                isFPU: true,
                fpuID: sharedID
            )
        }
    }

    /// Same split the iPhone uses: at most 3 entries, 10...33 g each, total at most 99 g.
    public static func splitIntoCarbEquivalents(
        total: Int,
        maxEntries: Int,
        maxPerEntry: Int,
        minPerEntry: Int
    ) -> [Int] {
        guard total >= minPerEntry else { return [] }
        let needed = (total + maxPerEntry - 1) / maxPerEntry
        let count = min(maxEntries, max(1, needed))

        func evenSplit(_ total: Int, count: Int) -> [Int] {
            let base = total / count
            let remainder = total % count
            return (0 ..< count).map { base + ($0 < remainder ? 1 : 0) }
        }

        var buckets = evenSplit(total, count: count)
        if buckets.count > 1 {
            for index in stride(from: buckets.count - 1, through: 1, by: -1) {
                let value = buckets[index]
                guard value > 0, value < minPerEntry else { continue }
                buckets[index - 1] += value
                buckets[index] = 0
            }
            buckets = buckets.filter { $0 > 0 }
        }
        buckets = buckets.map { min(maxPerEntry, $0) }.filter { $0 >= minPerEntry }
        return buckets
    }
}
