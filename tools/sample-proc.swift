import Foundation
import Darwin

// 采样指定进程的 CPU 占用与物理内存（libproc），不依赖 ps/top。
// 用法：./mi_proc <pid> [秒]
let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else {
    print("usage: mi_proc <pid> [seconds]"); exit(1)
}
let seconds = args.count >= 3 ? (Double(args[2]) ?? 3) : 3

func sample() -> (cpu: Double, rss: Double)? {
    var info = rusage_info_v4()
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    guard kr == 0 else { return nil }
    let cpu = Double(info.ri_user_time + info.ri_system_time) / 1_000_000_000.0
    let rss = Double(info.ri_phys_footprint) / 1_048_576.0
    return (cpu, rss)
}

guard let a = sample() else { print("cannot read pid \(pid)"); exit(2) }
Thread.sleep(forTimeInterval: seconds)
guard let b = sample() else { print("cannot read pid \(pid)"); exit(2) }
let cpu = (b.cpu - a.cpu) / seconds * 100.0
print(String(format: "pid=%d  cpu=%.2f%%  mem=%.1f MB  (窗口 %.0fs)", pid, max(0, cpu), b.rss, seconds))
