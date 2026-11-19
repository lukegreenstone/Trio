import Foundation

enum RheosStats {
    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    static func mean(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else { return nil }
        return finite.reduce(0, +) / Double(finite.count)
    }

    static func nearest(_ points: [RheosGlucosePoint], to date: Date, within seconds: TimeInterval) -> Double? {
        var best: RheosGlucosePoint?
        var bestDistance = seconds
        for point in points where point.mgdl.isFinite {
            let distance = abs(point.date.timeIntervalSince(date))
            if distance <= bestDistance {
                bestDistance = distance
                best = point
            }
        }
        return best?.mgdl
    }

    static func coefficientOfVariationPercent(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        guard finite.count >= 2, let mean = mean(finite), mean > 0 else { return nil }
        let variance = finite.reduce(0) { partial, value in
            let delta = value - mean
            return partial + delta * delta
        } / Double(finite.count - 1)
        return (variance.squareRoot() / mean) * 100
    }

    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 3 else { return nil }
        guard let meanX = mean(xs), let meanY = mean(ys) else { return nil }
        var numerator = 0.0
        var denomX = 0.0
        var denomY = 0.0
        for index in xs.indices {
            let dx = xs[index] - meanX
            let dy = ys[index] - meanY
            numerator += dx * dy
            denomX += dx * dx
            denomY += dy * dy
        }
        let denominator = (denomX * denomY).squareRoot()
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    /// Ordinary least squares `y = a + b x`. Returns nil when x does not vary.
    static func linearFit(x: [Double], y: [Double]) -> (intercept: Double, slope: Double)? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        guard let correlation = pearson(x, y), let meanX = mean(x), let meanY = mean(y) else {
            guard let meanY = mean(y) else { return nil }
            return (meanY, 0)
        }
        var numerator = 0.0
        var denominator = 0.0
        for index in x.indices {
            let dx = x[index] - meanX
            numerator += dx * (y[index] - meanY)
            denominator += dx * dx
        }
        guard denominator > 0 else { return (meanY, 0) }
        let slope = numerator / denominator
        return (meanY - slope * meanX, slope * (correlation == 0 ? 0 : 1))
    }
}
