import Charts
import SwiftUI
import WatchKit

struct TrioMainWatchView: View {
    @State private var state = WatchState()
    @Environment(\.scenePhase) private var scenePhase

    // misc
    @State private var currentPage: Int = 0
    @State private var rotationDegrees: Double = 0.0
    @State private var showingTempTargetSheet = false

    // view visbility
    @State private var showingTreatmentMenuSheet: Bool = false
    @State private var showingHandyFrei = false
    @State private var showingOverrideSheet: Bool = false
    @State private var showingInsulinHistory = false
    @State private var showingMealHistory = false
    // navigation flag for meal bolus combo
    @State private var continueToBolus = false
    @State private var navigationPath = NavigationPath()

    // treatments
    @State private var selectedTreatment: TreatmentOption?

    var isWatchStateDated: Bool {
        if state.handyFreiRunning { return false }
        // If `lastWatchStateUpdate` is nil, treat as "dated"
        guard let lastUpdateTimestamp = state.lastWatchStateUpdate else {
            return true
        }
        let now = Date().timeIntervalSince1970
        let secondsSinceUpdate = now - lastUpdateTimestamp
        // Return true if last update older than 5 min, so 1 loop cycle
        return secondsSinceUpdate > 5 * 60
    }

    var isSessionUnreachable: Bool {
        if state.handyFreiRunning { return false }
        guard let session = state.session else {
            return true // No session at all => unreachable
        }
        // Return true if not .activated OR not reachable
        return session.activationState != .activated
    }

    // Active adjustment indicator
    private func isAdjustmentActive<T>(for presets: [T], predicate: (T) -> Bool) -> Bool {
        let sortedPresets = presets.sorted { predicate($0) && !predicate($1) }
        return !sortedPresets.isEmpty && sortedPresets.first(where: predicate) != nil
    }

    private var isTempTargetActive: Bool {
        isAdjustmentActive(for: state.tempTargetPresets) { $0.isEnabled }
    }

    private var isOverrideActive: Bool {
        isAdjustmentActive(for: state.overridePresets) { $0.isEnabled }
    }

    private var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TabView(selection: $currentPage) {
                // Page 1: Current glucose trend in "BG bobble"
                ZStack {
                    GlucoseTrendView(
                        state: state,
                        rotationDegrees: rotationDegrees,
                        isWatchStateDated: isWatchStateDated || isSessionUnreachable
                    )

                    Button("Handy-frei") { showingHandyFrei = true }
                        .font(.footnote)
                        .buttonStyle(.bordered)
                        .frame(maxHeight: .infinity, alignment: .top)

                    if state.showSyncingAnimation {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.primary, Color.tabBar, Color.clear)
                            .symbolEffect(
                                .variableColor.iterative,
                                options: .repeating,
                                value: state.showSyncingAnimation
                            )
                            .position(
                                x: 20,
                                y: (WKInterfaceDevice.current().screenBounds.height / 4) -
                                    7 // Font .body == 14, so half of default size for the SF Symbol image
                            )
                    }
                }.tag(0)

                // Page 2: Glucose chart
                GlucoseChartView(
                    state: state,
                    glucoseValues: state.glucoseValues
                )
                .tag(1)

                RheosWatchView(state: state)
                    .tag(2)
            }
            .onAppear {
                /// Hard reset variables when main view appears
                /// Reset `bolusAmount` and `recommendedBolus` to ensure no stale / old value is set when user opens bolus input or meal combo the next time.
                state.bolusAmount = 0
                state.recommendedBolus = 0
            }
            .background(trioBackgroundColor)
            .tabViewStyle(.verticalPage)
            .digitalCrownRotation($currentPage.doubleBinding(), from: 0, through: 2, by: 1)
            .onChange(of: state.trend) { _, newTrend in
                withAnimation {
                    updateRotation(for: newTrend)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingInsulinHistory = true
                    } label: {
                        VStack {
                            Image(systemName: "syringe.fill")
                                .foregroundStyle(Color.insulin)
                            Text(shownIOB)
                                .foregroundStyle(isWatchStateDated ? Color.secondary : Color.white)
                                .frame(alignment: .leading)
                                .minimumScaleFactor(0.5)
                        }.font(.caption2)
                    }
                    .buttonStyle(.plain)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingMealHistory = true
                    } label: {
                        VStack {
                            Image(systemName: "fork.knife")
                                .foregroundStyle(Color.orange)
                            Text(shownCOB)
                                .foregroundStyle(isWatchStateDated || isSessionUnreachable ? Color.secondary : Color.white)
                                .frame(alignment: .trailing)
                                .minimumScaleFactor(0.5)
                        }.font(.caption2)
                    }
                    .buttonStyle(.plain)
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        showingOverrideSheet = true
                    } label: {
                        Image(systemName: "clock.arrow.2.circlepath")
                            .foregroundStyle(Color.primary, isOverrideActive ? Color.primary : Color.purple)
                    }
                    .tint(isOverrideActive ? Color.purple : nil)
                    .disabled(isWatchStateDated || isSessionUnreachable)

                    Button {
                        showingTreatmentMenuSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Color.bgDarkerDarkBlue)
                    }
                    .controlSize(.large)
                    .buttonStyle(WatchOSButtonStyle(deviceType: state.deviceType))
                    .disabled(isWatchStateDated || isSessionUnreachable)

                    Button {
                        showingTempTargetSheet = true
                    } label: {
                        Image(systemName: "target")
                            .foregroundStyle(isTempTargetActive ? Color.primary : Color.loopGreen.opacity(0.75))
                    }
                    .tint(isTempTargetActive ? Color.loopGreen.opacity(0.75) : nil)
                    .disabled(isWatchStateDated || isSessionUnreachable)
                }
            }
            .fullScreenCover(isPresented: $showingTreatmentMenuSheet) {
                TreatmentMenuView(deviceType: state.deviceType, selectedTreatment: $selectedTreatment) {
                    handleTreatmentSelection()
                }
                .onAppear {
                    // reset the conditional navigation flag when opening
                    continueToBolus = false
                }
            }
            .sheet(isPresented: $showingOverrideSheet) {
                OverridePresetsView(
                    state: state,
                    overridePresets: state.overridePresets
                ) {
                    showingOverrideSheet = false
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
            }
            .sheet(isPresented: $showingHandyFrei) {
                HandyFreiWatchView(state: state)
            }
            .onChange(of: state.mealNeedsBolus) { _, needs in
                guard needs else { return }
                state.mealNeedsBolus = false
                showingHandyFrei = false
                navigationPath.append(NavigationDestinations.bolusInput)
            }
            .sheet(isPresented: $showingTempTargetSheet) {
                TempTargetPresetsView(
                    state: state,
                    tempTargetPresets: state.tempTargetPresets
                ) {
                    showingTempTargetSheet = false
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
            }
            .navigationDestination(for: NavigationDestinations.self) { destination in
                switch destination {
                case .acknowledgmentPending:
                    AcknowledgementPendingView(
                        navigationPath: $navigationPath,
                        state: state,
                        shouldNavigateToRoot: $state.shouldNavigateToRoot
                    )
                case .carbsInput:
                    CarbsInputView(
                        navigationPath: $navigationPath,
                        state: state,
                        continueToBolus: continueToBolus
                    )
                case .bolusInput:
                    BolusInputView(
                        navigationPath: $navigationPath,
                        state: state
                    )
                case .bolusConfirm:
                    BolusConfirmationView(
                        navigationPath: $navigationPath,
                        state: state,
                        bolusAmount: $state.bolusAmount,
                        confirmationProgress: $state.confirmationProgress
                    )
                case .mealPresets:
                    MealPresetListView(state: state)
                }
            }
            .onChange(of: navigationPath) { _, newPath in
                if newPath.isEmpty {
                    // Reset conditional view navigation when returning to root view
                    continueToBolus = false
                }
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showingInsulinHistory) {
            WatchHistorySheet(title: "Insulin", lines: insulinLines)
        }
        .sheet(isPresented: $showingMealHistory) {
            WatchHistorySheet(title: "Mahlzeiten", lines: mealLines)
        }
        .onAppear {
            HandyFreiSession.shared.resumeIfNeeded(state)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active || phase == .background {
                HandyFreiSession.shared.wakeFromBackground()
            }
        }
    }

    private var insulinLines: [WatchHistoryLine] {
        if state.handyFreiRunning {
            return HandyFreiSession.shared.insulinHistory(state).map {
                WatchHistoryLine(id: $0.id, date: $0.date, title: $0.title, detail: $0.detail, isFPU: $0.isFPU)
            }
        }
        return state.phoneInsulinHistory
    }

    private var mealLines: [WatchHistoryLine] {
        if state.handyFreiRunning {
            return HandyFreiSession.shared.mealHistory(state).map {
                WatchHistoryLine(id: $0.id, date: $0.date, title: $0.title, detail: $0.detail, isFPU: $0.isFPU)
            }
        }
        return state.phoneMealHistory
    }

    private var shownIOB: String {
        if state.handyFreiRunning { return state.iob ?? "--" }
        return isWatchStateDated || isSessionUnreachable ? "--" : (state.iob ?? "--")
    }

    private var shownCOB: String {
        if state.handyFreiRunning { return state.cob ?? "--" }
        return isWatchStateDated || isSessionUnreachable ? "--" : (state.cob ?? "--")
    }

    private func updateRotation(for trend: String?) {
        switch trend {
        case "DoubleUp",
             "SingleUp":
            rotationDegrees = -90
        case "FortyFiveUp":
            rotationDegrees = -45
        case "Flat":
            rotationDegrees = 0
        case "FortyFiveDown":
            rotationDegrees = 45
        case "DoubleDown",
             "SingleDown":
            rotationDegrees = 90
        default:
            rotationDegrees = 0
        }
    }

    private func handleTreatmentSelection() {
        showingTreatmentMenuSheet = false // Dismiss the sheet

        guard let treatment = selectedTreatment else { return }

        switch treatment {
        case .meal:
            navigationPath.append(NavigationDestinations.carbsInput)
        case .savedMeal:
            navigationPath.append(NavigationDestinations.mealPresets)
        case .bolus:
            // Reset carbs amount when directly going to bolus input
            state.carbsAmount = 0
            navigationPath.append(NavigationDestinations.bolusInput)
        case .mealBolusCombo:
            continueToBolus = true // Explicitely set subsequent view navigation
            navigationPath.append(NavigationDestinations.carbsInput)
        }
    }
}

struct WatchHistorySheet: View {
    let title: String
    let lines: [WatchHistoryLine]

    var body: some View {
        List {
            if lines.isEmpty {
                Text("Keine Einträge der letzten 24 Stunden.")
                    .font(.footnote)
            }
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.isFPU ? "FPU \(Self.clock(line.date))" : "\(line.title) \(Self.clock(line.date))")
                        .font(.headline)
                    Text(line.detail)
                        .font(.footnote)
                        .foregroundStyle(line.isFPU ? Color.orange : Color.secondary)
                }
            }
        }
        .navigationTitle(title)
    }

    private static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

#Preview {
    TrioMainWatchView()
}
