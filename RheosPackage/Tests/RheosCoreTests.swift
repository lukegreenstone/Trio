import XCTest

@testable import RheosCore

final class RheosCoreTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testDefaultBandMatchesAutosensDefaults() {
        let bounds = RheosBounds()
        XCTAssertEqual(bounds.minimumMultiplier, 0.7, accuracy: 0.000_1)
        XCTAssertEqual(bounds.maximumMultiplier, 1.2, accuracy: 0.000_1)
    }

    func testBandIsCutToTrioAutosensLimits() {
        let wide = RheosBounds(minimumMultiplier: 0.5, maximumMultiplier: 1.5)
        XCTAssertEqual(wide.effectiveRange(autosensMin: 0.7, autosensMax: 1.2), 0.7 ... 1.2)
        let defaults = RheosBounds()
        XCTAssertEqual(defaults.effectiveRange(autosensMin: 0.9, autosensMax: 1.1), 0.9 ... 1.1)
        XCTAssertEqual(defaults.effectiveRange(autosensMin: 1, autosensMax: 1), 1 ... 1)
        var hugeStep = RheosBounds()
        hugeStep.maxDailyChange = 0.5
        hugeStep.maxContextNudge = 0.9
        XCTAssertEqual(hugeStep.sanitized().maxDailyChange, 0.10, accuracy: 0.000_1)
        XCTAssertEqual(hugeStep.sanitized().maxContextNudge, 0.20, accuracy: 0.000_1)
    }

    func testScaleRespectsBasalCeilingAndIsfFloor() {
        let band = 0.7 ... 1.2
        let capped = RheosApplicationPoint.scale(
            values: [RheosScheduleValue(minutes: 0, value: 1)],
            factors: Array(repeating: 1.2, count: 24),
            kind: .basal,
            band: band,
            basalCeiling: 1
        )
        XCTAssertEqual(capped[0], 1, accuracy: 0.000_1)

        let raised = RheosApplicationPoint.scale(
            values: [RheosScheduleValue(minutes: 0, value: 1)],
            factors: Array(repeating: 1.2, count: 24),
            kind: .basal,
            band: band,
            basalCeiling: 2
        )
        XCTAssertEqual(raised[0], 1.2, accuracy: 0.000_1)

        let alreadyAbove = RheosApplicationPoint.scale(
            values: [RheosScheduleValue(minutes: 0, value: 1.5)],
            factors: Array(repeating: 1.2, count: 24),
            kind: .basal,
            band: band,
            basalCeiling: 1
        )
        XCTAssertEqual(alreadyAbove[0], 1.5, accuracy: 0.000_1)

        let isfFloored = RheosApplicationPoint.scale(
            values: [RheosScheduleValue(minutes: 0, value: 6)],
            factors: Array(repeating: 0.7, count: 24),
            kind: .isf,
            band: band,
            basalCeiling: nil
        )
        XCTAssertEqual(isfFloored[0], 5, accuracy: 0.000_1)

        let isfScaled = RheosApplicationPoint.scale(
            values: [RheosScheduleValue(minutes: 120, value: 40)],
            factors: hourFactors(hour: 2, value: 0.7),
            kind: .isf,
            band: band,
            basalCeiling: nil
        )
        XCTAssertEqual(isfScaled[0], 28, accuracy: 0.000_1)

        let carbFloor = RheosApplicationPoint.scale(
            values: [RheosScheduleValue(minutes: 0, value: 1)],
            factors: Array(repeating: 0.7, count: 24),
            kind: .carbRatio,
            band: band,
            basalCeiling: nil
        )
        XCTAssertEqual(carbFloor[0], 1, accuracy: 0.000_1)

        let unchanged = RheosApplicationPoint.scale(
            values: [RheosScheduleValue(minutes: 0, value: 10)],
            factors: [1.2, 1.2],
            kind: .carbRatio,
            band: band,
            basalCeiling: nil
        )
        XCTAssertEqual(unchanged[0], 10, accuracy: 0.000_1)
    }

    func testConfirmationsNeverRequestABolus() {
        XCTAssertEqual(RheosApplicationPoint.effect(of: .mealObservation(id: "meal")), .none)
        if case let .suggestion(text) = RheosApplicationPoint.effect(of: .contextMode(.sport)) {
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(text.contains("keinen Bolus"))
        } else {
            XCTFail("Ankündigung darf nichts aktivieren")
        }
        XCTAssertEqual(RheosContextMode.krank.presetName, "Krank")
    }

    func testScharfAppliesBoundedFactorsWhenWalkForwardPasses() {
        let now = date(day: 17, hour: 12)
        let decision = RheosLearner.evaluate(
            dataset: RheosDataset(glucose: stableGlucose(days: 1 ... 17)),
            mode: .scharf,
            bounds: RheosBounds(),
            previous: nil,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(decision.code, .applied)
        XCTAssertTrue(decision.applied)
        XCTAssertTrue(decision.walkForward.passed)
        XCTAssertEqual(decision.learnedFactors.basal[12], 1.2, accuracy: 0.001)
        XCTAssertLessThan(decision.learnedFactors.isf[12], 0.9)
        XCTAssertGreaterThan(decision.learnedFactors.isf[12], 0.69)
        XCTAssertEqual(decision.factors.basal[12], 1.15, accuracy: 0.001)
        XCTAssertEqual(decision.factors.isf[12], 0.85, accuracy: 0.001)
        XCTAssertEqual(decision.factors.basal[3], 0.9141414141414139, accuracy: 0.001)
        XCTAssertEqual(decision.factors.isf[3], 1.0858585858585856, accuracy: 0.001)
        XCTAssertEqual(decision.factors.basal[8], 1, accuracy: 0.001)
        XCTAssertTrue(decision.factors.carbRatio.allSatisfy { abs($0 - 1) < 0.001 })
        XCTAssertTrue(decision.factors.basal.allSatisfy { $0 >= 0.7 && $0 <= 1.2 })
    }

    func testDailyStepDoesNotMoveTwiceOnTheSameDay() {
        let now = date(day: 17, hour: 12)
        let dataset = RheosDataset(glucose: stableGlucose(days: 1 ... 17))
        let first = RheosLearner.evaluate(
            dataset: dataset,
            mode: .scharf,
            bounds: RheosBounds(),
            previous: nil,
            now: now,
            calendar: calendar
        )
        let second = RheosLearner.evaluate(
            dataset: dataset,
            mode: .scharf,
            bounds: RheosBounds(),
            previous: RheosAppliedState(factors: first.factors, appliedAt: now),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(second.factors, first.factors)

        let nextDay = RheosLearner.evaluate(
            dataset: dataset,
            mode: .scharf,
            bounds: RheosBounds(),
            previous: RheosAppliedState(factors: first.factors, appliedAt: now.addingTimeInterval(-86_400)),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(nextDay.factors.basal[12], 1.2, accuracy: 0.001)
    }

    func testFallbackWhenDataOrWalkForwardFails() {
        let now = date(day: 5, hour: 8)
        let short = RheosLearner.evaluate(
            dataset: RheosDataset(glucose: stableGlucose(days: 1 ... 5)),
            mode: .scharf,
            bounds: RheosBounds(),
            previous: nil,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(short.code, .fallbackInsufficientData)
        XCTAssertFalse(short.applied)
        XCTAssertTrue(short.factors.isIdentity)

        let inverted = RheosLearner.evaluate(
            dataset: RheosDataset(glucose: stableGlucose(days: 1 ... 17, invertFrom: 15)),
            mode: .scharf,
            bounds: RheosBounds(),
            previous: nil,
            now: date(day: 17, hour: 12),
            calendar: calendar
        )
        XCTAssertEqual(inverted.code, .fallbackWalkForward)
        XCTAssertFalse(inverted.applied)
        XCTAssertTrue(inverted.factors.isIdentity)
        XCTAssertTrue(inverted.reason.contains("Rückfall auf Trio"))
    }

    func testAusAndShadowDoNotApply() {
        let dataset = RheosDataset(glucose: stableGlucose(days: 1 ... 17))
        let now = date(day: 17, hour: 12)
        let off = RheosLearner.evaluate(
            dataset: dataset,
            mode: .aus,
            bounds: RheosBounds(),
            previous: nil,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(off.code, .off)
        XCTAssertFalse(off.applied)
        XCTAssertTrue(off.factors.isIdentity)
        XCTAssertEqual(off.learnedFactors.basal[12], 1.2, accuracy: 0.001)

        let shadow = RheosLearner.evaluate(
            dataset: dataset,
            mode: .schatten,
            bounds: RheosBounds(),
            previous: nil,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(shadow.code, .shadow)
        XCTAssertFalse(shadow.applied)
        XCTAssertTrue(shadow.factors.isIdentity)
        XCTAssertTrue(shadow.walkForward.passed)
    }

    func testAutosensWindowCapsTheAppliedFactor() {
        let decision = RheosLearner.evaluate(
            dataset: RheosDataset(glucose: stableGlucose(days: 1 ... 17)),
            mode: .scharf,
            bounds: RheosBounds(minimumMultiplier: 0.5, maximumMultiplier: 1.5),
            previous: nil,
            autosensMin: 0.7,
            autosensMax: 1,
            now: date(day: 17, hour: 12),
            calendar: calendar
        )
        XCTAssertEqual(decision.bandMaximum, 1, accuracy: 0.000_1)
        XCTAssertLessThanOrEqual(decision.factors.basal.max() ?? 0, 1.000_1)
        XCTAssertGreaterThanOrEqual(decision.factors.basal.min() ?? 0, 0.7 - 0.000_1)
    }

    func testPinnedAutosensLeavesTrioUnchanged() {
        let decision = RheosLearner.evaluate(
            dataset: RheosDataset(glucose: stableGlucose(days: 1 ... 17)),
            mode: .scharf,
            bounds: RheosBounds(),
            previous: nil,
            autosensMin: 1,
            autosensMax: 1,
            now: date(day: 17, hour: 12),
            calendar: calendar
        )
        XCTAssertFalse(decision.applied)
        XCTAssertTrue(decision.factors.isIdentity)
        XCTAssertEqual(decision.code, .fallbackWalkForward)
    }

    func testCarbRatioLearnsFromMealRiseWithoutLeavingTheBand() {
        var dataset = RheosDataset(glucose: stableGlucose(days: 1 ... 17))
        for day in 1 ... 8 {
            let meal = date(day: day, hour: 19, minute: 5)
            dataset.meals.append(
                RheosMealEvent(id: "m\(day)", date: meal, carbs: 40, fat: 30, protein: 20, note: "", acknowledged: false)
            )
            dataset.glucose.append(RheosGlucosePoint(date: meal, mgdl: 110))
            dataset.glucose.append(RheosGlucosePoint(date: meal.addingTimeInterval(3 * 3600), mgdl: 260))
        }
        let decision = RheosLearner.evaluate(
            dataset: dataset,
            mode: .scharf,
            bounds: RheosBounds(),
            previous: nil,
            now: date(day: 17, hour: 12),
            calendar: calendar
        )
        XCTAssertTrue(decision.walkForward.passed)
        XCTAssertEqual(decision.learnedFactors.carbRatio[19], 0.7, accuracy: 0.001)
        XCTAssertEqual(decision.factors.carbRatio[19], 0.85, accuracy: 0.001)
    }

    func testStabilityDawnAndBodyDraft() {
        let stability = RheosAnalysis.stability(glucose: [
            RheosGlucosePoint(date: date(day: 1, hour: 1), mgdl: 69),
            RheosGlucosePoint(date: date(day: 1, hour: 2), mgdl: 70),
            RheosGlucosePoint(date: date(day: 1, hour: 3), mgdl: 140),
            RheosGlucosePoint(date: date(day: 1, hour: 4), mgdl: 141),
            RheosGlucosePoint(date: date(day: 1, hour: 5), mgdl: 180),
            RheosGlucosePoint(date: date(day: 1, hour: 6), mgdl: 181)
        ])
        XCTAssertEqual(stability.timeInTightRange ?? -1, 2.0 / 6.0, accuracy: 0.000_1)
        XCTAssertEqual(stability.timeInRange ?? -1, 4.0 / 6.0, accuracy: 0.000_1)
        XCTAssertEqual(RheosStats.coefficientOfVariationPercent([100, 100]) ?? -1, 0, accuracy: 0.000_1)

        let mealDate = date(day: 1, hour: 21)
        let dataset = RheosDataset(
            glucose: [
                RheosGlucosePoint(date: date(day: 2, hour: 1), mgdl: 100),
                RheosGlucosePoint(date: date(day: 2, hour: 4), mgdl: 160)
            ],
            meals: [
                RheosMealEvent(id: "late", date: mealDate, carbs: 20, fat: 30, protein: 10, note: "", acknowledged: false)
            ]
        )
        let dawn = RheosAnalysis.dawn(dataset: dataset, calendar: calendar)
        XCTAssertEqual(dawn.lateMealCount, 1)
        XCTAssertEqual(dawn.nightsCompared, 1)
        XCTAssertEqual(dawn.medianRiseMgdl ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(dawn.nightsWithRiseOver20, 1)

        let draft = RheosAnalysis.bodyDraft(RheosBodyInputs(ageYears: 40, weightKg: 80, heightCm: 180))
        XCTAssertEqual(draft.totalDailyDose ?? 0, 32, accuracy: 0.001)
        XCTAssertEqual(draft.basalPerHour ?? 0, 16.0 / 24.0, accuracy: 0.001)
        XCTAssertEqual(draft.isfMgdlPerUnit ?? 0, 1800.0 / 32.0, accuracy: 0.001)
        XCTAssertEqual(draft.carbGramsPerUnit ?? 0, 500.0 / 32.0, accuracy: 0.001)
        XCTAssertFalse(draft.appliedToProfile)
        XCTAssertTrue(draft.summary.contains("nicht angewendet"))
    }

    func testWearableSignalIsProposedOnlyWhenItImprovesPrediction() {
        var days: [RheosWearableDay] = []
        var glucose: [RheosGlucosePoint] = []
        for day in 1 ... 12 {
            let value = 100 + Double(day) * 5
            days.append(RheosWearableDay(day: self.date(day: day, hour: 0), restingHeartRate: value, heartRate: 50))
            glucose.append(RheosGlucosePoint(date: date(day: day, hour: 12), mgdl: value))
        }
        let useful = RheosAnalysis.signalRelevance(
            dataset: RheosDataset(glucose: glucose, wearableDays: days),
            calendar: calendar
        )
        XCTAssertEqual(useful.first { $0.signal == "Ruhepuls" }?.proposed, true)
        XCTAssertEqual(useful.first { $0.signal == "Herzfrequenz" }?.proposed, false)
    }

    func testContextProposalNamesAPresetAndDoesNotCarryADose() {
        let now = date(day: 10, hour: 15)
        let dataset = RheosDataset(
            workouts: [
                RheosWorkout(id: "w", activity: "Laufen", start: now.addingTimeInterval(-2 * 3600), durationMinutes: 40)
            ]
        )
        let proposals = RheosAnalysis.contextProposals(dataset: dataset, now: now, calendar: calendar)
        XCTAssertTrue(proposals.contains { $0.mode == .sport && $0.presetName == "Sport" })
        XCTAssertTrue(proposals.contains { $0.mode == .fasten })
    }

    func testChatStubStaysOnDevice() {
        let report = RheosReportBuilder.build(
            dataset: RheosDataset(),
            mode: .schatten,
            bounds: RheosBounds(),
            previous: nil,
            autosensMin: 0.7,
            autosensMax: 1.2,
            now: date(day: 1, hour: 4),
            calendar: calendar
        )
        let reply = RheosChatStub.reply(question: "warum 4 uhr", report: report)
        XCTAssertTrue(reply.contains("kein Netzwerk-Modell"))
        XCTAssertTrue(reply.contains("keinen Bolus"))
    }

    func testStoreRoundTripAndLogDedupe() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RheosStore(directory: directory)
        let point = RheosGlucosePoint(date: date(day: 2, hour: 3), mgdl: 118)
        store.saveDataset(RheosDataset(glucose: [point]), now: date(day: 3, hour: 0))
        XCTAssertEqual(store.loadDataset().glucose, [point])

        let entry = RheosApplicationLog(
            date: date(day: 3, hour: 4),
            applied: true,
            code: .applied,
            reason: "test",
            hour: 4,
            basal: 1.05,
            isf: 0.95,
            carbRatio: 1,
            bandMinimum: 0.7,
            bandMaximum: 1.2
        )
        store.appendApplication(entry)
        store.appendApplication(entry)
        XCTAssertEqual(store.applicationLogs().count, 1)
        var later = entry
        later.hour = 5
        later.date = date(day: 3, hour: 5)
        store.appendApplication(later)
        XCTAssertEqual(store.applicationLogs().count, 2)
        let urls = try store.exportFiles(now: date(day: 3, hour: 6))
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
    }

    func testSchemaMigrationKeepsGlucoseAndLearnedFactors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var basal = Array(repeating: 1.0, count: 24)
        basal[4] = 1.05
        let version1: [String: Any] = [
            "schemaVersion": 1,
            "glucoseReadings": [["t": "2026-11-01T03:00:00Z", "mgdl": 144]],
            "learnedBasal": basal,
            "learnedAt": "2026-11-02T04:00:00Z"
        ]
        let original = try JSONSerialization.data(withJSONObject: version1, options: [.prettyPrinted])
        let stateURL = directory.appendingPathComponent("rheos-state.json")
        try original.write(to: stateURL)

        let store = RheosStore(directory: directory)
        XCTAssertEqual(store.loadDataset().glucose.first?.mgdl ?? 0, 144, accuracy: 0.001)
        XCTAssertEqual(store.loadApplied()?.factors.basal[4] ?? 0, 1.05, accuracy: 0.001)
        let rewritten = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertTrue(rewritten.contains("\"schemaVersion\" : 4") || rewritten.contains("\"schemaVersion\": 4"))
        let backup = try String(contentsOf: directory.appendingPathComponent("rheos-state.v1.bak"), encoding: .utf8)
        XCTAssertTrue(backup.contains("glucoseReadings"))
        XCTAssertTrue(backup.contains("144"))
    }

    func testImportRestoresLearningInsteadOfStartingEmpty() throws {
        let now = date(day: 17, hour: 12)
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = RheosStore(directory: sourceDirectory)
        source.saveDataset(RheosDataset(glucose: stableGlucose(days: 1 ... 17)), now: now)
        var restored = RheosHourlyFactors.identity
        restored.basal[12] = 1.05
        source.saveApplied(RheosAppliedState(factors: restored, appliedAt: now.addingTimeInterval(-86_400)))
        let exported = try source.exportFiles(now: now)

        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = RheosStore(directory: destinationDirectory)
        destination.saveDataset(
            RheosDataset(glucose: [RheosGlucosePoint(date: date(day: 1, hour: 1), mgdl: 50)]),
            now: now
        )
        try destination.importArchive(from: exported[0])

        XCTAssertEqual(destination.loadDataset().glucose.count, source.loadDataset().glucose.count)
        XCTAssertEqual(destination.loadApplied()?.factors.basal[12] ?? 0, 1.05, accuracy: 0.001)
        let decision = RheosLearner.evaluate(
            dataset: destination.loadDataset(),
            mode: .scharf,
            bounds: RheosBounds(),
            previous: destination.loadApplied(),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(decision.code, .applied)
        XCTAssertEqual(decision.factors.basal[12], 1.2, accuracy: 0.001)
        let leftovers = try FileManager.default.contentsOfDirectory(at: destinationDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.contains { $0.lastPathComponent.hasPrefix("rheos-state.pre-import-") })
    }

    func testNewerSchemaIsNotRewrittenAndGarbageIsLeftInPlace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("rheos-state.json")
        let newer: [String: Any] = [
            "schemaVersion": 99,
            "futureField": "keep-me",
            "dataset": [
                "glucose": [["date": "2026-11-01T03:00:00Z", "mgdl": 130]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: newer, options: [.prettyPrinted]).write(to: stateURL)
        let store = RheosStore(directory: directory)
        XCTAssertEqual(store.loadDataset().glucose.first?.mgdl ?? 0, 130, accuracy: 0.001)
        store.saveDataset(store.loadDataset(), now: date(day: 2, hour: 0))
        let afterSave = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertTrue(afterSave.contains("keep-me"))
        XCTAssertTrue(afterSave.contains("99"))

        let garbageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: garbageDirectory, withIntermediateDirectories: true)
        let garbageURL = garbageDirectory.appendingPathComponent("rheos-state.json")
        try Data("this is not json".utf8).write(to: garbageURL)
        let garbageStore = RheosStore(directory: garbageDirectory)
        _ = garbageStore.loadDataset()
        XCTAssertEqual(try String(contentsOf: garbageURL, encoding: .utf8), "this is not json")
    }

    func testTargetScheduleComesFromTrioNotAFixed110() {
        let schedule = RheosTargetSchedule.from(entries: [
            (minutes: 0, low: 100, high: 100),
            (minutes: 12 * 60, low: 120, high: 120)
        ])
        XCTAssertEqual(schedule.value(atHour: 8), 100, accuracy: 0.001)
        XCTAssertEqual(schedule.value(atHour: 15), 120, accuracy: 0.001)

        let glucose = (0 ..< 17).flatMap { day in
            (0 ..< 24).flatMap { hour in
                [0, 15, 30, 45].map { minute in
                    RheosGlucosePoint(date: date(day: day + 1, hour: hour, minute: minute), mgdl: 120)
                }
            }
        }
        let at100 = RheosLearner.evaluate(
            dataset: RheosDataset(glucose: glucose),
            mode: .scharf,
            bounds: RheosBounds(),
            previous: nil,
            targets: .flat(100),
            now: date(day: 17, hour: 12),
            calendar: calendar
        )
        let at120 = RheosLearner.evaluate(
            dataset: RheosDataset(glucose: glucose),
            mode: .scharf,
            bounds: RheosBounds(),
            previous: nil,
            targets: .flat(120),
            now: date(day: 17, hour: 12),
            calendar: calendar
        )
        XCTAssertGreaterThan(at100.learnedFactors.basal[8], 1)
        XCTAssertEqual(at120.learnedFactors.basal[8], 1, accuracy: 0.05)
        XCTAssertGreaterThan(at100.learnedFactors.basal[8], at120.learnedFactors.basal[8])
    }

    func testIOBExplainsPartOfAHighGlucoseHour() {
        let calendar = self.calendar
        var glucose: [RheosGlucosePoint] = []
        var states: [RheosStatePoint] = []
        for day in 1 ... 17 {
            for hour in 0 ..< 24 {
                for minute in [0, 15, 30, 45] {
                    let when = date(day: day, hour: hour, minute: minute)
                    if hour == 8, minute >= 30 {
                        glucose.append(RheosGlucosePoint(date: when, mgdl: 50))
                        states.append(RheosStatePoint(date: when, iob: 4, cob: 0))
                    } else if hour == 15 {
                        glucose.append(RheosGlucosePoint(date: when, mgdl: 180))
                    } else if hour == 16 {
                        glucose.append(RheosGlucosePoint(date: when, mgdl: 50))
                        states.append(RheosStatePoint(date: when, iob: 4, cob: 0))
                    } else {
                        glucose.append(RheosGlucosePoint(date: when, mgdl: 110))
                    }
                }
            }
        }
        let model = RheosFit.fit(
            observations: RheosFit.observations(
                dataset: RheosDataset(glucose: glucose, states: states),
                targets: .flat(110),
                calendar: calendar
            ),
            band: 0.7 ... 1.2
        )
        XCTAssertLessThan(model.iobSlope, 0)
        XCTAssertLessThan(model.factors.basal[16], model.factors.basal[15])
    }

    func testChatSuggestionsAreNotesNotDoses() {
        let reply = """
        Der Anstieg um 4 Uhr steckt im Stundenmodell.
        [[suggestion kind=sport]]
        Heute war ein Lauf. Nur ein Hinweis.
        [[/suggestion]]
        [[suggestion kind=bolus]]
        2 Einheiten
        [[/suggestion]]
        """
        let suggestions = RheosChatParser.suggestions(in: reply)
        XCTAssertEqual(suggestions.map(\.kind), ["sport"])
        XCTAssertEqual(
            RheosApplicationPoint.effect(of: .contextMode(.sport)),
            .suggestion(RheosContextInference.suggestion(forAnnouncement: "sport"))
        )
    }

    func testCareSuggestionsDoNotImplyADose() {
        let calendar = self.calendar
        let now = date(day: 2, hour: 12)
        var glucose: [RheosGlucosePoint] = []
        for minute in stride(from: 0, through: 90, by: 15) {
            glucose.append(RheosGlucosePoint(date: now.addingTimeInterval(-Double(90 - minute) * 60), mgdl: 280))
        }
        let high = RheosDataset(glucose: glucose, insulin: [RheosInsulinEvent(date: now.addingTimeInterval(-30 * 60), units: 3, kind: "bolus")], states: [RheosStatePoint(date: now, iob: 2, cob: 0)])
        let check = RheosCare.patchCheck(dataset: high, now: now)
        XCTAssertNotNil(check)
        XCTAssertTrue(check?.contains("Ketone") == true)
        XCTAssertTrue(check?.contains("kein Insulin") == true)

        var falling = glucose
        falling[falling.count - 1].mgdl = 260
        XCTAssertNil(RheosCare.patchCheck(dataset: RheosDataset(glucose: falling, states: [RheosStatePoint(date: now, iob: 2)]), now: now))

        let night = date(day: 2, hour: 23)
        let compression = [
            RheosGlucosePoint(date: night, mgdl: 140),
            RheosGlucosePoint(date: night.addingTimeInterval(5 * 60), mgdl: 55),
            RheosGlucosePoint(date: night.addingTimeInterval(12 * 60), mgdl: 135)
        ]
        let flagged = RheosCare.compressionLows(glucose: compression, calendar: calendar)
        XCTAssertEqual(flagged.count, 1)
        let slow = [
            RheosGlucosePoint(date: night, mgdl: 140),
            RheosGlucosePoint(date: night.addingTimeInterval(5 * 60), mgdl: 125),
            RheosGlucosePoint(date: night.addingTimeInterval(10 * 60), mgdl: 110)
        ]
        XCTAssertTrue(RheosCare.compressionLows(glucose: slow, calendar: calendar).isEmpty)
        let day = date(day: 2, hour: 14)
        let daytime = [
            RheosGlucosePoint(date: day, mgdl: 140),
            RheosGlucosePoint(date: day.addingTimeInterval(5 * 60), mgdl: 55),
            RheosGlucosePoint(date: day.addingTimeInterval(12 * 60), mgdl: 135)
        ]
        XCTAssertTrue(RheosCare.compressionLows(glucose: daytime, calendar: calendar).isEmpty)
        XCTAssertEqual(RheosCare.excludingCompression(RheosDataset(glucose: compression), calendar: calendar).glucose.count, 2)

        let first = date(day: 1, hour: 8)
        let second = date(day: 2, hour: 8)
        var siteGlucose: [RheosGlucosePoint] = []
        for index in 0 ..< 12 {
            siteGlucose.append(RheosGlucosePoint(date: first.addingTimeInterval(Double(index) * 600), mgdl: 210))
            siteGlucose.append(RheosGlucosePoint(date: second.addingTimeInterval(Double(index) * 600), mgdl: 110))
        }
        let notes = RheosCare.siteNotes(
            sites: [
                RheosPatchSite(id: "a", place: "Bauch", started: first),
                RheosPatchSite(id: "b", place: "Arm", started: second)
            ],
            glucose: siteGlucose
        )
        XCTAssertTrue(notes.contains { $0.contains("Bauch") && $0.contains("210") })
        XCTAssertTrue(notes.contains { $0.contains("Arm") && $0.contains("110") })
        XCTAssertTrue(notes.allSatisfy { !$0.contains("Bolus") })

        let weekly = RheosCare.weeklyReport(glucose: siteGlucose, learned: "Stundenfaktoren im Band.", now: second.addingTimeInterval(3600))
        XCTAssertTrue(weekly.contains("70–140"))
        XCTAssertTrue(weekly.contains("keine Dosierung"))

        let hypoNow = date(day: 3, hour: 15)
        var hypoGlucose = [
            RheosGlucosePoint(date: hypoNow.addingTimeInterval(-20 * 60), mgdl: 120),
            RheosGlucosePoint(date: hypoNow.addingTimeInterval(-10 * 60), mgdl: 100),
            RheosGlucosePoint(date: hypoNow, mgdl: 82)
        ]
        var meals: [RheosMealEvent] = []
        for index in 0 ..< 3 {
            let when = date(day: 4 + index, hour: 10)
            meals.append(RheosMealEvent(id: "h\(index)", date: when, carbs: 15, fat: 0, protein: 0, note: "", acknowledged: false))
            hypoGlucose.append(RheosGlucosePoint(date: when.addingTimeInterval(-10 * 60), mgdl: 65))
            hypoGlucose.append(RheosGlucosePoint(date: when.addingTimeInterval(20 * 60), mgdl: 95))
        }
        let suggestion = RheosCare.hypoSuggestion(dataset: RheosDataset(glucose: hypoGlucose, meals: meals), now: hypoNow)
        XCTAssertTrue(suggestion?.contains("15 g") == true)
        XCTAssertTrue(suggestion?.contains("trägt nichts ein") == true)
        let tooFew = RheosCare.hypoSuggestion(
            dataset: RheosDataset(glucose: Array(hypoGlucose.prefix(3)), meals: Array(meals.prefix(1))),
            now: hypoNow
        )
        XCTAssertTrue(tooFew?.contains("zu wenige") == true)

        let drink = date(day: 5, hour: 18)
        let drink2 = date(day: 7, hour: 18)
        let alcoholGlucose = [
            RheosGlucosePoint(date: drink.addingTimeInterval(6 * 3600), mgdl: 62),
            RheosGlucosePoint(date: drink2.addingTimeInterval(6 * 3600), mgdl: 64)
        ]
        let alcohol = RheosCare.alcoholNote(
            dataset: RheosDataset(glucose: alcoholGlucose),
            alcoholDates: [drink, drink2],
            now: drink2.addingTimeInterval(20 * 3600)
        )
        XCTAssertTrue(alcohol?.contains("Temp-Target") == true)
        XCTAssertTrue(alcohol?.contains("aktiviert es nicht") == true)
    }

    func testFinishedWorkoutAdjustsFactorsWithoutAnAnnouncement() {
        let now = date(day: 17, hour: 16)
        let glucose = stableGlucose(days: 1 ... 17)
        let plain = RheosLearner.evaluate(
            dataset: RheosDataset(glucose: glucose),
            mode: .scharf,
            bounds: RheosBounds(),
            previous: nil,
            now: now,
            calendar: calendar
        )
        let end = now.addingTimeInterval(-3600)
        let finished = RheosWorkout(
            id: "run",
            activity: "Laufen",
            start: end.addingTimeInterval(-40 * 60),
            durationMinutes: 40
        )
        let withWorkout = RheosLearner.evaluate(
            dataset: RheosDataset(glucose: glucose, workouts: [finished]),
            mode: .scharf,
            bounds: RheosBounds(),
            previous: nil,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(withWorkout.code, .applied)
        XCTAssertLessThan(withWorkout.factors.basal[16], plain.factors.basal[16])
        XCTAssertGreaterThanOrEqual(withWorkout.factors.basal[16], 0.7)
        let stillRunning = RheosWorkout(id: "open", activity: "Laufen", start: now, durationMinutes: 40)
        let ignored = RheosLearner.evaluate(
            dataset: RheosDataset(glucose: glucose, workouts: [stillRunning]),
            mode: .scharf,
            bounds: RheosBounds(),
            previous: nil,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(ignored.factors.basal[16], plain.factors.basal[16], accuracy: 0.001)
    }

    func testBackupCopyIsOptional() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backup = directory.appendingPathComponent("icloud-stand-in", isDirectory: true)
        let store = RheosStore(directory: directory)
        store.backupDirectory = { backup }
        store.saveDataset(
            RheosDataset(glucose: [RheosGlucosePoint(date: date(day: 2, hour: 3), mgdl: 118)]),
            now: date(day: 3, hour: 0)
        )
        let copied = backup.appendingPathComponent("rheos-state.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        let text = try String(contentsOf: copied, encoding: .utf8)
        XCTAssertTrue(text.contains("118"))
    }

    func testLegacySplitFilesAreFoldedInWithoutDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataset = RheosDataset(glucose: [RheosGlucosePoint(date: date(day: 2, hour: 3), mgdl: 121)])
        let data = try RheosCoding.encoder().encode(dataset)
        try data.write(to: directory.appendingPathComponent("dataset.json"))
        let store = RheosStore(directory: directory)
        XCTAssertEqual(store.loadDataset().glucose.first?.mgdl ?? 0, 121, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("dataset.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rheos-state.json").path))
    }

    func testSilenceKeepsUrgentLowAudible() {
        XCTAssertEqual(
            AlarmSilencePolicy.delivery(snoozed: true, style: .fullySilent, isUrgentLow: true),
            .deliver(tone: true)
        )
        XCTAssertEqual(
            AlarmSilencePolicy.delivery(snoozed: true, style: .vibrateOnly, isUrgentLow: false, glucoseMgdl: 54),
            .deliver(tone: true)
        )
        XCTAssertEqual(
            AlarmSilencePolicy.delivery(snoozed: true, style: .fullySilent, isUrgentLow: false, glucoseMgdl: 55),
            .suppress
        )
        XCTAssertEqual(
            AlarmSilencePolicy.delivery(snoozed: true, style: .vibrateOnly, isUrgentLow: false, glucoseMgdl: 180),
            .deliver(tone: false)
        )
        XCTAssertEqual(
            AlarmSilencePolicy.delivery(snoozed: true, style: nil, isUrgentLow: false, glucoseMgdl: 200),
            .suppress
        )
        XCTAssertEqual(
            AlarmSilencePolicy.delivery(snoozed: true, style: .fullySilent, isUrgentLow: false, isCritical: true),
            .deliver(tone: true)
        )
        XCTAssertEqual(
            AlarmSilencePolicy.delivery(snoozed: false, style: .fullySilent, isUrgentLow: false, glucoseMgdl: 40),
            .deliver(tone: true)
        )
        XCTAssertEqual(AlarmSilencePolicy.clampedMinutes(0), 0)
        XCTAssertEqual(AlarmSilencePolicy.clampedMinutes(10_000), 12 * 60)
        XCTAssertEqual(AlarmSilencePolicy.presetHours, [1, 2, 4, 6])
    }

    func testWatchConfirmDoesNotDoseAndIgnoresBolusPayloads() {
        let breakfast = RheosWatchMessages.action(RheosWatchFields(
            decision: "confirm",
            kind: "meal",
            note: "Standardfrühstück"
        ))
        XCTAssertEqual(breakfast, .confirm(kind: "meal", note: "Standardfrühstück", suggestionID: nil))
        if let breakfast {
            XCTAssertFalse(RheosWatchMessages.changesInsulin(breakfast))
        }

        let snack = RheosWatchMessages.action(RheosWatchFields(
            decision: "confirm",
            kind: "snack",
            note: "small carbs, observe"
        ))
        XCTAssertEqual(snack, .confirm(kind: "snack", note: "small carbs, observe", suggestionID: nil))

        let hiddenBolus = RheosWatchMessages.action(RheosWatchFields(
            decision: "confirm",
            kind: "meal",
            note: "Standardfrühstück",
            containsBolusOrCarbs: true
        ))
        XCTAssertNil(hiddenBolus)
        XCTAssertNil(RheosWatchMessages.action(RheosWatchFields(decision: "confirm", kind: "bolus", note: "2")))
        XCTAssertNil(RheosWatchMessages.action(RheosWatchFields(chat: "   ")))

        let silence = RheosWatchMessages.action(RheosWatchFields(snoozeMinutes: 120, snoozeStyle: "fullySilent"))
        XCTAssertEqual(silence, .silence(minutes: 120, style: .fullySilent))
        let chat = RheosWatchMessages.action(RheosWatchFields(chat: "Warum hoch?"))
        XCTAssertEqual(chat, .chat("Warum hoch?"))
        if let chat {
            XCTAssertFalse(RheosWatchMessages.changesInsulin(chat))
        }
    }

    func testWatchCatalogIsNotesOnly() {
        let care = RheosCareReport(
            patchCheck: "Pflaster prüfen",
            compressionExcluded: [],
            siteNotes: [],
            weekly: "",
            hypoSuggestion: nil,
            alcohol: "Alkohol-Hinweis"
        )
        let lines = RheosWatchCatalog.lines(
            care: care,
            chat: [RheosChatSuggestion(kind: "sport", text: "Training notieren")]
        )
        XCTAssertEqual(lines.map(\.kind), ["note", "note", "sport"])
        XCTAssertFalse(lines.contains { $0.kind == "bolus" || $0.note.contains("U") && $0.kind == "bolus" })
        for line in lines {
            let action = RheosWatchMessages.action(RheosWatchFields(
                decision: "confirm",
                kind: line.kind,
                note: line.note,
                suggestionID: line.id
            ))
            guard let action else {
                XCTFail("missing action")
                continue
            }
            XCTAssertFalse(RheosWatchMessages.changesInsulin(action))
        }
    }

    func testBodyDataIsADraftAndDoesNotBecomeTheProfile() throws {
        let adult = RheosBodyDraftMath.draft(RheosBodyInputs(ageYears: 70, weightKg: 60))
        XCTAssertEqual(RheosBodyDraftMath.unitsPerKilogram(ageYears: 70), 0.2, accuracy: 0.001)
        XCTAssertEqual(adult.totalDailyDose ?? 0, 12, accuracy: 0.001)
        XCTAssertFalse(adult.appliedToProfile)
        XCTAssertNil(RheosBodyDraftMath.draft(RheosBodyInputs(heightCm: 170)).totalDailyDose)

        var manual = RheosBodyRecord.markingManual(RheosBodyInputs(weightKg: 81, heightCm: 180))
        let health = RheosBodyInputs(ageYears: 41, weightKg: 70, heightCm: 175, bodyFatPercent: 22, leanMassKg: 55)
        let merged = RheosBodyRecord.merging(current: manual, health: health)
        XCTAssertEqual(merged.weightKg ?? 0, 81, accuracy: 0.001)
        XCTAssertEqual(merged.ageYears ?? 0, 41, accuracy: 0.001)
        XCTAssertEqual(merged.muscleMassKg ?? 0, 55, accuracy: 0.001)
        XCTAssertTrue(merged.muscleComesFromLeanMass)
        XCTAssertFalse(merged.manualFields.contains("ageYears"))

        let now = date(day: 4, hour: 9)
        var history = RheosBodyRecord.appending([], inputs: merged, source: "health", now: now)
        history = RheosBodyRecord.appending(history, inputs: merged, source: "health", now: now.addingTimeInterval(60))
        XCTAssertEqual(history.count, 1)
        manual.weightKg = 82
        manual = RheosBodyRecord.markingManual(manual)
        history = RheosBodyRecord.appending(history, inputs: manual, source: "manual", now: now.addingTimeInterval(120))
        XCTAssertEqual(history.count, 2)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let version2: [String: Any] = [
            "schemaVersion": 2,
            "dataset": [
                "glucose": [["date": "2026-11-01T03:00:00Z", "mgdl": 110]],
                "body": ["ageYears": 40, "weightKg": 80]
            ]
        ]
        let url = directory.appendingPathComponent("rheos-state.json")
        try JSONSerialization.data(withJSONObject: version2).write(to: url)
        let store = RheosStore(directory: directory)
        let loaded = store.loadDataset()
        XCTAssertEqual(loaded.body.weightKg ?? 0, 80, accuracy: 0.001)
        XCTAssertTrue(loaded.bodyHistory.isEmpty)
        XCTAssertFalse(RheosAnalysis.bodyDraft(loaded.body).appliedToProfile)

        var thin = RheosDataset(glucose: [RheosGlucosePoint(date: date(day: 1, hour: 1), mgdl: 140)])
        thin.body = RheosBodyInputs(ageYears: 40, weightKg: 80)
        let decision = RheosLearner.evaluate(
            dataset: thin,
            mode: .scharf,
            bounds: RheosBounds(),
            previous: nil,
            now: date(day: 2, hour: 1),
            calendar: calendar
        )
        XCTAssertFalse(decision.applied)
        XCTAssertEqual(decision.factors.basal, RheosHourlyFactors.identity.basal)
    }

    func testBodyPriorShrinksSparseHoursCloserToOne() {
        let band = 0.7 ... 1.2
        let observations = (0 ..< 24).flatMap { hour in
            (0 ..< 4).map { _ in
                RheosFit.Observation(
                    day: date(day: 1, hour: 0),
                    hour: hour,
                    glucose: 180,
                    target: 100,
                    iob: 0,
                    activeCarbs: 0
                )
            }
        }
        let plain = RheosFit.fit(observations: observations, band: band, priorStrength: RheosBodyPrior.plain)
        let cautious = RheosFit.fit(observations: observations, band: band, priorStrength: RheosBodyPrior.withBody)
        XCTAssertGreaterThan(plain.factors.basal[12], 1)
        XCTAssertLessThan(cautious.factors.basal[12], plain.factors.basal[12])
        XCTAssertGreaterThan(cautious.factors.basal[12], 1)
    }

    func testScharfRampPreviewKrankAndShadowWeek() {
        var bounds = RheosBounds()
        bounds.firstDayMaxChange = 0.12
        bounds.laterDayMaxChange = 0.30
        let limits = bounds.sanitized()
        let first = RheosRamp.maxStep(now: date(day: 4, hour: 8), scharfSince: date(day: 4, hour: 1), bounds: limits, calendar: calendar)
        let later = RheosRamp.maxStep(now: date(day: 5, hour: 8), scharfSince: date(day: 4, hour: 1), bounds: limits, calendar: calendar)
        XCTAssertEqual(first, 0.12, accuracy: 0.001)
        XCTAssertEqual(later, 0.30, accuracy: 0.001)
        XCTAssertGreaterThan(later, first)
        let band = limits.effectiveRange(autosensMin: 0.7, autosensMax: 1.2)
        XCTAssertEqual(band.lowerBound, 0.7, accuracy: 0.001)
        XCTAssertEqual(band.upperBound, 1.2, accuracy: 0.001)

        let short = RheosCoreModel.fit(
            dataset: RheosDataset(glucose: stableGlucose(days: 1 ... 3)),
            targets: .flat(100),
            band: band,
            calendar: calendar
        )
        XCTAssertFalse(short.trained)
        XCTAssertEqual(short.factors, .identity)

        let preview = RheosRamp.preview(learned: .identity, step: first, shadow: RheosShadowStatus())
        XCTAssertTrue(preview.contains("nicht angewendet"))

        let missing = RheosPresetPlan.missingMessage(name: "Krank")
        XCTAssertTrue(missing.contains("Krank"))
        XCTAssertFalse(missing.contains("120"))
        XCTAssertFalse(missing.contains("Bolus von"))

        let week = RheosShadowCompare.week(
            dataset: RheosDataset(glucose: [
                RheosGlucosePoint(date: date(day: 4, hour: 10), mgdl: 130),
                RheosGlucosePoint(date: date(day: 4, hour: 11), mgdl: 90)
            ], insulin: [RheosInsulinEvent(date: date(day: 4, hour: 10), units: 2, kind: "bolus")]),
            fit: short,
            now: date(day: 4, hour: 12),
            calendar: calendar
        )
        XCTAssertTrue(week.shadowOnly)
        XCTAssertTrue(week.summary.contains("kein kontrafaktisches"))
        XCTAssertTrue(week.summary.contains("zu wenig Daten"))
        XCTAssertFalse(week.summary.contains("Ridge —"))
        XCTAssertEqual(
            RheosCoreModel.features(hour: 8, iob: 1, carbs: 10, fpu: 2).count,
            RheosCoreModel.baseFeatureCount
        )
        XCTAssertEqual(
            RheosSignalCatalog.values(
                accepted: [],
                day: RheosWearableDay(day: date(day: 1, hour: 0), restingHeartRate: 80)
            ).count,
            0
        )
        XCTAssertEqual(
            RheosSignalCatalog.values(
                accepted: ["Ruhepuls"],
                day: RheosWearableDay(day: date(day: 1, hour: 0), restingHeartRate: 80)
            ).count,
            1
        )
        XCTAssertEqual(week.actualInsulin, 2, accuracy: 0.001)

        let parsed = RheosMealParser.estimate(in: "Hier {\"carbs\":40,\"fat\":20,\"protein\":15}")
        XCTAssertEqual(parsed?.carbs ?? 0, 40, accuracy: 0.001)
        XCTAssertTrue(RheosFPUSplit.proposal(hour: 20, fat: 20, protein: 10).contains("keinen Bolus"))
        let situation = RheosChatSituation.advice(question: "Sport in 2 h", forecast: RheosChatSituation.forecastLine(mae: nil))
        XCTAssertEqual(situation?.kind, "sport")
        XCTAssertFalse(situation?.text.contains("2 U") ?? true)
    }

    func testWatchFaceShowsAgeAndRespectsReloadBudget() {
        let now = date(day: 3, hour: 8)
        let reading = WatchFaceReading(
            glucose: "96",
            trend: "FortyFiveDown",
            readingDate: now.addingTimeInterval(-3 * 60),
            rheosMode: "schatten"
        )
        XCTAssertEqual(reading.trendArrow, "↘")
        XCTAssertEqual(reading.modeLabel, "Schatten")
        XCTAssertEqual(reading.ageLabel(at: now), "3m")
        XCTAssertFalse(reading.isStale(at: now))
        XCTAssertTrue(reading.isStale(at: now.addingTimeInterval(15 * 60)))
        XCTAssertEqual(WatchFaceTrend.arrow(for: "DoubleUp"), "↑↑")

        XCTAssertTrue(WatchFaceBudget.shouldReload(lastReload: nil, contentChanged: true, now: now))
        XCTAssertFalse(WatchFaceBudget.shouldReload(
            lastReload: now.addingTimeInterval(-60),
            contentChanged: true,
            now: now
        ))
        XCTAssertTrue(WatchFaceBudget.shouldReload(
            lastReload: now.addingTimeInterval(-5 * 60),
            contentChanged: true,
            now: now
        ))
        XCTAssertFalse(WatchFaceBudget.shouldReload(
            lastReload: now.addingTimeInterval(-5 * 60),
            contentChanged: false,
            now: now
        ))
        XCTAssertEqual(WatchFaceBudget.entryDates(from: now).count, 15)

        let suite = "trio.watchface.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        WatchFaceStore.save(reading, defaults: defaults)
        XCTAssertEqual(WatchFaceStore.load(defaults: defaults), reading)
        WatchFaceStore.markReloaded(now, defaults: defaults)
        XCTAssertEqual(WatchFaceStore.lastReload(defaults: defaults), now)
    }

    func testBasalWakeDynamicISFAndDataQuality() {
        let factors = Array(repeating: 1.2, count: 24)
        let proposal = RheosBasalRecommendation.propose(
            rates: [(minutes: 0, rate: 1)],
            factors: factors,
            previous: Array(repeating: 1, count: 24),
            dawnNote: "Dawn. "
        )
        XCTAssertTrue(proposal.material)
        XCTAssertEqual(proposal.slots[6].proposed, 1.2, accuracy: 0.001)
        XCTAssertTrue(proposal.summary.contains("nicht gespeichert"))
        XCTAssertFalse(RheosBasalRecommendation.materiallyDifferent(
            previous: proposal.slots.map(\.proposed),
            next: proposal.slots.map(\.proposed)
        ))

        let dawn = RheosWake.classify([
            RheosWakeSample(wakeHour: 6, clockRise: 40, wakeRise: 5),
            RheosWakeSample(wakeHour: 6.2, clockRise: 42, wakeRise: 8),
            RheosWakeSample(wakeHour: 6.4, clockRise: 38, wakeRise: 6),
            RheosWakeSample(wakeHour: 9, clockRise: 41, wakeRise: 30),
            RheosWakeSample(wakeHour: 9.2, clockRise: 39, wakeRise: 28),
            RheosWakeSample(wakeHour: 9.5, clockRise: 40, wakeRise: 35)
        ])
        XCTAssertEqual(dawn, .dawn)
        let feet = RheosWake.classify([
            RheosWakeSample(wakeHour: 6, clockRise: 10, wakeRise: 30),
            RheosWakeSample(wakeHour: 6.2, clockRise: 12, wakeRise: 32),
            RheosWakeSample(wakeHour: 6.5, clockRise: 8, wakeRise: 29),
            RheosWakeSample(wakeHour: 9, clockRise: 40, wakeRise: 31),
            RheosWakeSample(wakeHour: 9.3, clockRise: 45, wakeRise: 30),
            RheosWakeSample(wakeHour: 9.6, clockRise: 42, wakeRise: 28)
        ])
        XCTAssertEqual(feet, .feetOnFloor)
        XCTAssertTrue(RheosWake.shouldAskAgain(previous: "dawn", current: .feetOnFloor))

        let shadow = RheosWake.window(
            factors: .identity,
            minutesSinceWake: 40,
            kind: .feetOnFloor,
            enabled: true,
            confirmed: false,
            modeIsScharf: false,
            band: 0.7 ... 1.2
        )
        XCTAssertFalse(shadow.apply)
        let live = RheosWake.window(
            factors: .identity,
            minutesSinceWake: 40,
            kind: .feetOnFloor,
            enabled: true,
            confirmed: true,
            modeIsScharf: true,
            band: 0.7 ... 1.2
        )
        XCTAssertTrue(live.apply)
        XCTAssertGreaterThan(live.factors.basal[0], 1)
        XCTAssertLessThan(live.factors.isf[0], 1)

        let learned = RheosHourlyFactors(
            basal: Array(repeating: 1.1, count: 24),
            isf: Array(repeating: 0.8, count: 24),
            carbRatio: Array(repeating: 0.9, count: 24)
        )
        let neutral = RheosDynamicISF.neutralize(learned, dynamicISFOn: true)
        XCTAssertEqual(neutral.isf[4], 1, accuracy: 0.001)
        XCTAssertEqual(neutral.basal[4], 1.1, accuracy: 0.001)
        XCTAssertNotNil(RheosDynamicISF.doubleCountWarning(meanBasalFactor: 1.1, autosensRatio: 1.2))

        let first = date(day: 2, hour: 1)
        let afterGap = date(day: 2, hour: 4)
        let warmup = RheosDataQuality.warmupDates(glucose: [
            RheosGlucosePoint(date: first, mgdl: 100),
            RheosGlucosePoint(date: afterGap, mgdl: 110),
            RheosGlucosePoint(date: afterGap.addingTimeInterval(30 * 60), mgdl: 112)
        ])
        XCTAssertTrue(warmup.contains(afterGap.timeIntervalSince1970))
        let site = date(day: 2, hour: 10)
        let blockedSite = RheosDataQuality.siteDates(
            glucose: [RheosGlucosePoint(date: site.addingTimeInterval(3600), mgdl: 100)],
            sites: [RheosPatchSite(id: "site", place: "Arm", started: site)]
        )
        XCTAssertTrue(blockedSite.contains(site.addingTimeInterval(3600).timeIntervalSince1970))
        let highStart = date(day: 4, hour: 1)
        let highs = (0 ..< 5).map {
            RheosGlucosePoint(date: highStart.addingTimeInterval(Double($0) * 20 * 60), mgdl: 280)
        }
        XCTAssertFalse(RheosDataQuality.occlusionDates(glucose: highs, now: highStart.addingTimeInterval(2 * 3600)).isEmpty)
        XCTAssertNotNil(RheosUpkeep.loopWarning(lastLoop: date(day: 3, hour: 1), now: date(day: 3, hour: 3)))
        XCTAssertNil(RheosUpkeep.exportReminder(lastExport: date(day: 3, hour: 1), hasData: true, now: date(day: 3, hour: 2)))
        XCTAssertFalse(RheosCloudPolicy.allowsCloud(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard))
    }

    func testAbsorptionSportUAMNightAndSettings() {
        let eveningShare = RheosAbsorption.immediateShare(lateFraction: 0.75, band: .evening, meals: 4)
        let morningShare = RheosAbsorption.immediateShare(lateFraction: 0, band: .morning, meals: 4)
        XCTAssertLessThan(eveningShare, morningShare)
        XCTAssertEqual(RheosAbsorption.lateFraction(rise2h: 10, rise4h: 40), 0.75, accuracy: 0.001)
        let evening = RheosBolusShare.suggest(
            hour: 19,
            trioPercent: 0.8,
            bands: [RheosAbsorptionBand(band: .evening, meals: 4, lateFraction: 0.75, immediateShare: eveningShare)],
            calculatorUnits: 4,
            smbOn: true,
            uamOn: true,
            maxIOB: 2,
            modeIsScharf: false
        )
        XCTAssertLessThan(evening.refinedPercent, 0.8)
        XCTAssertFalse(evening.copiesIntoField)
        XCTAssertTrue(evening.line.contains("Schatten"))
        let guarded = RheosBolusShare.suggest(
            hour: 19,
            trioPercent: 0.8,
            bands: [],
            calculatorUnits: 4,
            smbOn: false,
            uamOn: false,
            maxIOB: 0,
            modeIsScharf: true
        )
        XCTAssertTrue(guarded.line.contains("nicht automatisch"))

        let meal = RheosMealEvent(id: "m", date: date(day: 3, hour: 19), carbs: 40, fat: 20, protein: 20, note: "", acknowledged: false)
        let insulin = [
            RheosInsulinEvent(date: date(day: 3, hour: 19, minute: 5), units: 4, kind: "bolus"),
            RheosInsulinEvent(date: date(day: 3, hour: 21), units: 1.5, kind: "smb")
        ]
        let split = RheosAbsorptionShadow.split(meal: meal, insulin: insulin, trioPercent: 0.8, refinedPercent: 0.4)
        XCTAssertEqual(split?.wouldGiveNow ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(split?.smbUnits ?? 0, 1.5, accuracy: 0.001)
        XCTAssertTrue(split?.line.contains("nichts abgegeben") ?? false)

        var glucose: [RheosGlucosePoint] = []
        for day in 1 ... 4 {
            glucose.append(RheosGlucosePoint(date: date(day: day, hour: 18), mgdl: 140))
            glucose.append(RheosGlucosePoint(date: date(day: day, hour: 18, minute: 40), mgdl: 100))
            glucose.append(RheosGlucosePoint(date: date(day: day + 1, hour: 2), mgdl: 70))
            glucose.append(RheosGlucosePoint(date: date(day: day + 1, hour: 3), mgdl: 70))
        }
        for day in 10 ... 12 {
            glucose.append(RheosGlucosePoint(date: date(day: day, hour: 2), mgdl: 110))
            glucose.append(RheosGlucosePoint(date: date(day: day, hour: 3), mgdl: 110))
        }
        let workouts = (1 ... 4).map {
            RheosWorkout(id: "w\($0)", activity: "Lauf", start: date(day: $0, hour: 18), durationMinutes: 40, averageHeartRate: 130, activeEnergy: nil)
        }
        let sport = RheosSportLearning.learn(workouts: workouts, glucose: glucose, now: date(day: 5, hour: 17), calendar: calendar)
        XCTAssertNotNil(sport.suggestion)
        XCTAssertTrue(sport.suggestion?.contains("Preset Sport") ?? false)
        XCTAssertTrue(sport.suggestion?.contains("erfindet kein Ziel") ?? false)
        XCTAssertFalse(sport.suggestion?.contains("Ziel 1") ?? true)

        let rise = [
            RheosGlucosePoint(date: date(day: 6, hour: 15), mgdl: 100),
            RheosGlucosePoint(date: date(day: 6, hour: 15, minute: 40), mgdl: 120),
            RheosGlucosePoint(date: date(day: 6, hour: 16, minute: 10), mgdl: 145)
        ]
        let prompt = RheosUAM.detect(glucose: rise, meals: [], now: date(day: 6, hour: 16, minute: 10), lastAsked: nil, calendar: calendar)
        XCTAssertNotNil(prompt)
        XCTAssertNil(RheosUAM.detect(
            glucose: rise,
            meals: [RheosMealEvent(id: "now", date: date(day: 6, hour: 16), carbs: 20, fat: 0, protein: 0, note: "", acknowledged: false)],
            now: date(day: 6, hour: 16, minute: 10),
            lastAsked: nil,
            calendar: calendar
        ))
        XCTAssertEqual(RheosUAM.interpret("späte Verdauung"), .late)
        XCTAssertEqual(RheosUAM.interpret("Stress"), .other)
        var meals = [meal]
        let latePrompt = RheosUAMPrompt(rise: 40, started: date(day: 3, hour: 22), mealID: meal.id, mealDate: meal.date, text: "")
        let marked = RheosUAM.lateMark(prompt: latePrompt, now: date(day: 3, hour: 23), calendar: calendar)
        XCTAssertEqual(meals.count, 1)
        XCTAssertTrue(marked?.note.contains("Kein neuer Eintrag") ?? false)
        let caution = RheosNightCaution.dampen(
            RheosHourlyFactors(basal: hourFactors(hour: 23, value: 1.15), isf: hourFactors(hour: 23, value: 0.85), carbRatio: Array(repeating: 1, count: 24)),
            now: date(day: 3, hour: 23, minute: 30),
            marks: marked.map { [$0.mark] } ?? [],
            modeIsScharf: true,
            calendar: calendar
        )
        XCTAssertTrue(caution.apply)
        XCTAssertEqual(caution.factors.basal[23], 1, accuracy: 0.001)
        XCTAssertEqual(caution.factors.isf[23], 1, accuracy: 0.001)
        let logged = RheosNightCaution.dampen(
            caution.factors,
            now: date(day: 3, hour: 23, minute: 30),
            marks: marked.map { [$0.mark] } ?? [],
            modeIsScharf: false,
            calendar: calendar
        )
        XCTAssertFalse(logged.apply)

        var nightGlucose: [RheosGlucosePoint] = []
        for day in 1 ... 6 {
            nightGlucose.append(RheosGlucosePoint(date: date(day: day, hour: 2), mgdl: 60))
            nightGlucose.append(RheosGlucosePoint(date: date(day: day, hour: 4), mgdl: 190))
        }
        let night = RheosNightReview.check(glucose: nightGlucose, now: date(day: 7, hour: 8), calendar: calendar)
        XCTAssertTrue(night.shouldShowBeforeBasal)
        XCTAssertTrue(RheosNightReview.blocksBasalChange(show: true, acknowledgedDay: nil, today: "2026-01-07"))
        XCTAssertFalse(RheosNightReview.blocksBasalChange(show: true, acknowledgedDay: "2026-01-07", today: "2026-01-07"))

        let story = RheosSettingsStory.explain(RheosTrioReading(
            bolusPercent: 0.8,
            maxSMBMinutes: 30,
            maxIOB: 0,
            smbOn: true,
            uamOn: false,
            autosensMin: 0.7,
            autosensMax: 1.2,
            targets: "100–110 mg/dL",
            dynamicISFOn: true,
            closedLoop: true
        ))
        XCTAssertTrue(story.contains("ändert diese Einstellungen nicht"))
        XCTAssertTrue(story.contains("Dynamic ISF"))
        XCTAssertTrue(story.contains("80"))
    }

    func testMealParserRejectsZerosAndReadsFences() {
        XCTAssertNil(RheosMealParser.estimate(in: "{\"carbs\":0,\"fat\":0,\"protein\":0,\"kcal\":0}"))
        XCTAssertNil(RheosMealParser.estimate(in: "keine zahlen"))
        let fenced = """
        Hier die Schätzung:
        ```json
        {"carbs":"42","fat":8,"protein":12,"kcal":"300"}
        ```
        """
        let meal = RheosMealParser.estimate(in: fenced)
        XCTAssertEqual(meal?.carbs ?? 0, 42, accuracy: 0.001)
        XCTAssertEqual(meal?.fat ?? 0, 8, accuracy: 0.001)
        XCTAssertEqual(meal?.protein ?? 0, 12, accuracy: 0.001)
        let parts: [Any] = [
            ["type": "text", "text": "Reis"] as [String: Any],
            ["text": "40 g"] as [String: Any]
        ]
        XCTAssertEqual(RheosCloudContent.text(from: parts), "Reis\n40 g")
        XCTAssertNil(RheosCloudContent.text(from: "   "))
        XCTAssertFalse(RheosMealText.prompt(for: "Reis").contains("\"carbs\":0"))
        XCTAssertFalse(RheosMealText.photoPrompt.contains("\"carbs\":0"))
    }

    func testStepWindowsLieInPulseAndShortNights() {
        let quiet = RheosStepActivity.Windows(steps5: 0, steps15: 0, steps30: 0, steps60: 0, feedFresh: false)
        let unknown = RheosStepActivity.status(windows: quiet, heartRate: nil, restingHeartRate: 60)
        XCTAssertEqual(unknown.status, .unknown)
        XCTAssertTrue(unknown.line.contains("nicht an"))

        let walking = RheosStepActivity.Windows(steps5: 500, steps15: 500, steps30: 500, steps60: 500, feedFresh: true)
        XCTAssertEqual(RheosStepActivity.status(windows: walking, heartRate: nil, restingHeartRate: 60).status, .active)

        let still = RheosStepActivity.Windows(steps5: 0, steps15: 10, steps30: 20, steps60: 100, feedFresh: true)
        XCTAssertEqual(RheosStepActivity.status(windows: still, heartRate: 70, restingHeartRate: 60).status, .inactive)
        let guarded = RheosStepActivity.status(windows: still, heartRate: 100, restingHeartRate: 60)
        XCTAssertEqual(guarded.status, .pulseGuard)
        XCTAssertEqual(RheosStepActivity.zone(bpm: 100, resting: 60), 2)

        let waiting = RheosStepActivity.lieIn(minutesAfterUsualWake: 30, windows: still)
        XCTAssertTrue(waiting.waiting)
        let up = RheosStepActivity.Windows(steps5: 40, steps15: 120, steps30: 200, steps60: 260, feedFresh: true)
        XCTAssertFalse(RheosStepActivity.lieIn(minutesAfterUsualWake: 30, windows: up).waiting)
        XCTAssertFalse(RheosStepActivity.lieIn(minutesAfterUsualWake: 30, windows: quiet).waiting)
        XCTAssertFalse(RheosStepActivity.lieIn(minutesAfterUsualWake: 150, windows: still).waiting)
        XCTAssertNotNil(RheosStepActivity.movementNote(status: .active, iob: 3))
        XCTAssertNil(RheosStepActivity.movementNote(status: .inactive, iob: 3))

        let sleep = (1 ... 3).map { day in
            RheosSleepInterval(
                id: "n\(day)",
                start: date(day: day, hour: 1),
                end: date(day: day, hour: 5),
                stage: "asleep"
            )
        }
        XCTAssertTrue(RheosStepActivity.shortNights(sleep: sleep, now: date(day: 8, hour: 12), calendar: calendar).contains("kurze Nächte"))

        let defaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let stored = RheosMealDraftStore.save(
            RheosMealEstimate(carbs: 30, fat: 10, protein: 12, kcal: nil, note: "Reis"),
            defaults: defaults
        )
        XCTAssertTrue(stored)
        let taken = RheosMealDraftStore.take(defaults: defaults)
        XCTAssertEqual(taken?.carbs, 30)
        XCTAssertEqual(taken?.fat, 10)
        XCTAssertNil(RheosMealDraftStore.take(defaults: defaults))
    }

    func testHourLogUpdatesInsteadOfRepeating() {
        let first = RheosDecisionLog.entry(
            now: date(day: 3, hour: 1, minute: 5),
            factors: .identity,
            inputs: "Wenig Schritte über 60 Minuten (60 unter 500)",
            reason: "Schatten",
            autosensRatio: 1,
            applied: false
        )
        let again = RheosDecisionLog.entry(
            now: date(day: 3, hour: 1, minute: 20),
            factors: .identity,
            inputs: "Wenig Schritte über 60 Minuten (61 unter 500)",
            reason: "Schatten",
            autosensRatio: 1,
            applied: false
        )
        let log = RheosDecisionLog.appending([first], again, calendar: calendar)
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].repeatCount, 2)
        XCTAssertEqual(log[0].since, first.date)
        let nextHour = RheosDecisionLog.entry(
            now: date(day: 3, hour: 2),
            factors: .identity,
            inputs: again.inputs,
            reason: again.reason,
            autosensRatio: 1,
            applied: false
        )
        XCTAssertEqual(RheosDecisionLog.appending(log, nextHour, calendar: calendar).count, 2)
        var moved = again
        moved.basal = 1.2
        moved.applied = true
        XCTAssertEqual(RheosDecisionLog.appending([first], moved, calendar: calendar).count, 2)
    }

    func testSleepHidesInactivityAndLowHoursStaySafe() {
        let still = RheosStepActivity.Windows(steps5: 0, steps15: 10, steps30: 20, steps60: 40, feedFresh: true)
        let asleep = RheosStepActivity.status(windows: still, heartRate: 55, restingHeartRate: 60, asleep: true)
        XCTAssertFalse(asleep.line.contains("Wenig Schritte"))
        XCTAssertEqual(asleep.status, .normal)
        let awake = RheosStepActivity.status(windows: still, heartRate: 55, restingHeartRate: 60, asleep: false)
        XCTAssertTrue(awake.line.contains("Wenig Schritte"))

        let nights = (1 ... 3).map { day in
            RheosSleepInterval(id: "s\(day)", start: date(day: day, hour: 23), end: date(day: day + 1, hour: 7), stage: "asleep")
        }
        XCTAssertTrue(RheosStepActivity.isAsleep(now: date(day: 4, hour: 1), sleep: nights, calendar: calendar))

        let covered = [RheosSleepInterval(id: "now", start: date(day: 4, hour: 0), end: date(day: 4, hour: 6), stage: "asleep")]
        XCTAssertTrue(RheosStepActivity.isAsleep(now: date(day: 4, hour: 1), sleep: covered, calendar: calendar))

        XCTAssertNil(RheosMealDelta.usable(-210))
        XCTAssertEqual(RheosMealDelta.usable(-40) ?? 0, -40, accuracy: 0.001)
        XCTAssertEqual(RheosMealDelta.text(nil, due: date(day: 4, hour: 6), now: date(day: 4, hour: 5)), "noch offen")
        XCTAssertEqual(RheosMealDelta.text(nil, due: date(day: 4, hour: 4), now: date(day: 4, hour: 5)), "keine Daten")
        XCTAssertEqual(RheosMealDelta.text(-210, due: date(day: 4, hour: 4), now: date(day: 4, hour: 5)), "unsicher")
        XCTAssertNil(RheosMealDelta.sample([RheosGlucosePoint(date: date(day: 4, hour: 1), mgdl: 4.2)], at: date(day: 4, hour: 1)))

        let low = RheosNightLow.hours(from: [
            RheosHourlyGlucose(hour: 4, medianMgdl: 59, count: 12),
            RheosHourlyGlucose(hour: 5, medianMgdl: 90, count: 12),
            RheosHourlyGlucose(hour: 6, medianMgdl: 62, count: 2)
        ])
        XCTAssertEqual(low, [4])
        XCTAssertTrue(RheosNightLow.notice(low)?.contains("Diabetes-Team") ?? false)
        let protected = RheosNightLow.protect(
            RheosHourlyFactors(basal: hourFactors(hour: 4, value: 1.15), isf: hourFactors(hour: 4, value: 0.8), carbRatio: Array(repeating: 1, count: 24)),
            hours: Set(low)
        )
        XCTAssertEqual(protected.basal[4], 1, accuracy: 0.001)
        XCTAssertEqual(protected.isf[4], 1, accuracy: 0.001)
        XCTAssertEqual(protected.basal[5], 1, accuracy: 0.001)
        XCTAssertTrue(RheosModelCard.line(trained: false, networkMAE: nil, ridgeMAE: nil, source: "median").contains("zu wenig Daten"))

        let same = RheosAbsorptionShadow.split(
            meal: RheosMealEvent(id: "same", date: date(day: 3, hour: 12), carbs: 40, fat: 0, protein: 0, note: "", acknowledged: false),
            insulin: [RheosInsulinEvent(date: date(day: 3, hour: 12, minute: 2), units: 2.55, kind: "bolus")],
            trioPercent: 0.5,
            refinedPercent: 0.5
        )
        XCTAssertTrue(same?.line.contains("keine Abweichung") ?? false)
        XCTAssertTrue(same?.line.contains("2,55") ?? false)
        XCTAssertFalse(same?.line.contains("statt") ?? true)
    }

    private func stableGlucose(days: ClosedRange<Int>, invertFrom: Int? = nil) -> [RheosGlucosePoint] {
        var points: [RheosGlucosePoint] = []
        for day in days {
            for hour in 0 ..< 24 {
                var value = 110.0
                if hour < 6 { value = 90 }
                if hour >= 12, hour < 17 { value = 180 }
                if let invertFrom, day >= invertFrom {
                    if value == 90 { value = 180 }
                    else if value == 180 { value = 90 }
                }
                for minute in [0, 15, 30, 45] {
                    points.append(RheosGlucosePoint(date: date(day: day, hour: hour, minute: minute), mgdl: value))
                }
            }
        }
        return points
    }

    private func hourFactors(hour: Int, value: Double) -> [Double] {
        var factors = Array(repeating: 1.0, count: 24)
        factors[hour] = value
        return factors
    }

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute))!
    }
}
