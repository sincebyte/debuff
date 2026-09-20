import Foundation

/// 语音转写文本的「清整理」客户端：把一段（或多段拼起来的）转写文本交给
/// OpenAI 兼容的 Chat Completions 接口，做错别字纠正与重复词/口水词清理。
final class DictationCleaner {
    struct Configuration {
        let urlString: String
        let apiKey: String
        let model: String
        /// 清整理系统提示词，由用户在设置里维护（默认取内置版本）。
        let systemPrompt: String
    }

    /// 对一段文本做清整理。`context` 是已整理好的前文（仅用于理解语境，调用方负责
    /// 截断到 500 字以内）；只整理并替换 `text` 部分。`completion` 一律在主线程回调。
    func clean(
        text: String,
        context: String = "",
        configuration: Configuration,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            finish(.success(text), completion: completion)
            return
        }
        guard let url = URL(string: configuration.urlString) else {
            finish(.failure(DictationError.cleaningFailed("清整理接口地址无效")), completion: completion)
            return
        }
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            finish(.failure(DictationError.cleaningFailed("未配置清整理 API Key")), completion: completion)
            return
        }

        let contextText = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let userContent = contextText.isEmpty
            ? trimmed
            : "【上文】\(contextText)\n【待整理】\(trimmed)"
        let payload: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": configuration.systemPrompt],
                ["role": "user", "content": userContent],
            ],
            "temperature": 0,
            "stream": false,
            // 关闭推理链：该模型默认会先生成一大段 reasoning 再给正文，耗时翻倍且对
            // 本任务毫无用处；显式关闭后端到端可稳定在 1 秒级，且只返回正文。
            "reasoning_effort": "none",
            "max_tokens": Self.maxTokens(forCharacters: trimmed.count),
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            finish(.failure(DictationError.cleaningFailed("清整理请求构造失败")), completion: completion)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error), completion: completion)
                return
            }
            guard let data else {
                self.finish(.failure(DictationError.cleaningFailed("清整理无响应")), completion: completion)
                return
            }
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                self.finish(.failure(DictationError.cleaningFailed("清整理无响应")), completion: completion)
                return
            }
            guard status == 200 else {
                let message = Self.extractErrorMessage(from: data) ?? "HTTP \(status)"
                self.finish(.failure(DictationError.cleaningFailed(message)), completion: completion)
                return
            }
            do {
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                let content = decoded.choices?.first?.message.content ?? ""
                self.finish(.success(content), completion: completion)
            } catch {
                self.finish(.failure(error), completion: completion)
            }
        }.resume()
    }

    /// 连通性检查：发一条极小的对话请求，验证地址、Key 与模型是否可用。
    func checkHealth(configuration: Configuration, completion: @escaping (Bool, String) -> Void) {
        clean(text: "你好", configuration: configuration) { result in
            switch result {
            case .success:
                completion(true, "清整理服务连接正常")
            case .failure(let error):
                completion(false, "清整理服务不可用：\(error.localizedDescription)")
            }
        }
    }

    /// 已关闭推理链，输出只含整理后的正文：token 上限够放下与输入等长的结果即可，
    /// 给足余量但不过大，避免极端输入下生成失控。
    private static func maxTokens(forCharacters count: Int) -> Int {
        min(4096, max(1024, count * 2 + 256))
    }

    private func finish(_ result: Result<String, Error>, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async {
            completion(result)
        }
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]?
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
