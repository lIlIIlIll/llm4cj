package llm4cj

import std.collection.*
import std.deriving.Derive

@Derive[Equatable]
public enum LlmWireRequestStyle { OpenAiResponses | OpenAiChat | AnthropicMessages | DeepSeekResponses | DeepSeekChat | DeepSeekMessages }
@Derive[Equatable]
public enum LlmWireOutputTokenField { MaxOutputTokens | MaxCompletionTokens | MaxTokens }
@Derive[Equatable]
public enum LlmWireStructuredOutputMode { Text | JsonObject | JsonSchema }
@Derive[Equatable]
public enum LlmWireParallelToolStyle { Unsupported | OpenAiTopLevel | AnthropicToolChoice }
@Derive[Equatable]
public enum LlmWirePromptCacheStyle { Unsupported | OpenAi | Anthropic | ProviderAutomatic }
@Derive[Equatable]
public enum LlmWireRequirementState { Satisfied | Unsatisfied(String) | Unknown(String) }

public class LlmWireHeader {
    public let name: String
    public let value: String
    public init(name: String, value: String) {
        if (!validHeaderName(name.trimAscii()) || value.contains("\r") || value.contains("\n") || containsHeaderControl(value)) {
            throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.header_invalid", "header name and value must be safe single-line values")
        }
        this.name = name.trimAscii().toAsciiLower()
        this.value = value.trimAscii()
    }
}

func validHeaderName(value: String): Bool {
    let bytes = value.toArray(); if (bytes.isEmpty()) { return false }
    for (byte in bytes) {
        let alphaNumeric = (byte >= 48u8 && byte <= 57u8) || (byte >= 65u8 && byte <= 90u8) || (byte >= 97u8 && byte <= 122u8)
        let punctuation = byte == 33u8 || byte == 35u8 || byte == 36u8 || byte == 37u8 || byte == 38u8 || byte == 39u8 || byte == 42u8 || byte == 43u8 || byte == 45u8 || byte == 46u8 || byte == 94u8 || byte == 95u8 || byte == 96u8 || byte == 124u8 || byte == 126u8
        if (!alphaNumeric && !punctuation) { return false }
    }
    true
}

func containsHeaderControl(value: String): Bool {
    for (byte in value.toArray()) { if (byte < 32u8 && byte != 9u8 || byte == 127u8) { return true } }
    false
}

public class LlmWireFeatureRequirement {
    public let featureId: String
    public let state: LlmWireRequirementState
    public init(featureId: String, state: LlmWireRequirementState) { this.featureId = featureId; this.state = state }
}

public interface LlmWireRequirementResolver { func resolve(requirement: LlmWireFeatureRequirement): LlmWireRequirementState }

public class LlmWireEncodedRequest {
    public let body: String
    public let requiredHeaders: Array<LlmWireHeader>
    public let featureRequirements: Array<LlmWireFeatureRequirement>
    public init(body: String, requiredHeaders!: Array<LlmWireHeader> = [], featureRequirements!: Array<LlmWireFeatureRequirement> = []) {
        this.body = body; this.requiredHeaders = requiredHeaders; this.featureRequirements = featureRequirements
    }
    // Inspection helpers; transport adapters must still consume the full plan.
    public func contains(fragment: String): Bool { body.contains(fragment) }
    public func indexOf(fragment: String): ?Int64 { body.indexOf(fragment) }
    public func validateForSend(resolver: LlmWireRequirementResolver): Unit {
        for (requirement in featureRequirements) {
            let state = match (requirement.state) { case LlmWireRequirementState.Unknown(_) => resolver.resolve(requirement); case value => value }
            match (state) {
                case LlmWireRequirementState.Satisfied => ()
                case LlmWireRequirementState.Unsatisfied(message) => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.feature_requirement_unsatisfied", message)
                case LlmWireRequirementState.Unknown(message) => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.feature_requirement_unresolved", message)
            }
        }
    }
    public func mergeHeaders(userHeaders: Array<LlmWireHeader>): Array<LlmWireHeader> {
        let output = ArrayList<LlmWireHeader>()
        for (required in requiredHeaders) { mergeOneHeader(output, required) }
        for (provided in userHeaders) { mergeOneHeader(output, provided) }
        output.toArray()
    }
}

func mergeOneHeader(output: ArrayList<LlmWireHeader>, value: LlmWireHeader): Unit {
    for (index in 0..output.size) {
        if (output[index].name == value.name) {
            if (value.name == "anthropic-beta") { output[index] = LlmWireHeader(value.name, mergeBetaTokens(output[index].value, value.value)); return }
            if (output[index].value != value.value) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.required_header_conflict", "caller header conflicts with an encoded request requirement: " + value.name) }
            return
        }
    }
    output.add(value)
}

func mergeBetaTokens(left: String, right: String): String {
    let tokens = ArrayList<String>()
    for (source in [left, right]) { for (raw in source.split(",")) {
        let token = raw.trimAscii(); if (token == "") { continue }
        var found = false; for (current in tokens where current == token) { found = true }
        if (!found) { tokens.add(token) }
    } }
    let result = StringBuilder()
    for (index in 0..tokens.size) { if (index > 0) { result.append(",") }; result.append(tokens[index]) }
    result.toString()
}

public class LlmWireDialectContract {
    public let compatibilityId: String
    public let protocol: LlmWireProtocol
    public let requestStyle: LlmWireRequestStyle
    public let outputTokenField: LlmWireOutputTokenField
    public let requireMaxOutputTokens: Bool
    public let thinkingControls: Array<LlmWireThinkingControl>
    public let thinkingLevels: Array<LlmWireThinkingLevel>
    public let structuredOutputModes: Array<LlmWireStructuredOutputMode>
    public let serviceTiers: Array<LlmWireServiceTier>
    public let generationSpeeds: Array<LlmWireGenerationSpeed>
    public let promptCacheStyle: LlmWirePromptCacheStyle
    public let promptCacheLifetimes: Array<LlmWirePromptCacheLifetime>
    public let promptCacheRoutingKey: Bool
    public let parallelToolStyle: LlmWireParallelToolStyle
    public let tools: Bool
    public init(
        compatibilityId: String, protocol: LlmWireProtocol, requestStyle: LlmWireRequestStyle, outputTokenField: LlmWireOutputTokenField,
        requireMaxOutputTokens!: Bool = false, thinkingControls!: Array<LlmWireThinkingControl> = [LlmWireThinkingControl.ProviderDefault],
        thinkingLevels!: Array<LlmWireThinkingLevel> = [], structuredOutputModes!: Array<LlmWireStructuredOutputMode> = [],
        serviceTiers!: Array<LlmWireServiceTier> = [], generationSpeeds!: Array<LlmWireGenerationSpeed> = [],
        promptCacheStyle!: LlmWirePromptCacheStyle = LlmWirePromptCacheStyle.Unsupported,
        promptCacheLifetimes!: Array<LlmWirePromptCacheLifetime> = [], promptCacheRoutingKey!: Bool = false,
        parallelToolStyle!: LlmWireParallelToolStyle = LlmWireParallelToolStyle.Unsupported, tools!: Bool = true
    ) {
        if (compatibilityId == "") { throw IllegalArgumentException("dialect compatibility ID must not be empty") }
        validateContractShape(protocol, requestStyle, outputTokenField, promptCacheStyle, parallelToolStyle)
        this.compatibilityId = compatibilityId; this.protocol = protocol; this.requestStyle = requestStyle; this.outputTokenField = outputTokenField
        this.requireMaxOutputTokens = requireMaxOutputTokens; this.thinkingControls = thinkingControls; this.thinkingLevels = thinkingLevels
        this.structuredOutputModes = structuredOutputModes; this.serviceTiers = serviceTiers; this.generationSpeeds = generationSpeeds
        this.promptCacheStyle = promptCacheStyle; this.promptCacheLifetimes = promptCacheLifetimes; this.promptCacheRoutingKey = promptCacheRoutingKey
        this.parallelToolStyle = parallelToolStyle; this.tools = tools
    }
}

public class LlmWireCapabilities {
    public let thinkingControls: Array<LlmWireThinkingControl>
    public let thinkingLevels: Array<LlmWireThinkingLevel>
    public let structuredOutputModes: Array<LlmWireStructuredOutputMode>
    public let serviceTiers: Array<LlmWireServiceTier>
    public let generationSpeeds: Array<LlmWireGenerationSpeed>
    public let promptCacheLifetimes: Array<LlmWirePromptCacheLifetime>
    public let tools: Bool
    public let parallelToolCalls: Bool
    public let nativeExplicitCacheBreakpoints: Bool
    public init(
        thinkingControls!: Array<LlmWireThinkingControl> = [], thinkingLevels!: Array<LlmWireThinkingLevel> = [],
        structuredOutputModes!: Array<LlmWireStructuredOutputMode> = [], serviceTiers!: Array<LlmWireServiceTier> = [],
        generationSpeeds!: Array<LlmWireGenerationSpeed> = [], promptCacheLifetimes!: Array<LlmWirePromptCacheLifetime> = [],
        tools!: Bool = false, parallelToolCalls!: Bool = false, nativeExplicitCacheBreakpoints!: Bool = false
    ) {
        this.thinkingControls = thinkingControls; this.thinkingLevels = thinkingLevels; this.structuredOutputModes = structuredOutputModes
        this.serviceTiers = serviceTiers; this.generationSpeeds = generationSpeeds; this.promptCacheLifetimes = promptCacheLifetimes
        this.tools = tools; this.parallelToolCalls = parallelToolCalls; this.nativeExplicitCacheBreakpoints = nativeExplicitCacheBreakpoints
    }
}

public interface LlmWireDialect { prop contract: LlmWireDialectContract; prop compatibilityId: String; prop protocol: LlmWireProtocol }

@Derive[Equatable]
public enum LlmWireBuiltinDialect { OpenAiResponses | OpenAiChat | AnthropicMessages | DeepSeekResponses | DeepSeekChat | DeepSeekMessages }

public class LlmWireStandardDialect <: LlmWireDialect {
    private let value: LlmWireDialectContract
    public init(contract: LlmWireDialectContract) { this.value = contract }
    public prop contract: LlmWireDialectContract { get() { value } }
    public prop compatibilityId: String { get() { value.compatibilityId } }
    public prop protocol: LlmWireProtocol { get() { value.protocol } }
}

public class LlmWireCodec {
    public let protocol: LlmWireProtocol
    public let dialect: LlmWireDialect
    public let capabilities: LlmWireCapabilities
    public let provider: String
    public init(protocol: LlmWireProtocol, dialect: LlmWireDialect, capabilities!: LlmWireCapabilities = LlmWireCapabilities(), provider!: String = "") {
        if (protocol != dialect.protocol || protocol != dialect.contract.protocol) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.dialect_protocol_mismatch", "dialect protocol does not match codec protocol") }
        if (dialect.compatibilityId != dialect.contract.compatibilityId) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.dialect_identity_mismatch", "dialect identity does not match its contract") }
        this.protocol = protocol; this.dialect = dialect; this.capabilities = capabilities; this.provider = provider
    }
    public func encodeRequest(request: LlmWireRequest): LlmWireEncodedRequest { validateWireRequest(this, request); encodeWireRequest(this, request) }
    public func decodeResponse(source: String): LlmWireResponseState { decodeWireResponse(this, source) }
    public func newStreamDecoder(limits!: LlmWireStreamLimits = LlmWireStreamLimits()): LlmWireStreamDecoder { newWireStreamDecoder(this, limits) }
}

func validateContractShape(protocol: LlmWireProtocol, style: LlmWireRequestStyle, tokenField: LlmWireOutputTokenField, cacheStyle: LlmWirePromptCacheStyle, parallelStyle: LlmWireParallelToolStyle): Unit {
    let valid = match (style) {
        case LlmWireRequestStyle.OpenAiResponses | LlmWireRequestStyle.DeepSeekResponses => protocol == LlmWireProtocol.Responses && tokenField == LlmWireOutputTokenField.MaxOutputTokens
        case LlmWireRequestStyle.OpenAiChat => protocol == LlmWireProtocol.ChatCompletions && tokenField == LlmWireOutputTokenField.MaxCompletionTokens
        case LlmWireRequestStyle.DeepSeekChat => protocol == LlmWireProtocol.ChatCompletions && tokenField == LlmWireOutputTokenField.MaxTokens
        case LlmWireRequestStyle.AnthropicMessages | LlmWireRequestStyle.DeepSeekMessages => protocol == LlmWireProtocol.Messages && tokenField == LlmWireOutputTokenField.MaxTokens
    }
    if (!valid) { throw IllegalArgumentException("dialect protocol, request style, and output token field are inconsistent") }
    if (parallelStyle == LlmWireParallelToolStyle.AnthropicToolChoice && protocol != LlmWireProtocol.Messages) { throw IllegalArgumentException("Anthropic tool choice requires Messages") }
    if (cacheStyle == LlmWirePromptCacheStyle.Anthropic && protocol != LlmWireProtocol.Messages) { throw IllegalArgumentException("Anthropic prompt cache requires Messages") }
}

public func openAiResponsesDialect(): LlmWireDialect { LlmWireStandardDialect(builtinContract(LlmWireBuiltinDialect.OpenAiResponses)) }
public func openAiChatDialect(): LlmWireDialect { LlmWireStandardDialect(builtinContract(LlmWireBuiltinDialect.OpenAiChat)) }
public func anthropicMessagesDialect(): LlmWireDialect { LlmWireStandardDialect(builtinContract(LlmWireBuiltinDialect.AnthropicMessages)) }
public func deepSeekResponsesDialect(): LlmWireDialect { LlmWireStandardDialect(builtinContract(LlmWireBuiltinDialect.DeepSeekResponses)) }
public func deepSeekChatDialect(): LlmWireDialect { LlmWireStandardDialect(builtinContract(LlmWireBuiltinDialect.DeepSeekChat)) }
public func deepSeekMessagesDialect(): LlmWireDialect { LlmWireStandardDialect(builtinContract(LlmWireBuiltinDialect.DeepSeekMessages)) }

func builtinContract(value: LlmWireBuiltinDialect): LlmWireDialectContract {
    let levels = [LlmWireThinkingLevel.Minimal, LlmWireThinkingLevel.Low, LlmWireThinkingLevel.Medium, LlmWireThinkingLevel.High, LlmWireThinkingLevel.XHigh, LlmWireThinkingLevel.Max]
    match (value) {
        case LlmWireBuiltinDialect.OpenAiResponses => LlmWireDialectContract("openai.responses.v1", LlmWireProtocol.Responses, LlmWireRequestStyle.OpenAiResponses, LlmWireOutputTokenField.MaxOutputTokens, thinkingControls: [LlmWireThinkingControl.ProviderDefault, LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium)], thinkingLevels: levels, structuredOutputModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject, LlmWireStructuredOutputMode.JsonSchema], serviceTiers: [LlmWireServiceTier.Auto, LlmWireServiceTier.Default, LlmWireServiceTier.Flex, LlmWireServiceTier.Priority, LlmWireServiceTier.Fast, LlmWireServiceTier.Ultrafast], promptCacheStyle: LlmWirePromptCacheStyle.OpenAi, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.TwentyFourHours], promptCacheRoutingKey: true, parallelToolStyle: LlmWireParallelToolStyle.OpenAiTopLevel)
        case LlmWireBuiltinDialect.OpenAiChat => LlmWireDialectContract("openai.chat.v1", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens, thinkingControls: [LlmWireThinkingControl.ProviderDefault, LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Enabled, LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium)], thinkingLevels: levels, structuredOutputModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject, LlmWireStructuredOutputMode.JsonSchema], serviceTiers: [LlmWireServiceTier.Auto, LlmWireServiceTier.Default, LlmWireServiceTier.Flex, LlmWireServiceTier.Priority, LlmWireServiceTier.Fast, LlmWireServiceTier.Ultrafast], promptCacheStyle: LlmWirePromptCacheStyle.OpenAi, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.TwentyFourHours], promptCacheRoutingKey: true, parallelToolStyle: LlmWireParallelToolStyle.OpenAiTopLevel)
        case LlmWireBuiltinDialect.AnthropicMessages => LlmWireDialectContract("anthropic.messages.v1", LlmWireProtocol.Messages, LlmWireRequestStyle.AnthropicMessages, LlmWireOutputTokenField.MaxTokens, requireMaxOutputTokens: true, thinkingControls: [LlmWireThinkingControl.ProviderDefault, LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Budget(1024), LlmWireThinkingControl.Adaptive(None)], thinkingLevels: levels, structuredOutputModes: [LlmWireStructuredOutputMode.JsonSchema], serviceTiers: [LlmWireServiceTier.Auto, LlmWireServiceTier.StandardOnly], generationSpeeds: [LlmWireGenerationSpeed.Standard, LlmWireGenerationSpeed.Fast], parallelToolStyle: LlmWireParallelToolStyle.AnthropicToolChoice)
        case LlmWireBuiltinDialect.DeepSeekResponses => LlmWireDialectContract("deepseek.responses.v1", LlmWireProtocol.Responses, LlmWireRequestStyle.DeepSeekResponses, LlmWireOutputTokenField.MaxOutputTokens, thinkingControls: [LlmWireThinkingControl.ProviderDefault, LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Enabled, LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium)], thinkingLevels: levels, structuredOutputModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject, LlmWireStructuredOutputMode.JsonSchema], promptCacheStyle: LlmWirePromptCacheStyle.ProviderAutomatic, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault])
        case LlmWireBuiltinDialect.DeepSeekChat => LlmWireDialectContract("deepseek.chat.v1", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.DeepSeekChat, LlmWireOutputTokenField.MaxTokens, thinkingControls: [LlmWireThinkingControl.ProviderDefault, LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Enabled, LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium)], thinkingLevels: levels, structuredOutputModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject], promptCacheStyle: LlmWirePromptCacheStyle.ProviderAutomatic, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault])
        case LlmWireBuiltinDialect.DeepSeekMessages => LlmWireDialectContract("deepseek.messages.v1", LlmWireProtocol.Messages, LlmWireRequestStyle.DeepSeekMessages, LlmWireOutputTokenField.MaxTokens, requireMaxOutputTokens: true, thinkingControls: [LlmWireThinkingControl.ProviderDefault, LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Enabled, LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium)], thinkingLevels: levels, promptCacheStyle: LlmWirePromptCacheStyle.ProviderAutomatic, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault])
    }
}
