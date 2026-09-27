import Combine
import Defaults
import SwiftUI

@MainActor
final class NotchTimer: ObservableObject {
    static let shared = NotchTimer()

    enum State { case idle, running, paused }
    @Published private(set) var state: State = .idle
    private var accumulated: TimeInterval = 0
    private var startedAt: ContinuousClock.Instant?

    var isActive: Bool { state != .idle }

    func elapsed(at now: ContinuousClock.Instant = .now) -> TimeInterval {
        guard let startedAt else { return accumulated }
        let duration = startedAt.duration(to: now).components
        return accumulated + Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    func resume(at now: ContinuousClock.Instant = .now) {
        guard state != .running else { return }
        startedAt = now
        state = .running
    }

    func pause(at now: ContinuousClock.Instant = .now) {
        guard state == .running else { return }
        accumulated = elapsed(at: now)
        startedAt = nil
        state = .paused
    }

    func reset() {
        startedAt = nil
        accumulated = 0
        state = .idle
    }

    static func formatted(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

struct NotchTimerView: View {
    var compact = false
    @ObservedObject private var timer = NotchTimer.shared
    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.playerColorTinting) private var playerColorTinting

    private var tint: Color {
        playerColorTinting
            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6)
            : .gray
    }

    var body: some View {
        VStack(spacing: 12) {
            if timer.isActive {
                TimelineView(.animation(minimumInterval: 1, paused: timer.state != .running)) { _ in
                    Text(NotchTimer.formatted(timer.elapsed()))
                        .font(.system(size: compact ? 13 : 22, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(tint)
                        .accessibilityLabel("Elapsed time")
                        .accessibilityValue(NotchTimer.formatted(timer.elapsed()))
                }
            }
            if !compact {
                HStack(spacing: 12) {
                    HoverButton(icon: timer.state == .running ? "pause.fill" : "play.fill", iconColor: tint) {
                        if timer.state == .running { timer.pause() } else { timer.resume() }
                    }
                    .help(timer.state == .running ? "Pause timer" : timer.isActive ? "Resume timer" : "Start timer")
                    .accessibilityLabel(timer.state == .running ? "Pause timer" : timer.isActive ? "Resume timer" : "Start timer")

                    if timer.isActive {
                        HoverButton(icon: "arrow.counterclockwise", iconColor: tint) { timer.reset() }
                            .help("Reset timer")
                            .accessibilityLabel("Reset timer")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
