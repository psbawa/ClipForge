import Foundation

public struct LLMUsage: Sendable, Codable, Equatable {
    public var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }
}

public struct LLMResponse: Sendable {
    public var text: String
    public var usage: LLMUsage
    public init(text: String, usage: LLMUsage) { self.text = text; self.usage = usage }
}

/// One block of a user message: text, or a JPEG image (vision).
public enum LLMContent: Sendable, Equatable {
    case text(String)
    case jpeg(Data)
}

public protocol LLMClient: Sendable {
    /// `system` is static and cached; `content` carries the volatile transcript (and frames, for vision).
    func complete(model: String, system: String, content: [LLMContent], maxTokens: Int, effort: String) async throws -> LLMResponse
}

public extension LLMClient {
    func complete(model: String, system: String, user: String, maxTokens: Int, effort: String) async throws -> LLMResponse {
        try await complete(model: model, system: system, content: [.text(user)], maxTokens: maxTokens, effort: effort)
    }
}

/// Raw HTTPS client for the Messages API (no official Swift SDK).
public struct AnthropicClient: LLMClient {
    let apiKey: @Sendable () -> String?
    let session: URLSession

    /// Hard ceiling per attempt (the request's timeoutInterval is only an idle timeout).
    public static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 180
        return URLSession(configuration: c)
    }()

    public init(session: URLSession = AnthropicClient.defaultSession, apiKey: @escaping @Sendable () -> String? = { Keychain.get(Keychain.Key.anthropic) }) {
        self.session = session; self.apiKey = apiKey
    }

    static func body(model: String, system: String, content: [LLMContent], maxTokens: Int, effort: String) -> [String: Any] {
        let blocks: [[String: Any]] = content.map {
            switch $0 {
            case .text(let t): ["type": "text", "text": t]
            case .jpeg(let d): ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": d.base64EncodedString()]]
            }
        }
        return [
            "model": model,
            "max_tokens": maxTokens,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": blocks]],
            "output_config": ["effort": effort],
        ]
    }

    public func complete(model: String, system: String, content: [LLMContent], maxTokens: Int, effort: String) async throws -> LLMResponse {
        guard let key = apiKey(), !key.isEmpty else { throw ClipForgeError("Add your Anthropic API key in Settings.") }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.body(model: model, system: system, content: content, maxTokens: maxTokens, effort: effort))

        var delay = 2.0
        for attempt in 0..<4 {
            let data: Data, resp: URLResponse
            do { (data, resp) = try await session.data(for: req) } catch let e as URLError where attempt < 3 {
                Log.ai.warning("Claude request network error \(e.code.rawValue); retrying")
                try await Task.sleep(for: .seconds(delay))
                delay *= 2
                continue
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return try Self.parse(data) }
            let retryable = status == 429 || status == 529 || status >= 500
            if retryable, attempt < 3 {
                let after = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                try await Task.sleep(for: .seconds(after ?? delay))
                delay *= 2
                continue
            }
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String ?? "HTTP \(status)"
            throw ClipForgeError(status == 401 ? "Anthropic API key was rejected." : "Claude API error: \(msg)")
        }
        throw ClipForgeError("Claude API unavailable")
    }

    static func parse(_ data: Data) throws -> LLMResponse {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClipForgeError("Bad API response") }
        if o["stop_reason"] as? String == "refusal" { throw ClipForgeError("Claude declined this request") }
        let text = (o["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
        let u = o["usage"] as? [String: Any] ?? [:]
        return LLMResponse(text: text, usage: LLMUsage(input: u["input_tokens"] as? Int ?? 0,
                                                       output: u["output_tokens"] as? Int ?? 0,
                                                       cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0,
                                                       cacheRead: u["cache_read_input_tokens"] as? Int ?? 0))
    }
}

/// Running API spend. Session total in memory; per-day total persisted so the budget cap survives restarts.
public actor CostTracker {
    public private(set) var sessionCost = 0.0
    public private(set) var sessionUsage = LLMUsage()
    let defaults: UserDefaults
    let now: @Sendable () -> Date

    public init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
    }

    public static func cost(_ u: LLMUsage, _ p: ModelPrice) -> Double {
        // Cache writes bill at 1.25x input (5-minute TTL), cache reads at 0.1x.
        let inputEquivalent: Double = Double(u.input) + Double(u.cacheWrite) * 1.25 + Double(u.cacheRead) * 0.1
        return (inputEquivalent * p.inputPerMTok + Double(u.output) * p.outputPerMTok) / 1_000_000
    }

    var dayKey: String { "cost." + ISO8601DateFormatter.string(from: now(), timeZone: .current, formatOptions: [.withFullDate]) }

    public var todayCost: Double { defaults.double(forKey: dayKey) }

    @discardableResult
    public func record(_ u: LLMUsage, price: ModelPrice?) -> Double {
        let c = price.map { Self.cost(u, $0) } ?? 0
        if price == nil { Log.ai.warning("No price configured for model; cost counted as 0") }
        sessionCost += c
        sessionUsage.input += u.input; sessionUsage.output += u.output
        sessionUsage.cacheWrite += u.cacheWrite; sessionUsage.cacheRead += u.cacheRead
        defaults.set(todayCost + c, forKey: dayKey)
        return c
    }

    /// budget 0 = unlimited.
    public func canSpend(budget: Double) -> Bool { budget <= 0 || todayCost < budget }
}
