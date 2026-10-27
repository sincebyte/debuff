import Foundation

/// 流式转写客户端：一次发送一小段 WAV，边读服务端 SSE 边把增量文字交回来。
///
/// 服务端 `POST /v1/audio/transcriptions/stream` 的响应是事件流：
///   data: {"type":"delta","text":"今天"}   // 引擎逐 token 解码，可直接上屏
///   data: {"type":"final","text":"今天下午3点"} // 本段清理后的最终文本
///   data: {"type":"done"}
///   data: {"type":"error","message":"..."}
///
/// `delta` 是未清理的原始 token，`final` 才是应保留的文本（去口水词、数字/指令
/// 归一、段尾标点策略都在服务端完成）。调用方在收到 `final` 时用其覆盖本段增量。
final class DictationStreamingTranscriber {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// 发送一段音频并读取对应的 SSE。`onDelta` 可能在任意线程调用；`completion`
    /// 在主线程回调，且无论成功、失败还是取消都恰好调用一次。
    func transcribe(
        wavData: Data,
        urlString: String,
        onDelta: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = Self.streamURL(from: urlString) else {
            completion(.failure(DictationError.transcriptionFailed("STT 流式地址无效")))
            return
        }
        let request = Self.makeRequest(wavData: wavData, url: url)
        let id = UUID()
        let task = Task { [weak self] in
            var finished = false
            func finish(_ result: Result<String, Error>) {
                guard !finished else { return }
                finished = true
                DispatchQueue.main.async {
                    completion(result)
                }
            }
            defer {
                self?.forget(id)
            }
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    finish(.failure(DictationError.transcriptionFailed("无响应")))
                    return
                }
                guard http.statusCode == 200 else {
                    let body = await Self.readPrefix(of: bytes, limit: 4096)
                    let message = Self.extractErrorMessage(from: body) ?? "HTTP \(http.statusCode)"
                    finish(.failure(DictationError.transcriptionFailed(message)))
                    return
                }

                var finalText: String?
                var streamError: String?
                for try await line in bytes.lines {
                    if Task.isCancelled {
                        finish(.failure(DictationError.transcriptionFailed("已取消")))
                        return
                    }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst("data:".count)
                        .trimmingCharacters(in: .whitespaces)
                    guard !payload.isEmpty,
                          let data = payload.data(using: .utf8),
                          let event = try? JSONDecoder().decode(ServerEvent.self, from: data)
                    else { continue }
                    switch event.type {
                    case "delta":
                        if let text = event.text, !text.isEmpty {
                            onDelta(text)
                        }
                    case "final":
                        finalText = event.text ?? ""
                    case "error":
                        streamError = event.message ?? "流式转写失败"
                    default:
                        break
                    }
                }
                if let streamError {
                    finish(.failure(DictationError.transcriptionFailed(streamError)))
                } else if Task.isCancelled {
                    finish(.failure(DictationError.transcriptionFailed("已取消")))
                } else if let finalText {
                    finish(.success(finalText))
                } else {
                    // 连接在 final 之前结束（服务端异常/被中断）：按失败处理，
                    // 由调用方决定是否保留已经显示的增量。
                    finish(.failure(DictationError.transcriptionFailed("流式转写未收到最终结果")))
                }
            } catch is CancellationError {
                finish(.failure(DictationError.transcriptionFailed("已取消")))
            } catch {
                finish(.failure(error))
            }
        }
        lock.lock()
        tasks[id] = task
        lock.unlock()
    }

    /// 取消所有在途流式请求（停止/清空/重建引擎时调用，避免旧结果落回新会话）。
    func cancelAll() {
        lock.lock()
        let all = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        for task in all {
            task.cancel()
        }
    }

    private func forget(_ id: UUID) {
        lock.lock()
        tasks[id] = nil
        lock.unlock()
    }

    private struct ServerEvent: Decodable {
        let type: String
        let text: String?
        let message: String?
    }

    /// 把一次性转写地址改造成流式地址：`/v1/audio/transcriptions` → 末尾加 `/stream`。
    static func streamURL(from urlString: String) -> URL? {
        guard var components = URLComponents(string: urlString) else { return nil }
        var path = components.path
        if path.hasSuffix("/audio/transcriptions") {
            path += "/stream"
        } else if !path.hasSuffix("/stream") {
            path = path.hasSuffix("/") ? path + "stream" : path + "/stream"
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func makeRequest(wavData: Data, url: URL) -> URLRequest {
        let boundary = "dictation-stream-\(UUID().uuidString)"
        var body = Data()
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(wavData)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    private static func readPrefix(of bytes: URLSession.AsyncBytes, limit: Int) async -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            // 错误响应体读不全也无妨，用已读到的部分。
        }
        return data
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        struct ErrorResponse: Decodable {
            struct Err: Decodable {
                let message: String?
            }

            let error: Err?
        }
        if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data),
           let message = decoded.error?.message,
           !message.isEmpty {
            return message
        }
        return String(data: data, encoding: .utf8)
    }
}
