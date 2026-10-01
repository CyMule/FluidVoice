import Foundation

// Shadows Foundation.UserDefaults so the real chat store never accesses app preferences.
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    var writes = 0
    func data(forKey key: String) -> Data? { self.values[key] as? Data }
    func string(forKey key: String) -> String? { self.values[key] as? String }
    func set(_ value: Any?, forKey key: String) { self.values[key] = value; self.writes += 1 }
}

@MainActor final class TerminalService {
    struct CommandResult: Codable {
        let success: Bool
        let command: String
        let output: String
        let error: String?
        let exitCode: Int32
        let executionTimeMs: Int
    }

    static let toolDefinition: [String: Any] = [:]
    static var executed: [String] = []
    static var delay = false
    static var pending: CheckedContinuation<CommandResult, Never>?
    func execute(command: String, workingDirectory: String?) async -> CommandResult {
        Self.executed.append(command)
        if Self.delay {
            return await withCheckedContinuation { Self.pending = $0 }
        }
        return Self.result(command)
    }

    static func result(_ command: String) -> CommandResult {
        .init(success: true, command: command, output: "fake output", error: nil, exitCode: 0, executionTimeMs: 1)
    }
}

@MainActor final class SettingsStore {
    enum Mode { case command }
    struct Provider { let id: String; let baseURL: String }
    struct ReasoningConfig { let isEnabled: Bool; let parameterName: String; let parameterValue: String }
    static let shared = SettingsStore()
    var commandModeConfirmBeforeExecute = false
    let commandModeReadinessIssue: String? = nil
    let effectiveCommandModeProviderID = "fake"
    let effectiveCommandModeSelectedModel = "fake"
    let savedProviders = [Provider(id: "fake", baseURL: "https://fake.invalid")]
    let enableAIStreaming = true
    func analyticsAIModelDescriptor(for mode: Mode) -> String { "fake" }
    func getAPIKey(for provider: String) -> String? { nil }
    func isReasoningModel(_ model: String) -> Bool { false }
    func isTemperatureUnsupported(_ model: String) -> Bool { false }
    func getReasoningConfig(forModel: String, provider: String) -> ReasoningConfig? { nil }
}

@MainActor final class ModelRepository {
    static let shared = ModelRepository()
    func isBuiltIn(_ provider: String) -> Bool { false }
    func defaultBaseURL(for provider: String) -> String { "" }
}

@MainActor final class AnalyticsService {
    static let shared = AnalyticsService()
    func recordUsage(mode: SettingsStore.Mode, aiModel: String) {}
}

@MainActor final class MeetingSummaryActivityCoordinator {
    static let shared = MeetingSummaryActivityCoordinator()
    var active = false
    func beginProcessing() -> UUID? {
        guard !self.active else { return nil }
        self.active = true
        return UUID()
    }

    func endProcessing(_ id: UUID) { self.active = false }
    static var busyErrors = 0
    static func presentBusyError() { self.busyErrors += 1 }
}

@MainActor final class NotificationService {
    static var failures = 0
    static func showCommandModeFailure(error: String) { self.failures += 1 }
}

@MainActor final class DebugLogger {
    static let shared = DebugLogger()
    var errors = 0
    func debug(_ message: String, source: String) {}
    func info(_ message: String, source: String) {}
    func error(_ message: String, source: String) { self.errors += 1 }
}

@MainActor final class NotchOverlayManager {
    static let shared = NotchOverlayManager()
    var shouldSyncCommandConversationToNotch = true
    var canShowExpandedCommandOutput = true
    var shows = 0
    func showExpandedCommandOutput() { self.shows += 1 }
}

@MainActor final class NotchContentState {
    struct CommandOutputMessage: Equatable {
        enum Role { case user, assistant, status }
        let role: Role
        let content: String
    }

    static let shared = NotchContentState()
    var commandConversationHistory: [CommandOutputMessage] = []
    var processing = false
    var streaming = ""
    var nonemptyStreamUpdates = 0
    func clearCommandOutput() { self.commandConversationHistory = [] }
    func refreshRecentChats() {}
    func addCommandMessage(role: CommandOutputMessage.Role, content: String) {
        self.commandConversationHistory.append(.init(role: role, content: content))
    }

    func setCommandProcessing(_ value: Bool) { self.processing = value }
    func updateCommandStreamingText(_ text: String) {
        self.streaming = text
        if !text.isEmpty { self.nonemptyStreamUpdates += 1 }
    }
}

enum LLMError: Error { case invalidRequest(String), invalidResponse }
@MainActor final class LLMClient {
    struct ToolCall {
        let id: String
        let name = "execute_terminal_command"
        let command: String
        func getString(_ key: String) -> String? { key == "command" ? self.command : nil }
        func getOptionalString(_ key: String) -> String? { nil }
    }

    struct Response {
        let content: String
        let thinking: String?
        let toolCalls: [ToolCall]
        static let done = Self(content: "Done", thinking: nil, toolCalls: [])
        static let tool = Self(content: "Run tool", thinking: nil, toolCalls: [.init(id: "tool", command: "fake command")])
    }

    struct Config {
        let messages: [[String: Any]]
        var maxRetries = 0
        var retryDelayMs = 0
        var onThinkingChunk: (@Sendable (String) -> Void)?
        var onContentChunk: (@Sendable (String) -> Void)?
        init(
            messages: [[String: Any]],
            model: String,
            baseURL: String,
            apiKey: String,
            streaming: Bool,
            tools: [[String: Any]],
            temperature: Double?,
            maxTokens: Int?,
            extraParameters: [String: Any]
        ) {
            self.messages = messages
        }
    }

    static let shared = LLMClient()
    var configs: [Config] = []
    var delay = true
    var responses: [Response] = []
    var pending: CheckedContinuation<Response, Error>?
    func call(_ config: Config) async throws -> Response {
        self.configs.append(config)
        if self.delay {
            defer { self.pending = nil }
            return try await withCheckedThrowingContinuation { self.pending = $0 }
        }
        return self.responses.isEmpty ? .done : self.responses.removeFirst()
    }

    func reset() { self.configs = []; self.responses = []; self.delay = true; self.pending = nil }
}

@main @MainActor enum CommandCancellationTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        self.checks += 1
    }

    static func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        preconditionFailure("Timed out awaiting fake dependency")
    }

    static func fixture() -> CommandModeService {
        LLMClient.shared.reset()
        TerminalService.executed = []
        TerminalService.delay = false
        TerminalService.pending = nil
        DebugLogger.shared.errors = 0
        NotificationService.failures = 0
        NotchOverlayManager.shared.shows = 0
        NotchContentState.shared.nonemptyStreamUpdates = 0
        let service = CommandModeService()
        service.clearHistory()
        return service
    }

    static func main() async {
        await self.cancelDelayedLLM(response: .tool)
        await self.cancelDelayedLLM(response: .done)
        await self.cancelDelayedLLMError()
        await self.cancelRunningTerminal(result: TerminalService.result("fake command"))
        await self.cancelRunningTerminal(result: .init(success: false, command: "fake command", output: "partial stdout", error: "actual failure", exitCode: 17, executionTimeMs: 42))
        await self.cancelRenderDelay()
        await self.validRecursiveToolRequestStillWorks()
        await self.invalidRequestDoesNothing()
        self.check(MeetingSummaryActivityCoordinator.busyErrors == 0, "A canceled request left processing locked")
        print("Command cancellation: \(self.checks) checks passed (production agent loop, streaming callbacks, real in-memory chat store)")
    }

    static func cancelDelayedLLM(response: LLMClient.Response) async {
        let service = self.fixture()
        var valid = true
        let task = Task { await service.processUserCommand("voice", notifyInvalidRequest: true, isOutputValid: { valid }) }
        await self.waitFor { LLMClient.shared.pending != nil }
        let messages = service.conversationHistory
        let saved = ChatHistoryStore.shared.currentSession
        let writes = UserDefaults.standard.writes
        let notch = NotchContentState.shared.commandConversationHistory
        valid = false
        // Both callbacks enqueue Tasks; the guards must live inside those Tasks.
        LLMClient.shared.configs[0].onContentChunk?("late content")
        LLMClient.shared.configs[0].onThinkingChunk?("late thinking")
        for _ in 0..<10 {
            await Task.yield()
        }
        self.check(service.streamingText.isEmpty && service.streamingThinkingText.isEmpty, "Canceled stream reached editor")
        self.check(NotchContentState.shared.nonemptyStreamUpdates == 0, "Canceled stream reached notch")
        LLMClient.shared.pending?.resume(returning: response)
        await task.value
        self.check(TerminalService.executed.isEmpty, "Canceled model response executed tool")
        self.check(LLMClient.shared.configs.count == 1, "Canceled response continued agent loop")
        self.check(service.conversationHistory == messages, "Canceled response changed conversation")
        self.check(ChatHistoryStore.shared.currentSession == saved && UserDefaults.standard.writes == writes, "Canceled response persisted chat")
        self.check(NotchContentState.shared.commandConversationHistory == notch && NotchOverlayManager.shared.shows == 0, "Canceled response displayed output")
        self.check(!service.isProcessing && service.currentStep == nil && service.pendingCommand == nil && !NotchContentState.shared.processing, "Canceled request left pending UI")
        self.check(!MeetingSummaryActivityCoordinator.shared.active, "Canceled request left processing lock")
        // Keep the canceled callback false even while the next request succeeds.
        LLMClient.shared.delay = false
        await service.processUserCommand("typed next")
        self.check(service.conversationHistory.last?.content == "Done" && !service.isProcessing, "Next default request failed")
        LLMClient.shared.configs[0].onContentChunk?("stale old callback")
        LLMClient.shared.configs[0].onThinkingChunk?("stale old thinking")
        for _ in 0..<10 {
            await Task.yield()
        }
        self.check(service.streamingText.isEmpty && service.streamingThinkingText.isEmpty, "Old canceled callback contaminated next request")
    }

    static func cancelDelayedLLMError() async {
        let service = self.fixture()
        var valid = true
        let task = Task { await service.processUserCommand("voice error", notifyInvalidRequest: true, isOutputValid: { valid }) }
        await self.waitFor { LLMClient.shared.pending != nil }
        let count = service.conversationHistory.count
        let writes = UserDefaults.standard.writes
        valid = false
        LLMClient.shared.pending?.resume(throwing: LLMError.invalidRequest("fake failure"))
        await task.value
        self.check(service.conversationHistory.count == count && UserDefaults.standard.writes == writes, "Canceled model error mutated chat")
        self.check(DebugLogger.shared.errors == 0 && NotificationService.failures == 0 && NotchOverlayManager.shared.shows == 0, "Canceled model error published failure")
        self.check(!service.isProcessing, "Canceled error left processing flag")
    }

    static func cancelRunningTerminal(result: TerminalService.CommandResult) async {
        let service = self.fixture()
        LLMClient.shared.delay = false
        LLMClient.shared.responses = [.tool]
        TerminalService.delay = true
        var valid = true
        let task = Task { await service.processUserCommand("voice tool", isOutputValid: { valid }) }
        await self.waitFor { TerminalService.pending != nil }
        let messages = service.conversationHistory
        let writes = UserDefaults.standard.writes
        let notch = NotchContentState.shared.commandConversationHistory
        valid = false
        TerminalService.pending?.resume(returning: result)
        await task.value
        self.check(TerminalService.executed.count == 1, "Started terminal operation was duplicated")
        self.check(LLMClient.shared.configs.count == 1, "Canceled terminal result continued loop")
        let completion = service.conversationHistory.last
        self.check(
            service.conversationHistory.count == messages.count + 1 && Array(service.conversationHistory.dropLast()) == messages && completion?.role == .tool,
            "Canceled terminal did not append exactly its actual completion"
        )
        let completionJSON = completion?.content.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        self.check(
            completionJSON?["output"] as? String == result.output && completionJSON?["exitCode"] as? Int32 == result.exitCode && completionJSON?["success"] as? Bool == result.success,
            "Canceled terminal lost actual stdout, exit code, or success"
        )
        self.check(completionJSON?["error"] as? String == result.error && completion?.stepType == (result.success ? .success : .failure), "Canceled terminal lost actual error or result status")
        self.check(
            UserDefaults.standard.writes == writes + 2 && ChatHistoryStore.shared.currentSession?.messages.count == service.conversationHistory.count,
            "Canceled terminal completion was not persisted exactly once"
        )
        self.check(NotchContentState.shared.commandConversationHistory == notch && NotchOverlayManager.shared.shows == 0, "Canceled terminal result displayed output")
        self.check(!service.isProcessing && service.currentStep == nil, "Canceled terminal left pending UI")
        self.check(service.conversationHistory[messages.count - 1].toolCall?.command == "fake command", "Canceled terminal lost already-started execution evidence")
        await service.processUserCommand("next typed request")
        let nextMessages = LLMClient.shared.configs[1].messages
        let nextToolCalls = nextMessages.filter { $0["tool_calls"] != nil }
        let nextToolResults = nextMessages.filter { $0["role"] as? String == "tool" }
        self.check(nextToolCalls.count == 1 && nextToolResults.count == 1 && nextToolResults[0]["tool_call_id"] as? String == "tool", "Next request did not retain a valid completed tool pair")
        self.check(nextToolResults[0]["content"] as? String == completion?.content, "Next request lost the actual executed result")
        self.check(service.conversationHistory.last?.content == "Done" && !service.isProcessing, "Next request after terminal cancellation failed")
    }

    static func cancelRenderDelay() async {
        let service = self.fixture()
        var valid = true
        let task = Task { await service.processUserCommand("voice render", isOutputValid: { valid }) }
        await self.waitFor { LLMClient.shared.pending != nil }
        LLMClient.shared.configs[0].onContentChunk?("live content")
        for _ in 0..<10 {
            await Task.yield()
        }
        LLMClient.shared.pending?.resume(returning: .tool)
        // The fake call has returned and production callLLM published its final buffer,
        // so the real agent is suspended in its existing 50ms rendering sleep.
        await self.waitFor { LLMClient.shared.pending == nil && service.streamingText == "live content" }
        valid = false
        let messages = service.conversationHistory
        let writes = UserDefaults.standard.writes
        await task.value
        self.check(TerminalService.executed.isEmpty && LLMClient.shared.configs.count == 1, "Cancellation during render delay executed a tool")
        self.check(service.conversationHistory == messages && UserDefaults.standard.writes == writes, "Cancellation during render delay mutated chat")
        self.check(!service.isProcessing, "Render-delay cancellation left pending UI")
    }

    static func validRecursiveToolRequestStillWorks() async {
        let service = self.fixture()
        LLMClient.shared.delay = false
        LLMClient.shared.responses = [.tool, .done]
        await service.processUserCommand("valid tool")
        self.check(TerminalService.executed == ["fake command"], "Valid tool failed")
        self.check(LLMClient.shared.configs.count == 2, "Valid tool did not continue agent loop")
        let requestMessages = LLMClient.shared.configs[1].messages
        let assistantCall = requestMessages.first { $0["tool_calls"] != nil }
        let toolResult = requestMessages.first { $0["role"] as? String == "tool" }
        self.check(assistantCall != nil && toolResult?["tool_call_id"] as? String == "tool", "Valid paired tool call lost its wire format")
        self.check(service.conversationHistory.map(\.role) == [.user, .assistant, .tool, .assistant], "Valid conversation lost messages")
        self.check(ChatHistoryStore.shared.currentSession?.messages.count == 4, "Valid request failed to persist")
        self.check(!service.isProcessing && NotchOverlayManager.shared.shows == 1, "Valid request did not finish visibly")
    }

    static func invalidRequestDoesNothing() async {
        let service = self.fixture()
        let messages = service.conversationHistory
        let writes = UserDefaults.standard.writes
        await service.processUserCommand("already canceled", isOutputValid: { false })
        self.check(service.conversationHistory == messages && UserDefaults.standard.writes == writes, "Already canceled request wrote chat")
        self.check(LLMClient.shared.configs.isEmpty && TerminalService.executed.isEmpty && !service.isProcessing, "Already canceled request started work")
    }
}
