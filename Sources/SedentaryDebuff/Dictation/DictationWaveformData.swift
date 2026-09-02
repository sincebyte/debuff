import Foundation

final class DictationWaveformData {
    private var samples: [Float] = []
    private var capacity = 0
    private var writeIndex = 0
    private var totalWritten = 0
    private(set) var sampleRate: Double = 48000
    private let lock = NSLock()

    func reset(sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.sampleRate = sampleRate
        let newCapacity = max(1024, Int(sampleRate * 0.8))
        if newCapacity != capacity {
            capacity = newCapacity
            samples = [Float](repeating: 0, count: capacity)
        }
        writeIndex = 0
        totalWritten = 0
    }

    func append(_ newSamples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard capacity > 0, !newSamples.isEmpty else { return }
        for sample in newSamples {
            samples[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            totalWritten += 1
        }
    }

    func readLast(count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard capacity > 0, totalWritten > 0 else { return [] }
        let available = min(count, totalWritten, capacity)
        guard available > 0 else { return [] }
        var out = [Float](repeating: 0, count: available)
        let start = (writeIndex - available + capacity) % capacity
        for i in 0..<available {
            out[i] = samples[(start + i) % capacity]
        }
        return out
    }
}
