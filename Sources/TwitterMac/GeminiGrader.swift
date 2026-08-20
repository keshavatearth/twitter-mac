import Foundation

/// Optional LLM grading, ported from the extension's `political_analysis.js`.
///
/// Two deliberate changes from the extension:
///   - The request is made here, natively, not from page JS. x.com's CSP would block
///     a fetch to generativelanguage.googleapis.com anyway, and this keeps the API key
///     out of a context that x.com scripts can read.
///   - Verdicts are cached on disk by tweet ID, so a tweet is graded at most once ever.
@MainActor
final class GeminiGrader {
    struct Verdict: Codable {
        var blocked: Bool
        var at: Date
    }

    private struct Pending: Equatable {
        let id: String
        let text: String
    }

    private var cache: [String: Verdict] = [:]
    private var queue: [Pending] = []
    private var inFlight = 0
    private var saveScheduled = false

    private let maxConcurrent = 2
    private let maxCacheEntries = 20_000
    private let cacheTTL: TimeInterval = 30 * 24 * 60 * 60

    private let cacheURL = AppConfig.appSupportDirectory.appendingPathComponent("verdicts.json")
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    var config: AppConfig
    var onVerdict: ((String, Bool) -> Void)?
    var onStatus: ((String?) -> Void)?
    private(set) var gradedThisSession = 0

    init(config: AppConfig) {
        self.config = config
        loadCache()
    }

    var cacheCount: Int { cache.count }

    // MARK: - Queueing

    func enqueue(id: String, text: String) {
        if let hit = cache[id] {
            onVerdict?(id, hit.blocked)
            return
        }
        guard config.hasGeminiKey else {
            onStatus?("No API key in \(AppConfig.fileURL.path)")
            return
        }
        guard !queue.contains(where: { $0.id == id }) else { return }
        queue.append(Pending(id: id, text: text))
        pump()
    }

    func cachedVerdict(for id: String) -> Bool? { cache[id]?.blocked }

    private func pump() {
        while inFlight < maxConcurrent, !queue.isEmpty {
            let next = queue.removeFirst()
            inFlight += 1
            Task { await run(next) }
        }
    }

    private func run(_ item: Pending) async {
        defer {
            inFlight -= 1
            pump()
        }
        do {
            let blocked = try await grade(text: item.text)
            cache[item.id] = Verdict(blocked: blocked, at: Date())
            gradedThisSession += 1
            scheduleSave()
            onStatus?(nil)
            onVerdict?(item.id, blocked)
        } catch {
            // Match the extension's failure posture: on error, show the tweet.
            onStatus?(shortDescription(of: error))
        }
    }

    // MARK: - Gemini call

    private func grade(text: String) async throws -> Bool {
        let model = config.geminiModel
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw GraderError.badModel(model)
        }

        var generationConfig: [String: Any] = [
            "temperature": 0,
            "maxOutputTokens": 16,
            "candidateCount": 1
        ]
        // 2.5-family models otherwise burn the whole output budget on reasoning tokens
        // and return an empty candidate. Older models reject the field, hence the check.
        if model.contains("2.5") {
            generationConfig["thinkingConfig"] = ["thinkingBudget": 0]
        }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": UserScripts.gradingInstructions()]]],
            "contents": [["role": "user", "parts": [["text": "Here's the tweet to analyze: \"\(text)\""]]]],
            "generationConfig": generationConfig
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header rather than ?key= so the secret never lands in a URL or a log line.
        request.setValue(config.geminiAPIKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GraderError.noResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GraderError.http(http.statusCode, apiMessage(from: data))
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let raw = parts.compactMap({ $0["text"] as? String }).first
        else { throw GraderError.unexpectedShape }

        let decision = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return decision.hasPrefix("blocked")
    }

    private func apiMessage(from data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String
        else { return "HTTP error" }
        return message
    }

    private func shortDescription(of error: Error) -> String {
        switch error {
        case GraderError.http(let code, let message): return "Gemini \(code): \(message.prefix(120))"
        case GraderError.badModel(let m): return "Bad model name: \(m)"
        case GraderError.unexpectedShape: return "Unexpected Gemini response shape"
        case GraderError.noResponse: return "No response from Gemini"
        default: return (error as NSError).localizedDescription
        }
    }

    enum GraderError: Error {
        case badModel(String)
        case http(Int, String)
        case unexpectedShape
        case noResponse
    }

    // MARK: - Disk cache

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Verdict].self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-cacheTTL)
        cache = decoded.filter { $0.value.at > cutoff }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.saveCache()
        }
    }

    func saveCache() {
        saveScheduled = false
        if cache.count > maxCacheEntries {
            let keep = cache.sorted { $0.value.at > $1.value.at }.prefix(maxCacheEntries)
            cache = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
