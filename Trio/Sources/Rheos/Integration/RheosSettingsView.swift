import Foundation
import SwiftUI
import Swinject
import UniformTypeIdentifiers

struct RheosSettingsView: View {
    let resolver: Resolver

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    @State private var mode = RheosModeStore.current
    @State private var confirmScharf = false
    @State private var minimum = RheosReference.defaultMinimumMultiplier
    @State private var maximum = RheosReference.defaultMaximumMultiplier
    @State private var daily = RheosReference.defaultMaxDailyChange
    @State private var contextNudge = RheosReference.defaultMaxContextNudge
    @State private var firstDay = RheosReference.defaultFirstDayChange
    @State private var laterDay = RheosReference.defaultLaterDayChange
    @State private var sundayReport = false
    @State private var cloudAnalysis = false
    @State private var basalText = ""
    @State private var reportText = ""
    @State private var previewText = ""
    @State private var decisionText = ""
    @State private var showShare = false
    @State private var showImport = false
    @State private var exportURLs: [URL] = []
    @State private var apiKey = ""
    @State private var cloudURL = RheosCloudChat.defaultBaseURL
    @State private var cloudModel = RheosCloudChat.defaultModel
    @State private var keyStored = false

    var body: some View {
        Form {
            Section {
                modeButton(.aus, title: "Aus", detail: "Trio arbeitet wie bisher. Rheos liest nichts.")
                modeButton(.schatten, title: "Schatten", detail: "Lernen und Vorschläge. Keine Wirkung auf Insulin.")
                modeButton(.scharf, title: "Scharf", detail: "Darf ISF, KH-Faktor und Basal im Band anpassen, wenn das Modell besteht.")
            } header: {
                Text("Modus")
            } footer: {
                Text("Standard ist Aus. Scharf fragt vorher nach. SMB, UAM, Max IOB, Max Basal, Max Bolus, Max SMB und die Autosens-Grenzen bleiben Trios Werte.")
            }

            if mode == .scharf {
                Section {
                    Button("Sofort zurück zu Schatten") {
                        coordinator?.setMode(.schatten)
                        reload()
                    }
                } footer: {
                    Text("Der nächste Loop benutzt wieder das unveränderte Profil. Ein schon laufendes temporäres Basal bleibt, bis Trio es ersetzt. Rheos sendet dafür keinen eigenen Pumpenbefehl.")
                }
            }

            Section {
                Stepper(value: $minimum, in: minimumRange, step: 0.05) {
                    Text("Untere Grenze \(minimum, format: .number.precision(.fractionLength(2)))")
                }
                Stepper(value: $maximum, in: maximumRange, step: 0.05) {
                    Text("Obere Grenze \(maximum, format: .number.precision(.fractionLength(2)))")
                }
                Stepper(value: $daily, in: 0.01 ... RheosReference.maxDailyChangeCap, step: 0.01) {
                    Text("Maximale Änderung pro Tag \(daily, format: .number.precision(.fractionLength(2)))")
                }
                Stepper(value: $contextNudge, in: 0.01 ... RheosReference.maxContextNudgeCap, step: 0.01) {
                    Text("Kontext am selben Tag höchstens \(contextNudge, format: .number.precision(.fractionLength(2)))")
                }
                Stepper(
                    value: $firstDay,
                    in: RheosReference.minimumFirstDayChange ... RheosReference.maximumFirstDayChange,
                    step: 0.01
                ) {
                    Text("Erster Scharf-Tag höchstens \(firstDay * 100, format: .number.precision(.fractionLength(0))) %")
                }
                Stepper(value: $laterDay, in: 0.10 ... RheosReference.maximumLaterDayChange, step: 0.01) {
                    Text("Danach höchstens \(laterDay * 100, format: .number.precision(.fractionLength(0))) %")
                }
                Toggle("Sonntags Wochenbericht", isOn: $sundayReport)
                Toggle("Cloud-Auswertung", isOn: $cloudAnalysis)
            } header: {
                Text("Band")
            } footer: {
                Text("Voreinstellung 0,70–1,20, geschnitten mit den aktuellen Autosens-Grenzen (\(format(liveAutosensMin))–\(format(liveAutosensMax))). Es gibt keine zusätzliche Grenze aus Rheos mal Autosens. Der erste Scharf-Tag bleibt bei 10–20 %. Danach darf der Schritt größer sein, das Band bleibt. Der Sonntagsbericht ist aus, bis du ihn einschaltest.")
            }

            Section {
                Text(decisionText.isEmpty ? "Noch keine Auswertung." : decisionText)
                NavigationLink("Vorschläge ansehen") {
                    RheosSuggestionsView(resolver: resolver)
                }
                NavigationLink("Körperdaten") {
                    RheosBodyView(resolver: resolver)
                }
                Text(RheosNightReview.check(
                    glucose: RheosStore.shared.loadDataset().glucose,
                    now: Date(),
                    calendar: .current
                ).summary)
                .font(.footnote)
                Button("Nachtmuster gesehen") {
                    _ = coordinator?.acknowledgeNight()
                }
                Button("Basalprofil-Vorschlag") {
                    basalText = coordinator?.basalProposal().summary ?? ""
                }
                if !basalText.isEmpty {
                    Text(basalText).font(.footnote)
                    Button("Basalprofil jetzt übernehmen") {
                        Task {
                            let text = await coordinator?.adoptBasalProposal()
                            basalText = text ?? ""
                        }
                    }
                }
                Toggle("Aufwachfenster", isOn: Binding(
                    get: { RheosStore.shared.loadDocument().wake?.enabled ?? false },
                    set: { coordinator?.setWake(enabled: $0) }
                ))
                Button("Aufwachfenster einmal bestätigen") {
                    coordinator?.setWake(enabled: true, confirmed: true)
                }
                Button("Lernbericht") {
                    Task {
                        let result = await coordinator?.learningNarrative()
                        if let result {
                            reportText = "\(result.0)\n\nQuelle: \(result.1)"
                        }
                    }
                }
                if !reportText.isEmpty {
                    Text(reportText).font(.footnote)
                    Button("Als PDF teilen") {
                        if let url = RheosTeamPDF.write(reportText) {
                            exportURLs = [url]
                            showShare = true
                        }
                    }
                }
                ForEach(Array(RheosStore.shared.loadDocument().hourLog.suffix(12).reversed())) { row in
                    let autosens = row.autosensRatio ?? 1
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(row.hour) Uhr · Basal ×\(row.basal, format: .number.precision(.fractionLength(2))) · ISF ×\(row.isf, format: .number.precision(.fractionLength(2))) · Autosens \(autosens, format: .number.precision(.fractionLength(2))) · \(row.applied ? "angewendet" : "Schatten")")
                        Text(row.inputs)
                        Text(row.reason)
                    }
                    .font(.footnote)
                }
            } header: {
                Text("Letzte Auswertung")
            } footer: {
                Text("Cloud-Auswertung ist aus, bis du sie einschaltest. Dann gehen nur die schon zusammengefassten Sätze an das Modell, keine Rohwerte. Die Dosis bleibt auf dem Gerät.")
            }

            Section {
                SecureField("API-Schlüssel, optional", text: $apiKey)
                TextField("Basis-URL", text: $cloudURL)
                TextField("Modellname", text: $cloudModel)
                Button(keyStored ? "Schlüssel ersetzen" : "Schlüssel im Schlüsselbund sichern") {
                    saveKey()
                }
                if keyStored {
                    Button("Schlüssel löschen", role: .destructive) {
                        deleteKey()
                    }
                }
            } header: {
                Text("Chat")
            } footer: {
                Text("Wenn das iPhone Apple Intelligence hat, antwortet das Modell auf dem Gerät. Sonst kann ein Cloud-Modell den Schlüssel aus dem Schlüsselbund nutzen. Der Schlüssel steht in keiner Datei im Projekt. Der Chat erklärt und darf Hinweise vorschlagen. Er dosiert nicht und ändert keine Grenzen.")
            }

            Section {
                Button("Health-Daten jetzt lesen") {
                    Task { await coordinator?.refresh() }
                }
                Button("Lernstand exportieren") {
                    export()
                }
                Button("Lernstand importieren") {
                    showImport = true
                }
            } footer: {
                Text("Health wird nur gelesen und kommt verzögert, nicht live. Der Lernstand liegt in dieser Trio-Installation und bleibt bei Updates erhalten. Er ist auf dem Gerät geschützt und im iPhone-Backup enthalten. Eine iCloud-Drive-Kopie läuft nur, wenn die Capability im Profil steht. Export und Import sichern den kompletten Lernstand.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Rheos")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: minimum) { _, newValue in
            if newValue > maximum { maximum = newValue }
            saveBand()
        }
        .onChange(of: maximum) { _, newValue in
            if newValue < minimum { minimum = newValue }
            saveBand()
        }
        .onChange(of: daily) { _, _ in
            saveBand()
        }
        .onChange(of: contextNudge) { _, _ in
            saveBand()
        }
        .onChange(of: firstDay) { _, _ in
            saveBand()
        }
        .onChange(of: laterDay) { _, _ in
            saveBand()
        }
        .onChange(of: sundayReport) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: RheosCareNotifier.sundayKey)
        }
        .onChange(of: cloudAnalysis) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: RheosCloudPolicy.key)
        }
        .onReceive(
            Foundation.NotificationCenter.default.publisher(for: Foundation.Notification.Name.rheosModeDidChange)
        ) { (_: Foundation.Notification) in
            reload()
        }
        .alert("Rheos auf Scharf stellen?", isPresented: $confirmScharf) {
            Button("Scharf aktivieren", role: .destructive) {
                coordinator?.setMode(.scharf)
                reload()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(previewText)
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(activityItems: exportURLs)
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try coordinator?.importArchive(from: url)
                    decisionText = "Importiert. Glukose, Faktoren und Entscheidungen sind wieder da."
                    reload()
                } catch {
                    decisionText = "Import fehlgeschlagen. Der bisherige Lernstand bleibt."
                }
            case .failure:
                decisionText = "Import abgebrochen."
            }
        }
    }

    private var coordinator: RheosCoordinator? {
        resolver.resolve(RheosCoordinator.self)
    }

    private var liveAutosensMin: Double {
        guard let value = resolver.resolve(SettingsManager.self)?.preferences.autosensMin else {
            return RheosReference.defaultMinimumMultiplier
        }
        return NSDecimalNumber(decimal: value).doubleValue
    }

    private var liveAutosensMax: Double {
        guard let value = resolver.resolve(SettingsManager.self)?.preferences.autosensMax else {
            return RheosReference.defaultMaximumMultiplier
        }
        return NSDecimalNumber(decimal: value).doubleValue
    }

    private var stepperMin: Double { min(liveAutosensMin, liveAutosensMax) }
    private var stepperMax: Double { max(liveAutosensMin, liveAutosensMax) }
    private var minimumRange: ClosedRange<Double> { min(minimum, stepperMin) ... max(minimum, stepperMax) }
    private var maximumRange: ClosedRange<Double> { min(maximum, stepperMin) ... max(maximum, stepperMax) }

    @ViewBuilder private func modeButton(_ value: RheosMode, title: String, detail: String) -> some View {
        Button {
            if value == .scharf, mode != .scharf {
                previewText = coordinator?.scharfPreview()
                    ?? "Vorschau nicht verfügbar. Scharf schreibt nichts, bevor du bestätigst."
                confirmScharf = true
            } else if value != .scharf {
                coordinator?.setMode(value)
                reload()
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if mode == value {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func reload() {
        mode = RheosModeStore.current
        let bounds = RheosStore.shared.loadBounds()
        minimum = min(max(bounds.minimumMultiplier, stepperMin), stepperMax)
        maximum = min(max(bounds.maximumMultiplier, stepperMin), stepperMax)
        if minimum > maximum { maximum = minimum }
        daily = bounds.maxDailyChange
        contextNudge = bounds.maxContextNudge
        firstDay = bounds.firstDayMaxChange
        laterDay = bounds.laterDayMaxChange
        sundayReport = UserDefaults.standard.bool(forKey: RheosCareNotifier.sundayKey)
        cloudAnalysis = RheosCloudPolicy.allowsCloud()
        cloudURL = UserDefaults.standard.string(forKey: RheosCloudChat.baseURLKey) ?? RheosCloudChat.defaultBaseURL
        cloudModel = UserDefaults.standard.string(forKey: RheosCloudChat.modelKey) ?? RheosCloudChat.defaultModel
        if case let .success(stored) = resolver.resolve(Keychain.self)?.getValue(String.self, forKey: RheosCloudChat.keychainKey) {
            keyStored = !(stored ?? "").isEmpty
        } else {
            keyStored = false
        }
        decisionText = RheosStore.shared.loadDecision()?.reason ?? ""
    }

    private func saveBand() {
        var bounds = RheosStore.shared.loadBounds()
        bounds.minimumMultiplier = minimum
        bounds.maximumMultiplier = maximum
        bounds.maxDailyChange = daily
        bounds.maxContextNudge = contextNudge
        bounds.firstDayMaxChange = firstDay
        bounds.laterDayMaxChange = laterDay
        coordinator?.saveBounds(bounds)
    }

    private func export() {
        do {
            exportURLs = try coordinator?.exportFiles() ?? []
            UserDefaults.standard.set(Date(), forKey: RheosUpkeep.exportKey)
            showShare = !exportURLs.isEmpty
        } catch {
            decisionText = "Export fehlgeschlagen."
        }
    }

    private func saveKey() {
        UserDefaults.standard.set(cloudURL, forKey: RheosCloudChat.baseURLKey)
        UserDefaults.standard.set(cloudModel, forKey: RheosCloudChat.modelKey)
        guard let keychain = resolver.resolve(Keychain.self) else { return }
        if apiKey.isEmpty {
            keyStored = (try? keychain.hasValue(forKey: RheosCloudChat.keychainKey).get()) ?? false
            return
        }
        _ = keychain.setValue(apiKey, forKey: RheosCloudChat.keychainKey)
        apiKey = ""
        keyStored = true
    }

    private func deleteKey() {
        _ = resolver.resolve(Keychain.self)?.removeObject(forKey: RheosCloudChat.keychainKey)
        apiKey = ""
        keyStored = false
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
