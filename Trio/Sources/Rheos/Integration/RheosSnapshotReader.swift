import CoreData
import Foundation

/// Read-only copy of what Trio has already stored.
///
/// This type does not call pump or CGM managers and does not save a Core Data context.
enum RheosSnapshotReader {
    static func read() async -> RheosDataset {
        async let glucose = fetchGlucose()
        async let insulin = fetchInsulin()
        async let meals = fetchMeals()
        async let states = fetchStates()
        async let adjustments = fetchAdjustments()
        async let notes = fetchNotes()
        var dataset = RheosDataset()
        dataset.glucose = await glucose
        dataset.insulin = await insulin
        dataset.meals = await meals
        dataset.states = await states
        dataset.adjustments = await adjustments
        dataset.notes = await notes
        return dataset
    }

    private static var cutoff: Date {
        Date().addingTimeInterval(-Double(RheosReference.retentionDays) * 86400)
    }

    private static func fetchGlucose() async -> [RheosGlucosePoint] {
        await fetch(GlucoseStored.self, key: "date", predicate: NSPredicate(format: "date >= %@", cutoff as NSDate)) { rows in
            rows.compactMap { row in
                guard let date = row.date, row.glucose > 0 else { return nil }
                return RheosGlucosePoint(date: date, mgdl: Double(row.glucose))
            }
        }
    }

    private static func fetchMeals() async -> [RheosMealEvent] {
        await fetch(CarbEntryStored.self, key: "date", predicate: NSPredicate(format: "date >= %@", cutoff as NSDate)) { rows in
            rows.compactMap { row in
                guard !row.isFPU, let date = row.date else { return nil }
                return RheosMealEvent(
                    id: row.id?.uuidString ?? "\(date.timeIntervalSince1970)-\(row.carbs)",
                    date: date,
                    carbs: row.carbs,
                    fat: row.fat,
                    protein: row.protein,
                    note: row.note ?? "",
                    acknowledged: false
                )
            }
        }
    }

    private static func fetchInsulin() async -> [RheosInsulinEvent] {
        await fetch(
            PumpEventStored.self,
            key: "timestamp",
            predicate: NSPredicate(format: "timestamp >= %@", cutoff as NSDate),
            relationships: ["bolus", "tempBasal"]
        ) { rows in
            rows.compactMap { row -> RheosInsulinEvent? in
                guard let date = row.timestamp else { return nil }
                if let amount = row.bolus?.amount?.doubleValue, amount > 0 {
                    let smb = row.bolus?.isSMB == true || row.type == PumpEventStored.EventType.smb.rawValue
                    return RheosInsulinEvent(date: date, units: amount, kind: smb ? "smb" : "bolus")
                }
                if let delivered = row.tempBasal?.deliveredUnits?.doubleValue, delivered > 0 {
                    let scheduled = row.tempBasal?.isScheduledBasal == true
                    return RheosInsulinEvent(date: date, units: delivered, kind: scheduled ? "scheduledBasal" : "tempBasal")
                }
                return nil
            }
        }
    }

    private static func fetchStates() async -> [RheosStatePoint] {
        await fetch(
            OrefDetermination.self,
            key: "deliverAt",
            predicate: NSPredicate(format: "deliverAt >= %@", cutoff as NSDate),
            limit: 20_000
        ) { rows in
            rows.compactMap { row in
                guard let date = row.deliverAt else { return nil }
                return RheosStatePoint(
                    date: date,
                    iob: row.iob?.doubleValue,
                    cob: Double(row.cob),
                    dynamicISF: row.insulinSensitivity?.doubleValue
                )
            }
        }
    }

    private static func fetchAdjustments() async -> [RheosAdjustmentInterval] {
        let overrides = await fetch(
            OverrideStored.self,
            key: "date",
            predicate: NSPredicate(format: "enabled == YES AND date >= %@", cutoff as NSDate)
        ) { rows in
            rows.compactMap { row -> RheosAdjustmentInterval? in
                guard let start = row.date else { return nil }
                return RheosAdjustmentInterval(
                    id: row.id ?? UUID().uuidString,
                    name: row.name ?? "Override",
                    kind: "override",
                    start: start,
                    end: nil,
                    percent: row.percentage,
                    targetMgdl: row.target?.doubleValue
                )
            }
        }
        let targets = await fetch(
            TempTargetStored.self,
            key: "date",
            predicate: NSPredicate(format: "enabled == YES AND date >= %@", cutoff as NSDate)
        ) { rows in
            rows.compactMap { row -> RheosAdjustmentInterval? in
                guard let start = row.date else { return nil }
                return RheosAdjustmentInterval(
                    id: row.id?.uuidString ?? UUID().uuidString,
                    name: row.name ?? "Temp Target",
                    kind: "tempTarget",
                    start: start,
                    end: nil,
                    percent: nil,
                    targetMgdl: row.target?.doubleValue
                )
            }
        }
        let overrideRuns = await fetch(
            OverrideRunStored.self,
            key: "startDate",
            predicate: NSPredicate(format: "startDate >= %@", cutoff as NSDate),
            relationships: ["override"]
        ) { rows in
            rows.compactMap { row -> RheosAdjustmentInterval? in
                guard let start = row.startDate else { return nil }
                return RheosAdjustmentInterval(
                    id: row.id?.uuidString ?? UUID().uuidString,
                    name: row.name ?? "Override",
                    kind: "overrideRun",
                    start: start,
                    end: row.endDate,
                    percent: row.override?.percentage,
                    targetMgdl: row.target?.doubleValue
                )
            }
        }
        return overrides + targets + overrideRuns
    }

    private static func fetchNotes() async -> [RheosNote] {
        let carbNotes = await fetchMeals().compactMap { meal -> RheosNote? in
            let text = meal.note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RheosNote(date: meal.date, text: text)
        }
        let pumpNotes = await fetch(
            PumpEventStored.self,
            key: "timestamp",
            predicate: NSPredicate(format: "timestamp >= %@ AND note != nil", cutoff as NSDate)
        ) { rows in
            rows.compactMap { row -> RheosNote? in
                guard let date = row.timestamp, let text = row.note?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return RheosNote(date: date, text: text)
            }
        }
        return carbNotes + pumpNotes
    }

    private static func fetch<T: NSManagedObject, Result>(
        _ type: T.Type,
        key: String,
        predicate: NSPredicate,
        relationships: [String]? = nil,
        limit: Int? = nil,
        map: @escaping ([T]) -> [Result]
    ) async -> [Result] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "rheos.\(String(describing: type))"
        do {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: type,
                onContext: context,
                predicate: predicate,
                key: key,
                ascending: true,
                fetchLimit: limit,
                relationshipKeyPathsForPrefetching: relationships
            )
            return await context.perform {
                guard let rows = results as? [T] else { return [] }
                return map(rows)
            }
        } catch {
            debug(.service, "Rheos read of \(String(describing: type)) failed: \(error)")
            return []
        }
    }
}
