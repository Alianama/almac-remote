// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

/// A locally-installed AI coding-agent CLI that "Ask AI" can shell out to.
/// Almac Remote never talks to any AI provider's API directly and never
/// stores a key — auth is whatever account the user is already logged into
/// via that CLI's own login (each of these supports a free-tier account).
enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case claude, codex, gemini, opencode
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude:   return "Claude Code"
        case .codex:    return "Codex (ChatGPT)"
        case .gemini:   return "Gemini"
        case .opencode: return "OpenCode"
        }
    }

    /// A starting set of models to pre-fill Settings with. None of
    /// `claude`/`codex`/`gemini` expose a "list models" command, but Codex
    /// maintains its own local cache the Settings "Discover" button can read
    /// (see `AIModelDiscovery`) — Claude has no such file, so it's seeded
    /// once here from Anthropic's published catalog instead.
    static func seedClaudeModels() -> [AIModelEntry] {
        [
            AIModelEntry(modelID: "claude-opus-5", alias: "Opus 5"),
            AIModelEntry(modelID: "claude-sonnet-5", alias: "Sonnet 5"),
            AIModelEntry(modelID: "claude-haiku-4-5", alias: "Haiku 4.5"),
            AIModelEntry(modelID: "claude-fable-5", alias: "Fable 5"),
        ]
    }
}

/// A model choice configured for a provider — the raw value sent as
/// `--model`/`-m`, plus an optional friendly name to show in the UI.
struct AIModelEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var modelID: String
    var alias: String

    init(modelID: String, alias: String = "") {
        self.id = UUID()
        self.modelID = modelID
        self.alias = alias
    }
    var displayName: String { alias.isEmpty ? modelID : alias }
}

struct AIAssistantError: Error { let message: String }

/// Real usage figures parsed from a CLI's own response, when it reports
/// them — never estimated or fabricated. Each turn is an independent
/// one-shot process (no shared session), so this reflects only that turn,
/// not a running conversation total.
struct AIUsageStats: Codable, Equatable {
    var inputTokens: Int?
    var outputTokens: Int?
    /// Set instead of input/output when a CLI only reports a combined figure.
    var totalTokens: Int?
    var contextWindow: Int?
    var costUSD: Double?
    var durationMs: Int?

    var usedTokens: Int? {
        if let totalTokens { return totalTokens }
        if inputTokens != nil || outputTokens != nil { return (inputTokens ?? 0) + (outputTokens ?? 0) }
        return nil
    }
    var percentOfContext: Double? {
        guard let used = usedTokens, let window = contextWindow, window > 0 else { return nil }
        return Double(used) / Double(window) * 100
    }
}

/// One turn in the "Ask AI" panel's transcript.
struct AIChatMessage: Identifiable, Codable {
    enum Role: String, Codable { case user, assistant, error }
    let id: UUID
    let role: Role
    var text: String
    let date: Date
    let provider: AIProvider?
    var usage: AIUsageStats?

    init(role: Role, text: String, provider: AIProvider? = nil, usage: AIUsageStats? = nil, date: Date = Date()) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.provider = provider
        self.usage = usage
        self.date = date
    }
}

/// One "Ask AI" conversation thread — the panel can hold several, switch
/// between them, and start new ones (all persisted).
struct AIChatSession: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [AIChatMessage]
    var createdAt: Date
    var updatedAt: Date
    /// Each CLI's own session/conversation id for THIS chat thread, keyed by
    /// `AIProvider.rawValue` — passed back as `--resume` so a later turn
    /// continues with full context instead of starting fresh every message.
    /// Empty for a brand-new thread, and per-provider since switching the
    /// provider picker mid-thread can't resume a different CLI's session.
    var providerSessionTokens: [String: String] = [:]

    init(title: String = "", messages: [AIChatMessage] = []) {
        self.id = UUID()
        self.title = title
        self.messages = messages
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}

/// A handle to an in-flight `AIAssistant.ask` call so the UI can cancel it —
/// `Task.cancel()` alone wouldn't kill the underlying subprocess. `Process`
/// is safe to message (`.terminate()`) from any thread.
final class AIAskHandle: @unchecked Sendable {
    fileprivate weak var process: Process?
    func cancel() { process?.terminate() }
}

/// Runs an installed AI CLI non-interactively for a single Q&A prompt.
enum AIAssistant {
    /// GUI apps on macOS don't inherit the shell's PATH (nvm/asdf/Homebrew
    /// managed installs live outside it), so check these common install
    /// locations in addition to PATH.
    private static let extraSearchDirs = [
        "/opt/homebrew/bin", "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.npm-global/bin",
    ]

    /// Full path to `provider`'s CLI, or nil if it isn't installed.
    static func binaryPath(for provider: AIProvider) -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for dir in pathDirs + extraSearchDirs {
            let candidate = dir + "/" + provider.rawValue
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Read-only/no-side-effect args per CLI — this is a Q&A box, not a
    /// coding-agent session, so tool/file/shell access is deliberately off.
    /// `model`, when non-empty, is passed as each CLI's own `--model`/`-m`
    /// flag (a free-form string, since the set of valid model names/aliases
    /// changes over time and each CLI already validates it itself). Claude
    /// and Gemini use `--output-format json` so real usage stats can be
    /// parsed back out; Codex has no such structured mode for `exec`, so it
    /// keeps `-o <file>` for a clean answer and reports usage via its own
    /// plain-text "tokens used" summary line on stdout.
    /// `resumeToken`, when set, continues that provider's own conversation
    /// for this chat thread instead of starting fresh — each CLI's actual
    /// session id (Claude/Codex) or "latest" (Gemini has no id to give back).
    /// Verified directly: `claude -p --resume <id>` and
    /// `codex exec resume <id> <prompt>` both recall prior turns correctly.
    private static func args(for provider: AIProvider, prompt: String, model: String,
                              outputFile: URL?, resumeToken: String?) -> [String] {
        switch provider {
        case .claude:
            var a = ["-p", prompt, "--output-format", "json", "--restricted"]
            if !model.isEmpty { a += ["--model", model] }
            if let resumeToken { a += ["--resume", resumeToken] }
            return a
        case .codex:
            var a = ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--color", "never",
                     "-o", outputFile!.path]
            if !model.isEmpty { a += ["-m", model] }
            if let resumeToken {
                a += ["resume", resumeToken, prompt]
            } else {
                a.append(prompt)
            }
            return a
        case .gemini:
            // Gemini refuses to run headlessly in a folder it hasn't been told to
            // trust ("Approval mode overridden... folder is not trusted"). Safe to
            // skip that prompt here since --approval-mode plan already keeps this
            // read-only — there's no edit/exec capability to gate behind trust.
            var a = ["-p", prompt, "--output-format", "json", "--approval-mode", "plan", "--skip-trust"]
            if !model.isEmpty { a += ["-m", model] }
            // Gemini's --resume takes "latest" or an index, not an opaque id —
            // there's nothing else to key off since it never hands one back.
            if resumeToken != nil { a += ["--resume", "latest"] }
            return a
        case .opencode:
            // "plan" is the least-permissive built-in agent (denies file edits) —
            // OpenCode has no single "disable everything but chat" flag the way
            // Claude's --restricted or Codex's --sandbox read-only do.
            var a = ["run", prompt, "--agent", "plan", "--format", "json"]
            if !model.isEmpty { a += ["-m", model] }
            if let resumeToken { a += ["-s", resumeToken] }
            return a
        }
    }

    /// Claude's `--output-format json` envelope: top-level `result` (the
    /// answer text), `usage.{input,output}_tokens` (+ cache fields, folded
    /// into "input"), `total_cost_usd`, `duration_ms`, and a `modelUsage`
    /// dict keyed by model id with that model's `contextWindow`. Verified
    /// directly against a real `claude -p ... --output-format json` run.
    private static func parseClaudeJSON(_ text: String) -> (text: String, usage: AIUsageStats, sessionID: String?)? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let resultText = (obj["result"] as? String) ?? text
        var usage = AIUsageStats()
        if let u = obj["usage"] as? [String: Any] {
            let input = (u["input_tokens"] as? Int ?? 0)
                + (u["cache_read_input_tokens"] as? Int ?? 0)
                + (u["cache_creation_input_tokens"] as? Int ?? 0)
            usage.inputTokens = input
            usage.outputTokens = u["output_tokens"] as? Int
        }
        usage.costUSD = obj["total_cost_usd"] as? Double
        usage.durationMs = obj["duration_ms"] as? Int
        if let modelUsage = obj["modelUsage"] as? [String: Any] {
            for (_, v) in modelUsage {
                if let entry = v as? [String: Any], let window = entry["contextWindow"] as? Int {
                    usage.contextWindow = window
                    break
                }
            }
        }
        let isError = (obj["is_error"] as? Bool) ?? false
        return isError ? nil : (resultText, usage, obj["session_id"] as? String)
    }

    /// Gemini's `--output-format json` is unverified here (not installed on
    /// this machine to test against) — best-effort parse of the shapes a
    /// Gemini-API-backed CLI would plausibly use. Falls back to `nil` (never
    /// fabricates numbers) if none of these match; the raw text is still
    /// used as the answer regardless via the caller's fallback path.
    private static func parseGeminiJSON(_ text: String) -> (text: String, usage: AIUsageStats)? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let resultText = (obj["response"] as? String) ?? (obj["text"] as? String) ?? (obj["result"] as? String)
        guard let resultText else { return nil }
        var usage = AIUsageStats()
        if let u = (obj["usageMetadata"] as? [String: Any]) ?? (obj["usage"] as? [String: Any]) {
            usage.inputTokens = (u["promptTokenCount"] as? Int) ?? (u["input_tokens"] as? Int)
            usage.outputTokens = (u["candidatesTokenCount"] as? Int) ?? (u["output_tokens"] as? Int)
            usage.totalTokens = u["totalTokenCount"] as? Int
        }
        return (resultText, usage)
    }

    enum OpenCodeParseResult {
        case success(text: String, usage: AIUsageStats, sessionID: String?)
        case apiError(String)
        case unrecognized
    }

    /// `opencode run --format json` prints one JSON object per line (NDJSON
    /// event stream), not a single result object — verified directly against
    /// real `opencode run`/`opencode run -s <id>` round trips (confirmed
    /// session resume actually recalls prior turns). Relevant event shapes:
    /// `{"type":"text","sessionID":...,"part":{"text":"..."}}`,
    /// `{"type":"step_finish","sessionID":...,"part":{"tokens":{"input":n,"output":n},"cost":n}}`,
    /// `{"type":"error","sessionID":...,"error":{"data":{"message":"..."}}}`.
    private static func parseOpenCodeStream(_ text: String) -> OpenCodeParseResult {
        var textParts: [String] = []
        var usage = AIUsageStats()
        var sessionID: String?
        var sawEvent = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            sawEvent = true
            if let sid = obj["sessionID"] as? String { sessionID = sid }
            switch obj["type"] as? String {
            case "text":
                if let part = obj["part"] as? [String: Any], let t = part["text"] as? String { textParts.append(t) }
            case "step_finish":
                if let part = obj["part"] as? [String: Any] {
                    if let tokens = part["tokens"] as? [String: Any] {
                        usage.inputTokens = tokens["input"] as? Int
                        usage.outputTokens = tokens["output"] as? Int
                    }
                    usage.costUSD = part["cost"] as? Double
                }
            case "error":
                if let err = obj["error"] as? [String: Any],
                   let errData = err["data"] as? [String: Any],
                   let message = errData["message"] as? String {
                    return .apiError(message)
                }
                return .apiError("OpenCode reported an error")
            default:
                break
            }
        }
        guard sawEvent else { return .unrecognized }
        let joined = textParts.joined()
        return joined.isEmpty ? .unrecognized : .success(text: joined, usage: usage, sessionID: sessionID)
    }

    /// Codex `exec` (non-JSON) prints a trailing "tokens used\n<number>"
    /// summary on **stderr** (verified with stdout/stderr captured
    /// separately — stdout never had it) — a combined figure, not split
    /// input/output.
    private static func parseCodexTokenCount(fromStderr stderr: String) -> Int? {
        let lines = stderr.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "tokens used" }),
              idx + 1 < lines.count else { return nil }
        let numberText = lines[idx + 1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        // Codex prints this as a "K tokens" style decimal (e.g. "7.996" ~= 7,996 tokens).
        guard let value = Double(numberText) else { return nil }
        return Int((value * 1000).rounded())
    }

    /// Codex `exec` prints "session id: <uuid>" as part of its startup banner
    /// on **stderr**, not stdout (verified directly: `codex exec ... >out 2>err`
    /// — the line only ever showed up in `err`). That id is what
    /// `codex exec resume <id> <prompt>` expects. Checking stdout too as a
    /// harmless fallback in case a future version moves it.
    private static func parseCodexSessionID(fromStreams streams: [String]) -> String? {
        for stream in streams {
            for line in stream.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("session id:") {
                    return trimmed.dropFirst("session id:".count).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    struct AIAskAnswer { var text: String; var usage: AIUsageStats?; var sessionToken: String? }

    static func ask(_ provider: AIProvider, prompt: String, model: String = "",
                     cliPath: String? = nil, extraEnv: [String: String] = [:],
                     resumeToken: String? = nil,
                     handle: AIAskHandle? = nil) async -> Result<AIAskAnswer, AIAssistantError> {
        let bin: String
        if let cliPath, !cliPath.isEmpty {
            bin = cliPath
        } else if let found = binaryPath(for: provider) {
            bin = found
        } else {
            return .failure(AIAssistantError(message: String(format: t("AskAI.NotInstalled"), provider.displayName)))
        }
        // Only codex has a "final message to file" flag; the others print
        // clean plain text straight to stdout in non-interactive mode.
        let outputFile = provider == .codex
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("askai-\(UUID().uuidString).txt")
            : nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args(for: provider, prompt: prompt, model: model, outputFile: outputFile, resumeToken: resumeToken)
        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in extraEnv { env[key] = value }
            process.environment = env
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        handle?.process = process

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                defer { if let outputFile { try? FileManager.default.removeItem(at: outputFile) } }
                // ponytail: reads the whole pipe in one shot after exit, which can
                // deadlock if a response is large enough to fill the OS pipe buffer
                // before the process exits. Fine for a short Q&A answer; switch to
                // an incremental readabilityHandler if responses grow past ~64KB.
                let outText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if let outputFile, proc.terminationStatus == 0,
                   let fileText = try? String(contentsOf: outputFile, encoding: .utf8) {
                    let trimmed = fileText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        var usage = AIUsageStats()
                        usage.totalTokens = parseCodexTokenCount(fromStderr: errText)
                        let sessionID = parseCodexSessionID(fromStreams: [errText, outText])
                        continuation.resume(returning: .success(AIAskAnswer(text: trimmed, usage: usage, sessionToken: sessionID)))
                        return
                    }
                }
                if proc.terminationStatus == 0, !outText.isEmpty {
                    switch provider {
                    case .claude:
                        if let parsed = parseClaudeJSON(outText) {
                            continuation.resume(returning: .success(
                                AIAskAnswer(text: parsed.text, usage: parsed.usage, sessionToken: parsed.sessionID)))
                        } else {
                            // Unexpected shape (e.g. a future CLI version) — still
                            // surface *something* rather than fail silently.
                            continuation.resume(returning: .success(AIAskAnswer(text: outText, usage: nil, sessionToken: nil)))
                        }
                    case .gemini:
                        // No id comes back from Gemini to store — a successful
                        // reply just means "resumable", so the token here is a
                        // marker to add `--resume latest` next turn.
                        if let parsed = parseGeminiJSON(outText) {
                            continuation.resume(returning: .success(AIAskAnswer(text: parsed.text, usage: parsed.usage, sessionToken: "latest")))
                        } else {
                            continuation.resume(returning: .success(AIAskAnswer(text: outText, usage: nil, sessionToken: "latest")))
                        }
                    case .codex:
                        let sessionID = parseCodexSessionID(fromStreams: [errText, outText])
                        continuation.resume(returning: .success(AIAskAnswer(text: outText, usage: nil, sessionToken: sessionID)))
                    case .opencode:
                        // OpenCode can exit 0 with an "error" event in the stream
                        // (e.g. an invalid API key for whichever provider/model was
                        // picked) — that has to surface as a failure, not a "success"
                        // whose answer is a raw JSON error blob.
                        switch parseOpenCodeStream(outText) {
                        case .success(let text, let usage, let sessionID):
                            continuation.resume(returning: .success(AIAskAnswer(text: text, usage: usage, sessionToken: sessionID)))
                        case .apiError(let message):
                            continuation.resume(returning: .failure(AIAssistantError(message: message)))
                        case .unrecognized:
                            continuation.resume(returning: .success(AIAskAnswer(text: outText, usage: nil, sessionToken: nil)))
                        }
                    }
                } else {
                    continuation.resume(returning: .failure(AIAssistantError(message: errText.isEmpty ? outText : errText)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: .failure(AIAssistantError(message: error.localizedDescription)))
            }
        }
    }
}

/// Auto-discovers a provider's available models by reading a CLI's OWN
/// locally cached catalog file — never a network call, never guessed.
/// Confirmed only for Codex, which maintains `~/.codex/models_cache.json`
/// (refreshed by the CLI itself on login/use); Claude and Gemini have no
/// equivalent file on this machine, so they report "unavailable" rather
/// than fabricating a list.
enum AIModelDiscovery {
    struct Unsupported: Error { let message: String }

    static func discover(for provider: AIProvider) -> Result<[AIModelEntry], Unsupported> {
        switch provider {
        case .codex:
            return discoverCodex()
        case .opencode:
            return discoverOpenCode()
        case .claude, .gemini:
            return .failure(Unsupported(message: t("Settings.AIDiscoveryUnsupported")))
        }
    }

    private static func discoverCodex() -> Result<[AIModelEntry], Unsupported> {
        let unsupported = Unsupported(message: t("Settings.AIDiscoveryUnsupported"))
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else {
            return .failure(unsupported)
        }
        // "hide" entries are internal/reserved models (e.g. background
        // review agents) not meant to be picked by a user directly.
        let entries = models.compactMap { m -> AIModelEntry? in
            guard (m["visibility"] as? String) == "list", let slug = m["slug"] as? String else { return nil }
            return AIModelEntry(modelID: slug, alias: (m["display_name"] as? String) ?? slug)
        }
        return entries.isEmpty ? .failure(unsupported) : .success(entries)
    }

    /// `opencode models` is a genuine live command (unlike Codex's cache
    /// file) — one "provider/model" id per line, plain text, already in the
    /// exact format `opencode run -m` expects. Verified directly.
    private static func discoverOpenCode() -> Result<[AIModelEntry], Unsupported> {
        let unsupported = Unsupported(message: t("Settings.AIDiscoveryUnsupported"))
        guard let bin = AIAssistant.binaryPath(for: .opencode) else { return .failure(unsupported) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["models"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return .failure(unsupported)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return .failure(unsupported)
        }
        let entries = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("/") }
            .map { AIModelEntry(modelID: $0, alias: $0) }
        return entries.isEmpty ? .failure(unsupported) : .success(entries)
    }
}
