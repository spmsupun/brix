import AppKit
import MetricKit

/// Local performance log for beta builds, so slowdowns can be found and fixed
/// later. Nothing leaves the Mac. Writes to `<support>/diagnostics`:
///   perf-<date>.log   one line a minute (CPU, memory, threads, open files,
///                     child processes), plus every main-thread stall and
///                     sustained high CPU as it happens
///   sample-<time>.txt a 3 s `sample` of Brix taken during a stall over 1 s or
///                     30 s of high CPU (at most one every 10 minutes)
///   metrickit-*.json  macOS's own hang, CPU and crash reports for Brix
/// Files older than 7 days are deleted at launch. Help > Performance Log opens
/// the folder.
final class PerfMonitor: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = PerfMonitor()
    static var directory: URL { Persistence.supportDirectory.appendingPathComponent("diagnostics", isDirectory: true) }

    private let queue = DispatchQueue(label: "brix.perf")
    private var lastSample = Date.distantPast
    private var lastCPU: (time: Double, at: Date)?
    private var hot = 0

    func start() {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        prune(dir)
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        log("start version=\(v) pid=\(getpid()) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        MXMetricManager.shared.add(self)
        // The watchdog is a plain thread: it must keep running when the main
        // thread or every GCD worker is stuck, which is when it matters.
        let t = Thread { [weak self] in self?.watchdog() }
        t.name = "brix.perf.watchdog"
        t.start()
        // `BRIX_PERF_SELFTEST=1`: block the main thread for 2 s once, to check a stall is caught.
        if ProcessInfo.processInfo.environment["BRIX_PERF_SELFTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Thread.sleep(forTimeInterval: 2) }
        }
    }

    // MARK: Main-thread stalls

    private func watchdog() {
        var ticks = 0
        while true {
            let sent = Date()
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            if answered.wait(timeout: .now() + 0.25) == .timedOut {
                // Still stuck after 1 s: sample now, while it's happening.
                if answered.wait(timeout: .now() + 0.75) == .timedOut { sample(reason: "stall") }
                answered.wait()
                log("stall \(Int(Date().timeIntervalSince(sent) * 1000))ms")
            }
            Thread.sleep(forTimeInterval: 0.5)
            ticks += 1
            if ticks % 20 == 0 { tick(summary: ticks % 120 == 0) }
        }
    }

    // MARK: Resource use, every 10 s

    private func tick(summary: Bool) {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        let cpuTime = Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        let now = Date()
        defer { lastCPU = (cpuTime, now) }
        guard let last = lastCPU else { return }
        let cpu = (cpuTime - last.time) / now.timeIntervalSince(last.at) * 100
        hot = cpu > 60 ? hot + 1 : 0
        if hot == 1 || summary {
            log("\(hot > 0 ? "high-cpu" : "usage") cpu=\(Int(cpu))% mem=\(Int(MacStats.Sampler.appFootprint() / 1_048_576))MB threads=\(threadCount()) fds=\(openFiles()) children=\(childCount())")
        }
        if hot == 3 { sample(reason: "high-cpu") }
    }

    private func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }

    private func openFiles() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }

    private func childCount() -> Int {
        var size = 0
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return -1 }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return -1 }
        let me = getpid()
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).filter { $0.kp_eproc.e_ppid == me }.count
    }

    // MARK: Samples

    /// Spawned directly, not through GCD or Process: it has to work when those are the thing that's stuck.
    private func sample(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastSample) > 600 else { return }
        lastSample = now
        let file = Self.directory.appendingPathComponent("sample-\(Self.stamp(now))-\(reason).txt").path
        let args = ["/usr/bin/sample", "\(getpid())", "3", "-file", file]
        var pid: pid_t = 0
        var cargs = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        // Close-on-exec by default, so `sample` gets none of Brix's descriptors.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let r = posix_spawn(&pid, args[0], nil, &attr, &cargs, environ)
        posix_spawnattr_destroy(&attr)
        guard r == 0 else { log("sample failed to start: errno \(r)"); return }
        let name = URL(fileURLWithPath: file).lastPathComponent
        log("sampling (\(reason)) to \(name)")
        // Reaped on its own thread so it can't linger as a zombie.
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            if status != 0 { self?.log("sample \(name) exited with status \(status)") }
        }
    }

    // MARK: MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            let url = Self.directory.appendingPathComponent("metrickit-\(Self.stamp(p.timeStampEnd)).json")
            try? p.jsonRepresentation().write(to: url)
            log("macOS diagnostic report: \(url.lastPathComponent)")
        }
    }

    // MARK: Log file

    private func log(_ line: String) {
        let now = Date()
        queue.async {
            let url = Self.directory.appendingPathComponent("perf-\(Self.day(now)).log")
            let data = Data("\(Self.stamp(now)) \(line)\n".utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                // First line of the day, or the folder was deleted while Brix ran.
                try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }

    private func prune(_ dir: URL) {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) < cutoff {
            try? FileManager.default.removeItem(at: f)
        }
    }

    private static func stamp(_ d: Date) -> String { fmt("yyyy-MM-dd'T'HH-mm-ss", d) }
    private static func day(_ d: Date) -> String { fmt("yyyy-MM-dd", d) }
    private static func fmt(_ f: String, _ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = f
        return df.string(from: d)
    }
}
