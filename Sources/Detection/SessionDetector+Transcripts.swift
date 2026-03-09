import Foundation

extension SessionDetector {
func parseClaudeTranscriptActivity(path: String) -> TranscriptActivity? {
    guard let lines = Self.readTailLines(path: path, maxBytes: 360_000) else { return nil }
    var activity = TranscriptActivity()

    for line in lines {
        guard let data = line.data(using: String.Encoding.utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = (object["timestamp"] as? String).flatMap(Self.parseISO8601)
        else { continue }

        switch object["type"] as? String {
        case "assistant":
            guard let message = object["message"] as? [String: Any] else { continue }
            let stopReason = message["stop_reason"] as? String
            var hasToolUse = false
            if let content = message["content"] as? [[String: Any]] {
                for item in content {
                    if item["type"] as? String == "tool_use",
                       let callId = item["id"] as? String {
                        activity.openCallIds.insert(callId)
                        hasToolUse = true
                    }
                }
            }
            if stopReason == "end_turn" {
                activity.openCallIds.removeAll()
                if hasToolUse {
                    activity.markToolActivity(timestamp)
                } else {
                    activity.markAssistantMessage(timestamp)
                }
            } else if hasToolUse {
                activity.markToolActivity(timestamp)
            } else if (message["role"] as? String) == "assistant" {
                activity.markActivity(timestamp)
            }
        case "user":
            guard let message = object["message"] as? [String: Any] else { continue }
            if let content = message["content"] as? [[String: Any]] {
                for item in content {
                    if item["type"] as? String == "tool_result",
                       let callId = item["tool_use_id"] as? String {
                        activity.openCallIds.remove(callId)
                        activity.markToolActivity(timestamp)
                    }
                }
            }
        case "progress":
            guard let data = object["data"] as? [String: Any],
                  data["type"] as? String == "hook_progress"
            else { continue }
            let hookEvent = data["hookEvent"] as? String
            if hookEvent == "Stop" {
                activity.openCallIds.removeAll()
            } else {
                if let callId = object["toolUseID"] as? String {
                    if hookEvent == "PreToolUse" {
                        activity.openCallIds.insert(callId)
                    } else if hookEvent == "PostToolUse" {
                        activity.openCallIds.remove(callId)
                    }
                }
                activity.markToolActivity(timestamp)
            }
        default:
            continue
        }
    }

    return activity.sawRelevantEvent ? activity : nil
}

func parseCodexTranscriptActivity(path: String) -> TranscriptActivity? {
    guard let lines = Self.readTailLines(path: path, maxBytes: 300_000) else { return nil }
    var activity = TranscriptActivity()

    for line in lines {
        guard let data = line.data(using: String.Encoding.utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = (object["timestamp"] as? String).flatMap(Self.parseISO8601)
        else { continue }

        switch object["type"] as? String {
        case "event_msg":
            guard let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String
            else { continue }
            if payloadType == "task_started" {
                activity.markActivity(timestamp)
            } else if payloadType == "task_complete" {
                activity.markActivity(timestamp)
            } else if payloadType == "agent_message",
                      (payload["phase"] as? String) == "commentary" {
                activity.markActivity(timestamp)
            }
        case "response_item":
            guard let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String
            else { continue }
            switch payloadType {
            case "function_call":
                if let callId = payload["call_id"] as? String {
                    activity.openCallIds.insert(callId)
                }
                activity.markToolActivity(timestamp)
            case "function_call_output":
                if let callId = payload["call_id"] as? String {
                    activity.openCallIds.remove(callId)
                }
                activity.markToolActivity(timestamp)
            case "custom_tool_call":
                activity.markToolActivity(timestamp)
            case "reasoning":
                activity.markActivity(timestamp)
            case "message":
                let role = payload["role"] as? String
                let phase = payload["phase"] as? String
                if role == "assistant" && phase == "commentary" {
                    activity.markActivity(timestamp)
                } else if role == "assistant" {
                    activity.markAssistantMessage(timestamp)
                }
            default:
                continue
            }
        default:
            continue
        }
    }

    return activity.sawRelevantEvent ? activity : nil
}

static func extractCodexUserText(from object: [String: Any]) -> String? {
    if object["type"] as? String == "event_msg",
       let payload = object["payload"] as? [String: Any],
       payload["type"] as? String == "user_message",
       let message = payload["message"] as? String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    if object["type"] as? String == "message",
       object["role"] as? String == "user",
       let content = object["content"] {
        return extractText(fromContent: content)
    }

    if object["type"] as? String == "response_item",
       let payload = object["payload"] as? [String: Any],
       payload["type"] as? String == "message",
       payload["role"] as? String == "user",
       let content = payload["content"] {
        return extractText(fromContent: content)
    }
    return nil
}

static func extractClaudeUserText(from message: [String: Any]) -> String? {
    if let content = message["content"] as? String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    if let content = message["content"] {
        return extractText(fromContent: content)
    }
    return nil
}

static func extractText(fromContent content: Any) -> String? {
    if let text = content as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    if let array = content as? [[String: Any]] {
        var texts: [String] = []
        for item in array {
            let type = item["type"] as? String
            if type == nil || type == "input_text" || type == "text" || type == "output_text",
               let text = item["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { texts.append(trimmed) }
            }
        }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
    return nil
}

static func cleanPrompt(_ prompt: String?) -> String? {
    guard let prompt else { return nil }
    var trimmed = prompt
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }

    let closingMarkers = [
        "</environment_context>",
        "</instructions>",
        "</collaboration_mode>",
        "</personality_spec>",
        "</permissions instructions>",
    ]
    for marker in closingMarkers {
        if let range = trimmed.range(of: marker, options: [.caseInsensitive]) {
            trimmed = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    let lower = trimmed.lowercased()
    if isMetaPrompt(lower) { return nil }

    let flattened = trimmed
        .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "`", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanedLower = flattened.lowercased()
    if flattened.isEmpty || isMetaPrompt(cleanedLower) { return nil }
    return String(flattened.prefix(500))
}

static func isMetaPrompt(_ lower: String) -> Bool {
    if lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
    let markers = [
        "<environment_context>",
        "<instructions>",
        "<system_instruction>",
        "<collaboration_mode>",
        "<personality_spec>",
        "<permissions instructions>",
        "current working directory:",
        "# agents.md instructions",
        "how an agent should work with me",
        "filesystem sandboxing defines",
        "skills available in this session",
        "you are codex",
        "you are working inside conductor",
    ]
    return markers.contains(where: { lower.contains($0) })
}

static func pickPrompt(from candidates: [String]) -> String? {
    for candidate in candidates {
        if let cleaned = cleanPrompt(candidate) {
            return cleaned
        }
    }
    return nil
}

static func readAllLines(path: String) -> [String]? {
    guard let text = try? String(contentsOfFile: path, encoding: String.Encoding.utf8) else { return nil }
    return text.components(separatedBy: "\n")
}

func processStartDate(forPid pid: Int32) -> Date? {
    guard let output = runProcess(path: "/bin/ps", arguments: ["-p", "\(pid)", "-o", "lstart="]) else {
        return nil
    }
    let normalized = output
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    guard !normalized.isEmpty else { return nil }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return formatter.date(from: normalized)
}

func cachedCwdPath(forPid pid: Int32) -> String? {
    let now = Date()
    if let cached = cwdPathCacheByPid[pid],
       now.timeIntervalSince(cached.fetchedAt) < cwdCacheTTL {
        return cached.path
    }
    let path = Self.cwdPath(forPid: pid)
    cwdPathCacheByPid[pid] = CachedPathLookup(fetchedAt: now, path: path)
    return path
}

func cachedTranscriptActivity(for tool: SessionTool, path: String) -> TranscriptActivity? {
    let mtime = Self.fileModificationDate(path: path)
    if let cached = transcriptActivityCacheByPath[path],
       cached.mtime == mtime {
        return cached.activity
    }

    let activity: TranscriptActivity?
    switch tool {
    case .claude:
        activity = parseClaudeTranscriptActivity(path: path)
    case .codex:
        activity = parseCodexTranscriptActivity(path: path)
    case .terminal:
        activity = nil
    }
    transcriptActivityCacheByPath[path] = CachedTranscriptActivity(mtime: mtime, activity: activity)
    return activity
}

static func readTailLines(path: String, maxBytes: Int) -> [String]? {
    let url = URL(fileURLWithPath: path)
    guard let text = readTail(of: url, maxBytes: maxBytes) else { return nil }
    return text.components(separatedBy: "\n")
}

static func readTail(of fileURL: URL, maxBytes: Int) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
    defer { try? handle.close() }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
          let fileSize = attrs[.size] as? NSNumber else { return nil }
    let total = UInt64(fileSize.intValue)
    let offset = total > UInt64(maxBytes) ? total - UInt64(maxBytes) : 0
    do {
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        return String(data: data, encoding: String.Encoding.utf8)
    } catch {
        return nil
    }
}

static func claudeProjectSlug(for cwdPath: String) -> String {
    let segments = cwdPath
        .split(separator: "/")
        .map(String.init)
    return "-" + segments.joined(separator: "-")
}

static func codexIdFromPath(_ path: String) -> String? {
    let file = (path as NSString).lastPathComponent
    let noExt = (file as NSString).deletingPathExtension
    guard let idx = noExt.range(of: "rollout-", options: [.literal]) else { return nil }
    let trimmed = String(noExt[idx.upperBound...])
    let parts = trimmed.split(separator: "-")
    if parts.count < 6 { return nil }
    return parts.suffix(5).joined(separator: "-")
}

static func parseISO8601(_ value: String) -> Date? {
    if let date = iso8601FractionalFormatter.date(from: value) { return date }
    return iso8601Formatter.date(from: value)
}

static func fileModificationDate(path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
}

private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private static let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

static func cwdPath(forPid pid: Int32) -> String? {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    proc.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    for line in output.components(separatedBy: "\n") {
        if line.hasPrefix("n/") {
            return String(line.dropFirst())
        }
    }
    return nil
}
}
