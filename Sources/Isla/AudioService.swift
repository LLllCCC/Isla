import Foundation
import CoreAudio

/// 系统输出音量 + 播放活性查询。全部走公开 CoreAudio API，零权限。
final class AudioService {
    static let shared = AudioService()
    private init() {}

    private var defaultDevice: AudioDeviceID {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return st == noErr ? dev : 0
    }

    /// 默认输出设备此刻是否有 IO 在跑。
    /// 注意：这是**设备级**状态，只要还有别的 App（浏览器、系统提示音）占着输出就一直为 1，
    /// 所以不能拿它判断「当前这首歌是不是停了」。判断单曲请用 `isRendering(pid:)`。
    private var cachedRunning = false
    private var runningCheckedAt = Date.distantPast
    var isOutputRunning: Bool {
        if Date().timeIntervalSince(runningCheckedAt) < 0.4 { return cachedRunning }
        runningCheckedAt = Date()
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(defaultDevice, &addr, 0, nil, &size, &running)
        cachedRunning = (st == noErr && running != 0)
        return cachedRunning
    }

    // MARK: - 单进程是否正在出声

    /// CoreAudio 的「进程对象」列表：每个开过音频单元的进程一项。
    private var procCache: [pid_t: Bool] = [:]
    private var procCacheAt = Date.distantPast
    /// 列表里「有输出」的进程数量，用来发现「有新 App 开始放声音了」。
    private var cachedActiveCount = 0

    /// 刷新进程缓存（0.25s 一次，本身是几十微秒的 C 调用，可放心高频调用）。
    private func refreshProcessCacheIfNeeded() {
        if Date().timeIntervalSince(procCacheAt) < 0.25 { return }
        procCacheAt = Date()
        var map: [pid_t: Bool] = [:]
        var size = UInt32(0)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            procCache = map
            return
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { procCache = map; return }
        var list = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &list) == noErr else {
            procCache = map
            return
        }
        var active = 0
        for obj in list {
            var pid = pid_t(0)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &pid) == noErr else { continue }

            var running = UInt32(0)
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            var runAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let st = AudioObjectGetPropertyData(obj, &runAddr, 0, nil, &runSize, &running)
            let on = (st == noErr && running != 0)
            if on { active += 1 }
            map[pid] = on
        }
        procCache = map
        cachedActiveCount = active
    }

    /// 指定进程此刻是否在向输出设备送音频。
    /// 这是「这辆车到底有没有在放」最接近真相的公开信号：
    /// 播放器暂停后会关闭音频单元 → 这里变成 false。
    /// 代价是系统回收进程对象有延迟（QQ 音乐实测约 7s），所以只能当中等延迟的兜底。
    func isRendering(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        refreshProcessCacheIfNeeded()
        return procCache[pid_t(pid)] ?? false
    }

    /// 当前有多少个进程正在出声。数量变化 = 有 App 开始/停止播放，可用来立刻补拉一次 NowPlaying。
    /// （设备级 `isOutputRunning` 在本机长期为 1：WebKit GPU 一直占着输出，靠它等不到「刚开始播」的那一拍。）
    var activeProcessCount: Int {
        refreshProcessCacheIfNeeded()
        return cachedActiveCount
    }

    // 'vmvc' = 虚拟主音量，比逐声道读写可靠
    private var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: AudioObjectPropertySelector(0x766D7663),
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    var volume: Float {
        var vol = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        var addr = volumeAddress
        let st = AudioObjectGetPropertyData(defaultDevice, &addr, 0, nil, &size, &vol)
        return st == noErr ? max(0, min(1, vol)) : 0
    }

    var isMuted: Bool {
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(defaultDevice, &addr, 0, nil, &size, &muted)
        return st == noErr && muted == 1
    }

    func setVolume(_ value: Float) {
        var v = max(0, min(1, value))
        var addr = volumeAddress
        _ = AudioObjectSetPropertyData(defaultDevice, &addr, 0, nil,
                                       UInt32(MemoryLayout<Float>.size), &v)
    }

    func adjust(by delta: Float) {
        setVolume(volume + delta)
    }
}
