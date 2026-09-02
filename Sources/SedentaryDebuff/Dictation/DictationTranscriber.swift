import Foundation

final class DictationTranscriber {
    private let queue = DispatchQueue(label: "dictation.transcriber")

    func transcribe(wavData: Data, urlString: String, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let semaphore = DispatchSemaphore(value: 0)
            var outcome: Result<String, Error> = .failure(DictationError.transcriptionFailed("cancelled"))
            self.httpTranscribe(wavData: wavData, urlString: urlString) { result in
                outcome = result
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 180)
            DispatchQueue.main.async {
                completion(outcome)
            }
        }
    }

    func checkHealth(urlString: String, completion: @escaping (Bool) -> Void) {
        guard var components = URLComponents(string: urlString) else {
            completion(false)
            return
        }
        components.path = "/health"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            completion(ok)
        }.resume()
    }

    private func httpTranscribe(
        wavData: Data,
        urlString: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            completion(.failure(DictationError.transcriptionFailed("STT 地址无效")))
            return
        }

        let boundary = "dictation-\(UUID().uuidString)"
        var body = Data()
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"segment.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(wavData)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data else {
                completion(.failure(DictationError.transcriptionFailed("无响应")))
                return
            }
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                completion(.failure(DictationError.transcriptionFailed("无响应")))
                return
            }
            if status != 200 {
                let message = Self.extractErrorMessage(from: data) ?? "HTTP \(status)"
                completion(.failure(DictationError.transcriptionFailed(message)))
                return
            }
            struct Response: Decodable {
                let text: String?
            }
            do {
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                completion(.success(decoded.text ?? ""))
            } catch {
                completion(.failure(error))
            }
        }.resume()
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
