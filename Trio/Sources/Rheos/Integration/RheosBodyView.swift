import SwiftUI
import Swinject

/// Body measurements for a labelled draft and a more cautious learning prior.
/// Saving here does not write a Trio profile and does not deliver insulin.
struct RheosBodyView: View {
    let resolver: Resolver

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    @State private var age = ""
    @State private var weight = ""
    @State private var height = ""
    @State private var fat = ""
    @State private var muscle = ""
    @State private var sex: RheosBiologicalSex = .unspecified
    @State private var draft = RheosBodyDraftMath.draft(RheosBodyInputs())
    @State private var history: [RheosBodySnapshot] = []
    @State private var status = ""
    @State private var muscleFromLean = false

    var body: some View {
        Form {
            Section {
                Text("Entwurf zur Besprechung mit dem Diabetesteam. Diese Zahlen werden nicht ins Profil geschrieben und nicht als Insulin abgegeben.")
                    .font(.footnote)
            }

            Section {
                Picker("Geschlecht", selection: $sex) {
                    ForEach(RheosBiologicalSex.allCases, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
                TextField("Alter in Jahren", text: $age)
                    .keyboardType(.decimalPad)
                TextField("Gewicht in kg", text: $weight)
                    .keyboardType(.decimalPad)
                TextField("Größe in cm", text: $height)
                    .keyboardType(.decimalPad)
                TextField("Körperfett in %", text: $fat)
                    .keyboardType(.decimalPad)
                TextField("Muskelmasse in kg", text: $muscle)
                    .keyboardType(.decimalPad)
                if muscleFromLean {
                    Text("Die Muskelzahl kommt aus der fettfreien Masse von Apple Health. Das ist nicht reine Muskelmasse. Tippen überschreibt sie.")
                        .font(.footnote)
                }
                Button("Speichern und Entwurf zeigen") {
                    save()
                }
                Button("Leere Felder aus Apple Health") {
                    Task { await loadHealth() }
                }
            } header: {
                Text("Eingabe")
            } footer: {
                Text("Was du selbst einträgst, bleibt. Ein späterer Health-Abruf überschreibt nur leere oder nicht manuell gesetzte Felder.")
            }

            Section {
                if let total = draft.totalDailyDose {
                    labelled("Tagesdosis, Entwurf", total, "E")
                    labelled("Basal, Entwurf", draft.basalPerHour, "E/h")
                    labelled("ISF, Entwurf", draft.isfMgdlPerUnit, "mg/dL pro E")
                    labelled("KH-Faktor, Entwurf", draft.carbGramsPerUnit, "g pro E")
                }
                Text(draft.summary).font(.footnote)
            } header: {
                Text("Entwurf, nicht angewendet")
            }

            Section {
                if history.isEmpty {
                    Text("Noch kein Verlauf.")
                }
                ForEach(history.reversed()) { snapshot in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(snapshot.date.formatted(date: .abbreviated, time: .shortened)) · \(snapshot.source)")
                            .font(.caption)
                        Text(line(snapshot.inputs))
                            .font(.footnote)
                    }
                }
            } header: {
                Text("Verlauf")
            }
            if !status.isEmpty {
                Section {
                    Text(status).font(.footnote)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Körperdaten")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func labelled(_ title: String, _ value: Double?, _ unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.map { "\(format($0)) \(unit)" } ?? "—")
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        var inputs = RheosBodyInputs(
            ageYears: number(age),
            weightKg: number(weight),
            heightCm: number(height),
            sex: sex == .unspecified ? nil : sex,
            bodyFatPercent: number(fat),
            muscleMassKg: number(muscle),
            leanMassKg: nil,
            muscleComesFromLeanMass: false
        )
        let previous = RheosStore.shared.loadDataset().body
        if inputs.leanMassKg == nil { inputs.leanMassKg = previous.leanMassKg }
        if inputs.muscleMassKg == previous.muscleMassKg, previous.muscleComesFromLeanMass, number(muscle) != nil {
            inputs.muscleComesFromLeanMass = true
        }
        coordinator?.saveBody(inputs)
        status = "Gespeichert. Der Entwurf bleibt eine Notiz für das Team."
        reload()
    }

    private func loadHealth() async {
        status = await coordinator?.importBodyFromHealth() ?? "Rheos ist nicht gestartet."
        reload()
    }

    private func reload() {
        let dataset = RheosStore.shared.loadDataset()
        let inputs = dataset.body
        age = inputs.ageYears.map(format) ?? ""
        weight = inputs.weightKg.map(format) ?? ""
        height = inputs.heightCm.map(format) ?? ""
        fat = inputs.bodyFatPercent.map(format) ?? ""
        muscle = inputs.muscleMassKg.map(format) ?? ""
        sex = inputs.sex ?? .unspecified
        muscleFromLean = inputs.muscleComesFromLeanMass
        draft = RheosBodyDraftMath.draft(inputs)
        history = dataset.bodyHistory
    }

    private func line(_ inputs: RheosBodyInputs) -> String {
        [
            inputs.weightKg.map { "\(format($0)) kg" },
            inputs.heightCm.map { "\(format($0)) cm" },
            inputs.bodyFatPercent.map { "Fett \(format($0)) %" },
            inputs.muscleMassKg.map { "Muskel \(format($0)) kg" },
            inputs.sex?.title
        ].compactMap { $0 }.joined(separator: ", ")
    }

    private func number(_ text: String) -> Double? {
        let value = Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private var coordinator: RheosCoordinator? {
        resolver.resolve(RheosCoordinator.self)
    }
}
