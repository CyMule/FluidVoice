import SwiftUI

/// Keep capture and model readiness distinct: audio can be recording before the
/// recognizer is ready, and stopping capture does not mean its text is finished.
nonisolated enum DictationProgressPhase: Equatable {
    case recordingWhilePreparing
    case stoppedWhilePreparing
    case finishing

    static func resolve(recording: Bool, processing: Bool, preparing: Bool) -> Self? {
        if processing { return preparing ? .stoppedWhilePreparing : .finishing }
        return recording && preparing ? .recordingWhilePreparing : nil
    }

    static func requiresVisibleStopProgress(ready: Bool, warming: Bool) -> Bool {
        !ready || warming
    }

    var title: String {
        switch self {
        case .recordingWhilePreparing: "Getting ready…"
        case .stoppedWhilePreparing: "Preparing your text…"
        case .finishing: "Finishing your text…"
        }
    }

    var detail: String {
        switch self {
        case .recordingWhilePreparing:
            "Recording your voice. Text will appear when ready."
        case .stoppedWhilePreparing:
            "Recording stopped. Waiting for speech recognition before inserting your text."
        case .finishing:
            "Recording stopped. Your text will be inserted when ready."
        }
    }
}

struct DictationProgressView: View {
    let phase: DictationProgressPhase
    let fontSize: CGFloat
    let onCancel: () -> Void
    @State private var startedAt = ProcessInfo.processInfo.systemUptime

    var body: some View {
        // Resizable previews can be very short; retain the title and cancel
        // control even when the explanatory copy cannot fit.
        ViewThatFits(in: .vertical) {
            self.status(showsDetail: true)
            self.status(showsDetail: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func status(showsDetail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(self.phase.title)
                    .font(.fluidSystem(size: self.fontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(Int(max(0, ProcessInfo.processInfo.systemUptime - self.startedAt)))s")
                        .font(.fluidSystem(size: max(10, self.fontSize - 2), weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.65))
                        .accessibilityLabel("Time spent waiting")
                }
            }
            if showsDetail {
                Text(self.phase.detail)
                    .font(.fluidSystem(size: max(10, self.fontSize - 1)))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: self.onCancel) {
                Text("Cancel dictation")
                    .font(.fluidSystem(size: max(10, self.fontSize - 1), weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Cancel this dictation so it will not insert text.")
        }
        .foregroundStyle(.white.opacity(0.96))
        .accessibilityLabel(self.phase.title + " " + self.phase.detail)
    }
}
