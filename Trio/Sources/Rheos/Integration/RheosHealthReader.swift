import Foundation
import HealthKit

/// Read-only HealthKit queries for wearable context.
///
/// Authorization asks for read access only. Rheos does not write these types,
/// and this type never touches a pump or a CGM.
///
/// HealthKit background delivery is not real-time and is not used. Samples are
/// whatever has already synced (a finished workout, last night's sleep, the
/// day's step total). Callers must treat them as delayed context.
enum RheosHealthReader {
    static func requestReadAccess(store: HKHealthStore) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let types = readTypes()
        guard !types.isEmpty else { return }
        do {
            try await store.requestAuthorization(toShare: nil, read: types)
        } catch {
            debug(.service, "Rheos HealthKit read authorization failed: \(error)")
        }
    }

    static func read(store: HKHealthStore, now: Date = Date()) async -> (
        days: [RheosWearableDay],
        workouts: [RheosWorkout],
        sleep: [RheosSleepInterval]
    ) {
        guard HKHealthStore.isHealthDataAvailable() else { return ([], [], []) }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -RheosReference.retentionDays, to: now) ?? now
        let quantity = await quantities(store: store, start: start, end: now, calendar: calendar)
        let workouts = await workouts(store: store, start: start, end: now)
        let sleep = await sleep(store: store, start: start, end: now)
        var days = quantity
        add(workouts, to: &days, calendar: calendar)
        add(sleep, to: &days, calendar: calendar)
        return (days.sorted { $0.day < $1.day }, workouts, sleep)
    }

    static func readTypes() -> Set<HKObjectType> {
        var types = Set<HKObjectType>()
        let identifiers: [HKQuantityTypeIdentifier] = [
            .heartRate,
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .respiratoryRate,
            .oxygenSaturation,
            .appleSleepingWristTemperature,
            .stepCount,
            .activeEnergyBurned,
            .bodyMass,
            .height,
            .bodyFatPercentage,
            .leanBodyMass
        ]
        for identifier in identifiers {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        types.insert(HKObjectType.workoutType())
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        if let sex = HKCharacteristicType.characteristicType(forIdentifier: .biologicalSex) {
            types.insert(sex)
        }
        if let birth = HKCharacteristicType.characteristicType(forIdentifier: .dateOfBirth) {
            types.insert(birth)
        }
        return types
    }

    /// Latest body measurements already stored in Apple Health.
    /// Lean mass is not skeletal muscle. The caller labels that.
    static func readBody(store: HKHealthStore, now: Date = Date()) async -> RheosBodyInputs {
        guard HKHealthStore.isHealthDataAvailable() else { return RheosBodyInputs() }
        var inputs = RheosBodyInputs()
        if let birthday = try? store.dateOfBirthComponents(),
           let date = Calendar.current.date(from: birthday) {
            let years = Calendar.current.dateComponents([.year], from: date, to: now).year
            if let years, years > 0, years < 130 { inputs.ageYears = Double(years) }
        }
        if let sex = try? store.biologicalSex().biologicalSex {
            switch sex {
            case .female: inputs.sex = .female
            case .male: inputs.sex = .male
            case .other: inputs.sex = .other
            default: break
            }
        }
        inputs.weightKg = await latestKilograms(store: store, identifier: .bodyMass)
        if let meters = await latest(store: store, identifier: .height, unit: .meter()) {
            inputs.heightCm = meters * 100
        }
        if let fraction = await latest(store: store, identifier: .bodyFatPercentage, unit: .percent()) {
            inputs.bodyFatPercent = fraction <= 1.5 ? fraction * 100 : fraction
        }
        inputs.leanMassKg = await latestKilograms(store: store, identifier: .leanBodyMass)
        return inputs
    }

    private static func latestKilograms(store: HKHealthStore, identifier: HKQuantityTypeIdentifier) async -> Double? {
        await latest(store: store, identifier: identifier, unit: .gramUnit(with: .kilo))
    }

    private static func latest(
        store: HKHealthStore,
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, _ in
                let quantity = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: quantity)
            }
            store.execute(query)
        }
    }

    private static func quantities(
        store: HKHealthStore,
        start: Date,
        end: Date,
        calendar: Calendar
    ) async -> [RheosWearableDay] {
        var byDay: [Date: RheosWearableDay] = [:]
        func day(_ date: Date) -> RheosWearableDay {
            let startOfDay = calendar.startOfDay(for: date)
            if byDay[startOfDay] == nil {
                byDay[startOfDay] = RheosWearableDay(day: startOfDay)
            }
            return byDay[startOfDay]!
        }

        if let type = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            let values = await statistics(store: store, type: type, unit: HKUnit.count().unitDivided(by: .minute()), options: .discreteAverage, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.heartRate = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
            let values = await statistics(store: store, type: type, unit: HKUnit.count().unitDivided(by: .minute()), options: .discreteAverage, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.restingHeartRate = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
            let values = await statistics(store: store, type: type, unit: HKUnit.secondUnit(with: .milli), options: .discreteAverage, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.hrvSDNN = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) {
            let values = await statistics(store: store, type: type, unit: HKUnit.count().unitDivided(by: .minute()), options: .discreteAverage, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.respiratoryRate = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) {
            let values = await statistics(store: store, type: type, unit: HKUnit.percent(), options: .discreteAverage, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.oxygenSaturation = value * 100
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .appleSleepingWristTemperature) {
            let values = await statistics(store: store, type: type, unit: HKUnit.degreeCelsius(), options: .discreteAverage, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.wristTemperature = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            let values = await statistics(store: store, type: type, unit: .count(), options: .cumulativeSum, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.steps = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            let values = await statistics(store: store, type: type, unit: .kilocalorie(), options: .cumulativeSum, start: start, end: end, calendar: calendar)
            for (date, value) in values {
                var row = day(date)
                row.activeEnergy = value
                byDay[calendar.startOfDay(for: date)] = row
            }
        }
        return Array(byDay.values)
    }

    private static func statistics(
        store: HKHealthStore,
        type: HKQuantityType,
        unit: HKUnit,
        options: HKStatisticsOptions,
        start: Date,
        end: Date,
        calendar: Calendar
    ) async -> [Date: Double] {
        await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let anchor = calendar.startOfDay(for: start)
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                options: options,
                anchorDate: anchor,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, _ in
                var values: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let quantity = options.contains(.cumulativeSum) ? statistics.sumQuantity() : statistics.averageQuantity()
                    if let quantity {
                        values[calendar.startOfDay(for: statistics.startDate)] = quantity.doubleValue(for: unit)
                    }
                }
                resumed.resume(continuation, returning: values)
            }
            store.execute(query)
        }
    }

    private static func workouts(store: HKHealthStore, start: Date, end: Date) async -> [RheosWorkout] {
        await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                let workouts = (samples as? [HKWorkout])?.map { workout -> RheosWorkout in
                    let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
                    let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate)
                    let energy = energyType.flatMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .kilocalorie()) }
                    let heart = heartType.flatMap {
                        workout.statistics(for: $0)?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                    }
                    return RheosWorkout(
                        id: workout.uuid.uuidString,
                        activity: activityName(workout.workoutActivityType),
                        start: workout.startDate,
                        durationMinutes: workout.duration / 60,
                        averageHeartRate: heart,
                        activeEnergy: energy
                    )
                } ?? []
                resumed.resume(continuation, returning: workouts)
            }
            store.execute(query)
        }
    }

    private static func sleep(store: HKHealthStore, start: Date, end: Date) async -> [RheosSleepInterval] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        return await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let query = HKSampleQuery(
                sampleType: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                let intervals = (samples as? [HKCategorySample])?.compactMap { sample -> RheosSleepInterval? in
                    let stage = sleepStage(sample.value)
                    guard stage != "inBed", stage != "awake" else { return nil }
                    return RheosSleepInterval(
                        id: sample.uuid.uuidString,
                        start: sample.startDate,
                        end: sample.endDate,
                        stage: stage
                    )
                } ?? []
                resumed.resume(continuation, returning: intervals)
            }
            store.execute(query)
        }
    }

    private static func add(_ workouts: [RheosWorkout], to days: inout [RheosWearableDay], calendar: Calendar) {
        for workout in workouts {
            let key = calendar.startOfDay(for: workout.start)
            if let index = days.firstIndex(where: { calendar.startOfDay(for: $0.day) == key }) {
                days[index].workoutMinutes = (days[index].workoutMinutes ?? 0) + workout.durationMinutes
            } else {
                var day = RheosWearableDay(day: key)
                day.workoutMinutes = workout.durationMinutes
                days.append(day)
            }
        }
    }

    private static func add(_ sleep: [RheosSleepInterval], to days: inout [RheosWearableDay], calendar: Calendar) {
        for interval in sleep {
            let key = calendar.startOfDay(for: interval.start)
            let hours = interval.end.timeIntervalSince(interval.start) / 3600
            guard hours > 0 else { continue }
            if let index = days.firstIndex(where: { calendar.startOfDay(for: $0.day) == key }) {
                days[index].sleepHours = (days[index].sleepHours ?? 0) + hours
            } else {
                var day = RheosWearableDay(day: key)
                day.sleepHours = hours
                days.append(day)
            }
        }
    }

    private static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Laufen"
        case .cycling: return "Radfahren"
        case .walking: return "Gehen"
        case .traditionalStrengthTraining: return "Krafttraining"
        case .functionalStrengthTraining: return "Functional Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .swimming: return "Schwimmen"
        case .yoga: return "Yoga"
        default: return "Workout \(type.rawValue)"
        }
    }

    private static func sleepStage(_ value: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed: return "inBed"
        case .asleepUnspecified: return "asleep"
        case .awake: return "awake"
        case .asleepCore: return "core"
        case .asleepDeep: return "deep"
        case .asleepREM: return "rem"
        default: return "other"
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume<T>(_ continuation: CheckedContinuation<T, Never>, returning value: T) {
        lock.lock()
        let shouldResume = !resumed
        resumed = true
        lock.unlock()
        if shouldResume {
            continuation.resume(returning: value)
        }
    }
}
