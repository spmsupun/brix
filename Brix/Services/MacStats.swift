import Foundation
import IOKit.ps
import Darwin

/// This Mac's CPU, memory, storage and battery, read from the system directly
/// (no processes started), cheap enough to sample every few seconds.
struct MacStats: Equatable {
    var chip = ""
    var cpu: Double?
    var memoryUsed: Double = 0
    var memoryTotal: Double = 0
    var diskFree: Double = 0
    var diskTotal: Double = 0
    var battery: Int?
    var charging = false
    /// Brix's own memory: the footprint Activity Monitor shows as "Memory".
    var appMemory: Double = 0

    /// CPU ticks from the previous sample; CPU use is the change between two.
    final class Sampler {
        private var last: (busy: UInt64, total: UInt64)?

        func read() -> MacStats {
            var s = MacStats()
            s.chip = Self.sysctl("machdep.cpu.brand_string") ?? ""
            s.cpu = cpu()
            s.memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
            s.memoryUsed = Self.memoryUsed()
            if let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
                s.diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
                s.diskTotal = Double(v.volumeTotalCapacity ?? 0)
            }
            (s.battery, s.charging) = Self.battery()
            s.appMemory = Self.appFootprint()
            return s
        }

        private func cpu() -> Double? {
            var info = host_cpu_load_info()
            var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
            let r = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
            }
            guard r == KERN_SUCCESS else { return nil }
            let t = info.cpu_ticks
            let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)   // user + system + nice
            let total = busy + UInt64(t.2)                        // + idle
            defer { last = (busy, total) }
            guard let last, total > last.total else { return nil }
            return Double(busy - last.busy) / Double(total - last.total)
        }

        /// Active, wired and compressed pages: what Activity Monitor calls "Memory Used".
        static func memoryUsed() -> Double {
            var stats = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
            let r = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
            }
            guard r == KERN_SUCCESS else { return 0 }
            let page = Double(vm_kernel_page_size)
            return (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        }

        static func appFootprint() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let r = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return r == KERN_SUCCESS ? Double(info.phys_footprint) : 0
        }

        static func battery() -> (Int?, Bool) {
            guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                  let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                return (cur * 100 / max, d[kIOPSIsChargingKey] as? Bool ?? false)
            }
            return (nil, false)
        }

        static func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
            return String(cString: buf)
        }
    }

    /// Sizes of the usual space hogs a developer can clear: Xcode's build cache,
    /// Docker's disk image, and agent transcripts. ponytail: walks each folder,
    /// so it runs once per visit off the main thread.
    static func hogs(home: String = NSHomeDirectory()) -> [(name: String, path: String, bytes: Int64)] {
        let places = [("Xcode build cache", home + "/Library/Developer/Xcode/DerivedData"),
                      ("Docker", home + "/Library/Containers/com.docker.docker/Data/vms"),
                      ("Agent transcripts", home + "/.claude/projects"),
                      ("Codex sessions", home + "/.codex/sessions")]
        return places.compactMap { name, path in
            let size = folderSize(path)
            return size > 0 ? (name, path, size) : nil
        }.sorted { $0.bytes > $1.bytes }
    }

    static func folderSize(_ path: String) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in walker {
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
