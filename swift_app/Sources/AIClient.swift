import Foundation

struct AIClient {

    enum Provider: String {
        case deepseek
        case kimi

        var url: URL {
            switch self {
            case .deepseek: return URL(string: "https://api.deepseek.com/v1/chat/completions")!
            case .kimi:     return URL(string: "https://api.moonshot.cn/v1/chat/completions")!
            }
        }

        var model: String {
            switch self {
            case .deepseek: return "deepseek-chat"
            case .kimi:     return "moonshot-v1-8k"
            }
        }
    }

    // Synchronous call via semaphore — MUST be called from a background thread.
    // Both DeepSeek and Kimi use OpenAI-compatible format.
    static func chat(provider: Provider, apiKey: String,
                     system: String, history: [[String: Any]]) throws -> String {
        var req = URLRequest(url: provider.url)
        req.httpMethod = "POST"
        req.setValue("application/json",       forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)",        forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60

        // System message prepended; history contains prior user/assistant turns + current user turn
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        messages.append(contentsOf: history)

        let body: [String: Any] = [
            "model":      provider.model,
            "max_tokens": 2048,
            "messages":   messages,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var resultText  = ""
        var resultError: Error?
        let sem = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: req) { data, response, err in
            defer { sem.signal() }
            if let err = err { resultError = err; return }
            guard let data = data else { resultError = APIError.bad("no data"); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? ""
                resultError = APIError.bad("AI API \(status): \(msg)")
                return
            }
            guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices  = json["choices"] as? [[String: Any]],
                  let message  = choices.first?["message"] as? [String: Any],
                  let text     = message["content"] as? String else {
                resultError = APIError.bad("unexpected response format")
                return
            }
            resultText = text
        }.resume()

        sem.wait()
        if let e = resultError { throw e }
        return resultText
    }
}
