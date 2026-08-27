package llm4cj

import yjson.*
import std.collection.*
import std.deriving.Derive

@Derive[Equatable]
public enum LlmWireProtocol { Responses | ChatCompletions | Messages }
@Derive[Equatable]
public enum LlmWireRole { User | Assistant }
@Derive[Equatable]
public enum LlmWireImageSourceKind { Url | Base64 }
@Derive[Equatable]
public enum LlmWireImageDetail { Auto | Low | High }
@Derive[Equatable]
public enum LlmWireThinkingLevel { Minimal | Low | Medium | High | XHigh | Max }
@Derive[Equatable]
public enum LlmWireThinkingControl {
    ProviderDefault | Disabled | Enabled | Effort(LlmWireThinkingLevel) |
    Budget(Int64) | Adaptive(?LlmWireThinkingLevel)
}
@Derive[Equatable]
public enum LlmWireServiceTier {
    ProviderDefault | Auto | Default | StandardOnly | Flex | Priority | Fast | Ultrafast
}
@Derive[Equatable]
public enum LlmWireGenerationSpeed { ProviderDefault | Standard | Fast }
@Derive[Equatable]
public enum LlmWirePromptCacheLifetime {
    ProviderDefault | FiveMinutes | ThirtyMinutes | OneHour | TwentyFourHours
}
public enum LlmWirePromptCache {
    ProviderDefault | Automatic(LlmWirePromptCacheLifetime)
}
@Derive[Equatable]
public enum LlmWireToolChoice { ProviderDefault | Auto | NoTools | Required }
@Derive[Equatable]
public enum LlmWireOpaqueCompletion { Complete | Partial }
@Derive[Equatable]
public enum LlmWireNativeReplayScope { AssistantTurn | Conversation }

public class LlmWireImageBlock {
    public let sourceKind: LlmWireImageSourceKind
    public let data: String
    public let mediaType: String
    public let detail: LlmWireImageDetail
    public init(sourceKind: LlmWireImageSourceKind, data: String, mediaType!: String = "", detail!: LlmWireImageDetail = LlmWireImageDetail.Auto) {
        this.sourceKind = sourceKind
        this.data = data
        this.mediaType = mediaType
        this.detail = detail
    }
}

public class LlmWireTextBlock {
    public let text: String
    public init(text: String) { this.text = text }
}

public class LlmWireReasoningBlock {
    public let text: String
    public let replayDialectId: String
    public init(text: String, replayDialectId!: String = "") {
        this.text = text
        this.replayDialectId = replayDialectId
    }
}

public enum LlmWireToolArguments {
    Complete(JsonNode)
    | InvalidJson(String)
    | InvalidShape(JsonNode)
    | Partial(String)
}

public class LlmWireToolCallBlock {
    public let callId: String
    public let name: String
    public let arguments: LlmWireToolArguments
    public init(callId: String, name: String, arguments: LlmWireToolArguments) {
        this.callId = callId
        this.name = name
        this.arguments = arguments
    }
}

public class LlmWireToolResultBlock {
    public let callId: String
    public let content: String
    public let isError: Bool
    public init(callId: String, content: String, isError!: Bool = false) {
        this.callId = callId
        this.content = content
        this.isError = isError
    }
}

public class LlmWireRefusalBlock {
    public let text: String
    public init(text: String) { this.text = text }
}

public class LlmWireOpaqueBlock {
    public let nativeType: String
    public let completion: LlmWireOpaqueCompletion
    private let diagnosticJson: String

    init(nativeType: String, payload: JsonNode, completion!: LlmWireOpaqueCompletion = LlmWireOpaqueCompletion.Complete) {
        if (nativeType == "" || payload.wireKind != WireJsonKind.Object) {
            throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.opaque_payload_invalid", "opaque diagnostic payload must be a typed object")
        }
        this.nativeType = nativeType
        this.completion = completion
        this.diagnosticJson = payload.stringify()
    }

    public func payload(): JsonNode { parseWireJson(diagnosticJson) }
    public func snapshot(): String { diagnosticJson }
}

public class LlmWireNativeReplayBlock {
    public let protocol: LlmWireProtocol
    public let dialectId: String
    public let nativeType: String
    public let schemaVersion: Int64
    public let modelConstraint: ?String
    public let scope: LlmWireNativeReplayScope
    public let assistantTurnIndex: Int64
    public let blockOrder: Int64
    public let completion: LlmWireOpaqueCompletion
    public let displayReasoning: ?String
    private let canonicalReplayJson: String

    init(
        protocol: LlmWireProtocol,
        dialectId: String,
        nativeType: String,
        schemaVersion: Int64,
        modelConstraint: ?String,
        scope: LlmWireNativeReplayScope,
        assistantTurnIndex: Int64,
        blockOrder: Int64,
        completion: LlmWireOpaqueCompletion,
        canonicalReplayJson: String,
        displayReasoning: ?String
    ) {
        this.protocol = protocol; this.dialectId = dialectId; this.nativeType = nativeType; this.schemaVersion = schemaVersion
        this.modelConstraint = modelConstraint; this.scope = scope; this.assistantTurnIndex = assistantTurnIndex; this.blockOrder = blockOrder
        this.completion = completion; this.canonicalReplayJson = canonicalReplayJson; this.displayReasoning = displayReasoning
    }

    public static func restore(snapshot: String): LlmWireNativeReplayBlock {
        let root = wireObject(parseWireJson(snapshot), "native replay snapshot")
        let complete = wireRequiredField(root, "complete")
        if (complete.wireKind != WireJsonKind.Boolean || !complete.bool) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.native_replay_incomplete", "only complete native state can be restored for replay") }
        nativeReplayFromPayload(
            parseProtocol(wireRequiredString(root, "protocol")), wireRequiredString(root, "dialect_id"), wireRequiredString(root, "native_type"),
            wireObject(wireRequiredField(root, "payload"), "native replay payload"), schemaVersion: wireRequiredInt(root, "schema_version"),
            modelConstraint: wireOptionalString(root, "model_constraint"), scope: parseReplayScope(wireRequiredString(root, "scope")),
            assistantTurnIndex: wireRequiredInt(root, "assistant_turn_index"), blockOrder: wireRequiredInt(root, "block_order"),
            displayReasoning: wireOptionalString(root, "display_reasoning")
        )
    }

    public func payload(): JsonNode { parseWireJson(canonicalReplayJson) }
    public func snapshot(): String {
        let root = wireJsonObject([
            WireJsonField("protocol", wireJsonString(protocolName(protocol))), WireJsonField("dialect_id", wireJsonString(dialectId)),
            WireJsonField("native_type", wireJsonString(nativeType)), WireJsonField("schema_version", wireJsonNumber(schemaVersion.toString())),
            WireJsonField("scope", wireJsonString(replayScopeName(scope))), WireJsonField("assistant_turn_index", wireJsonNumber(assistantTurnIndex.toString())),
            WireJsonField("block_order", wireJsonNumber(blockOrder.toString())), WireJsonField("complete", wireJsonBool(completion == LlmWireOpaqueCompletion.Complete)),
            WireJsonField("payload", payload())
        ])
        match (modelConstraint) { case Some(value) => root.put("model_constraint", wireJsonString(value)); case None => () }
        match (displayReasoning) { case Some(value) => root.put("display_reasoning", wireJsonString(value)); case None => () }
        root.stringify()
    }
}

func nativeReplayFromPayload(
    protocol: LlmWireProtocol, dialectId: String, nativeType: String, payload: JsonNode,
    schemaVersion!: Int64 = 1, modelConstraint!: ?String = None,
    scope!: LlmWireNativeReplayScope = LlmWireNativeReplayScope.AssistantTurn,
    assistantTurnIndex!: Int64 = 0, blockOrder!: Int64 = 0,
    completion!: LlmWireOpaqueCompletion = LlmWireOpaqueCompletion.Complete,
    displayReasoning!: ?String = None
): LlmWireNativeReplayBlock {
    if (dialectId == "" || nativeType == "" || schemaVersion < 1 || assistantTurnIndex < 0 || blockOrder < 0 || payload.wireKind != WireJsonKind.Object) {
        throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.native_replay_payload_invalid", "native replay metadata and payload must be complete")
    }
    match (payload.field("type")) {
        case Some(value) => if (value.wireKind != WireJsonKind.Text || value.text != nativeType) { throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.native_replay_type_mismatch", "native replay type does not match payload") }
        case None => throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.native_replay_type_missing", "native replay payload must contain type")
    }
    LlmWireNativeReplayBlock(protocol, dialectId, nativeType, schemaVersion, modelConstraint, scope, assistantTurnIndex, blockOrder, completion, payload.stringify(), displayReasoning)
}

func protocolName(value: LlmWireProtocol): String { match (value) { case LlmWireProtocol.Responses => "responses"; case LlmWireProtocol.ChatCompletions => "chat_completions"; case LlmWireProtocol.Messages => "messages" } }
func parseProtocol(value: String): LlmWireProtocol { match (value) { case "responses" => LlmWireProtocol.Responses; case "chat_completions" => LlmWireProtocol.ChatCompletions; case "messages" => LlmWireProtocol.Messages; case _ => throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.native_replay_protocol_invalid", "unknown native replay protocol") } }
func replayScopeName(value: LlmWireNativeReplayScope): String { match (value) { case LlmWireNativeReplayScope.AssistantTurn => "assistant_turn"; case LlmWireNativeReplayScope.Conversation => "conversation" } }
func parseReplayScope(value: String): LlmWireNativeReplayScope { match (value) { case "assistant_turn" => LlmWireNativeReplayScope.AssistantTurn; case "conversation" => LlmWireNativeReplayScope.Conversation; case _ => throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.native_replay_scope_invalid", "unknown native replay scope") } }

public enum LlmWireBlock {
    Text(LlmWireTextBlock)
    | Image(LlmWireImageBlock)
    | Reasoning(LlmWireReasoningBlock)
    | ToolCall(LlmWireToolCallBlock)
    | ToolResult(LlmWireToolResultBlock)
    | Refusal(LlmWireRefusalBlock)
    | NativeReplay(LlmWireNativeReplayBlock)
    | Opaque(LlmWireOpaqueBlock)
}

public class LlmWireMessage {
    public let role: LlmWireRole
    public let blocks: Array<LlmWireBlock>
    public init(role: LlmWireRole, blocks: Array<LlmWireBlock>) {
        this.role = role
        this.blocks = blocks
    }
}

public class LlmWireTool {
    public let name: String
    public let description: String
    public let inputSchema: JsonNode
    public init(name: String, description: String, inputSchema: JsonNode) {
        this.name = name
        this.description = description
        this.inputSchema = inputSchema
    }
}

public class LlmWireJsonSchema {
    public let name: String
    public let description: String
    public let schema: JsonNode
    public let strict: Bool
    public init(name: String, schema: JsonNode, description!: String = "", strict!: Bool = true) {
        this.name = name
        this.description = description
        this.schema = schema
        this.strict = strict
    }
}

public enum LlmWireStructuredOutput {
    ProviderDefault | Text | JsonObject | JsonSchema(LlmWireJsonSchema)
}

public class LlmWireRequest {
    public let model: String
    public let system: String
    public let messages: Array<LlmWireMessage>
    public let tools: Array<LlmWireTool>
    public let thinking: LlmWireThinkingControl
    public let maxOutputTokens: ?Int64
    public let streaming: ?Bool
    public let parallelToolCalls: ?Bool
    public let serviceTier: LlmWireServiceTier
    public let generationSpeed: LlmWireGenerationSpeed
    public let promptCache: LlmWirePromptCache
    public let promptCacheRoutingKey: ?String
    public let toolChoice: LlmWireToolChoice
    public let structuredOutput: LlmWireStructuredOutput

    public init(
        model: String,
        messages: Array<LlmWireMessage>,
        system!: String = "",
        tools!: Array<LlmWireTool> = [],
        thinking!: LlmWireThinkingControl = LlmWireThinkingControl.ProviderDefault,
        maxOutputTokens!: ?Int64 = None,
        streaming!: ?Bool = None,
        parallelToolCalls!: ?Bool = None,
        serviceTier!: LlmWireServiceTier = LlmWireServiceTier.ProviderDefault,
        generationSpeed!: LlmWireGenerationSpeed = LlmWireGenerationSpeed.ProviderDefault,
        promptCache!: LlmWirePromptCache = LlmWirePromptCache.ProviderDefault,
        promptCacheRoutingKey!: ?String = None,
        toolChoice!: LlmWireToolChoice = LlmWireToolChoice.ProviderDefault,
        structuredOutput!: LlmWireStructuredOutput = LlmWireStructuredOutput.ProviderDefault
    ) {
        this.model = model
        this.messages = messages
        this.system = system
        this.tools = tools
        this.thinking = thinking
        this.maxOutputTokens = maxOutputTokens
        this.streaming = streaming
        this.parallelToolCalls = parallelToolCalls
        this.serviceTier = serviceTier
        this.generationSpeed = generationSpeed
        this.promptCache = promptCache
        this.promptCacheRoutingKey = promptCacheRoutingKey
        this.toolChoice = toolChoice
        this.structuredOutput = structuredOutput
    }
}

public class LlmWireUsage {
    public let inputTokens: ?Int64
    public let outputTokens: ?Int64
    public let reasoningTokens: ?Int64
    public let cacheReadTokens: ?Int64
    public let cacheWriteTokens: ?Int64
    public init(inputTokens!: ?Int64 = None, outputTokens!: ?Int64 = None, reasoningTokens!: ?Int64 = None, cacheReadTokens!: ?Int64 = None, cacheWriteTokens!: ?Int64 = None) {
        this.inputTokens = inputTokens
        this.outputTokens = outputTokens
        this.reasoningTokens = reasoningTokens
        this.cacheReadTokens = cacheReadTokens
        this.cacheWriteTokens = cacheWriteTokens
    }
}

public class LlmWireReply {
    public let responseId: String
    public let model: String
    public let blocks: Array<LlmWireBlock>
    public let usage: LlmWireUsage
    public let rawStopReason: String
    public init(responseId!: String = "", model!: String = "", blocks!: Array<LlmWireBlock> = [], usage!: LlmWireUsage = LlmWireUsage(), rawStopReason!: String = "") {
        this.responseId = responseId
        this.model = model
        this.blocks = blocks
        this.usage = usage
        this.rawStopReason = rawStopReason
    }
    public func toContinuationInput(): Array<LlmWireMessage> {
        let replayable = ArrayList<LlmWireBlock>()
        for (block in blocks) { match (block) {
            case LlmWireBlock.Text(_) | LlmWireBlock.ToolCall(_) | LlmWireBlock.NativeReplay(_) => replayable.add(block)
            case _ => ()
        } }
        if (replayable.isEmpty()) { [] } else { [LlmWireMessage(LlmWireRole.Assistant, replayable.toArray())] }
    }
}

public enum LlmWirePendingReply { Queued(LlmWireReply) | InProgress(LlmWireReply) }
public enum LlmWireIncompleteReason {
    MaxTokens | Length | ContentFilter | ModelContextWindowExceeded | PauseTurn | Other(String)
}
public enum LlmWireFailureKind { ProviderError | Cancelled | InsufficientSystemResource | Other }
public class LlmWireFailure {
    public let kind: LlmWireFailureKind
    public let message: String
    public let provider: String
    public let providerErrorCode: String
    public let providerErrorType: String
    public let retryable: Bool
    public init(kind: LlmWireFailureKind, message: String, provider!: String = "", providerErrorCode!: String = "", providerErrorType!: String = "", retryable!: Bool = false) {
        this.kind = kind
        this.message = message
        this.provider = provider
        this.providerErrorCode = providerErrorCode
        this.providerErrorType = providerErrorType
        this.retryable = retryable
    }
}
public enum LlmWireTerminal {
    Succeeded(LlmWireReply)
    | Incomplete(LlmWireReply, LlmWireIncompleteReason)
    | Failed(LlmWireFailure)
}
public enum LlmWireResponseState { Pending(LlmWirePendingReply) | Terminal(LlmWireTerminal) }
