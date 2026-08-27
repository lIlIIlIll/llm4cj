package llm4cj

import yjson.*
import std.collection.*
import std.deriving.Derive

public class LlmWireCapabilities {
    public let thinkingDisabled: Bool
    public let thinkingEnabled: Bool
    public let thinkingEffort: Bool
    public let thinkingBudget: Bool
    public let thinkingAdaptive: Bool
    public let thinkingLevels: Array<LlmWireThinkingLevel>
    public let tools: Bool
    public let structuredOutput: Bool
    public let parallelToolCalls: Bool
    public let serviceTier: Bool
    public let stableCache: Bool

    public init(
        thinkingDisabled!: Bool = false,
        thinkingEnabled!: Bool = false,
        thinkingEffort!: Bool = false,
        thinkingBudget!: Bool = false,
        thinkingAdaptive!: Bool = false,
        thinkingLevels!: Array<LlmWireThinkingLevel> = [],
        tools!: Bool = false,
        structuredOutput!: Bool = false,
        parallelToolCalls!: Bool = false,
        serviceTier!: Bool = false,
        stableCache!: Bool = false
    ) {
        this.thinkingDisabled = thinkingDisabled
        this.thinkingEnabled = thinkingEnabled
        this.thinkingEffort = thinkingEffort
        this.thinkingBudget = thinkingBudget
        this.thinkingAdaptive = thinkingAdaptive
        this.thinkingLevels = thinkingLevels
        this.tools = tools
        this.structuredOutput = structuredOutput
        this.parallelToolCalls = parallelToolCalls
        this.serviceTier = serviceTier
        this.stableCache = stableCache
    }
}

public interface LlmWireDialect {
    prop compatibilityId: String
    prop protocol: LlmWireProtocol
    func validateThinking(control: LlmWireThinkingControl, capabilities: LlmWireCapabilities): Unit
    func encodeThinking(control: LlmWireThinkingControl): JsonNode
}

@Derive[Equatable]
public enum LlmWireBuiltinDialect {
    OpenAiResponses | OpenAiChat | AnthropicMessages |
    DeepSeekResponses | DeepSeekChat | DeepSeekMessages
}

public class LlmWireStandardDialect <: LlmWireDialect {
    private let builtin: LlmWireBuiltinDialect
    public init(builtin: LlmWireBuiltinDialect) { this.builtin = builtin }

    public prop compatibilityId: String {
        get() {
            match (builtin) {
                case LlmWireBuiltinDialect.OpenAiResponses => "openai.responses.v1"
                case LlmWireBuiltinDialect.OpenAiChat => "openai.chat.v1"
                case LlmWireBuiltinDialect.AnthropicMessages => "anthropic.messages.v1"
                case LlmWireBuiltinDialect.DeepSeekResponses => "deepseek.responses.v1"
                case LlmWireBuiltinDialect.DeepSeekChat => "deepseek.chat.v1"
                case LlmWireBuiltinDialect.DeepSeekMessages => "deepseek.messages.v1"
            }
        }
    }

    public prop protocol: LlmWireProtocol {
        get() {
            match (builtin) {
                case LlmWireBuiltinDialect.OpenAiResponses | LlmWireBuiltinDialect.DeepSeekResponses => LlmWireProtocol.Responses
                case LlmWireBuiltinDialect.OpenAiChat | LlmWireBuiltinDialect.DeepSeekChat => LlmWireProtocol.ChatCompletions
                case LlmWireBuiltinDialect.AnthropicMessages | LlmWireBuiltinDialect.DeepSeekMessages => LlmWireProtocol.Messages
            }
        }
    }

    public func validateThinking(control: LlmWireThinkingControl, capabilities: LlmWireCapabilities): Unit {
        let supported = match (control) {
            case LlmWireThinkingControl.ProviderDefault => true
            case LlmWireThinkingControl.Disabled => capabilities.thinkingDisabled
            case LlmWireThinkingControl.Enabled => capabilities.thinkingEnabled
            case LlmWireThinkingControl.Effort(level) => capabilities.thinkingEffort && supportsThinkingLevel(capabilities, level)
            case LlmWireThinkingControl.Budget(tokens) => capabilities.thinkingBudget && tokens > 0
            case LlmWireThinkingControl.Adaptive(level) => capabilities.thinkingAdaptive && match (level) { case Some(value) => supportsThinkingLevel(capabilities, value); case None => true }
        }
        if (!supported) {
            throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.thinking_unsupported", "thinking control is not supported by the supplied dialect and capabilities")
        }
        match ((builtin, control)) {
            case (LlmWireBuiltinDialect.OpenAiResponses, LlmWireThinkingControl.Disabled) |
                 (LlmWireBuiltinDialect.OpenAiResponses, LlmWireThinkingControl.Enabled) |
                 (LlmWireBuiltinDialect.OpenAiResponses, LlmWireThinkingControl.Budget(_)) |
                 (LlmWireBuiltinDialect.OpenAiResponses, LlmWireThinkingControl.Adaptive(_)) |
                 (LlmWireBuiltinDialect.OpenAiChat, LlmWireThinkingControl.Budget(_)) |
                 (LlmWireBuiltinDialect.OpenAiChat, LlmWireThinkingControl.Adaptive(_)) |
                 (LlmWireBuiltinDialect.AnthropicMessages, LlmWireThinkingControl.Effort(_)) |
                 (LlmWireBuiltinDialect.DeepSeekResponses, LlmWireThinkingControl.Budget(_)) |
                 (LlmWireBuiltinDialect.DeepSeekResponses, LlmWireThinkingControl.Adaptive(_)) |
                 (LlmWireBuiltinDialect.DeepSeekChat, LlmWireThinkingControl.Budget(_)) |
                 (LlmWireBuiltinDialect.DeepSeekChat, LlmWireThinkingControl.Adaptive(_)) |
                 (LlmWireBuiltinDialect.DeepSeekMessages, LlmWireThinkingControl.Budget(_)) |
                 (LlmWireBuiltinDialect.DeepSeekMessages, LlmWireThinkingControl.Adaptive(_)) =>
                throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.thinking_not_representable", "thinking control cannot be represented by this dialect")
            case _ => ()
        }
    }

    public func encodeThinking(control: LlmWireThinkingControl): JsonNode {
        match (control) {
            case LlmWireThinkingControl.ProviderDefault => wireJsonObject([])
            case _ => wireJsonObject(encodeStandardThinking(builtin, control))
        }
    }
}

public class LlmWireCodec {
    public let protocol: LlmWireProtocol
    public let dialect: LlmWireDialect
    public let capabilities: LlmWireCapabilities
    public let provider: String
    public let validationPolicy: LlmWireValidationPolicy

    public init(
        protocol: LlmWireProtocol,
        dialect: LlmWireDialect,
        capabilities!: LlmWireCapabilities = LlmWireCapabilities(),
        provider!: String = "",
        validationPolicy!: LlmWireValidationPolicy = LlmWireValidationPolicy.Strict
    ) {
        if (protocol != dialect.protocol) {
            throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.dialect_protocol_mismatch", "dialect protocol does not match codec protocol")
        }
        this.protocol = protocol
        this.dialect = dialect
        this.capabilities = capabilities
        this.provider = provider
        this.validationPolicy = validationPolicy
    }

    public func encodeRequest(request: LlmWireRequest): String {
        validateWireRequest(this, request)
        encodeWireRequest(this, request)
    }

    public func decodeResponse(source: String): LlmWireResponseState {
        decodeWireResponse(this, source)
    }

    public func newStreamDecoder(): LlmWireStreamDecoder {
        newWireStreamDecoder(this)
    }
}

public func openAiResponsesDialect(): LlmWireDialect { LlmWireStandardDialect(LlmWireBuiltinDialect.OpenAiResponses) }
public func openAiChatDialect(): LlmWireDialect { LlmWireStandardDialect(LlmWireBuiltinDialect.OpenAiChat) }
public func anthropicMessagesDialect(): LlmWireDialect { LlmWireStandardDialect(LlmWireBuiltinDialect.AnthropicMessages) }
public func deepSeekResponsesDialect(): LlmWireDialect { LlmWireStandardDialect(LlmWireBuiltinDialect.DeepSeekResponses) }
public func deepSeekChatDialect(): LlmWireDialect { LlmWireStandardDialect(LlmWireBuiltinDialect.DeepSeekChat) }
public func deepSeekMessagesDialect(): LlmWireDialect { LlmWireStandardDialect(LlmWireBuiltinDialect.DeepSeekMessages) }

func encodeStandardThinking(builtin: LlmWireBuiltinDialect, control: LlmWireThinkingControl): Array<WireJsonField> {
    match (builtin) {
        case LlmWireBuiltinDialect.OpenAiResponses => match (control) {
            case LlmWireThinkingControl.Effort(level) => [WireJsonField("reasoning", wireJsonObject([WireJsonField("effort", wireJsonString(wireThinkingLevel(level)))]))]
            case _ => []
        }
        case LlmWireBuiltinDialect.DeepSeekResponses => match (control) {
            case LlmWireThinkingControl.Disabled => [WireJsonField("thinking", wireJsonObject([WireJsonField("type", wireJsonString("disabled"))]))]
            case LlmWireThinkingControl.Enabled => [WireJsonField("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled"))]))]
            case LlmWireThinkingControl.Effort(level) => [
                WireJsonField("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled"))])),
                WireJsonField("reasoning", wireJsonObject([WireJsonField("effort", wireJsonString(wireThinkingLevel(level)))]))
            ]
            case _ => []
        }
        case LlmWireBuiltinDialect.OpenAiChat => match (control) {
            case LlmWireThinkingControl.Disabled => [WireJsonField("reasoning_effort", wireJsonString("none"))]
            case LlmWireThinkingControl.Enabled => [WireJsonField("reasoning_effort", wireJsonString("medium"))]
            case LlmWireThinkingControl.Effort(level) => [WireJsonField("reasoning_effort", wireJsonString(wireThinkingLevel(level)))]
            case _ => []
        }
        case LlmWireBuiltinDialect.AnthropicMessages => match (control) {
            case LlmWireThinkingControl.Disabled => [WireJsonField("thinking", wireJsonObject([WireJsonField("type", wireJsonString("disabled"))]))]
            case LlmWireThinkingControl.Enabled => [WireJsonField("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled"))]))]
            case LlmWireThinkingControl.Budget(tokens) => [WireJsonField("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled")), WireJsonField("budget_tokens", wireJsonNumber(tokens.toString()))]))]
            case LlmWireThinkingControl.Adaptive(level) =>
                let result = ArrayList<WireJsonField>()
                result.add(WireJsonField("thinking", wireJsonObject([WireJsonField("type", wireJsonString("adaptive"))])))
                match (level) {
                    case Some(value) => result.add(WireJsonField("output_config", wireJsonObject([WireJsonField("effort", wireJsonString(wireThinkingLevel(value)))])))
                    case None => ()
                }
                result.toArray()
            case _ => []
        }
        case LlmWireBuiltinDialect.DeepSeekChat => match (control) {
            case LlmWireThinkingControl.Disabled => [WireJsonField("thinking", wireJsonObject([WireJsonField("type", wireJsonString("disabled"))]))]
            case LlmWireThinkingControl.Enabled => [WireJsonField("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled"))]))]
            case LlmWireThinkingControl.Effort(level) => [
                WireJsonField("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled"))])),
                WireJsonField("reasoning_effort", wireJsonString(wireThinkingLevel(level)))
            ]
            case _ => []
        }
        case LlmWireBuiltinDialect.DeepSeekMessages => match (control) {
            case LlmWireThinkingControl.Disabled => [WireJsonField("thinking", wireJsonObject([WireJsonField("type", wireJsonString("disabled"))]))]
            case LlmWireThinkingControl.Enabled => [WireJsonField("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled"))]))]
            case LlmWireThinkingControl.Effort(level) => [
                WireJsonField("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled"))])),
                WireJsonField("output_config", wireJsonObject([WireJsonField("effort", wireJsonString(wireThinkingLevel(level)))]))
            ]
            case _ => []
        }
    }
}


func wireThinkingLevel(level: LlmWireThinkingLevel): String {
    match (level) {
        case LlmWireThinkingLevel.Minimal => "minimal"
        case LlmWireThinkingLevel.Low => "low"
        case LlmWireThinkingLevel.Medium => "medium"
        case LlmWireThinkingLevel.High => "high"
        case LlmWireThinkingLevel.XHigh => "xhigh"
        case LlmWireThinkingLevel.Max => "max"
    }
}

func supportsThinkingLevel(capabilities: LlmWireCapabilities, level: LlmWireThinkingLevel): Bool {
    for (value in capabilities.thinkingLevels where value == level) { return true }
    false
}
