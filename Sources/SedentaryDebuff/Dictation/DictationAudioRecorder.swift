import AVFoundation
import Foundation

enum DictationRecorderError: LocalizedError {
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "无法读取输入设备的音频格式"
        }
    }
}

final class DictationAudioRecorder {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var sampleRate: Double = 16000

    /// inputNode 与硬件绑定。锁屏/唤醒或切换设备后硬件格式会变，长期复用同一
    /// 引擎会让 inputNode 缓存旧设备格式：installTap 用过期格式挂 tap 会抛
    /// NSException（Failed to create tap due to format mismatch）直接崩溃，
    /// 因此硬件变化时必须重建引擎让 inputNode 重新绑定当前硬件。
    private var engine = AVAudioEngine()
    /// 是否已在 inputNode 挂了 tap。切换输入设备时引擎会被系统自行 stop，
    /// 但挂上的 tap 不会随之移除，重挂前必须显式删掉，否则 installTap 因
    /// 「已有 tap」抛异常直接崩溃（required condition is false: nullptr == Tap()）。
    private var tapInstalled = false

    var isRunning: Bool { engine.isRunning }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async {
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        default:
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    func start() throws {
        if engine.isRunning {
            engine.stop()
        }
        // 上次因设备变化被系统停掉的残留 tap 需先移除，再按新设备格式重挂。
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationRecorderError.invalidInputFormat
        }
        sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    /// 输入/输出硬件变化后调用：丢弃旧引擎并新建，让 inputNode 重新绑定当前
    /// 硬件，避免用旧设备缓存的格式 installTap 而崩溃。必须在引擎未运行的
    /// 引擎队列上调用。
    func rebuildEngine() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine = AVAudioEngine()
        sampleRate = 0
    }
}
