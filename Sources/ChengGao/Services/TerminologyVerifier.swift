import Foundation

protocol TerminologyVerifying: Sendable {
    func verify(_ corrections: [TranscriptCorrection]) async -> [TranscriptCorrection]
}

/// Optional privacy-preserving verification. It sends only the proposed
/// corrected proper noun to Chinese Wikipedia, never the transcript or prompt.
actor WikipediaTerminologyVerifier: TerminologyVerifying {
    func verify(_ corrections: [TranscriptCorrection]) async -> [TranscriptCorrection] {
        var results: [TranscriptCorrection] = []
        for var correction in corrections.prefix(12) {
            correction.verification = await exists(title: correction.corrected) ? .onlineVerified : .onlineNotFound
            results.append(correction)
        }
        if corrections.count > 12 { results.append(contentsOf: corrections.dropFirst(12)) }
        return results
    }

    private func exists(title: String) async -> Bool {
        var components = URLComponents(string: "https://zh.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "titles", value: title)
        ]
        guard let url = components.url else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("ChengGao/1.0 local terminology verifier", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = root["query"] as? [String: Any],
                  let pages = query["pages"] as? [String: [String: Any]] else { return false }
            return pages.values.contains { $0["missing"] == nil && $0["invalid"] == nil }
        } catch {
            return false
        }
    }
}
