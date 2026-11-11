import AVFoundation
import PhotosUI
import Speech
import SwiftUI
import UIKit

struct RheosHomeSheet: View {
    let resolver: Resolver
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer = ""

    var body: some View {
        NavigationStack {
            Form {
                RheosPromptList(resolver: resolver)
                Section("Chat") {
                    TextField("Frage", text: $question)
                    HStack {
                        RheosMicButton { question = $0 }
                        Button("Antwort") {
                            Task { await ask() }
                        }
                    }
                    if !answer.isEmpty {
                        Text(answer).font(.footnote)
                    }
                }
                RheosMealForm(resolver: resolver)
            }
            .navigationTitle("Rheos")
            .toolbar {
                Button("Schließen") { dismiss() }
            }
        }
    }

    private func ask() async {
        let dataset = RheosStore.shared.loadDataset()
        let state = RheosStore.shared.loadDocument()
        let report = RheosReportBuilder.build(
            dataset: dataset,
            mode: RheosModeStore.current,
            bounds: state.bounds,
            previous: state.applied,
            autosensMin: 0.7,
            autosensMax: 1.2,
            targets: RheosTargetLoader.schedule(resolver: resolver),
            now: Date()
        )
        let result = await RheosChatEngine.reply(
            question: question,
            report: report,
            resolver: resolver,
            settingsNote: RheosTrioSettingsReader.note(resolver: resolver)
        )
        answer = "\(result.text)\n\nQuelle: \(result.source)"
    }
}

struct RheosMealForm: View {
    let resolver: Resolver
    @State private var note = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var protein = ""
    @State private var status = ""
    @State private var photo: PhotosPickerItem?
    @State private var showCamera = false

    var body: some View {
        Section("Mahlzeit") {
            TextField("Beschreibung", text: $note)
            TextField("Kohlenhydrate g", text: $carbs)
            TextField("Fett g", text: $fat)
            TextField("Protein g", text: $protein)
            HStack {
                PhotosPicker(selection: $photo, matching: .images) { Text("Mediathek") }
                Button("Kamera") { showCamera = true }
                RheosMicButton { note = $0 }
            }
            Button("Schätzen") {
                Task { await estimate() }
            }
            Button("In den Kohlenhydrat-Bildschirm") { stage(nil) }
            if !status.isEmpty { Text(status).font(.footnote) }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                let data: Data?
                do { data = try await item.loadTransferable(type: Data.self) } catch { data = nil }
                guard let data else { return }
                let estimate = await RheosMealAssist.estimate(jpeg: data, resolver: resolver)
                if let estimate { fill(estimate) }
            }
        }
        .sheet(isPresented: $showCamera) {
            RheosCameraPicker { data in
                Task {
                    let estimate = await RheosMealAssist.estimate(jpeg: data, resolver: resolver)
                    if let estimate { fill(estimate) }
                }
            }
        }
    }

    private func estimate() async {
        let result = await RheosMealAssist.estimate(description: note, resolver: resolver)
        if let meal = result.0 {
            fill(meal)
            status = "Quelle: \(result.1)"
        } else {
            status = result.1
        }
    }

    private func fill(_ meal: RheosMealEstimate) {
        carbs = String(format: "%.0f", meal.carbs)
        fat = String(format: "%.0f", meal.fat)
        protein = String(format: "%.0f", meal.protein)
        stage(meal)
    }

    private func stage(_ meal: RheosMealEstimate?) {
        let draft = meal ?? RheosMealEstimate(
            carbs: Double(carbs.replacingOccurrences(of: ",", with: ".")) ?? 0,
            fat: Double(fat.replacingOccurrences(of: ",", with: ".")) ?? 0,
            protein: Double(protein.replacingOccurrences(of: ",", with: ".")) ?? 0,
            kcal: nil,
            note: note
        )
        RheosMealDraftStore.save(draft)
        status = "Werte liegen im Kohlenhydrat-Bildschirm. Du speicherst sie dort."
    }
}

struct RheosMicButton: View {
    var onText: (String) -> Void
    @State private var listening = false
    @State private var engine = AVAudioEngine()
    @State private var request: SFSpeechAudioBufferRecognitionRequest?
    @State private var task: SFSpeechRecognitionTask?

    var body: some View {
        Button(listening ? "Stopp" : "Mikrofon") {
            if listening { stop() } else { start() }
        }
    }

    private func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { return }
            DispatchQueue.main.async { begin() }
        }
    }

    private func begin() {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE")) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try? engine.start()
        listening = true
        task = recognizer.recognitionTask(with: request) { result, _ in
            if let text = result?.bestTranscription.formattedString {
                DispatchQueue.main.async { onText(text) }
            }
        }
    }

    private func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        listening = false
    }
}

struct RheosCameraButton: View {
    var onImage: (Data) -> Void
    @State private var show = false

    var body: some View {
        Button("Kamera") { show = true }
            .sheet(isPresented: $show) {
                RheosCameraPicker(onImage: onImage)
            }
    }
}

struct RheosCameraPicker: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: RheosCameraPicker
        init(parent: RheosCameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.6) {
                parent.onImage(data)
            }
            parent.dismiss()
        }
    }
}

struct RheosPromptList: View {
    let resolver: Resolver
    @State private var speech = ""

    var body: some View {
        let state = RheosStore.shared.loadDocument()
        let dataset = state.dataset
        let sport = RheosSportLearning.learn(
            workouts: dataset.workouts,
            glucose: dataset.glucose,
            now: Date(),
            calendar: .current
        )
        let night = RheosNightReview.check(glucose: dataset.glucose, now: Date(), calendar: .current)
        let lines = RheosPromptLines.lines(openUAM: state.openUAM, sport: sport, night: night)
        if !lines.isEmpty || state.openUAM != nil {
            Section("Rückfrage") {
                if let sportText = sport.suggestion {
                    Text(sportText).font(.footnote)
                } else if !sport.summary.isEmpty {
                    Text(sport.summary).font(.footnote)
                }
                if night.shouldShowBeforeBasal {
                    Text(night.summary).font(.footnote)
                }
                ForEach(lines) { line in
                    Button(line.title) {
                        Task {
                            let confirmed = await resolver.resolve(RheosCoordinator.self)?.confirmKind(
                                kind: line.kind,
                                note: line.note,
                                suggestionID: line.id
                            )
                            speech = confirmed ?? ""
                        }
                    }
                }
                if state.openUAM != nil {
                    TextField("Frei sprechen oder tippen", text: $speech)
                    RheosMicButton { speech = $0 }
                    Button("Antwort zur Rückfrage") {
                        let kind = RheosUAM.interpret(speech)
                        Task {
                            let confirmed = await resolver.resolve(RheosCoordinator.self)?.confirmKind(
                                kind: kind.rawValue,
                                note: speech
                            )
                            speech = confirmed ?? ""
                        }
                    }
                }
            }
        }
    }
}

struct RheosBolusHint: View {
    var trioPercent: Double
    var smbOn: Bool
    var uamOn: Bool
    var maxIOB: Double
    var calculatorUnits: Double
    var onFill: (Double) -> Void
    @State private var confirmed = false

    var body: some View {
        let dataset = RheosStore.shared.loadDataset()
        let bands = RheosAbsorption.bands(
            RheosAbsorption.points(
                meals: dataset.meals,
                glucose: dataset.glucose,
                late: RheosStore.shared.loadDocument().lateDigestion,
                calendar: .current
            )
        )
        let share = RheosBolusShare.suggest(
            hour: Calendar.current.component(.hour, from: Date()),
            trioPercent: trioPercent,
            bands: bands,
            calculatorUnits: calculatorUnits,
            smbOn: smbOn,
            uamOn: uamOn,
            maxIOB: maxIOB,
            modeIsScharf: RheosModeStore.current == .scharf
        )
        VStack(alignment: .leading, spacing: 4) {
            Text(share.line)
                .font(.footnote)
            if share.copiesIntoField, confirmed {
                Button("Rheos-Anteil ins Bolusfeld") { onFill(share.immediateUnits) }
                    .font(.footnote)
            } else if share.copiesIntoField {
                Button("Sofort-Anteil bestätigen") {
                    var state = RheosStore.shared.loadDocument()
                    state.absorptionShareConfirmed = true
                    RheosStore.shared.saveDocument(state)
                    confirmed = true
                }
                .font(.footnote)
            }
        }
        .onAppear {
            confirmed = RheosStore.shared.loadDocument().absorptionShareConfirmed
        }
    }
}

enum RheosTeamPDF {
    static func write(_ text: String) -> URL? {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let data = renderer.pdfData { context in
            context.beginPage()
            let body = NSAttributedString(
                string: "Rheos Bericht für das Diabetesteam\n\n\(text)\n\nKeine Dosierungsanweisung.",
                attributes: [.font: UIFont.systemFont(ofSize: 12)]
            )
            body.draw(in: CGRect(x: 36, y: 36, width: 523, height: 770))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rheos-bericht.pdf")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
