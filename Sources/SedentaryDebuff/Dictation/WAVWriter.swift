import Foundation

enum DictationError: LocalizedError {
    case formatUnavailable
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .formatUnavailable:
            return "无法创建 16kHz 单声道音频格式"
        case .transcriptionFailed(let message):
            return message
        }
    }
}

enum WAVWriter {
    static func pcm16Data(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let channelCount = 1
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = channelCount * bytesPerSample
        let byteRate = sampleRate * blockAlign
        let dataSize = samples.count * bytesPerSample

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(channelCount))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(byteRate))
        appendLE(UInt16(blockAlign))
        appendLE(UInt16(bitsPerSample))

        data.append(contentsOf: Array("data".utf8))
        appendLE(UInt32(dataSize))

        var pcm = [UInt8](repeating: 0, count: dataSize)
        for (index, sample) in samples.enumerated() {
            let clamped = min(1, max(-1, sample))
            let value = Int16(clamped * 32767)
            let le = value.littleEndian
            pcm[index * 2] = UInt8(le & 0xFF)
            pcm[index * 2 + 1] = UInt8((le >> 8) & 0xFF)
        }
        data.append(contentsOf: pcm)
        return data
    }
}
