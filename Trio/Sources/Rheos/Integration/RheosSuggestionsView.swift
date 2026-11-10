import PhotosUI
import SwiftUI
import Swinject

struct RheosSuggestionsView: View {
    let resolver: Resolver

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    @State private var report: RheosReport?
    @State private var status = ""
    @State private var question = ""
    @State private var answer = ""
    @State private var comparison = ""
    @State private var mealCarbs = ""
    @State private var mealFat = ""
    @State private var mealProtein = ""
    @State private var photo: PhotosPickerItem?
    @State private var suggestions: [RheosChatSuggestion] = []
    @State private var siteName = ""
    @State private var care = RheosCareReport(
        patchCheck: nil,
        compressionExcluded: [],
        siteNotes: [],
        weekly: "",
        hypoSuggestion: nil,
        alcohol: nil
    )
    @State private var showWeeklyShare = false
    @State private var weeklyURL: URL?

    var body: some View {
        Form {
            Section {
                Text("Nur Vorschlag, keine Wirkung. Diese Seite dosiert nicht und schickt keinen Bolus.")
                    .font(.footnote)
                if RheosModeStore.current == .scharf {
                    Text("Scharf kann ISF, KH-Faktor und Basal über den Profil-Haken anpassen. SMB und UAM bleiben Trios Algorithmus.")
                        .font(.footnote)
                }
            }

            if let report {
                Section("Stabilität") {
                    Text(report.stability.summary)
                    labeled("Werte", "\(report.stability.sampleCount)")
                    labeled("70–140 mg/dL", percent(report.stability.timeInTightRange))
                    labeled("70–180 mg/dL", percent(report.stability.timeInRange))
                    labeled("Variationskoeffizient", cv(report.stability.coefficientOfVariationPercent))
                }

                Section("Modell") {
                    Text(report.decision.reason)
                    labeled("Prüfung", report.decision.walkForward.passed ? "bestanden" : "nicht bestanden")
                    labeled("Angewendet", report.decision.applied ? "ja, im Band" : "nein")
                    Text(RheosCoreMLAdapter.statusLine(RheosStore.shared.loadDocument().shadow))
                        .font(.footnote)
                    if let loop = RheosStore.shared.loadDataset().loopReading {
                        Text("Autosens \(format(loop.autosensRatio)), Dynamic-ISF \(loop.dynamicISF.map(format) ?? "—") mg/dL pro E. Das Band bleibt der Schnitt aus Rheos und Autosens min/max.")
                            .font(.footnote)
                    }
                }

                Section("Wochenvergleich, Schatten") {
                    Text("Rheos gegen die echten Werte und gegen den Abstand zum Ziel 100. Das ist kein zweiter simulierter Loop.")
                        .font(.footnote)
                    Button("Diese Woche berechnen") {
                        comparison = coordinator?.storeWeekComparison().summary ?? ""
                    }
                    if !comparison.isEmpty {
                        Text(comparison).font(.footnote)
                    }
                    ForEach(RheosStore.shared.loadDocument().weeklyComparisons) { week in
                        Text(week.summary).font(.footnote)
                    }
                }

                Section("Krank") {
                    Button("Gespeichertes Preset Krank starten") {
                        Task { status = await coordinator?.startSavedPreset(named: "Krank") ?? "" }
                    }
                    Text("Nur ein Override oder Temp-Target, das du in Trio schon Krank genannt hast. Sonst passiert nichts.")
                        .font(.footnote)
                }

                Section("Mahlzeit") {
                    TextField("Kohlenhydrate g", text: $mealCarbs)
                    TextField("Fett g", text: $mealFat)
                    TextField("Protein g", text: $mealProtein)
                    PhotosPicker(selection: $photo, matching: .images) {
                        Text("Foto schätzen, nur online")
                    }
                    Button("In den Kohlenhydrat-Bildschirm legen") {
                        stageMeal(nil)
                    }
                    Text(RheosFPUSplit.proposal(hour: Calendar.current.component(.hour, from: Date()), fat: number(mealFat), protein: number(mealProtein)))
                        .font(.footnote)
                }

                Section("Glukose nach Stunde") {
                    if report.hourly.isEmpty {
                        Text("Noch keine Stundenwerte.")
                    }
                    ForEach(report.hourly) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.hour) Uhr · Median \(format(row.medianMgdl)) mg/dL (n=\(row.count))")
                            Text("Gelernt Basal ×\(factor(report.decision.learnedFactors.basal, row.hour)), ISF ×\(factor(report.decision.learnedFactors.isf, row.hour)), KH ×\(factor(report.decision.learnedFactors.carbRatio, row.hour))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Nacht nach später Mahlzeit") {
                    Text(report.dawn.summary)
                }

                Section("Mahlzeiten") {
                    if report.meals.isEmpty {
                        Text("Noch keine Mahlzeiten im Protokoll.")
                    }
                    ForEach(report.meals.suffix(30).reversed()) { meal in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(meal.presetKey) · \(format(meal.carbs)) g KH, \(format(meal.fat)) g Fett, \(format(meal.protein)) g Protein")
                            if !meal.note.isEmpty {
                                Text(meal.note).font(.footnote)
                            }
                            Text("Δ 2 h \(delta(meal.delta2h)) mg/dL · Δ 4 h \(delta(meal.delta4h)) mg/dL · 4 Uhr \(delta(meal.riseAt4am)) mg/dL")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if meal.acknowledged {
                                Text("Zur Kenntnis genommen. Kein Bolus.")
                                    .font(.footnote)
                            } else {
                                Button("Gesehen, kein Bolus") {
                                    coordinator?.acknowledgeMeal(id: meal.id)
                                    reload()
                                }
                            }
                        }
                    }
                }

                Section("Hinweise") {
                    Text("Trios Statistik zeigt TITR, TIR und CV bereits. Trios Tief- und Hoch-Alarme und der Alarm „Kohlenhydrate nötig“ bleiben unverändert. Die Texte hier dosieren nicht.")
                        .font(.footnote)
                    if let patch = care.patchCheck { Text(patch).font(.footnote) }
                    if care.compressionExcluded.isEmpty {
                        Text("Keine nächtlichen Sturzwerte vom Lernen ausgenommen.")
                            .font(.footnote)
                    } else {
                        Text("\(care.compressionExcluded.count) nächtliche Sturzwerte sind vom Lernen ausgenommen. Trios Tief-Alarm bleibt aktiv.")
                            .font(.footnote)
                    }
                    if let hypo = care.hypoSuggestion { Text(hypo).font(.footnote) }
                    if let alcohol = care.alcohol { Text(alcohol).font(.footnote) }
                    ForEach(care.siteNotes, id: \.self) { note in
                        Text(note).font(.footnote)
                    }
                    TextField("Neue Pflasterstelle", text: $siteName)
                    Button("Stelle speichern") {
                        coordinator?.recordPatchSite(siteName)
                        siteName = ""
                        reload()
                    }
                    Button("Alkohol ankündigen") {
                        status = coordinator?.announce(kind: "alcohol", note: "") ?? ""
                        reload()
                    }
                    Button("Wochenbericht teilen") {
                        shareWeekly()
                    }
                }

                Section("Kontext") {
                    Text("Du musst nichts ankündigen. Scharf liest beendete Trainings, die letzte Nacht, den Ruhepuls und Glukosemuster und passt nur ISF, KH-Faktor und Basal im Band an. Health-Daten kommen verzögert.")
                        .font(.footnote)
                    if report.contexts.isEmpty {
                        Text("Gerade kein zusätzlicher Kontext über das Stundenmodell hinaus.")
                    }
                    ForEach(report.contexts) { context in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.title).font(.headline)
                            Text(context.summary).font(.footnote)
                        }
                    }
                    Text("Optional, nur als früher Hinweis. Kein Bolus, kein Preset.")
                        .font(.footnote)
                    Button("Sport ankündigen") { status = coordinator?.announce(kind: "sport", note: "") ?? "" }
                    Button("Mahlzeit ankündigen") { status = coordinator?.announce(kind: "meal", note: "") ?? "" }
                    if !status.isEmpty {
                        Text(status).font(.footnote)
                    }
                }

                Section("Wearables") {
                    Text("Ein Signal landet erst im Dosismodell, wenn du Ja tippst. Nein lässt es draußen. Rheos schaltet keines selbst frei.")
                        .font(.footnote)
                    ForEach(report.signals) { signal in
                        let accepted = RheosStore.shared.loadDocument().acceptedSignals.contains(signal.signal)
                        let rejected = RheosStore.shared.loadDocument().rejectedSignals.contains(signal.signal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(signal.signal): \(signal.proposed ? "Effekt sichtbar" : "kein belastbarer Effekt")")
                            Text(signal.reason).font(.footnote).foregroundStyle(.secondary)
                            if accepted {
                                Text("Für das Dosismodell freigegeben.").font(.footnote)
                            } else if rejected {
                                Text("Nicht im Dosismodell.").font(.footnote)
                            } else if signal.proposed {
                                HStack {
                                    Button("Ja") { coordinator?.decideSignal(signal.signal, accepted: true); reload() }
                                    Button("Nein") { coordinator?.decideSignal(signal.signal, accepted: false); reload() }
                                }
                            }
                        }
                    }
                }

                Section("Körperdaten") {
                    NavigationLink("Körperdaten eingeben") {
                        RheosBodyView(resolver: resolver)
                    }
                    Text(report.body.summary).font(.footnote)
                }

                Section("Mahlzeiten-Muster") {
                    if report.mealPresets.isEmpty {
                        Text("Noch kein Muster. Rheos lernt das aus den eingetragenen Mahlzeiten, auch ohne extra Ankündigung.")
                    }
                    ForEach(report.mealPresets) { preset in
                        Text(preset.suggestion).font(.footnote)
                    }
                }

                Section("Assistent") {
                    TextField("Frage an das Protokoll", text: $question)
                    Button("Antwort") {
                        Task {
                            let result = await RheosChatEngine.reply(
                                question: question,
                                report: report,
                                resolver: resolver
                            )
                            answer = "\(result.text)\n\nQuelle: \(result.source)"
                            suggestions = result.suggestions
                        }
                    }
                    if !answer.isEmpty {
                        Text(answer).font(.footnote)
                    }
                    ForEach(suggestions) { suggestion in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(suggestion.text).font(.footnote)
                            Button("Bestätigen") {
                                Task {
                                    status = await coordinator?.confirmKind(kind: suggestion.kind, note: suggestion.text) ?? ""
                                }
                            }
                        }
                    }
                }
            } else {
                Section {
                    Text("Noch kein Bericht. Im Modus Schatten oder Scharf sammelt Rheos Daten.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Rheos Vorschläge")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let estimate = await RheosMealAssist.estimate(jpeg: data, resolver: resolver) {
                    mealCarbs = format(estimate.carbs)
                    mealFat = format(estimate.fat)
                    mealProtein = format(estimate.protein)
                    stageMeal(estimate)
                } else {
                    status = "Keine Foto-Schätzung. Offline oder ohne Schlüssel trägst du Kohlenhydrate, Fett und Protein selbst ein."
                }
            }
        }
        .sheet(isPresented: $showWeeklyShare) {
            if let weeklyURL {
                ShareSheet(activityItems: [weeklyURL])
            }
        }
    }

    private var coordinator: RheosCoordinator? {
        resolver.resolve(RheosCoordinator.self)
    }

    private func reload() {
        let dataset = RheosStore.shared.loadDataset()
        let preferences = resolver.resolve(SettingsManager.self)?.preferences
        let autosensMin = preferences.map { NSDecimalNumber(decimal: $0.autosensMin).doubleValue }
            ?? RheosReference.defaultMinimumMultiplier
        let autosensMax = preferences.map { NSDecimalNumber(decimal: $0.autosensMax).doubleValue }
            ?? RheosReference.defaultMaximumMultiplier
        report = RheosReportBuilder.build(
            dataset: dataset,
            mode: RheosModeStore.current,
            bounds: RheosStore.shared.loadBounds(),
            previous: RheosStore.shared.loadApplied(),
            autosensMin: autosensMin,
            autosensMax: autosensMax,
            targets: RheosTargetLoader.schedule(resolver: resolver),
            now: Date()
        )
        care = RheosCare.report(
            dataset: dataset,
            sites: RheosStore.shared.patchSites(),
            alcoholDates: RheosStore.shared.announcements().filter { $0.kind == "alcohol" }.map(\.date),
            learned: report?.decision.reason ?? "",
            now: Date(),
            calendar: .current
        )
    }

    private func shareWeekly() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rheos-wochenbericht.txt")
        try? care.weekly.write(to: url, atomically: true, encoding: .utf8)
        weeklyURL = url
        showWeeklyShare = true
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.0f %%", value * 100)
    }

    private func cv(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.0f %%", value)
    }

    private func stageMeal(_ estimate: RheosMealEstimate?) {
        let carbs = estimate?.carbs ?? number(mealCarbs)
        let fat = estimate?.fat ?? number(mealFat)
        let protein = estimate?.protein ?? number(mealProtein)
        let hour = Calendar.current.component(.hour, from: Date())
        let draft = RheosMealEstimate(
            carbs: carbs,
            fat: fat,
            protein: protein,
            kcal: estimate?.kcal ?? (4 * carbs + 9 * fat + 4 * protein),
            note: RheosFPUSplit.proposal(hour: hour, fat: fat, protein: protein)
        )
        RheosMealDraftStore.save(draft)
        status = "Werte liegen im Kohlenhydrat-Bildschirm bereit. Speichern dort übernimmt Trios FPU. Rheos gibt keinen Bolus."
    }

    private func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func format(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func delta(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%+.0f", value)
    }

    private func factor(_ values: [Double], _ hour: Int) -> String {
        guard values.count == 24 else { return "1.00" }
        return String(format: "%.2f", values[hour])
    }
}
