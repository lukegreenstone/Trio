import Foundation

enum RheosLearner {
    /// Fits hourly ISF, carb-ratio and basal multipliers and decides whether Scharf may apply them.
    ///
    /// The fit is a descriptive hourly median, not a machine-learning model. Walk-forward
    /// holds out the latest days. Application steps at most `maxDailyChange` once per calendar day
    /// and stays inside the intersection of the Rheos band and Trio's autosens window.
    static func evaluate(
        dataset: RheosDataset,
        mode: RheosMode,
        bounds: RheosBounds,
        previous: RheosAppliedState?,
        autosensMin: Double = RheosReference.defaultMinimumMultiplier,
        autosensMax: Double = RheosReference.defaultMaximumMultiplier,
        targets: RheosTargetSchedule = .flat(RheosReference.missingTargetFallbackMgdl),
        scharfSince: Date? = nil,
        acceptedSignals: [String] = [],
        dynamicISFOn: Bool = false,
        wake: RheosWakeState? = nil,
        sites: [RheosPatchSite] = [],
        lateDigestion: [RheosLateDigestion] = [],
        now: Date,
        calendar: Calendar = .current
    ) -> RheosProfileDecision {
        let limits = bounds.sanitized()
        let band = limits.effectiveRange(autosensMin: autosensMin, autosensMax: autosensMax)
        guard targets.isComplete else {
            let walk = RheosWalkForwardResult(
                passed: false,
                modelMAE: nil,
                baselineMAE: nil,
                dayCount: 0,
                sampleCount: dataset.glucose.count,
                reason: "Kein Glukose-Zielplan aus Trio. Rheos setzt keinen eigenen Zielwert."
            )
            return decision(
                mode: mode,
                code: mode == .scharf ? .fallbackInsufficientData : (mode == .aus ? .off : .shadow),
                applied: false,
                reason: walk.reason,
                factors: .identity,
                learned: .identity,
                walk: walk,
                band: band,
                now: now
            )
        }
        let learningSet = RheosDataQuality.excludingUnusable(dataset, sites: sites, calendar: calendar, now: now)
        let prior = RheosBodyPrior.strength(for: learningSet.body)
        let fitted = estimate(
            dataset: learningSet,
            targets: targets,
            band: band,
            acceptedSignals: acceptedSignals,
            calendar: calendar
        )
        let learned = RheosDynamicISF.neutralize(fitted, dynamicISFOn: dynamicISFOn)
        let walk = walkForward(
            dataset: learningSet,
            targets: targets,
            bounds: limits,
            priorStrength: prior,
            calendar: calendar
        )

        if mode == .aus {
            return decision(
                mode: mode,
                code: .off,
                applied: false,
                reason: "Rheos ist aus. Trio rechnet unverändert.",
                factors: .identity,
                learned: learned,
                walk: walk,
                band: band,
                now: now
            )
        }

        let noRoom = abs(band.lowerBound - 1) < 0.000_000_1 && abs(band.upperBound - 1) < 0.000_000_1
        if mode == .scharf, noRoom {
            return decision(
                mode: mode,
                code: .fallbackWalkForward,
                applied: false,
                reason: "Rückfall auf Trio. Die Autosens-Grenzen lassen Rheos keinen Spielraum (Band 1–1). SMB und UAM bleiben, wie Trio sie eingestellt hat.",
                factors: .identity,
                learned: learned.clamped(to: band),
                walk: walk,
                band: band,
                now: now
            )
        }

        guard mode == .scharf, walk.passed else {
            let code: RheosDecisionCode = mode == .scharf
                ? (walk.modelMAE == nil ? .fallbackInsufficientData : .fallbackWalkForward)
                : .shadow
            let reason: String
            if mode == .schatten {
                reason = walk.passed
                    ? "Schattenmodus. Das Stundenmodell hat die Prüfung bestanden und wird nicht angewendet."
                    : "Schattenmodus. \(walk.reason) Keine Wirkung auf Insulin."
            } else {
                reason = "Rückfall auf Trio. \(walk.reason) SMB und UAM laufen mit dem unveränderten Profil."
            }
            let wakePreview = RheosWake.window(
                factors: learned,
                minutesSinceWake: RheosWake.minutesSinceWake(now: now, wake: wake?.lastWake),
                kind: RheosWakeKind(rawValue: wake?.kind ?? "") ?? .unclear,
                enabled: wake?.enabled ?? false,
                confirmed: wake?.confirmed ?? false,
                modeIsScharf: false,
                band: band
            )
            let caution = RheosNightCaution.dampen(
                .identity,
                now: now,
                marks: lateDigestion,
                modeIsScharf: false,
                calendar: calendar
            )
            let shadowReason = reason + wakePreview.line + caution.line
            return decision(
                mode: mode,
                code: code,
                applied: false,
                reason: shadowReason,
                factors: .identity,
                learned: learned,
                walk: walk,
                band: band,
                now: now
            )
        }

        let contexts = RheosContextInference.infer(dataset: dataset, targets: targets, now: now, calendar: calendar)
        let need = RheosContextInference.insulinNeedByHour(contexts, maxNudge: limits.maxContextNudge, now: now, calendar: calendar)
        // The stored vector is the slow glucose model only. Context is applied
        // on top for this loop and is not written back into that vector, so a
        // workout cannot be multiplied twice.
        let slow: RheosHourlyFactors
        if let previous, calendar.isDate(previous.appliedAt, inSameDayAs: now) {
            slow = previous.factors.clamped(to: band)
        } else {
            slow = learned.stepped(
                from: previous?.factors ?? .identity,
                maxStep: RheosRamp.maxStep(now: now, scharfSince: scharfSince, bounds: limits, calendar: calendar),
                band: band
            )
        }
        let combined = RheosContextInference.combine(slow: slow, insulinNeed: need, band: band)
        var delivered = RheosDynamicISF.neutralize(combined, dynamicISFOn: dynamicISFOn)
        let wakeResult = RheosWake.window(
            factors: delivered,
            minutesSinceWake: RheosWake.minutesSinceWake(now: now, wake: wake?.lastWake),
            kind: RheosWakeKind(rawValue: wake?.kind ?? "") ?? .unclear,
            enabled: wake?.enabled ?? false,
            confirmed: wake?.confirmed ?? false,
            modeIsScharf: true,
            band: band
        )
        if wakeResult.apply { delivered = wakeResult.factors }
        let caution = RheosNightCaution.dampen(
            delivered,
            now: now,
            marks: lateDigestion,
            modeIsScharf: true,
            calendar: calendar
        )
        if caution.apply { delivered = caution.factors }
        let contextNote = contexts.isEmpty
            ? ""
            : " Kontext aus Daten: \(contexts.map(\.title).joined(separator: ", "))."
        let dynamicNote = dynamicISFOn ? " Dynamic ISF ist an, der Rheos-ISF-Faktor bleibt 1." : ""
        let doubleNote = RheosDynamicISF.doubleCountWarning(
            meanBasalFactor: delivered.basal.reduce(0, +) / Double(max(delivered.basal.count, 1)),
            autosensRatio: dataset.loopReading?.autosensRatio
        ).map { " \($0)" } ?? ""
        return decision(
            mode: mode,
            code: .applied,
            applied: true,
            reason: "Scharf. Stundenfaktoren für ISF, KH-Faktor und Basal, Band \(format(band.lowerBound))–\(format(band.upperBound)), höchstens \(format(limits.maxDailyChange)) pro Tag für das Stundenmodell. SMB und UAM bleiben an.\(contextNote)\(bodyNote(dataset))\(dynamicNote)\(wakeResult.line)\(caution.line)\(doubleNote)",
            factors: delivered,
            slowFactors: slow,
            learned: learned,
            walk: walk,
            band: band,
            now: now
        )
    }

    static func estimate(
        dataset: RheosDataset,
        targets: RheosTargetSchedule,
        band: ClosedRange<Double>,
        acceptedSignals: [String] = [],
        calendar: Calendar
    ) -> RheosHourlyFactors {
        let observations = RheosFit.observations(dataset: dataset, targets: targets, calendar: calendar)
        var model = RheosFit.fit(
            observations: observations,
            band: band,
            priorStrength: RheosBodyPrior.strength(for: dataset.body)
        )
        let core = RheosCoreModel.fit(
            dataset: dataset,
            targets: targets,
            band: band,
            acceptedSignals: acceptedSignals,
            calendar: calendar
        )
        if core.trained {
            model.factors.basal = core.factors.basal
            model.factors.isf = core.factors.isf
        }
        model.factors.carbRatio = RheosFit.carbRatioFactors(dataset: dataset, targets: targets, band: band, calendar: calendar)
        return model.factors
    }

    static func walkForward(
        dataset: RheosDataset,
        targets: RheosTargetSchedule,
        bounds: RheosBounds,
        priorStrength: Double = RheosBodyPrior.plain,
        calendar: Calendar
    ) -> RheosWalkForwardResult {
        let limits = bounds.sanitized()
        let observations = RheosFit.observations(dataset: dataset, targets: targets, calendar: calendar)
        let days = Array(Set(observations.map(\.day))).sorted()
        if days.count < limits.minimumDays || observations.count < limits.minimumGlucoseSamples {
            return RheosWalkForwardResult(
                passed: false,
                modelMAE: nil,
                baselineMAE: nil,
                dayCount: days.count,
                sampleCount: observations.count,
                reason: "Zu wenig Daten: \(days.count) Tage und \(observations.count) Werte. Gebraucht werden mindestens \(limits.minimumDays) Tage und \(limits.minimumGlucoseSamples) Werte."
            )
        }
        let testCount = RheosReference.walkForwardTestDays
        guard days.count > testCount else {
            return RheosWalkForwardResult(
                passed: false,
                modelMAE: nil,
                baselineMAE: nil,
                dayCount: days.count,
                sampleCount: observations.count,
                reason: "Nicht genug Tage für eine zeitlich getrennte Prüfung."
            )
        }
        let testDays = Set(days.suffix(testCount))
        let train = observations.filter { !testDays.contains($0.day) }
        let test = observations.filter { testDays.contains($0.day) }
        guard let trainGlobal = RheosStats.median(train.map(\.glucose)), !test.isEmpty else {
            return RheosWalkForwardResult(
                passed: false,
                modelMAE: nil,
                baselineMAE: nil,
                dayCount: days.count,
                sampleCount: observations.count,
                reason: "Die Prüfung konnte nicht gerechnet werden."
            )
        }
        let trained = RheosFit.fit(observations: train, band: 0.7 ... 1.2, priorStrength: priorStrength)
        let modelErrors = test.map { abs($0.glucose - RheosFit.predict($0, model: trained)) }
        let baselineErrors = test.map { abs($0.glucose - trainGlobal) }
        let modelMAE = RheosStats.mean(modelErrors) ?? 0
        let baselineMAE = RheosStats.mean(baselineErrors) ?? 0
        let passed = modelMAE <= baselineMAE * (1 - limits.minimumImprovement)
        let reason = passed
            ? "Walk-forward bestanden. Modellfehler \(format(modelMAE)) mg/dL, einfacher Mittelwert \(format(baselineMAE)) mg/dL. IOB-Steigung \(format(trained.iobSlope)), KH-Steigung \(format(trained.carbSlope))."
            : "Walk-forward nicht bestanden. Modellfehler \(format(modelMAE)) mg/dL gegen \(format(baselineMAE)) mg/dL beim einfachen Mittelwert. Kein Profilfaktor."
        return RheosWalkForwardResult(
            passed: passed,
            modelMAE: modelMAE,
            baselineMAE: baselineMAE,
            dayCount: days.count,
            sampleCount: observations.count,
            reason: reason
        )
    }

    private static func decision(
        mode: RheosMode,
        code: RheosDecisionCode,
        applied: Bool,
        reason: String,
        factors: RheosHourlyFactors,
        slowFactors: RheosHourlyFactors? = nil,
        learned: RheosHourlyFactors,
        walk: RheosWalkForwardResult,
        band: ClosedRange<Double>,
        now: Date
    ) -> RheosProfileDecision {
        RheosProfileDecision(
            mode: mode,
            code: code,
            applied: applied,
            reason: reason,
            factors: factors,
            slowFactors: slowFactors,
            learnedFactors: learned,
            walkForward: walk,
            evaluatedAt: now,
            bandMinimum: band.lowerBound,
            bandMaximum: band.upperBound
        )
    }

    private static func bodyNote(_ dataset: RheosDataset) -> String {
        guard dataset.body.weightKg != nil else { return "" }
        return " Körperdaten sind ein vorsichtigerer Prior und ein Entwurf für das Team, keine angewendete Insulinzahl."
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

}

enum RheosReportBuilder {
    static func build(
        dataset: RheosDataset,
        mode: RheosMode,
        bounds: RheosBounds,
        previous: RheosAppliedState?,
        autosensMin: Double,
        autosensMax: Double,
        targets: RheosTargetSchedule = .flat(RheosReference.missingTargetFallbackMgdl),
        scharfSince: Date? = nil,
        now: Date,
        calendar: Calendar = .current
    ) -> RheosReport {
        RheosReport(
            stability: RheosAnalysis.stability(glucose: dataset.glucose),
            hourly: RheosAnalysis.hourlyGlucose(dataset.glucose, calendar: calendar),
            dawn: RheosAnalysis.dawn(dataset: dataset, calendar: calendar),
            meals: RheosAnalysis.mealOutcomes(dataset: dataset, calendar: calendar),
            decision: RheosLearner.evaluate(
                dataset: dataset,
                mode: mode,
                bounds: bounds,
                previous: previous,
                autosensMin: autosensMin,
                autosensMax: autosensMax,
                targets: targets,
                scharfSince: scharfSince,
                now: now,
                calendar: calendar
            ),
            contexts: RheosContextInference.infer(dataset: dataset, targets: targets, now: now, calendar: calendar),
            mealPresets: RheosFit.mealPresets(dataset: dataset, calendar: calendar),
            proposals: RheosAnalysis.contextProposals(dataset: dataset, now: now, calendar: calendar),
            signals: RheosAnalysis.signalRelevance(dataset: dataset, calendar: calendar),
            body: RheosAnalysis.bodyDraft(dataset.body)
        )
    }
}

enum RheosChatStub {
    /// Local reply from the logged report. This type has no network client.
    static func reply(question: String, report: RheosReport, settingsNote: String = "") -> String {
        let asked = question.lowercased()
        var lines = [
            "Lokale Antwort aus dem Rheos-Protokoll. Es wird kein Netzwerk-Modell aufgerufen. Das ist keine Therapieanweisung."
        ]
        if asked.contains("4") || asked.contains("nacht") || asked.contains("morgen") || asked.contains("dawn") {
            lines.append(report.dawn.summary)
        }
        if asked.isEmpty || asked.contains("bereich") || asked.contains("tir") || asked.contains("stabil") {
            lines.append(report.stability.summary)
        }
        if asked.contains("isf") || asked.contains("basal") || asked.contains("faktor") || asked.contains("scharf") {
            lines.append(report.decision.reason)
        }
        if !settingsNote.isEmpty,
           asked.contains("einstell") || asked.contains("smb") || asked.contains("iob") || asked.contains("prozent")
           || asked.contains("ziel") || asked.contains("autosens") || asked.contains("uam")
           || asked.contains("schritt") || asked.contains("puls") || asked.contains("schlaf") {
            lines.append(settingsNote)
        }
        if lines.count == 1 {
            lines.append("Ich kann die geloggten Muster beschreiben: Zeit im Bereich, Stundenmediane, späte Mahlzeiten und ob die Walk-forward-Prüfung bestanden ist.")
        }
        lines.append("Fragen zur Dosis gehören zu deinem Team. Rheos gibt selbst keinen Bolus.")
        return lines.joined(separator: "\n\n")
    }
}
