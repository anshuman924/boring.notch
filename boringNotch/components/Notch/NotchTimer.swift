import Combine
import Defaults
import SwiftUI

@MainActor
final class NotchTimer: ObservableObject {
    static let shared = NotchTimer()

    enum State { case idle, setting, running, paused, finished, dismissing }
    @Published private(set) var state: State = .idle
    private var accumulated: TimeInterval = 0
    private var startedAt: ContinuousClock.Instant?
    private var countdownDuration: TimeInterval = 0
    private var completionTask: Task<Void, Never>?

    var isActive: Bool { state != .idle && state != .setting }
    var isCountdown: Bool { countdownDuration > 0 }
    var isShowingCompletion: Bool { state == .finished || state == .dismissing }

    func beginSetup() {
        guard state == .idle else { return }
        state = .setting
    }

    func startCountdown(seconds: TimeInterval, at now: ContinuousClock.Instant = .now) {
        guard state == .setting, seconds.isFinite, seconds > 0 else { return }
        countdownDuration = min(seconds, 359999)
        state = .idle
        resume(at: now)
    }

    func displayedTime(at now: ContinuousClock.Instant = .now) -> String {
        Self.formatted(isCountdown ? ceil(max(0, countdownDuration - elapsed(at: now))) : elapsed(at: now))
    }

    func elapsed(at now: ContinuousClock.Instant = .now) -> TimeInterval {
        guard let startedAt else { return accumulated }
        let duration = startedAt.duration(to: now).components
        return accumulated + Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    func resume(at now: ContinuousClock.Instant = .now) {
        guard state == .idle || state == .paused else { return }
        startedAt = now
        state = .running
        if isCountdown {
            let deadline = now.advanced(by: .seconds(max(0, countdownDuration - accumulated)))
            completionTask = Task { [weak self] in
                do {
                    // ContinuousClock includes sleep; completion is also delivered after wake.
                    try await ContinuousClock().sleep(until: deadline)
                    guard let self, !Task.isCancelled else { return }
                    self.accumulated = self.countdownDuration
                    self.startedAt = nil
                    self.state = .finished
                    try await Task.sleep(for: .seconds(1.35))
                    self.state = .dismissing
                    try await Task.sleep(for: .milliseconds(500))
                    self.reset()
                } catch { /* Pausing or resetting cancels pending completion. */ }
            }
        }
    }

    func pause(at now: ContinuousClock.Instant = .now) {
        guard state == .running else { return }
        completionTask?.cancel()
        accumulated = elapsed(at: now)
        startedAt = nil
        state = .paused
    }

    func reset() {
        completionTask?.cancel()
        completionTask = nil
        countdownDuration = 0
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
                    Text(timer.displayedTime())
                        .font(.system(size: compact ? 13 : 22, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(tint)
                        .accessibilityLabel(timer.isCountdown ? "Time remaining" : "Elapsed time")
                        .accessibilityValue(timer.displayedTime())
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
                    } else {
                        HoverButton(icon: "timer", iconColor: tint) { timer.beginSetup() }
                            .help("Set countdown")
                            .accessibilityLabel("Set countdown")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CountdownSetupView: View {
    @ObservedObject private var timer = NotchTimer.shared
    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.playerColorTinting) private var playerColorTinting
    @State private var hours = 0
    @State private var minutes = 5
    @State private var seconds = 0

    private var duration: Int { hours * 3600 + minutes * 60 + seconds }
    private var tint: Color {
        playerColorTinting
            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray
    }

    var body: some View {
        HStack(spacing: 12) {
            CountdownWheel(value: $hours, limit: 99, title: "Hours", tint: tint)
            Text(":").foregroundStyle(.secondary)
            CountdownWheel(value: $minutes, limit: 59, title: "Minutes", tint: tint)
            Text(":").foregroundStyle(.secondary)
            CountdownWheel(value: $seconds, limit: 59, title: "Seconds", tint: tint)

            Button {
                timer.startCountdown(seconds: TimeInterval(duration))
            } label: {
                Label("Start", systemImage: "play.fill")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.black)
                    .background(tint, in: Capsule())
            }
            .disabled(duration == 0)
            .opacity(duration == 0 ? 0.4 : 1)
            .accessibilityLabel("Start countdown")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CountdownWheel: View {
    @Binding var value: Int
    let limit: Int
    let title: LocalizedStringKey
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var direction = 1

    private func step(_ amount: Int) {
        let next = min(limit, max(0, value + amount))
        guard next != value else { return }
        direction = next > value ? 1 : -1
        if reduceMotion {
            value = next
        } else {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) { value = next }
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                VStack(spacing: 0) {
                    ForEach(-1...1, id: \.self) { offset in
                        let number = value + offset
                        Text(number >= 0 && number <= limit ? String(format: "%02d", number) : " ")
                            .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(offset == 0 ? tint : .secondary)
                            .scaleEffect(offset == 0 ? 1 : 0.85)
                            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                    }
                }
                .id(value)
                .transition(.asymmetric(
                    insertion: .offset(y: CGFloat(direction) * 32).combined(with: .opacity),
                    removal: .offset(y: CGFloat(-direction) * 32).combined(with: .opacity)
                ))
            }
            .frame(height: 96)
            .background {
                RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)).frame(height: 32)
            }
            .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
            .overlay { CountdownWheelInput(onStep: step) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(String(value))
            .accessibilityAdjustableAction { direction in
                step(direction == .increment ? 1 : -1)
            }
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CountdownWheelInput: NSViewRepresentable {
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ nsView: WheelView, context: Context) { nsView.onStep = onStep }

    class WheelView: NSView {
        var onStep: (Int) -> Void = { _ in }
        private var pending: CGFloat = 0

        override func scrollWheel(with event: NSEvent) {
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 24)
            pending -= delta
            let steps = Int(pending / 24)
            guard steps != 0 else { return }
            pending -= CGFloat(steps) * 24
            onStep(steps)
        }

        override func mouseDown(with event: NSEvent) {
            let y = convert(event.locationInWindow, from: nil).y
            if y < bounds.midY - 16 { onStep(1) }
            if y > bounds.midY + 16 { onStep(-1) }
        }
    }
}

struct CountdownCompletionView: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.playerColorTinting) private var playerColorTinting
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var tint: Color {
        playerColorTinting
            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray
    }

    var body: some View {
        ZStack {
            RadialGradient(colors: [tint.opacity(pulse ? 0.08 : 0.3), .clear], center: .center, startRadius: 0, endRadius: 300)
            if !reduceMotion {
                Circle().stroke(tint.opacity(pulse ? 0 : 0.7), lineWidth: 2)
                    .frame(width: 100, height: 100)
                    .scaleEffect(pulse ? 5 : 0.5)
            }
            HStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
                Text("00:00:00").monospacedDigit().foregroundStyle(.white)
            }
            .font(.system(size: 32, weight: .medium, design: .rounded))
            .scaleEffect(reduceMotion || pulse ? 1 : 0.92)
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Countdown finished")
        .onAppear { withAnimation(.easeOut(duration: 1.2)) { pulse = true } }
    }
}
