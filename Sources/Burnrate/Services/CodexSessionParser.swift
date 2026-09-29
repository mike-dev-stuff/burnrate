import Foundation

struct CodexSessionParser {
    private let codexHome: URL
    private let maxDaysToSearch = 7

    /// Bytes read from the end of a rollout file on the first attempt. Codex
    /// appends a `token_count` event every few lines, so the latest one is
    /// normally within a few KB of the end even when the file is hundreds of MB.
    /// The window grows if no record is found in it.
    private let initialTailWindow: UInt64 = 256 * 1024

    init() {
        // CODEX_HOME defaults to ~/.codex
        if let customHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            self.codexHome = URL(fileURLWithPath: customHome)
        } else {
            self.codexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
        }
    }

    var isCodexInstalled: Bool {
        FileManager.default.fileExists(atPath: codexHome.path)
    }

    func getUsageLimits() -> CodexUsageLimits? {
        let sessionsPath = codexHome.appendingPathComponent("sessions")

        guard FileManager.default.fileExists(atPath: sessionsPath.path) else {
            return nil
        }

        // Search backwards from today through YYYY/MM/DD directory structure
        let calendar = Calendar.current
        var currentDate = Date()

        for _ in 0..<maxDaysToSearch {
            let year = calendar.component(.year, from: currentDate)
            let month = calendar.component(.month, from: currentDate)
            let day = calendar.component(.day, from: currentDate)

            let dayPath = sessionsPath
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))

            if let limits = searchDirectoryForUsage(dayPath) {
                return limits
            }

            // Move to previous day
            currentDate = calendar.date(byAdding: .day, value: -1, to: currentDate) ?? currentDate
        }

        return nil
    }

    private func searchDirectoryForUsage(_ directoryPath: URL) -> CodexUsageLimits? {
        guard FileManager.default.fileExists(atPath: directoryPath.path) else {
            return nil
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: directoryPath,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ).filter { $0.pathExtension == "jsonl" }

            // Sort by modification date, newest first
            let sortedFiles = files.sorted { file1, file2 in
                let date1 = (try? file1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                let date2 = (try? file2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                return date1 > date2
            }

            // Search most recent files first for token_count records
            for file in sortedFiles {
                if let limits = parseFileForUsage(file) {
                    return limits
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    /// Finds the most recent `token_count` event that carries rate limits by
    /// reading the file from the end. Rollout files grow to hundreds of MB, so
    /// only a tail window is read; it is widened until a record is found or the
    /// whole file has been covered.
    private func parseFileForUsage(_ file: URL) -> CodexUsageLimits? {
        guard let fileHandle = FileHandle(forReadingAtPath: file.path) else {
            return nil
        }
        defer { try? fileHandle.close() }

        guard let fileSize = try? fileHandle.seekToEnd(), fileSize > 0 else {
            return nil
        }

        var windowSize = initialTailWindow
        while true {
            let readSize = min(windowSize, fileSize)
            let offset = fileSize - readSize

            do {
                try fileHandle.seek(toOffset: offset)
            } catch {
                return nil
            }
            guard let window = try? fileHandle.read(upToCount: Int(readSize)) else {
                return nil
            }

            if let payload = latestTokenCountPayload(in: window) {
                return makeLimits(from: payload)
            }

            if readSize >= fileSize {
                // Whole file scanned, nothing usable in it
                return nil
            }
            windowSize *= 4
        }
    }

    /// Walks `data` backwards one line at a time and decodes the last line that
    /// is a `token_count` event with rate limits. A partial first line (when the
    /// window does not start at the beginning of the file) or a partial last line
    /// (still being written by Codex) simply fails to decode and is skipped.
    private func latestTokenCountPayload(in data: Data) -> CodexTokenCountPayload? {
        let marker = Data("token_count".utf8)
        let decoder = JSONDecoder()
        var lineEnd = data.endIndex

        while lineEnd > data.startIndex {
            let lineStart = data[data.startIndex..<lineEnd]
                .lastIndex(of: 0x0A)
                .map { $0 + 1 } ?? data.startIndex
            let line = data[lineStart..<lineEnd]

            // Cheap substring check before paying for a JSON decode
            if line.range(of: marker) != nil,
               let record = try? decoder.decode(CodexEventMessage.self, from: Data(line)),
               record.type == "event_msg",
               let payload = record.payload,
               payload.type == "token_count",
               payload.rateLimits != nil {
                return payload
            }

            if lineStart == data.startIndex {
                break
            }
            lineEnd = lineStart - 1  // Skip the newline that ended the previous line
        }

        return nil
    }

    private func makeLimits(from payload: CodexTokenCountPayload) -> CodexUsageLimits? {
        guard let rateLimits = payload.rateLimits else {
            return nil
        }

        // Extract token info if available
        let tokenInfo = payload.info?.totalTokenUsage

        return CodexUsageLimits(
            fiveHourUtilization: rateLimits.primary?.usedPercent ?? 0,
            fiveHourResetsAt: unixTimestampToDate(rateLimits.primary?.resetsAt),
            weeklyUtilization: rateLimits.secondary?.usedPercent ?? 0,
            weeklyResetsAt: unixTimestampToDate(rateLimits.secondary?.resetsAt),
            inputTokens: tokenInfo?.inputTokens,
            outputTokens: tokenInfo?.outputTokens,
            reasoningTokens: tokenInfo?.reasoningOutputTokens
        )
    }

    private func unixTimestampToDate(_ timestamp: Int?) -> Date? {
        guard let timestamp = timestamp else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

// MARK: - JSON Models for Codex Session Files

// Root level: { "type": "event_msg", "payload": {...} }
private struct CodexEventMessage: Codable {
    let type: String?
    let payload: CodexTokenCountPayload?
}

// Payload: { "type": "token_count", "info": {...}, "rate_limits": {...} }
private struct CodexTokenCountPayload: Codable {
    let type: String?
    let info: CodexTokenInfo?
    let rateLimits: CodexRateLimits?

    enum CodingKeys: String, CodingKey {
        case type
        case info
        case rateLimits = "rate_limits"
    }
}

// Token info: { "total_token_usage": {...} }
private struct CodexTokenInfo: Codable {
    let totalTokenUsage: CodexTokenUsage?

    enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
    }
}

// Token usage counts
private struct CodexTokenUsage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
    }
}

// Rate limits container: { "primary": {...}, "secondary": {...} }
private struct CodexRateLimits: Codable {
    let primary: CodexRateLimit?
    let secondary: CodexRateLimit?
}

// Individual rate limit: { "used_percent": 0.0, "resets_at": 1768562144 }
private struct CodexRateLimit: Codable {
    let usedPercent: Double?
    let resetsAt: Int?  // Unix timestamp

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
    }
}
