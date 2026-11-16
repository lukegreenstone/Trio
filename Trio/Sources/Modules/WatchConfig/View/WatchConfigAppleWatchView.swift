import SwiftUI
import Swinject

struct WatchConfigAppleWatchView: BaseView {
    let resolver: Resolver
    @ObservedObject var state: WatchConfig.StateModel

    @State private var shouldDisplayHint: Bool = false
    @State var hintDetent = PresentationDetent.large
    @State var selectedVerboseHint: AnyView?
    @State var hintLabel: String?
    @State private var decimalPlaceholder: Decimal = 0.0
    @State private var booleanPlaceholder: Bool = false
    @State private var handyFreiNote = ""

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private func onDelete(offsets: IndexSet) {
        state.devices.remove(atOffsets: offsets)
        state.deleteGarminDevice()
    }

    var body: some View {
        List {
            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.confirmBolusFaster,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Confirm Bolus Faster")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Confirm Bolus Faster"),
                miniHint: String(localized: "Reduce the number of crown rotations required for bolus confirmation."),
                verboseHint: Text(
                    "Enabling this feature lowers the number of turns on the crown dial required when confirming a bolus."
                ),
                headerText: String(localized: "Apple Watch Configuration")
            )

            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.showForecastWatch,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Show forecast on Watch")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Show Forecast on Watch"),
                miniHint: String(localized: "Shows forecast on the Apple Watch"),
                verboseHint: Text(
                    "Enable this feature to show the forecast on the Apple Watch"
                ),
                headerText: String(localized: "Apple Watch Configuration")
            )

            Section {
                Toggle("Handy-frei (experimentell)", isOn: Binding(
                    get: { HandyFrei.isEnabled() },
                    set: { HandyFrei.setEnabled($0) }
                ))
                Text("Aus, bis du es einschaltest. Die Kopplung bleibt auf dem iPhone. Die Uhr bekommt nur eine Kopie und keine Befehle, die Patch oder Sensor beenden.")
                    .font(.footnote)
                Button("Handy-frei starten") {
                    let session = HandyFreiPhone.start(
                        fingerprint: HandyFrei.Fingerprint(
                            pumpPeripheralID: nil,
                            pumpSerial: nil,
                            sensorSerial: nil,
                            sensorPeripheralID: nil
                        ),
                        limits: HandyFrei.Limits(maxBolus: 0, maxIOB: 0, currentIOB: 0),
                        glucose: nil
                    )
                    handyFreiNote = session.note
                }
                .disabled(!HandyFrei.isEnabled())
                Button("Handy-frei beenden") {
                    let session = HandyFreiPhone.stop(
                        fingerprint: HandyFrei.Fingerprint(
                            pumpPeripheralID: nil,
                            pumpSerial: nil,
                            sensorSerial: nil,
                            sensorPeripheralID: nil
                        )
                    )
                    handyFreiNote = session.note
                }
                if !handyFreiNote.isEmpty {
                    Text(handyFreiNote).font(.footnote)
                }
            } header: {
                Text("Handy-frei")
            }

            Section(
                header: Text("Contact Image"),
                content: {
                    VStack {
                        HStack {
                            NavigationLink("Contacts Configuration") {
                                ContactImage.RootView(resolver: resolver)
                            }.foregroundStyle(Color.accentColor)
                        }
                    }
                }
            ).listRowBackground(Color.chart)
        }
        .listSectionSpacing(sectionSpacing)
        .sheet(isPresented: $shouldDisplayHint) {
            SettingInputHintView(
                hintDetent: $hintDetent,
                shouldDisplayHint: $shouldDisplayHint,
                hintLabel: hintLabel ?? "",
                hintText: selectedVerboseHint ?? AnyView(EmptyView()),
                sheetTitle: String(localized: "Help", comment: "Help sheet title")
            )
        }
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.automatic)
        .settingsHighlightScroll()
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
    }
}
