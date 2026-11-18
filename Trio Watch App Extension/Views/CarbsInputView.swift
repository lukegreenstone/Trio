import Foundation
import SwiftUI

// MARK: - Carbs Input View

struct CarbsInputView: View {
    @Binding var navigationPath: NavigationPath
    @State private var carbsAmount: Double = 0.0 // Needs to be Double due to .digitalCrownRotation() stride
    @State private var fatAmount: Double = 0
    @State private var proteinAmount: Double = 0
    @State private var field = 0
    @FocusState private var isCrownFocused: Bool // Manage crown focus

    let state: WatchState
    let continueToBolus: Bool

    private var effectiveCarbsLimit: Double { Double(truncating: state.maxCarbs as NSNumber) }
    private var effectiveFatLimit: Double { Double(truncating: state.maxFat as NSNumber) }
    private var effectiveProteinLimit: Double { Double(truncating: state.maxProtein as NSNumber) }
    private var activeAmount: Binding<Double> {
        switch field {
        case 1: return $fatAmount
        case 2: return $proteinAmount
        default: return $carbsAmount
        }
    }
    private var activeLimit: Double {
        switch field {
        case 1: return effectiveFatLimit
        case 2: return effectiveProteinLimit
        default: return effectiveCarbsLimit
        }
    }
    private var activeTitle: String {
        switch field {
        case 1: return "Fett"
        case 2: return "Eiweiß"
        default: return "Kohlenhydrate"
        }
    }

    var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        let buttonLabel = continueToBolus ? String(localized: "Proceed", comment: "Button Label to Proceed to Bolus on Watch") :
            String(localized: "Log Carbs", comment: "Button Label to Log Carbs on Watch")

        // TODO: introduce meal setting fpu enablement to conditional handle FPU
        VStack {
            Spacer()

            HStack {
                // "-" Button
                Button(action: {
                    if activeAmount.wrappedValue > 0 {
                        activeAmount.wrappedValue = max(0, activeAmount.wrappedValue - 5)
                    }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .tint(.orange)
                }
                .buttonStyle(.borderless)
                .disabled(activeAmount.wrappedValue <= 0)

                Spacer()

                // Display the current carb amount
                Text(String(format: "%.0f \(String(localized: "g", comment: "gram of carbs"))", activeAmount.wrappedValue))
                    .fontWeight(.bold)
                    .font(.system(.title2, design: .rounded))
                    .foregroundColor(activeAmount.wrappedValue > 0 && activeAmount.wrappedValue >= activeLimit ? .loopRed : .primary)
                    .focusable(true)
                    .focused($isCrownFocused)
                    .id(field)
                    .digitalCrownRotation(
                        activeAmount,
                        from: 0,
                        through: max(activeLimit, 1),
                        by: 1,
                        sensitivity: .medium,
                        isContinuous: false,
                        isHapticFeedbackEnabled: true
                    )

                Spacer()

                // "+" Button
                Button(action: {
                    activeAmount.wrappedValue = min(activeLimit, activeAmount.wrappedValue + 5)
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .tint(.orange)
                }
                .buttonStyle(.borderless)
                .disabled(activeAmount.wrappedValue >= activeLimit)
            }.padding(.horizontal)

            Text(activeTitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
            HStack {
                Button("KH \(Int(carbsAmount))") { field = 0 }.buttonStyle(.bordered).tint(field == 0 ? .orange : .gray)
                Button("F \(Int(fatAmount))") { field = 1 }.buttonStyle(.bordered).tint(field == 1 ? .orange : .gray)
                Button("E \(Int(proteinAmount))") { field = 2 }.buttonStyle(.bordered).tint(field == 2 ? .orange : .gray)
            }
            .font(.footnote)

            Spacer()

            if carbsAmount > 0.0 && carbsAmount >= effectiveCarbsLimit {
                Text("Carbs Limit Reached!")
                    .font(.footnote)
                    .foregroundColor(.loopRed)
            }

            Button(buttonLabel) {
                state.carbsAmount = Int(min(carbsAmount, effectiveCarbsLimit))
                state.fatAmount = Int(min(fatAmount, effectiveFatLimit))
                state.proteinAmount = Int(min(proteinAmount, effectiveProteinLimit))
                if continueToBolus {
                    navigationPath.append(NavigationDestinations.bolusInput)
                } else {
                    state.sendCarbsRequest(state.carbsAmount)
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(carbsAmount <= 0 && fatAmount <= 0 && proteinAmount <= 0)
        }
        .background(trioBackgroundColor)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: "fork.knife")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .padding()
                    .background(Color.orange)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
        }
    }
}
