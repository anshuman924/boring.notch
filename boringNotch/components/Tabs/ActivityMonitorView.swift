import IOKit
import SwiftUI

@MainActor
private final class ActivitySampler: ObservableObject {
    @Published private(set) var cpu: [Double] = []
    @Published private(set) var gpu: [Double] = []
    @Published private(set) var ram: [Double] = []
    @Published private(set) var gpuAvailable = true

    private var task: Task<Void, Never>?
    private var previousCPUTicks: [(used: UInt32, total: UInt32)]?
    private let historyLimit = 40

    func start() {
        guard task == nil else { return }
        cpu = []
        gpu = []
        ram = []
        gpuAvailable = true
        previousCPUTicks = nil

        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        previousCPUTicks = nil
    }

    private func sample() {
        if let value = cpuUsage() { cpu = appended(value, to: cpu) }
        if let value = gpuUsage() {
            gpuAvailable = true
            gpu = appended(value, to: gpu)
        } else {
            gpuAvailable = false
            gpu = []
        }
        if let value = ramUsage() { ram = appended(value, to: ram) }
    }

    private func appended(_ value: Double, to samples: [Double]) -> [Double] {
        var updated = samples
        updated.append(min(100, max(0, value)))
        if updated.count > historyLimit {
            updated.removeFirst(updated.count - historyLimit)
        }
        return updated
    }

    private func cpuUsage() -> Double? {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
            &processorCount, &processorInfo, &infoCount
        ) == KERN_SUCCESS, let processorInfo else { return nil }

        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: processorInfo)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size)
            )
        }

        var currentTicks: [(used: UInt32, total: UInt32)] = []
        for processor in 0..<Int(processorCount) {
            let offset = processor * Int(CPU_STATE_MAX)
            let user = UInt32(bitPattern: processorInfo[offset + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: processorInfo[offset + Int(CPU_STATE_SYSTEM)])
            let nice = UInt32(bitPattern: processorInfo[offset + Int(CPU_STATE_NICE)])
            let idle = UInt32(bitPattern: processorInfo[offset + Int(CPU_STATE_IDLE)])
            let used = user &+ system &+ nice
            currentTicks.append((used, used &+ idle))
        }

        defer { previousCPUTicks = currentTicks }
        guard let previousCPUTicks, previousCPUTicks.count == currentTicks.count else { return nil }
        var usedDelta: UInt64 = 0
        var totalDelta: UInt64 = 0
        for (current, previous) in zip(currentTicks, previousCPUTicks) {
            usedDelta += UInt64(current.used &- previous.used)
            totalDelta += UInt64(current.total &- previous.total)
        }
        guard totalDelta > 0 else { return nil }
        return 100 * Double(usedDelta) / Double(totalDelta)
    }

    private func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let statistics = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any],
                let value = statistics["Device Utilization %"] as? NSNumber
            else { continue }
            return value.doubleValue
        }
        return nil
    }

    private func ramUsage() -> Double? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // Active, wired and compressed pages approximate the memory macOS considers in use.
        let pages = UInt64(statistics.active_count)
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        let usedBytes = pages * UInt64(vm_kernel_page_size)
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        guard totalBytes > 0 else { return nil }
        return 100 * Double(usedBytes) / Double(totalBytes)
    }
}

struct ActivityMonitorView: View {
    @StateObject private var sampler = ActivitySampler()

    var body: some View {
        GeometryReader { geometry in
            let graphWidth = max(0, (geometry.size.width - 24) / 3)
            HStack(spacing: 12) {
                ActivityGraph(title: "CPU", color: Color(red: 0.28, green: 0.75, blue: 1), samples: sampler.cpu)
                    .frame(width: graphWidth)
                ActivityGraph(title: "GPU", color: Color(red: 0.96, green: 0.29, blue: 0.78), samples: sampler.gpu, available: sampler.gpuAvailable)
                    .frame(width: graphWidth)
                ActivityGraph(title: "RAM", color: Color(red: 0.32, green: 0.85, blue: 0.47), samples: sampler.ram)
                    .frame(width: graphWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { sampler.start() }
        .onDisappear { sampler.stop() }
    }
}

private struct ActivityGraph: View {
    let title: String
    let color: Color
    let samples: [Double]
    var available = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                Spacer(minLength: 2)
                Text(available ? samples.last.map { "\(Int($0.rounded()))%" } ?? "—" : "Unavailable")
                    .font(.system(size: available ? 12 : 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
            }

            HStack(spacing: 4) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("100")
                    Spacer()
                    Text("50")
                    Spacer()
                    Text("0")
                }
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.gray)

                GeometryReader { geometry in
                    ZStack {
                        Path { path in
                            for fraction in [0.0, 0.5, 1.0] {
                                let y = geometry.size.height * fraction
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                            }
                        }
                        .stroke(.white.opacity(0.18), lineWidth: 0.5)

                        Path { path in
                            guard !samples.isEmpty else { return }
                            for (index, sample) in samples.enumerated() {
                                let point = CGPoint(
                                    x: geometry.size.width * CGFloat(39 - (samples.count - 1 - index)) / 39,
                                    y: geometry.size.height * (1 - CGFloat(sample / 100))
                                )
                                if index == 0 { path.move(to: point) }
                                else { path.addLine(to: point) }
                            }
                        }
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(height: 92)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
}
