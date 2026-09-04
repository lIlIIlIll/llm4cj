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
public enum LlmWireToolErrorStyle { Unsupported | NativeField | ContentMarker }
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
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.header_invalid", "header name and value must be safe single-line values")
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

public class LlmWireHttpResponse {
    public let statusCode: Int64
    private let headersValue: Array<LlmWireHeader>
    private let bodyValue: Array<Byte>
    public init(statusCode: Int64, headers: Array<LlmWireHeader>, body: Array<Byte>) {
        this.statusCode = statusCode
        this.headersValue = copyValues(headers)
        this.bodyValue = copyValues(body)
    }
    public prop headers: Array<LlmWireHeader> { get() { copyValues(headersValue) } }
    public prop body: Array<Byte> { get() { copyValues(bodyValue) } }
}

public class LlmWireMaterializedRequest {
    private let bodyValue: Array<Byte>
    private let headersValue: Array<LlmWireHeader>
    init(body: Array<Byte>, headers: Array<LlmWireHeader>) {
        bodyValue = copyValues(body)
        headersValue = copyValues(headers)
    }
    public prop body: Array<Byte> { get() { copyValues(bodyValue) } }
    public prop headers: Array<LlmWireHeader> { get() { copyValues(headersValue) } }
}

public class LlmWirePreparedRequest {
    private let body: String
    private let requiredHeaders: Array<LlmWireHeader>
    private let featureRequirements: Array<LlmWireFeatureRequirement>
    private let streaming: Bool
    init(body: String, requiredHeaders!: Array<LlmWireHeader> = [], featureRequirements!: Array<LlmWireFeatureRequirement> = [], streaming!: Bool = false) {
        this.body = body
        this.requiredHeaders = copyValues(requiredHeaders)
        this.featureRequirements = copyValues(featureRequirements)
        this.streaming = streaming
    }
    // Package-only inspection helpers for deterministic codec tests.
    func contains(fragment: String): Bool { body.contains(fragment) }
    func indexOf(fragment: String): ?Int64 { body.indexOf(fragment) }
    func bodyText(): String { body }
    func requiredHeadersForTest(): Array<LlmWireHeader> { copyValues(requiredHeaders) }
    func featureRequirementsForTest(): Array<LlmWireFeatureRequirement> { copyValues(featureRequirements) }
    public func materialize(resolver!: ?LlmWireRequirementResolver = None, userHeaders!: Array<LlmWireHeader> = []): LlmWireResult<LlmWireMaterializedRequest> {
        try {
            validateForSend(resolver)
            let output = ArrayList<LlmWireHeader>()
            mergeOneHeader(output, LlmWireHeader("content-type", "application/json"))
            mergeOneHeader(output, LlmWireHeader("accept", if (streaming) { "text/event-stream" } else { "application/json" }))
            for (required in requiredHeaders) { mergeOneHeader(output, required) }
            for (provided in userHeaders) { mergeOneHeader(output, provided) }
            LlmWireResult.Ok(LlmWireMaterializedRequest(body.toArray(), output.toArray()))
        } catch (error: LlmWireError) {
            LlmWireResult.Err(withPhaseIfMissing(error, LlmTransportPhase.Request))
        }
    }
    func validateForSend(resolver: ?LlmWireRequirementResolver): Unit {
        for (requirement in featureRequirements) {
            let state = match (requirement.state) {
                case LlmWireRequirementState.Unknown(_) => match (resolver) { case Some(value) => value.resolve(requirement); case None => requirement.state }
                case value => value
            }
            match (state) {
                case LlmWireRequirementState.Satisfied => ()
                case LlmWireRequirementState.Unsatisfied(message) => throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.feature_requirement_unsatisfied", message)
                case LlmWireRequirementState.Unknown(message) => throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.feature_requirement_unresolved", message)
            }
        }
    }
    func mergeHeadersForTest(userHeaders: Array<LlmWireHeader>): Array<LlmWireHeader> {
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
            if (output[index].value != value.value) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.required_header_conflict", "caller header conflicts with an encoded request requirement: " + value.name) }
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
    private let thinkingModesValue: Array<LlmWireThinkingMode>
    private let reasoningEffortsValue: Array<LlmWireReasoningEffort>
    private let structuredOutputModesValue: Array<LlmWireStructuredOutputMode>
    private let serviceTiersValue: Array<LlmWireServiceTier>
    private let generationSpeedsValue: Array<LlmWireGenerationSpeed>
    public let promptCacheStyle: LlmWirePromptCacheStyle
    private let promptCacheLifetimesValue: Array<LlmWirePromptCacheLifetime>
    public let promptCacheRoutingKey: Bool
    public let parallelToolStyle: LlmWireParallelToolStyle
    public let tools: Bool
    public let usageMergeStyle: LlmWireUsageMergeStyle
    public let toolErrorStyle: LlmWireToolErrorStyle
    public init(
        compatibilityId: String, protocol: LlmWireProtocol, requestStyle: LlmWireRequestStyle, outputTokenField: LlmWireOutputTokenField,
        requireMaxOutputTokens!: Bool = false, thinkingModes!: Array<LlmWireThinkingMode> = [LlmWireThinkingMode.ProviderDefault],
        reasoningEfforts!: Array<LlmWireReasoningEffort> = [], structuredOutputModes!: Array<LlmWireStructuredOutputMode> = [],
        serviceTiers!: Array<LlmWireServiceTier> = [], generationSpeeds!: Array<LlmWireGenerationSpeed> = [],
        promptCacheStyle!: LlmWirePromptCacheStyle = LlmWirePromptCacheStyle.Unsupported,
        promptCacheLifetimes!: Array<LlmWirePromptCacheLifetime> = [], promptCacheRoutingKey!: Bool = false,
        parallelToolStyle!: LlmWireParallelToolStyle = LlmWireParallelToolStyle.Unsupported, tools!: Bool = true,
        usageMergeStyle!: LlmWireUsageMergeStyle = LlmWireUsageMergeStyle.ReplacePresent, toolErrorStyle!: LlmWireToolErrorStyle = LlmWireToolErrorStyle.Unsupported
    ) {
        if (!validCompatibilityId(compatibilityId)) { throw IllegalArgumentException("dialect compatibility ID must use 1-128 lowercase ASCII letters, digits, dot, underscore, or hyphen") }
        validateContractShape(
            protocol, requestStyle, outputTokenField, promptCacheStyle, parallelToolStyle,
            thinkingModes, reasoningEfforts, structuredOutputModes, serviceTiers, generationSpeeds,
            promptCacheLifetimes, promptCacheRoutingKey, toolErrorStyle
        )
        this.compatibilityId = compatibilityId; this.protocol = protocol; this.requestStyle = requestStyle; this.outputTokenField = outputTokenField
        rejectDuplicateContractValues(thinkingModes, reasoningEfforts, structuredOutputModes, serviceTiers, generationSpeeds, promptCacheLifetimes)
        this.requireMaxOutputTokens = requireMaxOutputTokens; this.thinkingModesValue = copyValues(thinkingModes); this.reasoningEffortsValue = copyValues(reasoningEfforts)
        this.structuredOutputModesValue = copyValues(structuredOutputModes); this.serviceTiersValue = copyValues(serviceTiers); this.generationSpeedsValue = copyValues(generationSpeeds)
        this.promptCacheStyle = promptCacheStyle; this.promptCacheLifetimesValue = copyValues(promptCacheLifetimes); this.promptCacheRoutingKey = promptCacheRoutingKey
        this.parallelToolStyle = parallelToolStyle; this.tools = tools; this.usageMergeStyle = usageMergeStyle; this.toolErrorStyle = toolErrorStyle
    }
    public prop thinkingModes: Array<LlmWireThinkingMode> { get() { copyValues(thinkingModesValue) } }
    public prop reasoningEfforts: Array<LlmWireReasoningEffort> { get() { copyValues(reasoningEffortsValue) } }
    public prop structuredOutputModes: Array<LlmWireStructuredOutputMode> { get() { copyValues(structuredOutputModesValue) } }
    public prop serviceTiers: Array<LlmWireServiceTier> { get() { copyValues(serviceTiersValue) } }
    public prop generationSpeeds: Array<LlmWireGenerationSpeed> { get() { copyValues(generationSpeedsValue) } }
    public prop promptCacheLifetimes: Array<LlmWirePromptCacheLifetime> { get() { copyValues(promptCacheLifetimesValue) } }
}

public class LlmWireInputCapabilities {
    private let modalitiesValue: Array<LlmWireInputModality>
    public init(modalities!: Array<LlmWireInputModality> = [LlmWireInputModality.Text]) {
        if (hasDuplicate(modalities)) { throw IllegalArgumentException("input capabilities must not contain duplicate modalities") }
        this.modalitiesValue = copyValues(modalities)
    }
    public prop modalities: Array<LlmWireInputModality> { get() { copyValues(modalitiesValue) } }
}

public class LlmWireThinkingCapabilities {
    private let modesValue: Array<LlmWireThinkingMode>
    private let effortsValue: Array<LlmWireReasoningEffort>
    public init(modes!: Array<LlmWireThinkingMode> = [], efforts!: Array<LlmWireReasoningEffort> = []) {
        if (hasDuplicate(modes) || hasDuplicate(efforts)) { throw IllegalArgumentException("thinking capabilities must not contain duplicate values") }
        this.modesValue = copyValues(modes); this.effortsValue = copyValues(efforts)
    }
    public prop modes: Array<LlmWireThinkingMode> { get() { copyValues(modesValue) } }
    public prop efforts: Array<LlmWireReasoningEffort> { get() { copyValues(effortsValue) } }
}

public class LlmWireToolCapabilities {
    public let enabled: Bool
    public let parallelCalls: Bool
    public init(enabled!: Bool = false, parallelCalls!: Bool = false) {
        if (parallelCalls && !enabled) { throw IllegalArgumentException("parallel tool calls require tools to be enabled") }
        this.enabled = enabled; this.parallelCalls = parallelCalls
    }
}

public class LlmWireOutputCapabilities {
    private let structuredModesValue: Array<LlmWireStructuredOutputMode>
    private let serviceTiersValue: Array<LlmWireServiceTier>
    private let generationSpeedsValue: Array<LlmWireGenerationSpeed>
    public init(
        structuredModes!: Array<LlmWireStructuredOutputMode> = [], serviceTiers!: Array<LlmWireServiceTier> = [],
        generationSpeeds!: Array<LlmWireGenerationSpeed> = []
    ) {
        if (hasDuplicate(structuredModes) || hasDuplicate(serviceTiers) || hasDuplicate(generationSpeeds)) { throw IllegalArgumentException("output capabilities must not contain duplicate values") }
        this.structuredModesValue = copyValues(structuredModes); this.serviceTiersValue = copyValues(serviceTiers); this.generationSpeedsValue = copyValues(generationSpeeds)
    }
    public prop structuredModes: Array<LlmWireStructuredOutputMode> { get() { copyValues(structuredModesValue) } }
    public prop serviceTiers: Array<LlmWireServiceTier> { get() { copyValues(serviceTiersValue) } }
    public prop generationSpeeds: Array<LlmWireGenerationSpeed> { get() { copyValues(generationSpeedsValue) } }
}

public class LlmWireCacheCapabilities {
    private let lifetimesValue: Array<LlmWirePromptCacheLifetime>
    public init(lifetimes!: Array<LlmWirePromptCacheLifetime> = []) {
        if (hasDuplicate(lifetimes)) { throw IllegalArgumentException("cache capabilities must not contain duplicate lifetimes") }
        this.lifetimesValue = copyValues(lifetimes)
    }
    public prop lifetimes: Array<LlmWirePromptCacheLifetime> { get() { copyValues(lifetimesValue) } }
}

public class LlmWireCapabilities {
    public let input: LlmWireInputCapabilities
    public let thinking: LlmWireThinkingCapabilities
    public let tools: LlmWireToolCapabilities
    public let output: LlmWireOutputCapabilities
    public let cache: LlmWireCacheCapabilities
    public init(
        input!: LlmWireInputCapabilities = LlmWireInputCapabilities(),
        thinking!: LlmWireThinkingCapabilities = LlmWireThinkingCapabilities(),
        tools!: LlmWireToolCapabilities = LlmWireToolCapabilities(),
        output!: LlmWireOutputCapabilities = LlmWireOutputCapabilities(),
        cache!: LlmWireCacheCapabilities = LlmWireCacheCapabilities()
    ) {
        this.input = input; this.thinking = thinking; this.tools = tools; this.output = output; this.cache = cache
    }
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
    controls: Array<LlmWireThinkingMode>, levels: Array<LlmWireReasoningEffort>, modes: Array<LlmWireStructuredOutputMode>,
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

func customDialectThinkingIsReplaySafe(contract: LlmWireDialectContract): Bool {
    if (!contract.reasoningEfforts.isEmpty()) { return false }
    for (mode in contract.thinkingModes) {
        if (mode != LlmWireThinkingMode.ProviderDefault) { return false }
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
        thinkingModes: value.thinkingModes, reasoningEfforts: value.reasoningEfforts,
        structuredOutputModes: value.structuredOutputModes, serviceTiers: value.serviceTiers,
        generationSpeeds: value.generationSpeeds, promptCacheStyle: value.promptCacheStyle,
        promptCacheLifetimes: value.promptCacheLifetimes, promptCacheRoutingKey: value.promptCacheRoutingKey,
        parallelToolStyle: value.parallelToolStyle, tools: value.tools, usageMergeStyle: value.usageMergeStyle, toolErrorStyle: value.toolErrorStyle
    )
}

public class LlmWireCodec {
    public let protocol: LlmWireProtocol
    public let dialect: LlmWireDialect
    public let capabilities: LlmWireCapabilities
    public let provider: String
    public let modelProfile: ?LlmWireModelProfile
    internal init(protocol: LlmWireProtocol, dialect: LlmWireDialect, capabilities!: LlmWireCapabilities = LlmWireCapabilities(), provider!: String = "", modelProfile!: ?LlmWireModelProfile = None) {
        let declaredProtocol = dialect.protocol
        let declaredIdentity = dialect.compatibilityId
        let declaredContract = dialect.contract
        if (protocol != declaredProtocol || protocol != declaredContract.protocol) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.dialect_protocol_mismatch", "dialect protocol does not match codec protocol") }
        if (declaredIdentity != declaredContract.compatibilityId) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.dialect_identity_mismatch", "dialect identity does not match its contract") }
        if (isBuiltinCompatibilityId(declaredIdentity) && !(dialect is BuiltinWireDialect)) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.dialect_identity_reserved", "built-in compatibility IDs may only be used by built-in dialects")
        }
        if (!isBuiltinCompatibilityId(declaredIdentity) && !customDialectThinkingIsReplaySafe(declaredContract)) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.dialect_thinking_replay_unsupported", "custom dialect thinking requires a replay schema that v0.1.1 does not expose")
        }
        let frozen = snapshotDialectContract(declaredContract)
        match (modelProfile) {
            case Some(profile) =>
                if (profile.dialectId != declaredIdentity) {
                    throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.model_profile_dialect_mismatch", "model profile belongs to a different dialect")
                }
            case None => ()
        }
        this.protocol = protocol; this.dialect = FrozenWireDialect(frozen); this.capabilities = capabilities; this.provider = provider; this.modelProfile = modelProfile
    }
    public func encodeRequest(request: LlmWireRequest, streaming!: Bool = false): LlmWirePreparedRequest {
        try { validateWireRequest(this, request); encodeWireRequest(this, request, streaming) }
        catch (error: LlmWireError) { throw withCodecContext(error, this, LlmTransportPhase.Encode) }
    }
    public func newRequestBuilder(model!: String = ""): LlmWireRequestBuilder {
        let resolved = if (model != "") { model } else { match (modelProfile) {
            case Some(profile) => profile.model
            case None => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.model_missing", "a codec without a model profile requires an explicit builder model")
        } }
        LlmWireRequestBuilder(this, resolved)
    }
    public func decodeResponse(source: String): LlmWireResponseState {
        try { decodeWireResponse(this, source) }
        catch (error: LlmWireError) { throw withCodecContext(error, this, LlmTransportPhase.WireDecode) }
    }
    public func decodeResponse(response: LlmWireHttpResponse, nowEpochMillis!: Int64 = 0): LlmWireResult<LlmWireResponseState> {
        decodeHttpResponse(this, response, nowEpochMillis)
    }
    public func newStreamDecoder(
        limits!: LlmWireStreamLimits = LlmWireStreamLimits(),
        sseLimits!: LlmWireSseLimits = LlmWireSseLimits()
    ): LlmWireStreamDecoder { LlmWireStreamDecoder(this, 200, [], limits, sseLimits) }
    public func newHttpStreamDecoder(
        statusCode: Int64, headers!: Array<LlmWireHeader> = [],
        limits!: LlmWireStreamLimits = LlmWireStreamLimits(),
        sseLimits!: LlmWireSseLimits = LlmWireSseLimits(),
        nowEpochMillis!: Int64 = 0
    ): LlmWireResult<LlmWireStreamDecoder> {
        try { LlmWireResult.Ok(LlmWireStreamDecoder(this, statusCode, headers, limits, sseLimits, nowEpochMillis: nowEpochMillis)) }
        catch (error: LlmWireError) { LlmWireResult.Err(withCodecContext(error, this, LlmTransportPhase.ResponseHeaders)) }
    }
}

internal func experimentalCodec(
    protocol: LlmWireProtocol, dialect: LlmWireDialect,
    capabilities!: LlmWireCapabilities = LlmWireCapabilities(), provider!: String = ""
): LlmWireCodec {
    LlmWireCodec(protocol, dialect, capabilities: capabilities, provider: provider)
}

public class LlmWireModelProfile {
    public let model: String
    public let dialectId: String
    public let capabilities: LlmWireCapabilities

    init(model: String, dialectId: String, capabilities: LlmWireCapabilities) {
        if (model.trimAscii() == "") {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.model_missing", "model profile requires a model ID")
        }
        this.model = model
        this.dialectId = dialectId
        this.capabilities = capabilities
    }
}

public func openAiResponsesModelProfile(model: String, capabilities!: LlmWireCapabilities = LlmWireCapabilities()): LlmWireModelProfile {
    LlmWireModelProfile(model, "openai.responses.v1", capabilities)
}
public func openAiChatModelProfile(model: String, capabilities!: LlmWireCapabilities = LlmWireCapabilities()): LlmWireModelProfile {
    LlmWireModelProfile(model, "openai.chat.v1", capabilities)
}
public func anthropicMessagesModelProfile(model: String, capabilities!: LlmWireCapabilities = LlmWireCapabilities()): LlmWireModelProfile {
    LlmWireModelProfile(model, "anthropic.messages.v1", capabilities)
}
public func deepSeekResponsesModelProfile(model: String, capabilities!: LlmWireCapabilities = LlmWireCapabilities()): LlmWireModelProfile {
    LlmWireModelProfile(model, "deepseek.responses.v1", capabilities)
}
public func deepSeekChatModelProfile(model: String, capabilities!: LlmWireCapabilities = LlmWireCapabilities()): LlmWireModelProfile {
    LlmWireModelProfile(model, "deepseek.chat.v1", capabilities)
}
public func deepSeekMessagesModelProfile(model: String, capabilities!: LlmWireCapabilities = LlmWireCapabilities()): LlmWireModelProfile {
    LlmWireModelProfile(model, "deepseek.messages.v1", capabilities)
}

public func openAiResponsesCodec(profile: LlmWireModelProfile, provider!: String = "openai"): LlmWireCodec {
    LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: profile.capabilities, provider: provider, modelProfile: Some(profile))
}
public func openAiChatCodec(profile: LlmWireModelProfile, provider!: String = "openai"): LlmWireCodec {
    LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: profile.capabilities, provider: provider, modelProfile: Some(profile))
}
public func anthropicMessagesCodec(profile: LlmWireModelProfile, provider!: String = "anthropic"): LlmWireCodec {
    LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: profile.capabilities, provider: provider, modelProfile: Some(profile))
}
public func deepSeekResponsesCodec(profile: LlmWireModelProfile, provider!: String = "deepseek"): LlmWireCodec {
    LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect(), capabilities: profile.capabilities, provider: provider, modelProfile: Some(profile))
}
public func deepSeekChatCodec(profile: LlmWireModelProfile, provider!: String = "deepseek"): LlmWireCodec {
    LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: profile.capabilities, provider: provider, modelProfile: Some(profile))
}
public func deepSeekMessagesCodec(profile: LlmWireModelProfile, provider!: String = "deepseek"): LlmWireCodec {
    LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect(), capabilities: profile.capabilities, provider: provider, modelProfile: Some(profile))
}

func withCodecContext(error: LlmWireError, codec: LlmWireCodec, defaultPhase: LlmTransportPhase): LlmWireError {
    LlmWireError(
        error.kind, error.code, error.message, retryable: error.retryable, httpStatus: error.httpStatus,
        retryAfterMillis: error.retryAfterMillis, provider: if (error.provider == "") { codec.provider } else { error.provider },
        providerErrorCode: error.providerErrorCode, providerErrorType: error.providerErrorType, diagnosticJson: error.diagnosticJson,
        phase: match (error.phase) { case Some(value) => Some(value); case None => Some(defaultPhase) },
        protocol: match (error.protocol) { case Some(value) => Some(value); case None => Some(codec.protocol) },
        dialectId: if (error.dialectId == "") { codec.dialect.compatibilityId } else { error.dialectId },
        eventType: error.eventType, blockIndex: error.blockIndex, toolCallId: error.toolCallId,
        providerRequestId: error.providerRequestId, usage: error.usage
    )
}

func withPhaseIfMissing(error: LlmWireError, phase: LlmTransportPhase): LlmWireError {
    LlmWireError(
        error.kind, error.code, error.message, retryable: error.retryable, httpStatus: error.httpStatus,
        retryAfterMillis: error.retryAfterMillis, provider: error.provider,
        providerErrorCode: error.providerErrorCode, providerErrorType: error.providerErrorType,
        diagnosticJson: error.diagnosticJson,
        phase: match (error.phase) { case Some(value) => Some(value); case None => Some(phase) },
        protocol: error.protocol, dialectId: error.dialectId, eventType: error.eventType,
        blockIndex: error.blockIndex, toolCallId: error.toolCallId,
        providerRequestId: error.providerRequestId, usage: error.usage
    )
}

func validateContractShape(
    protocol: LlmWireProtocol, style: LlmWireRequestStyle, tokenField: LlmWireOutputTokenField,
    cacheStyle: LlmWirePromptCacheStyle, parallelStyle: LlmWireParallelToolStyle,
    thinkingModes: Array<LlmWireThinkingMode>, reasoningEfforts: Array<LlmWireReasoningEffort>,
    structuredModes: Array<LlmWireStructuredOutputMode>, serviceTiers: Array<LlmWireServiceTier>,
    generationSpeeds: Array<LlmWireGenerationSpeed>, cacheLifetimes: Array<LlmWirePromptCacheLifetime>,
    cacheRoutingKey: Bool, toolErrorStyle: LlmWireToolErrorStyle
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
    if (toolErrorStyle != LlmWireToolErrorStyle.Unsupported && protocol != LlmWireProtocol.Messages) { throw IllegalArgumentException("tool error style has no encoding for this protocol") }
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
    for (mode in thinkingModes) {
        let representable = match ((style, mode)) {
            case (_, LlmWireThinkingMode.ProviderDefault) => true
            case (LlmWireRequestStyle.OpenAiChat, LlmWireThinkingMode.Disabled) |
                 (LlmWireRequestStyle.OpenAiChat, LlmWireThinkingMode.Enabled) |
                 (LlmWireRequestStyle.DeepSeekResponses, LlmWireThinkingMode.Disabled) |
                 (LlmWireRequestStyle.DeepSeekResponses, LlmWireThinkingMode.Enabled) |
                 (LlmWireRequestStyle.DeepSeekChat, LlmWireThinkingMode.Disabled) |
                 (LlmWireRequestStyle.DeepSeekChat, LlmWireThinkingMode.Enabled) |
                 (LlmWireRequestStyle.DeepSeekMessages, LlmWireThinkingMode.Disabled) |
                 (LlmWireRequestStyle.DeepSeekMessages, LlmWireThinkingMode.Enabled) |
                 (LlmWireRequestStyle.AnthropicMessages, LlmWireThinkingMode.Disabled) |
                 (LlmWireRequestStyle.AnthropicMessages, LlmWireThinkingMode.Budget(_)) |
                 (LlmWireRequestStyle.AnthropicMessages, LlmWireThinkingMode.Adaptive) => true
            case _ => false
        }
        if (!representable) { throw IllegalArgumentException("thinking mode has no encoding for this request style") }
    }
    if (!reasoningEfforts.isEmpty() && style == LlmWireRequestStyle.AnthropicMessages && !containsThinkingMode(thinkingModes, LlmWireThinkingMode.Adaptive)) {
        throw IllegalArgumentException("Anthropic reasoning effort requires adaptive thinking")
    }
}

func containsThinkingMode(values: Array<LlmWireThinkingMode>, target: LlmWireThinkingMode): Bool {
    for (value in values where value == target) { return true }; false
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
    let levels = [LlmWireReasoningEffort.Minimal, LlmWireReasoningEffort.Low, LlmWireReasoningEffort.Medium, LlmWireReasoningEffort.High, LlmWireReasoningEffort.XHigh, LlmWireReasoningEffort.Max]
    let anthropicLevels = [LlmWireReasoningEffort.Low, LlmWireReasoningEffort.Medium, LlmWireReasoningEffort.High, LlmWireReasoningEffort.XHigh, LlmWireReasoningEffort.Max]
    let deepSeekMessageLevels = [LlmWireReasoningEffort.Low, LlmWireReasoningEffort.Medium, LlmWireReasoningEffort.High, LlmWireReasoningEffort.XHigh, LlmWireReasoningEffort.Max]
    match (value) {
        case LlmWireBuiltinDialect.OpenAiResponses => LlmWireDialectContract("openai.responses.v1", LlmWireProtocol.Responses, LlmWireRequestStyle.OpenAiResponses, LlmWireOutputTokenField.MaxOutputTokens, thinkingModes: [LlmWireThinkingMode.ProviderDefault], reasoningEfforts: levels, structuredOutputModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject, LlmWireStructuredOutputMode.JsonSchema], serviceTiers: [LlmWireServiceTier.Auto, LlmWireServiceTier.Default, LlmWireServiceTier.Flex, LlmWireServiceTier.Priority, LlmWireServiceTier.Fast, LlmWireServiceTier.Ultrafast], promptCacheStyle: LlmWirePromptCacheStyle.OpenAi, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.ThirtyMinutes], promptCacheRoutingKey: true, parallelToolStyle: LlmWireParallelToolStyle.OpenAiTopLevel)
        case LlmWireBuiltinDialect.OpenAiChat => LlmWireDialectContract("openai.chat.v1", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens, thinkingModes: [LlmWireThinkingMode.ProviderDefault, LlmWireThinkingMode.Disabled, LlmWireThinkingMode.Enabled], reasoningEfforts: levels, structuredOutputModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject, LlmWireStructuredOutputMode.JsonSchema], serviceTiers: [LlmWireServiceTier.Auto, LlmWireServiceTier.Default, LlmWireServiceTier.Flex, LlmWireServiceTier.Priority, LlmWireServiceTier.Fast, LlmWireServiceTier.Ultrafast], promptCacheStyle: LlmWirePromptCacheStyle.OpenAi, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.ThirtyMinutes], promptCacheRoutingKey: true, parallelToolStyle: LlmWireParallelToolStyle.OpenAiTopLevel)
        case LlmWireBuiltinDialect.AnthropicMessages => LlmWireDialectContract("anthropic.messages.v1", LlmWireProtocol.Messages, LlmWireRequestStyle.AnthropicMessages, LlmWireOutputTokenField.MaxTokens, requireMaxOutputTokens: true, thinkingModes: [LlmWireThinkingMode.ProviderDefault, LlmWireThinkingMode.Disabled, LlmWireThinkingMode.Budget(1024), LlmWireThinkingMode.Adaptive], reasoningEfforts: anthropicLevels, structuredOutputModes: [LlmWireStructuredOutputMode.JsonSchema], serviceTiers: [LlmWireServiceTier.Auto, LlmWireServiceTier.StandardOnly], generationSpeeds: [LlmWireGenerationSpeed.Standard, LlmWireGenerationSpeed.Fast], promptCacheStyle: LlmWirePromptCacheStyle.Anthropic, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.FiveMinutes, LlmWirePromptCacheLifetime.OneHour], parallelToolStyle: LlmWireParallelToolStyle.AnthropicToolChoice, usageMergeStyle: LlmWireUsageMergeStyle.Monotonic, toolErrorStyle: LlmWireToolErrorStyle.NativeField)
        case LlmWireBuiltinDialect.DeepSeekResponses => LlmWireDialectContract("deepseek.responses.v1", LlmWireProtocol.Responses, LlmWireRequestStyle.DeepSeekResponses, LlmWireOutputTokenField.MaxOutputTokens, thinkingModes: [LlmWireThinkingMode.ProviderDefault, LlmWireThinkingMode.Disabled, LlmWireThinkingMode.Enabled], reasoningEfforts: levels, structuredOutputModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject, LlmWireStructuredOutputMode.JsonSchema], promptCacheStyle: LlmWirePromptCacheStyle.ProviderAutomatic, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault])
        case LlmWireBuiltinDialect.DeepSeekChat => LlmWireDialectContract("deepseek.chat.v1", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.DeepSeekChat, LlmWireOutputTokenField.MaxTokens, thinkingModes: [LlmWireThinkingMode.ProviderDefault, LlmWireThinkingMode.Disabled, LlmWireThinkingMode.Enabled], reasoningEfforts: deepSeekMessageLevels, structuredOutputModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject], promptCacheStyle: LlmWirePromptCacheStyle.ProviderAutomatic, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault])
        case LlmWireBuiltinDialect.DeepSeekMessages => LlmWireDialectContract("deepseek.messages.v1", LlmWireProtocol.Messages, LlmWireRequestStyle.DeepSeekMessages, LlmWireOutputTokenField.MaxTokens, requireMaxOutputTokens: true, thinkingModes: [LlmWireThinkingMode.ProviderDefault, LlmWireThinkingMode.Disabled, LlmWireThinkingMode.Enabled], reasoningEfforts: deepSeekMessageLevels, promptCacheStyle: LlmWirePromptCacheStyle.ProviderAutomatic, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault], usageMergeStyle: LlmWireUsageMergeStyle.Monotonic, toolErrorStyle: LlmWireToolErrorStyle.ContentMarker)
    }
}
