import Foundation

/// Where lyrics come from. Persisted in UserDefaults under `lyrics.provider`.
enum LyricsProvider: String, CaseIterable, Identifiable {
    case lrclib
    case gemini
    case exa

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lrclib: return "LRCLIB (free)"
        case .gemini: return "Google Gemini (API key)"
        case .exa:    return "Exa (API key)"
        }
    }

    /// Short label for the lyrics source badge.
    var badgeName: String {
        switch self {
        case .lrclib: return "LRCLIB"
        case .gemini: return "Gemini"
        case .exa:    return "Exa"
        }
    }
}

/// Fetches lyrics. Two backends:
///   • LRCLIB (https://lrclib.net) — free, no-auth, has plain + synced lyrics.
///   • Gemini Flash Lite grounded by Google Search — needs an API key, but
///     reliably finds lyrics for tracks LRCLIB is missing.
/// The provider is chosen by user settings; Gemini falls back to LRCLIB if it
/// errors so a transient API hiccup never leaves you with nothing.
struct LyricsService {
    struct Lyrics: Equatable {
        let plain: String?
        let synced: String?     // raw LRC format, e.g. "[00:12.34] line"
        let instrumental: Bool
        let source: LyricsProvider   // which backend actually produced these
    }

    static let providerDefaultsKey = "lyrics.provider"
    static let geminiKeyDefaultsKey = "lyrics.geminiAPIKey"
    static let exaKeyDefaultsKey = "lyrics.exaAPIKey"

    private let session: URLSession
    private let userAgent = "SonosControl (https://github.com/nfarina/SonosControl)"

    init(session: URLSession = .shared) {
        self.session = session
    }

    private var provider: LyricsProvider {
        let raw = UserDefaults.standard.string(forKey: Self.providerDefaultsKey) ?? ""
        return LyricsProvider(rawValue: raw) ?? .lrclib
    }

    private var geminiKey: String {
        (UserDefaults.standard.string(forKey: Self.geminiKeyDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var exaKey: String {
        (UserDefaults.standard.string(forKey: Self.exaKeyDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetch(artist: String, title: String, album: String, duration: TimeInterval) async throws -> Lyrics? {
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }

        // Premium providers first (if configured). Any failure falls through
        // to LRCLIB so a flaky API never leaves you with nothing.
        if provider == .gemini, !geminiKey.isEmpty {
            do {
                if let g = try await fetchGemini(artist: cleanArtist, title: cleanTitle) {
                    return g
                }
            } catch {
                logDebug("Gemini lyrics failed, falling back to LRCLIB: \(error)")
            }
        } else if provider == .exa, !exaKey.isEmpty {
            do {
                if let e = try await fetchExa(artist: cleanArtist, title: cleanTitle) {
                    return e
                }
            } catch {
                logDebug("Exa lyrics failed, falling back to LRCLIB: \(error)")
            }
        }

        if let exact = try await getExact(artist: cleanArtist, title: cleanTitle,
                                          album: album, duration: duration) {
            return exact
        }
        return try await search(artist: cleanArtist, title: cleanTitle)
    }

    // MARK: - Gemini (grounded by Google Search)

    private func fetchGemini(artist: String, title: String) async throws -> Lyrics? {
        let model = "gemini-3.1-flash-lite"
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = [URLQueryItem(name: "key", value: geminiKey)]
        guard let url = components.url else { return nil }

        let ask = "Please output only the complete lyrics to the song \"\(title)\" by \(artist). Use Google Search. If you cannot find the lyrics, reply with exactly NO_LYRICS_FOUND and nothing else."

        // A one-shot example primes the model to return bare lyrics with no
        // preamble or commentary.
        let body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": [["text": "Please output only the complete lyrics to the song \"Float\" by Jay Som / Jim Adkins. Use Google Search."]]],
                ["role": "model", "parts": [["text": "Wasted\nI'll give you one more chance to run\nLet's pretend\nI'm not scared"]]],
                ["role": "user", "parts": [["text": ask]]],
            ],
            "generationConfig": [
                "thinkingConfig": ["thinkingLevel": "MINIMAL"],
            ],
            "tools": [["googleSearch": [:]]],
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw LyricsError.gemini("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(bodyText.prefix(200))")
        }

        let text = Self.extractGeminiText(data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("NO_LYRICS_FOUND") else { return nil }
        return Lyrics(plain: text, synced: nil, instrumental: false, source: .gemini)
    }

    // MARK: - Exa (search + extract, OpenAI-compatible chat API)

    private func fetchExa(artist: String, title: String) async throws -> Lyrics? {
        guard let url = URL(string: "https://api.exa.ai/chat/completions") else { return nil }

        let ask = "Please output only the complete lyrics to the song \"\(title)\" by \(artist). Do not include commentary, source links, or section headers — just the lyrics. If you cannot find them, reply with exactly NO_LYRICS_FOUND and nothing else."
        let body: [String: Any] = [
            "model": "exa",
            "messages": [["role": "user", "content": ask]],
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(exaKey, forHTTPHeaderField: "x-api-key")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 25
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw LyricsError.exa("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(bodyText.prefix(200))")
        }

        let text = Self.extractOpenAIText(data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("NO_LYRICS_FOUND") else { return nil }
        return Lyrics(plain: text, synced: nil, instrumental: false, source: .exa)
    }

    /// Extract `choices[0].message.content` from an OpenAI-style chat reply.
    static func extractOpenAIText(_ data: Data) -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else { return "" }
        return content
    }

    /// Pull and concatenate all text parts from a Gemini generateContent reply.
    static func extractGeminiText(_ data: Data) -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    // MARK: - LRCLIB endpoints

    private func getExact(artist: String, title: String, album: String, duration: TimeInterval) async throws -> Lyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        if !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if duration > 0 {
            items.append(URLQueryItem(name: "duration", value: "\(Int(duration))"))
        }
        components.queryItems = items

        guard let url = components.url else { return nil }
        let (data, response) = try await request(url)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 else { return nil }

        let decoded = try JSONDecoder().decode(LRCLIBItem.self, from: data)
        return decoded.toLyrics()
    }

    private func search(artist: String, title: String) async throws -> Lyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let url = components.url else { return nil }
        let (data, response) = try await request(url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        let results = try JSONDecoder().decode([LRCLIBItem].self, from: data)
        let best = results.first { ($0.plainLyrics?.isEmpty == false) || ($0.syncedLyrics?.isEmpty == false) }
            ?? results.first
        return best?.toLyrics()
    }

    private func request(_ url: URL) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        do {
            return try await session.data(for: req)
        } catch let error as URLError where error.code == .timedOut {
            // LRCLIB can be briefly slow — retry once before giving up.
            return try await session.data(for: req)
        }
    }
}

enum LyricsError: Error {
    case gemini(String)
    case exa(String)
}

private struct LRCLIBItem: Decodable {
    let plainLyrics: String?
    let syncedLyrics: String?
    let instrumental: Bool?

    func toLyrics() -> LyricsService.Lyrics {
        LyricsService.Lyrics(
            plain: plainLyrics?.isEmpty == false ? plainLyrics : nil,
            synced: syncedLyrics?.isEmpty == false ? syncedLyrics : nil,
            instrumental: instrumental ?? false,
            source: .lrclib
        )
    }
}

/// UI-facing state for the lyrics panel.
enum LyricsState: Equatable {
    case idle
    case loading
    case loaded(LyricsService.Lyrics)
    case notFound
    case noSong       // nothing song-like playing (DJ talking, station promo)
    case failed(String)
}
