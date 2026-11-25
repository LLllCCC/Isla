import Foundation
import Darwin

/// CPU / 内存采样。Mach 公开接口，零权限。
final class StatsService {
    static let shared = StatsService()
    private init() {}

    private var lastCPU: host_cpu_load_info?
    private(set) var cpuPercent: Double = 0
    private(set) var memGB: Double = 0

    func sample() {
        sampleCPU()
        sampleMemory()
    }

    private func sampleCPU() {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        defer { lastCPU = load }
        guard let prev = lastCPU else { return }

        let user = Double(load.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(load.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(load.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(load.cpu_ticks.3 &- prev.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return }
        cpuPercent = max(0, min(100, (user + system + nice) / total * 100))
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        let used = Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)
        memGB = used * page / 1_073_741_824
    }
}
