import AVFoundation
import Foundation

final class DictationAudioRecorder {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var sampleRate: Double = 16000

    private let engine = AVAudioEngine()
    /// 是否已在 inputNode 挂了 tap。切换输入设备时引擎会被系统自行 stop，
    /// 但挂上的 tap 不会随之移除，重挂前必须显式删掉，否则 installTap 因
    /// 「已有 tap」抛异常直接崩溃（required condition is false: nullptr == Tap()）。
    private var tapInstalled = false

    var audioEngine: AVAudioEngine { engine }
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
}
