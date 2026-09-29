import Foundation

struct SessionParser {
    private let projectsPath: URL
    private let maxRecentSessions = 8

    init() {
        self.projectsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    func getRecentSessions() -> [SessionInfo] {
        guard FileManager.default.fileExists(atPath: projectsPath.path) else {
            return []
        }

        var sessionFiles: [(URL, Date, String, String)] = []

        do {
            let projectDirs = try FileManager.default.contentsOfDirectory(
                at: projectsPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )

            for projectDir in projectDirs {
                guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                    continue
                }

                let projectPath = decodeProjectPath(projectDir.lastPathComponent)
                let sessionJsonlFiles = try FileManager.default.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: .skipsHiddenFiles
                ).filter { $0.pathExtension == "jsonl" && !$0.lastPathComponent.hasPrefix("agent-") }

                for file in sessionJsonlFiles {
                    if let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                        sessionFiles.append((file, modDate, projectPath, projectDir.lastPathComponent))
                    }
                }
            }
        } catch {
            return []
        }

        // Sort by modification date, newest first
        sessionFiles.sort { $0.1 > $1.1 }

        // Parse only the most recent ones
        var sessions: [SessionInfo] = []
        for (file, _, projectPath, encodedProject) in sessionFiles.prefix(maxRecentSessions * 2) {
            if let session = parseSessionSummary(file: file, projectPath: projectPath, encodedProject: encodedProject) {
                sessions.append(session)
                if sessions.count >= maxRecentSessions {
                    break
                }
            }
        }

        return sessions.sorted { $0.timestamp > $1.timestamp }
    }

    func getCurrentSession() -> CurrentSession? {
        guard FileManager.default.fileExists(atPath: projectsPath.path) else {
            return nil
        }

        var latestFile: URL?
        var latestDate: Date?

        do {
            let projectDirs = try FileManager.default.contentsOfDirectory(
                at: projectsPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )

            for projectDir in projectDirs {
                guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                    continue
                }

                let sessionFiles = try FileManager.default.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: .skipsHiddenFiles
                ).filter { $0.pathExtension == "jsonl" && !$0.lastPathComponent.hasPrefix("agent-") }

                for file in sessionFiles {
                    if let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                        if latestDate == nil || modDate > latestDate! {
                            latestDate = modDate
                            latestFile = file
                        }
                    }
                }
            }
        } catch {
            return nil
        }

        guard let file = latestFile else { return nil }
        return parseCurrentSession(file: file)
    }

    private func decodeProjectPath(_ encoded: String) -> String {
        var path = encoded
        if path.hasPrefix("-") {
            path = String(path.dropFirst())
        }

        // `--` represents `/_` (path separator + leading underscore)
        path = path.replacingOccurrences(of: "--", with: "/_")

        // Single dashes become path separators
        path = "/" + path.replacingOccurrences(of: "-", with: "/")

        // Try to resolve actual path
        return resolveActualPath(path) ?? path
    }

    private func resolveActualPath(_ decodedPath: String) -> String? {
        if FileManager.default.fileExists(atPath: decodedPath) {
            return decodedPath
        }

        // Try combining path segments with hyphens
        let parts = decodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        if parts.count >= 2 {
            // Try /a/b-c instead of /a/b/c
            let combined = parts.dropLast(2) + [parts[parts.count - 2] + "-" + parts[parts.count - 1]]
            let combinedPath = combined.joined(separator: "/")
            if FileManager.default.fileExists(atPath: combinedPath) {
                return combinedPath
            }
        }

        return nil
    }

    private func parseSessionSummary(file: URL, projectPath: String, encodedProject: String) -> SessionInfo? {
        let sessionId = file.deletingPathExtension().lastPathComponent

        // Only the first `maxLines` lines are needed; stream them so a huge
        // file costs the same as a small one.
        guard let fileHandle = FileHandle(forReadingAtPath: file.path) else {
            return nil
        }
        defer { try? fileHandle.close() }

        var slug: String?
        var timestamp: Date?
        var messageCount = 0
        var totalTokens = 0
        var model: String?
        var summary: String?
        var lineCount = 0
        let maxLines = 150
        let decoder = JSONDecoder()

        forEachLine(in: fileHandle) { lineData in
            lineCount += 1
            if lineCount > maxLines {
                return false
            }

            guard let entry = try? decoder.decode(SessionEntry.self, from: lineData) else {
                return true
            }

            if entry.type == "user" && slug == nil {
                slug = entry.slug ?? String(sessionId.prefix(8))
                if let ts = entry.timestamp {
                    timestamp = parseTimestamp(ts)
                }
            }

            if entry.type == "user" || entry.type == "assistant" {
                messageCount += 1
            }

            if entry.type == "assistant", model == nil {
                model = entry.message?.model
                if let usage = entry.message?.usage {
                    totalTokens += (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0)
                }
            }

            if entry.type == "summary" {
                summary = entry.summary
            }

            return true
        }

        let fallbackDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()

        return SessionInfo(
            id: sessionId,
            slug: slug ?? String(sessionId.prefix(8)),
            projectPath: projectPath,
            encodedProject: encodedProject,
            timestamp: timestamp ?? fallbackDate,
            messageCount: messageCount,
            totalTokens: totalTokens,
            summary: summary,
            model: model ?? "unknown"
        )
    }

    private func parseCurrentSession(file: URL) -> CurrentSession? {
        let sessionId = file.deletingPathExtension().lastPathComponent
        let projectDir = file.deletingLastPathComponent().lastPathComponent
        let projectPath = decodeProjectPath(projectDir)

        // Check file size - for large files, only read beginning
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let fileSize = attrs[.size] as? Int64 else {
            return nil
        }

        guard let fileHandle = FileHandle(forReadingAtPath: file.path) else {
            return nil
        }
        defer { try? fileHandle.close() }

        var slug: String?
        var startTime: Date?
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
        var messageCount = 0

        // For very large files (>10MB), only read first 1MB
        let maxBytesToRead = fileSize > 10_000_000 ? 1_000_000 : Int(fileSize)
        let decoder = JSONDecoder()

        forEachLine(in: fileHandle, maxBytes: maxBytesToRead) { lineData in
            guard let entry = try? decoder.decode(SessionEntry.self, from: lineData) else {
                return true
            }

            if entry.type == "user" && slug == nil {
                slug = entry.slug ?? String(sessionId.prefix(8))
                if let ts = entry.timestamp {
                    startTime = parseTimestamp(ts)
                }
            }

            if entry.type == "user" || entry.type == "assistant" {
                messageCount += 1
            }

            if entry.type == "assistant", let usage = entry.message?.usage {
                inputTokens += usage.inputTokens ?? 0
                outputTokens += usage.outputTokens ?? 0
                cacheReadTokens += usage.cacheReadInputTokens ?? 0
                cacheCreationTokens += usage.cacheCreationInputTokens ?? 0
            }

            return true
        }

        let fallbackDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()

        return CurrentSession(
            sessionId: sessionId,
            slug: slug ?? String(sessionId.prefix(8)),
            projectPath: projectPath,
            startTime: startTime ?? fallbackDate,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            messageCount: messageCount
        )
    }

    private func parseTimestamp(_ ts: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: ts) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: ts)
    }
}

// MARK: - Line reading

/// Reads a JSONL file in chunks and hands each complete line (without its
/// trailing newline) to `body`. Every byte is scanned exactly once, so the cost
/// is linear in bytes read even when single lines are megabytes long. Reading
/// stops when `body` returns `false`, at end of file, or once `maxBytes` have
/// been consumed.
private func forEachLine(
    in fileHandle: FileHandle,
    maxBytes: Int = .max,
    chunkSize: Int = 64 * 1024,
    _ body: (Data) -> Bool
) {
    var partial = Data()  // Bytes of the current line carried over from earlier chunks
    var bytesRead = 0

    while bytesRead < maxBytes {
        let chunk = fileHandle.readData(ofLength: chunkSize)
        if chunk.isEmpty {
            // End of file: flush an unterminated final line, if any
            if !partial.isEmpty {
                _ = body(partial)
            }
            return
        }
        bytesRead += chunk.count

        var lineStart = chunk.startIndex
        while let newline = chunk[lineStart...].firstIndex(of: 0x0A) {
            let line: Data
            if partial.isEmpty {
                line = Data(chunk[lineStart..<newline])
            } else {
                partial.append(chunk[lineStart..<newline])
                line = partial
                partial = Data()
            }
            if !body(line) {
                return
            }
            lineStart = newline + 1
        }

        if lineStart < chunk.endIndex {
            partial.append(chunk[lineStart...])
        }
    }
}

// MARK: - JSON Models

private struct SessionEntry: Codable {
    let type: String?
    let slug: String?
    let timestamp: String?
    let summary: String?
    let message: MessageContent?
}

private struct MessageContent: Codable {
    let model: String?
    let usage: UsageInfo?
}

private struct UsageInfo: Codable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}
