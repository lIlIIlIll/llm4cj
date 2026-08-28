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
public enum LlmWireUsageMergeStyle { ReplacePresent | Monotonic | Delta }
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
    private let thinkingControlsValue: Array<LlmWireThinkingControl>
    private let thinkingLevelsValue: Array<LlmWireThinkingLevel>
    private let structuredOutputModesValue: Array<LlmWireStructuredOutputMode>
    private let serviceTiersValue: Array<LlmWireServiceTier>
    private let generationSpeedsValue: Array<LlmWireGenerationSpeed>
    public let promptCacheStyle: LlmWirePromptCacheStyle
    private let promptCacheLifetimesValue: Array<LlmWirePromptCacheLifetime>
    public let promptCacheRoutingKey: Bool
    public let parallelToolStyle: LlmWireParallelToolStyle
    public let tools: Bool
    public let usageMergeStyle: LlmWireUsageMergeStyle
    public init(
        compatibilityId: String, protocol: LlmWireProtocol, requestStyle: LlmWireRequestStyle, outputTokenField: LlmWireOutputTokenField,
        requireMaxOutputTokens!: Bool = false, thinkingControls!: Array<LlmWireThinkingControl> = [LlmWireThinkingControl.ProviderDefault],
        thinkingLevels!: Array<LlmWireThinkingLevel> = [], structuredOutputModes!: Array<LlmWireStructuredOutputMode> = [],
        serviceTiers!: Array<LlmWireServiceTier> = [], generationSpeeds!: Array<LlmWireGenerationSpeed> = [],
        promptCacheStyle!: LlmWirePromptCacheStyle = LlmWirePromptCacheStyle.Unsupported,
        promptCacheLifetimes!: Array<LlmWirePromptCacheLifetime> = [], promptCacheRoutingKey!: Bool = false,
        parallelToolStyle!: LlmWireParallelToolStyle = LlmWireParallelToolStyle.Unsupported, tools!: Bool = true,
        usageMergeStyle!: LlmWireUsageMergeStyle = LlmWireUsageMergeStyle.ReplacePresent
    ) {
        if (!validCompatibilityId(compatibilityId)) { throw IllegalArgumentException("dialect compatibility ID must use 1-128 lowercase ASCII letters, digits, dot, underscore, or hyphen") }
        validateContractShape(
            protocol, requestStyle, outputTokenField, promptCacheStyle, parallelToolStyle,
            thinkingControls, thinkingLevels, structuredOutputModes, serviceTiers, generationSpeeds,
            promptCacheLifetimes, promptCacheRoutingKey
        )
        this.compatibilityId = compatibilityId; this.protocol = protocol; this.requestStyle = requestStyle; this.outputTokenField = outputTokenField
        rejectDuplicateContractValues(thinkingControls, thinkingLevels, structuredOutputModes, serviceTiers, generationSpeeds, promptCacheLifetimes)
        this.requireMaxOutputTokens = requireMaxOutputTokens; this.thinkingControlsValue = copyValues(thinkingControls); this.thinkingLevelsValue = copyValues(thinkingLevels)
        this.structuredOutputModesValue = copyValues(structuredOutputModes); this.serviceTiersValue = copyValues(serviceTiers); this.generationSpeedsValue = copyValues(generationSpeeds)
        this.promptCacheStyle = promptCacheStyle; this.promptCacheLifetimesValue = copyValues(promptCacheLifetimes); this.promptCacheRoutingKey = promptCacheRoutingKey
        this.parallelToolStyle = parallelToolStyle; this.tools = tools; this.usageMergeStyle = usageMergeStyle
    }
    public prop thinkingControls: Array<LlmWireThinkingControl> { get() { copyValues(thinkingControlsValue) } }
    public prop thinkingLevels: Array<LlmWireThinkingLevel> { get() { copyValues(thinkingLevelsValue) } }
    public prop structuredOutputModes: Array<LlmWireStructuredOutputMode> { get() { copyValues(structuredOutputModesValue) } }
    public prop serviceTiers: Array<LlmWireServiceTier> { get() { copyValues(serviceTiersValue) } }
    public prop generationSpeeds: Array<LlmWireGenerationSpeed> { get() { copyValues(generationSpeedsValue) } }
    public prop promptCacheLifetimes: Array<LlmWirePromptCacheLifetime> { get() { copyValues(promptCacheLifetimesValue) } }
}

public class LlmWireCapabilities {
    private let inputModalitiesValue: Array<LlmWireInputModality>
    private let thinkingControlsValue: Array<LlmWireThinkingControl>
    private let thinkingLevelsValue: Array<LlmWireThinkingLevel>
    private let structuredOutputModesValue: Array<LlmWireStructuredOutputMode>
    private let serviceTiersValue: Array<LlmWireServiceTier>
    private let generationSpeedsValue: Array<LlmWireGenerationSpeed>
    private let promptCacheLifetimesValue: Array<LlmWirePromptCacheLifetime>
    public let tools: Bool
    public let parallelToolCalls: Bool
    public let nativeExplicitCacheBreakpoints: Bool
    public init(
        inputModalities!: Array<LlmWireInputModality> = [LlmWireInputModality.Text],
        thinkingControls!: Array<LlmWireThinkingControl> = [], thinkingLevels!: Array<LlmWireThinkingLevel> = [],
        structuredOutputModes!: Array<LlmWireStructuredOutputMode> = [], serviceTiers!: Array<LlmWireServiceTier> = [],
        generationSpeeds!: Array<LlmWireGenerationSpeed> = [], promptCacheLifetimes!: Array<LlmWirePromptCacheLifetime> = [],
        tools!: Bool = false, parallelToolCalls!: Bool = false, nativeExplicitCacheBreakpoints!: Bool = false
    ) {
        if (hasDuplicate(inputModalities)) { throw IllegalArgumentException("capability declarations must not contain duplicate input modalities") }
        rejectDuplicateContractValues(thinkingControls, thinkingLevels, structuredOutputModes, serviceTiers, generationSpeeds, promptCacheLifetimes)
        this.inputModalitiesValue = copyValues(inputModalities)
        this.thinkingControlsValue = copyValues(thinkingControls); this.thinkingLevelsValue = copyValues(thinkingLevels); this.structuredOutputModesValue = copyValues(structuredOutputModes)
        this.serviceTiersValue = copyValues(serviceTiers); this.generationSpeedsValue = copyValues(generationSpeeds); this.promptCacheLifetimesValue = copyValues(promptCacheLifetimes)
        this.tools = tools; this.parallelToolCalls = parallelToolCalls; this.nativeExplicitCacheBreakpoints = nativeExplicitCacheBreakpoints
    }
    public prop inputModalities: Array<LlmWireInputModality> { get() { copyValues(inputModalitiesValue) } }
    public prop thinkingControls: Array<LlmWireThinkingControl> { get() { copyValues(thinkingControlsValue) } }
    public prop thinkingLevels: Array<LlmWireThinkingLevel> { get() { copyValues(thinkingLevelsValue) } }
    public prop structuredOutputModes: Array<LlmWireStructuredOutputMode> { get() { copyValues(structuredOutputModesValue) } }
    public prop serviceTiers: Array<LlmWireServiceTier> { get() { copyValues(serviceTiersValue) } }
    public prop generationSpeeds: Array<LlmWireGenerationSpeed> { get() { copyValues(generationSpeedsValue) } }
    public prop promptCacheLifetimes: Array<LlmWirePromptCacheLifetime> { get() { copyValues(promptCacheLifetimesValue) } }
}

func copyValues<T>(values: Array<T>): Array<T> {
    let output = ArrayList<T>(); for (value in values) { output.add(value) }; output.toArray()
}

func validCompatibilityId(value: String): Bool {
    let bytes = value.toArray(); if (bytes.isEmpty() || bytes.size > 128) { return false }
    for (byte in bytes) {
        let allowed = (byte >= 97u8 && byte <= 122u8) || (byte >= 48u8 && byte <= 57u8) || byte == 46u8 || byte == 95u8 || byte == 45u8
        if (!allowed) { return false }
    }
    true
}

func rejectDuplicateContractValues(
    controls: Array<LlmWireThinkingControl>, levels: Array<LlmWireThinkingLevel>, modes: Array<LlmWireStructuredOutputMode>,
    tiers: Array<LlmWireServiceTier>, speeds: Array<LlmWireGenerationSpeed>, lifetimes: Array<LlmWirePromptCacheLifetime>
): Unit {
    if (hasDuplicate(controls) || hasDuplicate(levels) || hasDuplicate(modes) || hasDuplicate(tiers) || hasDuplicate(speeds) || hasDuplicate(lifetimes)) {
        throw IllegalArgumentException("dialect and capability declarations must not contain duplicate values")
    }
}

func hasDuplicate<T>(values: Array<T>): Bool where T <: Equatable<T> {
    for (left in 0..values.size) { for (right in left + 1..values.size) { if (values[left] == values[right]) { return true } } }; false
}

public interface LlmWireDialect { prop contract: LlmWireDialectContract; prop compatibilityId: String; prop protocol: LlmWireProtocol }

@Derive[Equatable]
public enum LlmWireBuiltinDialect { OpenAiResponses | OpenAiChat | AnthropicMessages | DeepSeekResponses | DeepSeekChat | DeepSeekMessages }

public class LlmWireStandardDialect <: LlmWireDialect {
    private let value: LlmWireDialectContract
    public init(contract: LlmWireDialectContract) {
        if (isBuiltinCompatibilityId(contract.compatibilityId)) {
            throw IllegalArgumentException("built-in compatibility IDs are reserved")
        }
        if (!customDialectThinkingIsReplaySafe(contract)) {
            throw IllegalArgumentException("custom dialects cannot declare provider-native thinking without a replay schema")
        }
        this.value = contract
    }
    public prop contract: LlmWireDialectContract { get() { value } }
    public prop compatibilityId: String { get() { value.compatibilityId } }
    public prop protocol: LlmWireProtocol { get() { value.protocol } }
}

func customDialectThinkingIsReplaySafe(contract: LlmWireDialectContract): Bool {
    if (!contract.thinkingLevels.isEmpty()) { return false }
    for (control in contract.thinkingControls) {
        if (control != LlmWireThinkingControl.ProviderDefault) { return false }
    }
    true
}

class BuiltinWireDialect <: LlmWireDialect {
    private let value: LlmWireDialectContract
    init(contract: LlmWireDialectContract) { this.value = contract }
    public prop contract: LlmWireDialectContract { get() { value } }
    public prop compatibilityId: String { get() { value.compatibilityId } }
    public prop protocol: LlmWireProtocol { get() { value.protocol } }
}

class FrozenWireDialect <: LlmWireDialect {
    private let value: LlmWireDialectContract
    init(contract: LlmWireDialectContract) { this.value = contract }
    public prop contract: LlmWireDialectContract { get() { value } }
    public prop compatibilityId: String { get() { value.compatibilityId } }
    public prop protocol: LlmWireProtocol { get() { value.protocol } }
}

func snapshotDialectContract(value: LlmWireDialectContract): LlmWireDialectContract {
    LlmWireDialectContract(
        value.compatibilityId, value.protocol, value.requestStyle, value.outputTokenField,
        requireMaxOutputTokens: value.requireMaxOutputTokens,
        thinkingControls: value.thinkingControls, thinkingLevels: value.thinkingLevels,
        structuredOutputModes: value.structuredOutputModes, serviceTiers: value.serviceTiers,
        generationSpeeds: value.generationSpeeds, promptCacheStyle: value.promptCacheStyle,
        promptCacheLifetimes: value.promptCacheLifetimes, promptCacheRoutingKey: value.promptCacheRoutingKey,
        parallelToolStyle: value.parallelToolStyle, tools: value.tools, usageMergeStyle: value.usageMergeStyle
    )
}

public class LlmWireCodec {
    public let protocol: LlmWireProtocol
    public let dialect: LlmWireDialect
    public let capabilities: LlmWireCapabilities
    public let provider: String
    public init(protocol: LlmWireProtocol, dialect: LlmWireDialect, capabilities!: LlmWireCapabilities = LlmWireCapabilities(), provider!: String = "") {
        let declaredProtocol = dialect.protocol
        let declaredIdentity = dialect.compatibilityId
        let declaredContract = dialect.contract
        if (protocol != declaredProtocol || protocol != declaredContract.protocol) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.dialect_protocol_mismatch", "dialect protocol does not match codec protocol") }
        if (declaredIdentity != declaredContract.compatibilityId) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.dialect_identity_mismatch", "dialect identity does not match its contract") }
        if (isBuiltinCompatibilityId(declaredIdentity) && !(dialect is BuiltinWireDialect)) {
            throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.dialect_identity_reserved", "built-in compatibility IDs may only be used by built-in dialects")
        }
        if (!isBuiltinCompatibilityId(declaredIdentity) && !customDialectThinkingIsReplaySafe(declaredContract)) {
            throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.dialect_thinking_replay_unsupported", "custom dialect thinking requires a replay schema that v0.2 does not expose")
        }
        let frozen = snapshotDialectContract(declaredContract)
        this.protocol = protocol; this.dialect = FrozenWireDialect(frozen); this.capabilities = capabilities; this.provider = provider
    }
    public func encodeRequest(request: LlmWireRequest): LlmWireEncodedRequest {
        try { validateWireRequest(this, request); encodeWireRequest(this, request) }
        catch (error: LlmTransportError) { throw withCodecContext(error, this, LlmTransportPhase.Encode) }
    }
    public func decodeResponse(source: String): LlmWireResponseState {
        try { decodeWireResponse(this, source) }
        catch (error: LlmTransportError) { throw withCodecContext(error, this, LlmTransportPhase.WireDecode) }
    }
    public func newStreamDecoder(limits!: LlmWireStreamLimits = LlmWireStreamLimits()): LlmWireStreamDecoder { newWireStreamDecoder(this, limits) }
}

func withCodecContext(error: LlmTransportError, codec: LlmWireCodec, defaultPhase: LlmTransportPhase): LlmTransportError {
    LlmTransportError(
        error.kind, error.code, error.message, retryable: error.retryable, httpStatus: error.httpStatus,
        retryAfterMillis: error.retryAfterMillis, provider: if (error.provider == "") { codec.provider } else { error.provider },
        providerErrorCode: error.providerErrorCode, providerErrorType: error.providerErrorType, diagnosticJson: error.diagnosticJson,
        phase: match (error.phase) { case Some(value) => Some(value); case None => Some(defaultPhase) },
        protocol: match (error.protocol) { case Some(value) => Some(value); case None => Some(codec.protocol) },
        dialectId: if (error.dialectId == "") { codec.dialect.compatibilityId } else { error.dialectId },
        eventType: error.eventType, blockIndex: error.blockIndex, toolCallId: error.toolCallId,
        providerRequestId: error.providerRequestId
    )
}

func validateContractShape(
    protocol: LlmWireProtocol, style: LlmWireRequestStyle, tokenField: LlmWireOutputTokenField,
    cacheStyle: LlmWirePromptCacheStyle, parallelStyle: LlmWireParallelToolStyle,
    thinkingControls: Array<LlmWireThinkingControl>, thinkingLevels: Array<LlmWireThinkingLevel>,
    structuredModes: Array<LlmWireStructuredOutputMode>, serviceTiers: Array<LlmWireServiceTier>,
    generationSpeeds: Array<LlmWireGenerationSpeed>, cacheLifetimes: Array<LlmWirePromptCacheLifetime>,
    cacheRoutingKey: Bool
): Unit {
    let valid = match (style) {
        case LlmWireRequestStyle.OpenAiResponses | LlmWireRequestStyle.DeepSeekResponses => protocol == LlmWireProtocol.Responses && tokenField == LlmWireOutputTokenField.MaxOutputTokens
        case LlmWireRequestStyle.OpenAiChat => protocol == LlmWireProtocol.ChatCompletions && tokenField == LlmWireOutputTokenField.MaxCompletionTokens
        case LlmWireRequestStyle.DeepSeekChat => protocol == LlmWireProtocol.ChatCompletions && tokenField == LlmWireOutputTokenField.MaxTokens
        case LlmWireRequestStyle.AnthropicMessages | LlmWireRequestStyle.DeepSeekMessages => protocol == LlmWireProtocol.Messages && tokenField == LlmWireOutputTokenField.MaxTokens
    }
    if (!valid) { throw IllegalArgumentException("dialect protocol, request style, and output token field are inconsistent") }
    let parallelRepresentable = match ((protocol, parallelStyle)) {
        case (_, LlmWireParallelToolStyle.Unsupported) |
             (LlmWireProtocol.Responses, LlmWireParallelToolStyle.OpenAiTopLevel) |
             (LlmWireProtocol.ChatCompletions, LlmWireParallelToolStyle.OpenAiTopLevel) |
             (LlmWireProtocol.Messages, LlmWireParallelToolStyle.AnthropicToolChoice) => true
        case _ => false
    }
    if (!parallelRepresentable) { throw IllegalArgumentException("parallel tool style has no encoding for this protocol") }
    let cacheRepresentable = match ((style, cacheStyle)) {
        case (_, LlmWirePromptCacheStyle.Unsupported) |
             (LlmWireRequestStyle.OpenAiResponses, LlmWirePromptCacheStyle.OpenAi) |
             (LlmWireRequestStyle.OpenAiChat, LlmWirePromptCacheStyle.OpenAi) |
             (LlmWireRequestStyle.AnthropicMessages, LlmWirePromptCacheStyle.Anthropic) |
             (LlmWireRequestStyle.DeepSeekResponses, LlmWirePromptCacheStyle.ProviderAutomatic) |
             (LlmWireRequestStyle.DeepSeekChat, LlmWirePromptCacheStyle.ProviderAutomatic) |
             (LlmWireRequestStyle.DeepSeekMessages, LlmWirePromptCacheStyle.ProviderAutomatic) => true
        case _ => false
    }
    if (!cacheRepresentable) { throw IllegalArgumentException("prompt cache style has no encoding for this request style") }
    if (cacheStyle == LlmWirePromptCacheStyle.Unsupported && !cacheLifetimes.isEmpty()) { throw IllegalArgumentException("unsupported prompt cache cannot declare cache lifetimes") }
    for (lifetime in cacheLifetimes) {
        let representable = match ((cacheStyle, lifetime)) {
            case (LlmWirePromptCacheStyle.OpenAi, LlmWirePromptCacheLifetime.ProviderDefault) |
                 (LlmWirePromptCacheStyle.OpenAi, LlmWirePromptCacheLifetime.ThirtyMinutes) |
                 (LlmWirePromptCacheStyle.Anthropic, LlmWirePromptCacheLifetime.ProviderDefault) |
                 (LlmWirePromptCacheStyle.Anthropic, LlmWirePromptCacheLifetime.FiveMinutes) |
                 (LlmWirePromptCacheStyle.Anthropic, LlmWirePromptCacheLifetime.OneHour) |
                 (LlmWirePromptCacheStyle.ProviderAutomatic, LlmWirePromptCacheLifetime.ProviderDefault) => true
            case _ => false
        }
        if (!representable) { throw IllegalArgumentException("prompt cache lifetime has no encoding for this cache style") }
    }
    if (cacheRoutingKey && style != LlmWireRequestStyle.OpenAiResponses && style != LlmWireRequestStyle.OpenAiChat) { throw IllegalArgumentException("prompt cache routing key has no encoding for this request style") }
    if (!serviceTiers.isEmpty() && style != LlmWireRequestStyle.OpenAiResponses && style != LlmWireRequestStyle.OpenAiChat && style != LlmWireRequestStyle.AnthropicMessages) {
        throw IllegalArgumentException("service tier has no encoding for this request style")
    }
    if (!generationSpeeds.isEmpty() && style != LlmWireRequestStyle.AnthropicMessages) {
        throw IllegalArgumentException("generation speed has no encoding for this request style")
    }
    for (mode in structuredModes) {
        let representable = match ((style, mode)) {
            case (LlmWireRequestStyle.OpenAiResponses, _) | (LlmWireRequestStyle.DeepSeekResponses, _) | (LlmWireRequestStyle.OpenAiChat, _) => true
            case (LlmWireRequestStyle.DeepSeekChat, LlmWireStructuredOutputMode.Text) |
                 (LlmWireRequestStyle.DeepSeekChat, LlmWireStructuredOutputMode.JsonObject) |
                 (LlmWireRequestStyle.AnthropicMessages, LlmWireStructuredOutputMode.JsonSchema) => true
            case _ => false
        }
        if (!representable) { throw IllegalArgumentException("structured output mode has no encoding for this request style") }
    }
    for (control in thinkingControls) {
        let representable = match ((style, control)) {
            case (_, LlmWireThinkingControl.ProviderDefault) => true
            case (LlmWireRequestStyle.OpenAiResponses, LlmWireThinkingControl.Effort(_)) |
                 (LlmWireRequestStyle.OpenAiChat, LlmWireThinkingControl.Disabled) |
                 (LlmWireRequestStyle.OpenAiChat, LlmWireThinkingControl.Enabled) |
                 (LlmWireRequestStyle.OpenAiChat, LlmWireThinkingControl.Effort(_)) |
                 (LlmWireRequestStyle.DeepSeekResponses, LlmWireThinkingControl.Disabled) |
                 (LlmWireRequestStyle.DeepSeekResponses, LlmWireThinkingControl.Enabled) |
                 (LlmWireRequestStyle.DeepSeekResponses, LlmWireThinkingControl.Effort(_)) |
                 (LlmWireRequestStyle.DeepSeekChat, LlmWireThinkingControl.Disabled) |
                 (LlmWireRequestStyle.DeepSeekChat, LlmWireThinkingControl.Enabled) |
                 (LlmWireRequestStyle.DeepSeekChat, LlmWireThinkingControl.Effort(_)) |
                 (LlmWireRequestStyle.DeepSeekMessages, LlmWireThinkingControl.Disabled) |
                 (LlmWireRequestStyle.DeepSeekMessages, LlmWireThinkingControl.Enabled) |
                 (LlmWireRequestStyle.DeepSeekMessages, LlmWireThinkingControl.Effort(_)) |
                 (LlmWireRequestStyle.AnthropicMessages, LlmWireThinkingControl.Disabled) |
                 (LlmWireRequestStyle.AnthropicMessages, LlmWireThinkingControl.Budget(_)) |
                 (LlmWireRequestStyle.AnthropicMessages, LlmWireThinkingControl.Adaptive(_)) => true
            case _ => false
        }
        if (!representable) { throw IllegalArgumentException("thinking control has no encoding for this request style") }
    }
    if (thinkingControls.isEmpty() && !thinkingLevels.isEmpty()) { throw IllegalArgumentException("thinking levels require an encodable thinking control") }
}

public func openAiResponsesDialect(): LlmWireDialect { BuiltinWireDialect(builtinContract(LlmWireBuiltinDialect.OpenAiResponses)) }
public func openAiChatDialect(): LlmWireDialect { BuiltinWireDialect(builtinContract(LlmWireBuiltinDialect.OpenAiChat)) }
public func anthropicMessagesDialect(): LlmWireDialect { BuiltinWireDialect(builtinContract(LlmWireBuiltinDialect.AnthropicMessages)) }
public func deepSeekResponsesDialect(): LlmWireDialect { BuiltinWireDialect(builtinContract(LlmWireBuiltinDialect.DeepSeekResponses)) }
public func deepSeekChatDialect(): LlmWireDialect { BuiltinWireDialect(builtinContract(LlmWireBuiltinDialect.DeepSeekChat)) }
public func deepSeekMessagesDialect(): LlmWireDialect { BuiltinWireDialect(builtinContract(LlmWireBuiltinDialect.DeepSeekMessages)) }

func isBuiltinCompatibilityId(value: String): Bool {
    value == "openai.responses.v1" || value == "openai.chat.v1" || value == "anthropic.messages.v1" ||
    value == "deepseek.responses.v1" || value == "deepseek.chat.v1" || value == "deepseek.messages.v1"
}

func builtinContract(value: LlmWireBuiltinDialect): LlmWireDialectContract {
    let levels = [LlmWireThinkingLevel.Minimal, LlmWireThinkingLevel.Low, LlmWireThinkingLevel.Medium, LlmWireThinkingLevel.High, LlmWireThinkingLevel.XHigh, LlmWireThinkingLevel.Max]
    let anthropicLevels = [LlmWireThinkingLevel.Low, LlmWireThinkingLevel.Medium, LlmWireThinkingLevel.High, LlmWireThinkingLevel.XHigh, LlmWireThinkingLevel.Max]
    let deepSeekMessageLevels = [LlmWireThinkingLevel.Low, LlmWireThinkingLevel.Medium, LlmWireThinkingLevel.High, LlmWireThinkingLevel.XHigh, LlmWireThinkingLevel.Max]
    match (value) {
        case LlmWireBuiltinDialect.OpenAiResponses => LlmWireDialectContract("openai.responses.v1", LlmWireProtocol.Responses, LlmWireRequestStyle.OpenAiResponses, LlmWireOutputTokenField.MaxOutputTokens, thinkingControls: [LlmWireThinkingControl.ProviderDefault, LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium)], thinkingLevels: levels, structuredOutputModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject, LlmWireStructuredOutputMode.JsonSchema], serviceTiers: [LlmWireServiceTier.Auto, LlmWireServiceTier.Default, LlmWireServiceTier.Flex, LlmWireServiceTier.Priority, LlmWireServiceTier.Fast, LlmWireServiceTier.Ultrafast], promptCacheStyle: LlmWirePromptCacheStyle.OpenAi, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.ThirtyMinutes], promptCacheRoutingKey: true, parallelToolStyle: LlmWireParallelToolStyle.OpenAiTopLevel)
        case LlmWireBuiltinDialect.OpenAiChat => LlmWireDialectContract("openai.chat.v1", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens, thinkingControls: [LlmWireThinkingControl.ProviderDefault, LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Enabled, LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium)], thinkingLevels: levels, structuredOutputModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject, LlmWireStructuredOutputMode.JsonSchema], serviceTiers: [LlmWireServiceTier.Auto, LlmWireServiceTier.Default, LlmWireServiceTier.Flex, LlmWireServiceTier.Priority, LlmWireServiceTier.Fast, LlmWireServiceTier.Ultrafast], promptCacheStyle: LlmWirePromptCacheStyle.OpenAi, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.ThirtyMinutes], promptCacheRoutingKey: true, parallelToolStyle: LlmWireParallelToolStyle.OpenAiTopLevel)
        case LlmWireBuiltinDialect.AnthropicMessages => LlmWireDialectContract("anthropic.messages.v1", LlmWireProtocol.Messages, LlmWireRequestStyle.AnthropicMessages, LlmWireOutputTokenField.MaxTokens, requireMaxOutputTokens: true, thinkingControls: [LlmWireThinkingControl.ProviderDefault, LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Budget(1024), LlmWireThinkingControl.Adaptive(None)], thinkingLevels: anthropicLevels, structuredOutputModes: [LlmWireStructuredOutputMode.JsonSchema], serviceTiers: [LlmWireServiceTier.Auto, LlmWireServiceTier.StandardOnly], generationSpeeds: [LlmWireGenerationSpeed.Standard, LlmWireGenerationSpeed.Fast], promptCacheStyle: LlmWirePromptCacheStyle.Anthropic, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.FiveMinutes, LlmWirePromptCacheLifetime.OneHour], parallelToolStyle: LlmWireParallelToolStyle.AnthropicToolChoice, usageMergeStyle: LlmWireUsageMergeStyle.Monotonic)
        case LlmWireBuiltinDialect.DeepSeekResponses => LlmWireDialectContract("deepseek.responses.v1", LlmWireProtocol.Responses, LlmWireRequestStyle.DeepSeekResponses, LlmWireOutputTokenField.MaxOutputTokens, thinkingControls: [LlmWireThinkingControl.ProviderDefault, LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Enabled, LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium)], thinkingLevels: levels, structuredOutputModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject, LlmWireStructuredOutputMode.JsonSchema], promptCacheStyle: LlmWirePromptCacheStyle.ProviderAutomatic, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault])
        case LlmWireBuiltinDialect.DeepSeekChat => LlmWireDialectContract("deepseek.chat.v1", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.DeepSeekChat, LlmWireOutputTokenField.MaxTokens, thinkingControls: [LlmWireThinkingControl.ProviderDefault, LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Enabled, LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium)], thinkingLevels: deepSeekMessageLevels, structuredOutputModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject], promptCacheStyle: LlmWirePromptCacheStyle.ProviderAutomatic, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault])
        case LlmWireBuiltinDialect.DeepSeekMessages => LlmWireDialectContract("deepseek.messages.v1", LlmWireProtocol.Messages, LlmWireRequestStyle.DeepSeekMessages, LlmWireOutputTokenField.MaxTokens, requireMaxOutputTokens: true, thinkingControls: [LlmWireThinkingControl.ProviderDefault, LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Enabled, LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium)], thinkingLevels: deepSeekMessageLevels, promptCacheStyle: LlmWirePromptCacheStyle.ProviderAutomatic, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault], usageMergeStyle: LlmWireUsageMergeStyle.Monotonic)
    }
}
