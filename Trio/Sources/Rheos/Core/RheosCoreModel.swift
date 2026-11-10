import Foundation

/// On-device linear model. The iOS target feeds the same numbers through Core ML
/// feature values. Weights live in the Rheos file, trained only on this dataset.
struct RheosTemporalWeights: Codable, Equatable {
    /// filters × channels × kernel(3), row-major.
    var kernels: [Double] = []
    var filters: Int = 2
    var channels: Int = 0
    var dense: [Double] = []
    var denseBias: Double = 0
}

struct RheosCoreWeights: Codable, Equatable {
    /// Ridge coefficients. The network weights sit beside them.
    var coefficients: [Double]
    var network: RheosTemporalWeights = RheosTemporalWeights()
    var trained: Bool
    var chosen: String = "median"
    var sampleCount: Int
    var mae: Double?
    var ridgeMAE: Double?
    var networkMAE: Double?
    var baselineMAE: Double?

    static let empty = RheosCoreWeights(coefficients: [], trained: false, sampleCount: 0, mae: nil, baselineMAE: nil)
}

struct RheosCoreFit: Equatable {
    var weights: RheosCoreWeights
    var factors: RheosHourlyFactors
    var trained: Bool
    var chosen: String
}

enum RheosCoreModel {
    /// Bias, sin, cos, IOB, active carbs, active FPU. Wearables are appended only after a yes.
    static let baseFeatureCount = 6

    static func fit(
        dataset: RheosDataset,
        targets: RheosTargetSchedule,
        band: ClosedRange<Double>,
        acceptedSignals: [String] = [],
        calendar: Calendar
    ) -> RheosCoreFit {
        let rows = rows(dataset: dataset, targets: targets, accepted: acceptedSignals, calendar: calendar)
        let idle = RheosCoreFit(weights: .empty, factors: .identity, trained: false, chosen: "median")
        guard rows.count >= RheosBounds().minimumGlucoseSamples else { return idle }
        let days = Set(rows.map(\.day))
        guard days.count >= 14 else { return idle }
        let holdoutDays = Set(days.sorted().suffix(RheosReference.walkForwardTestDays))
        let train = rows.filter { !holdoutDays.contains($0.day) }
        let test = rows.filter { holdoutDays.contains($0.day) }
        guard train.count >= 200, test.count >= 20, let baseline = hourMeanMAE(train: train, test: test) else {
            return idle
        }
        let ridgeMAE = solve(train).flatMap { mae(test, weights: $0) }
        let network = trainNetwork(train: train, test: test)
        var chosen = "median"
        var best = baseline
        if let ridgeMAE, ridgeMAE + 0.5 < best {
            chosen = "ridge"
            best = ridgeMAE
        }
        if let networkMAE = network?.mae, networkMAE + 0.5 < best {
            chosen = "network"
            best = networkMAE
        }
        let coefficients = solve(rows) ?? []
        let weights = RheosCoreWeights(
            coefficients: coefficients,
            network: network?.weights ?? RheosTemporalWeights(),
            trained: chosen != "median",
            chosen: chosen,
            sampleCount: rows.count,
            mae: chosen == "median" ? baseline : best,
            ridgeMAE: ridgeMAE,
            networkMAE: network?.mae,
            baselineMAE: baseline
        )
        guard chosen != "median" else {
            return RheosCoreFit(weights: weights, factors: .identity, trained: false, chosen: "median")
        }
        let factors: RheosHourlyFactors
        if chosen == "network", let net = network?.weights {
            factors = factorsFromNetwork(rows: rows, weights: net, band: band)
        } else {
            factors = factorsFrom(rows: rows, weights: coefficients, band: band)
        }
        return RheosCoreFit(weights: weights, factors: factors, trained: true, chosen: chosen)
    }

    static func predictGlucose(target: Double, features: [Double], weights: RheosCoreWeights) -> Double? {
        guard weights.trained, weights.coefficients.count == features.count else { return nil }
        let dot = zip(weights.coefficients, features).reduce(0) { $0 + $1.0 * $1.1 }
        return target + dot
    }

    static func features(hour: Int, iob: Double, carbs: Double, fpu: Double, signals: [Double] = []) -> [Double] {
        let angle = Double(hour) / 24 * 2 * Double.pi
        return [1, sin(angle), cos(angle), iob, carbs, fpu] + signals
    }

    private struct Row {
        var day: Date
        var hour: Int
        var target: Double
        var actual: Double
        var features: [Double]
    }

    private static func rows(
        dataset: RheosDataset,
        targets: RheosTargetSchedule,
        accepted: [String],
        calendar: Calendar
    ) -> [Row] {
        return dataset.glucose.compactMap { point in
            guard point.mgdl.isFinite, point.mgdl > 0 else { return nil }
            let hour = calendar.component(.hour, from: point.date)
            let day = calendar.startOfDay(for: point.date)
            let wearable = dataset.wearableDays.first { calendar.startOfDay(for: $0.day) == day }
            let state = dataset.states.min {
                abs($0.date.timeIntervalSince(point.date)) < abs($1.date.timeIntervalSince(point.date))
            }
            return Row(
                day: day,
                hour: hour,
                target: targets.value(atHour: hour),
                actual: point.mgdl,
                features: features(
                    hour: hour,
                    iob: state?.iob ?? 0,
                    carbs: activeCarbs(at: point.date, meals: dataset.meals),
                    fpu: activeFPU(at: point.date, meals: dataset.meals),
                    signals: RheosSignalCatalog.values(accepted: accepted, day: wearable)
                )
            )
        }
    }

    private static func solve(_ rows: [Row]) -> [Double]? {
        guard let n = rows.first?.features.count, n > 0 else { return nil }
        var matrix = Array(repeating: Array(repeating: 0.0, count: n + 1), count: n)
        let lambda = 1.0
        for row in rows {
            let y = row.actual - row.target
            for i in 0 ..< n {
                for j in 0 ..< n {
                    matrix[i][j] += row.features[i] * row.features[j]
                }
                matrix[i][n] += row.features[i] * y
            }
        }
        for i in 0 ..< n {
            matrix[i][i] += lambda
        }
        return gaussian(matrix)
    }

    private static func gaussian(_ input: [[Double]]) -> [Double]? {
        var matrix = input
        let n = matrix.count
        for column in 0 ..< n {
            var pivot = column
            for row in (column + 1) ..< n where abs(matrix[row][column]) > abs(matrix[pivot][column]) {
                pivot = row
            }
            if abs(matrix[pivot][column]) < 1e-8 { return nil }
            if pivot != column { matrix.swapAt(pivot, column) }
            let divisor = matrix[column][column]
            for j in column ... n { matrix[column][j] /= divisor }
            for row in 0 ..< n where row != column {
                let factor = matrix[row][column]
                for j in column ... n { matrix[row][j] -= factor * matrix[column][j] }
            }
        }
        return matrix.map { $0[n] }
    }

    private static func mae(_ rows: [Row], weights: [Double]) -> Double? {
        guard !rows.isEmpty else { return nil }
        let total = rows.reduce(0.0) { partial, row in
            let predicted = row.target + zip(weights, row.features).reduce(0) { $0 + $1.0 * $1.1 }
            return partial + abs(row.actual - predicted)
        }
        return total / Double(rows.count)
    }

    private static func hourMeanMAE(train: [Row], test: [Row]) -> Double? {
        guard !test.isEmpty else { return nil }
        var sums = Array(repeating: 0.0, count: 24)
        var counts = Array(repeating: 0, count: 24)
        for row in train {
            sums[row.hour] += row.actual
            counts[row.hour] += 1
        }
        let total = test.reduce(0.0) { partial, row in
            let prediction = counts[row.hour] > 0 ? sums[row.hour] / Double(counts[row.hour]) : row.target
            return partial + abs(row.actual - prediction)
        }
        return total / Double(test.count)
    }

    private static func baselineMAE(_ rows: [Row]) -> Double? {
        guard !rows.isEmpty else { return nil }
        let total = rows.reduce(0.0) { $0 + abs($1.actual - $1.target) }
        return total / Double(rows.count)
    }

    private static func factorsFrom(rows: [Row], weights: [Double], band: ClosedRange<Double>) -> RheosHourlyFactors {
        var buckets = Array(repeating: [Double](), count: 24)
        for row in rows {
            let predicted = row.target + zip(weights, row.features).reduce(0) { $0 + $1.0 * $1.1 }
            buckets[row.hour].append(row.actual - predicted)
        }
        return bucketsToFactors(buckets: buckets, rows: rows, band: band)
    }

    private static func bucketsToFactors(buckets: [[Double]], rows: [Row], band: ClosedRange<Double>) -> RheosHourlyFactors {
        var basal = Array(repeating: 1.0, count: 24)
        var isf = Array(repeating: 1.0, count: 24)
        for hour in 0 ..< 24 {
            guard buckets[hour].count >= RheosReference.minimumSamplesPerHour else { continue }
            let mean = buckets[hour].reduce(0, +) / Double(buckets[hour].count)
            let target = rows.first { $0.hour == hour }?.target ?? RheosReference.missingTargetFallbackMgdl
            let delta = mean / max(target, 1)
            basal[hour] = min(max(1 + RheosReference.deviationGain * delta, band.lowerBound), band.upperBound)
            isf[hour] = min(max(1 - RheosReference.deviationGain * delta, band.lowerBound), band.upperBound)
        }
        return RheosHourlyFactors(basal: basal, isf: isf, carbRatio: Array(repeating: 1, count: 24))
    }

    private static func activeCarbs(at date: Date, meals: [RheosMealEvent]) -> Double {
        meals.reduce(0) { partial, meal in
            let hours = date.timeIntervalSince(meal.date) / 3600
            guard hours >= 0, hours < 3 else { return partial }
            return partial + meal.carbs * (1 - hours / 3)
        }
    }

    private struct NetFit {
        var weights: RheosTemporalWeights
        var mae: Double
    }

    /// Two-filter temporal convolution over the last three feature steps.
    /// Trained only on this dataset. A signal channel exists only after a yes.
    private static func trainNetwork(train: [Row], test: [Row]) -> NetFit? {
        guard let channels = train.first?.features.count, channels > 0, train.count >= 30 else { return nil }
        let filters = 2
        let width = 3
        var kernels = (0 ..< (filters * channels * width)).map { Double(($0 % 5) - 2) * 0.01 }
        var dense = Array(repeating: 0.02, count: filters)
        var denseBias = 0.0
        let step = 0.005
        let limit = min(train.count, 180)
        for _ in 0 ..< 2 {
            var index = width - 1
            while index < limit {
                let window = [train[index - 2].features, train[index - 1].features, train[index].features]
                let pass = forward(window: window, kernels: kernels, filters: filters, channels: channels, dense: dense, bias: denseBias)
                let error = pass.pred - (train[index].actual - train[index].target)
                for filter in 0 ..< filters {
                    dense[filter] -= step * error * pass.hidden[filter]
                }
                denseBias -= step * error
                for filter in 0 ..< filters {
                    let mask = pass.hidden[filter] > 0 ? 1.0 : 0.0
                    let upstream = error * dense[filter] * mask
                    for channel in 0 ..< channels {
                        for tap in 0 ..< width {
                            let position = ((filter * channels + channel) * width) + tap
                            kernels[position] = min(max(kernels[position] - step * upstream * window[tap][channel], -1), 1)
                        }
                    }
                }
                index += 3
            }
        }
        let weights = RheosTemporalWeights(
            kernels: kernels,
            filters: filters,
            channels: channels,
            dense: dense,
            denseBias: denseBias
        )
        var errors: [Double] = []
        if test.count >= width {
            for index in (width - 1) ..< test.count {
                let window = [test[index - 2].features, test[index - 1].features, test[index].features]
                let pred = forward(
                    window: window,
                    kernels: kernels,
                    filters: filters,
                    channels: channels,
                    dense: dense,
                    bias: denseBias
                ).pred
                errors.append(abs(test[index].actual - (test[index].target + pred)))
            }
        }
        guard !errors.isEmpty else { return nil }
        return NetFit(weights: weights, mae: errors.reduce(0, +) / Double(errors.count))
    }

    private static func forward(
        window: [[Double]],
        kernels: [Double],
        filters: Int,
        channels: Int,
        dense: [Double],
        bias: Double
    ) -> (hidden: [Double], pred: Double) {
        var hidden = Array(repeating: 0.0, count: filters)
        for filter in 0 ..< filters {
            var sum = 0.0
            for channel in 0 ..< channels {
                for tap in 0 ..< 3 {
                    let position = ((filter * channels + channel) * 3) + tap
                    sum += kernels[position] * window[tap][channel]
                }
            }
            hidden[filter] = max(0, sum)
        }
        let pred = bias + zip(dense, hidden).reduce(0) { $0 + $1.0 * $1.1 }
        return (hidden, pred)
    }

    private static func factorsFromNetwork(rows: [Row], weights: RheosTemporalWeights, band: ClosedRange<Double>) -> RheosHourlyFactors {
        var buckets = Array(repeating: [Double](), count: 24)
        guard rows.count >= 3, weights.channels == rows[0].features.count else {
            return .identity
        }
        for index in 2 ..< rows.count {
            let window = [rows[index - 2].features, rows[index - 1].features, rows[index].features]
            let pred = forward(
                window: window,
                kernels: weights.kernels,
                filters: weights.filters,
                channels: weights.channels,
                dense: weights.dense,
                bias: weights.denseBias
            ).pred
            buckets[rows[index].hour].append(rows[index].actual - (rows[index].target + pred))
        }
        return bucketsToFactors(buckets: buckets, rows: rows, band: band)
    }

    private static func activeFPU(at date: Date, meals: [RheosMealEvent]) -> Double {
        meals.reduce(0) { partial, meal in
            let hours = date.timeIntervalSince(meal.date) / 3600
            guard hours >= 0, hours < 5 else { return partial }
            let fpu = (meal.fat + meal.protein) * 0.1
            return partial + fpu * (1 - hours / 5)
        }
    }
}
