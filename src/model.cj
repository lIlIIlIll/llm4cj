package llm4cj

import yjson.*
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
public enum LlmWireThinkingControl {
    ProviderDefault | Disabled | Enabled | Effort(LlmWireThinkingLevel) |
    Budget(Int64) | Adaptive(?LlmWireThinkingLevel)
}
@Derive[Equatable]
public enum LlmWireCachePolicy { ProviderDefault | StablePrefix }
@Derive[Equatable]
public enum LlmWireToolChoice { ProviderDefault | Auto | NoTools | Required }
@Derive[Equatable]
public enum LlmWireValidationPolicy { Strict | Lenient }
@Derive[Equatable]
public enum LlmWireOpaqueCompletion { Complete | Partial }

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
    public init(text: String) { this.text = text }
}

public enum LlmWireToolArguments {
    Complete(JsonNode, String)
    | InvalidJson(String)
    | InvalidShape(JsonNode, String)
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
    public let protocol: LlmWireProtocol
    public let dialectId: String
    public let nativeType: String
    public let completion: LlmWireOpaqueCompletion
    public let displayReasoning: ?String
    private let canonicalReplayJson: String

    private init(
        protocol: LlmWireProtocol,
        dialectId: String,
        nativeType: String,
        completion: LlmWireOpaqueCompletion,
        canonicalReplayJson: String,
        displayReasoning: ?String
    ) {
        this.protocol = protocol
        this.dialectId = dialectId
        this.nativeType = nativeType
        this.completion = completion
        this.canonicalReplayJson = canonicalReplayJson
        this.displayReasoning = displayReasoning
    }

    public static func fromPayload(
        protocol: LlmWireProtocol,
        dialectId: String,
        nativeType: String,
        payload: JsonNode,
        completion!: LlmWireOpaqueCompletion = LlmWireOpaqueCompletion.Complete,
        displayReasoning!: ?String = None
    ): LlmWireOpaqueBlock {
        LlmWireOpaqueBlock(protocol, dialectId, nativeType, completion, payload.stringify(), displayReasoning)
    }

    public static func restore(
        protocol: LlmWireProtocol,
        dialectId: String,
        nativeType: String,
        canonicalReplayJson: String,
        completion!: LlmWireOpaqueCompletion = LlmWireOpaqueCompletion.Complete,
        displayReasoning!: ?String = None
    ): LlmWireOpaqueBlock {
        let parsed = parseWireJson(canonicalReplayJson)
        if (parsed.wireKind != WireJsonKind.Object) {
            throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.opaque_payload_invalid", "opaque replay payload must be an object")
        }
        LlmWireOpaqueBlock(protocol, dialectId, nativeType, completion, parsed.stringify(), displayReasoning)
    }

    public func payload(): JsonNode { parseWireJson(canonicalReplayJson) }
    public func snapshot(): String { canonicalReplayJson }
}

public enum LlmWireBlock {
    Text(LlmWireTextBlock)
    | Image(LlmWireImageBlock)
    | Reasoning(LlmWireReasoningBlock)
    | ToolCall(LlmWireToolCallBlock)
    | ToolResult(LlmWireToolResultBlock)
    | Refusal(LlmWireRefusalBlock)
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

public class LlmWireStructuredOutput {
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

public class LlmWireRequest {
    public let model: String
    public let system: String
    public let messages: Array<LlmWireMessage>
    public let tools: Array<LlmWireTool>
    public let thinking: LlmWireThinkingControl
    public let maxOutputTokens: ?Int64
    public let streaming: ?Bool
    public let parallelToolCalls: ?Bool
    public let serviceTier: ?String
    public let cachePolicy: LlmWireCachePolicy
    public let cacheKey: ?String
    public let toolChoice: LlmWireToolChoice
    public let structuredOutput: ?LlmWireStructuredOutput

    public init(
        model: String,
        messages: Array<LlmWireMessage>,
        system!: String = "",
        tools!: Array<LlmWireTool> = [],
        thinking!: LlmWireThinkingControl = LlmWireThinkingControl.ProviderDefault,
        maxOutputTokens!: ?Int64 = None,
        streaming!: ?Bool = None,
        parallelToolCalls!: ?Bool = None,
        serviceTier!: ?String = None,
        cachePolicy!: LlmWireCachePolicy = LlmWireCachePolicy.ProviderDefault,
        cacheKey!: ?String = None,
        toolChoice!: LlmWireToolChoice = LlmWireToolChoice.ProviderDefault,
        structuredOutput!: ?LlmWireStructuredOutput = None
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
        this.cachePolicy = cachePolicy
        this.cacheKey = cacheKey
        this.toolChoice = toolChoice
        this.structuredOutput = structuredOutput
    }
}

public class LlmWireUsage {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    public init(inputTokens!: Int64 = 0, outputTokens!: Int64 = 0, reasoningTokens!: Int64 = 0, cacheReadTokens!: Int64 = 0, cacheWriteTokens!: Int64 = 0) {
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
