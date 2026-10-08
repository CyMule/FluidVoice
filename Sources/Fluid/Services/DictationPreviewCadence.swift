import Foundation

/// Schedules the next preview after the active inference has returned. The speech
/// model, audio context and final pass stay unchanged; idle waits are the only
/// thing this policy controls. Slow decodes fall back to the original cadence.
nonisolated struct DictationPreviewCadence: Sendable {
    private(set) var estimatedDecodeSeconds: Double = 0.1

    mutating func recordDecode(duration: Double) {
        guard duration.isFinite, duration >= 0 else { return }
        // React immediately to contention, recover gradually after a slow call.
        self.estimatedDecodeSeconds = max(duration, self.estimatedDecodeSeconds * 0.8)
    }

    mutating func recordFailure(fallbackInterval: Double) {
        self.estimatedDecodeSeconds = max(self.estimatedDecodeSeconds, fallbackInterval / 3)
    }

    func delaySeconds(
        enabled: Bool,
        availableSamples: Int,
        minimumSamples: Int,
        fallbackInterval: Double
    ) -> Double {
        guard enabled else { return fallbackInterval }
        if availableSamples < minimumSamples {
            // Wake when enough audio should have arrived, rather than overshooting
            // the one-second model requirement by a whole polling interval.
            let missingAudioSeconds = Double(max(0, minimumSamples - max(0, availableSamples))) / 16_000
            return min(fallbackInterval, max(0.04, missingAudioSeconds))
        }
        // Aim for at most 25% inference duty during ordinary speech. Never run
        // back-to-back; at high load retain the established fallback interval.
        return min(fallbackInterval, max(0.2, self.estimatedDecodeSeconds * 3))
    }
}
