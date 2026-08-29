package llm4cj

import yjson.*
import std.collection.*
import std.deriving.Derive

@Derive[Equatable]
public enum LlmWireProtocol { Responses | ChatCompletions | Messages }
@Derive[Equatable]
public enum LlmWireRole { User | Assistant }
@Derive[Equatable]
public enum LlmWireInstructionRole { System | Developer }
@Derive[Equatable]
public enum LlmWireInputModality { Text | Image }
@Derive[Equatable]
public enum LlmWireImageSourceKind { Url | Base64 | File }
@Derive[Equatable]
public enum LlmWireImageDetail { Auto | Low | High }
@Derive[Equatable]
public enum LlmWireReasoningEffort { ProviderDefault | Minimal | Low | Medium | High | XHigh | Max }
@Derive[Equatable]
public enum LlmWireThinkingMode { ProviderDefault | Disabled | Enabled | Budget(Int64) | Adaptive }
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
@Derive[Equatable]
public enum LlmWireOutputPhase { Unspecified | Analysis | Commentary | Final }
@Derive[Equatable]
public enum LlmWireCitationKind {
    Url | File | CharacterRange | PageRange | ContentBlockRange | WebSearchResult | SearchResult
}

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

public class LlmWireCitation {
    public let kind: LlmWireCitationKind
    public let citedText: String
    public let documentIndex: ?Int64
    public let documentTitle: String
    public let startIndex: ?Int64
    public let endIndex: ?Int64
    public let startPage: ?Int64
    public let endPage: ?Int64
    public let startBlock: ?Int64
    public let endBlock: ?Int64
    public let url: String
    public let title: String
    public let fileId: String
    public let filename: String
    public init(
        kind: LlmWireCitationKind, citedText!: String = "", documentIndex!: ?Int64 = None,
        documentTitle!: String = "", startIndex!: ?Int64 = None, endIndex!: ?Int64 = None,
        startPage!: ?Int64 = None, endPage!: ?Int64 = None, startBlock!: ?Int64 = None,
        endBlock!: ?Int64 = None, url!: String = "", title!: String = "", fileId!: String = "",
        filename!: String = ""
    ) {
        this.kind = kind; this.citedText = citedText; this.documentIndex = documentIndex
        this.documentTitle = documentTitle; this.startIndex = startIndex; this.endIndex = endIndex
        this.startPage = startPage; this.endPage = endPage; this.startBlock = startBlock; this.endBlock = endBlock
        this.url = url; this.title = title; this.fileId = fileId; this.filename = filename
    }
}

public enum LlmWireAnnotation { UrlCitation(LlmWireCitation) | FileCitation(LlmWireCitation) }

public class LlmWireTokenLogprobCandidate {
    public let token: String
    public let bytes: Array<Int64>
    public let logprob: LlmWireJson
    public init(token: String, logprob: LlmWireJson, bytes!: Array<Int64> = []) {
        this.token = token; this.logprob = logprob; this.bytes = copyValues(bytes)
    }
}

public class LlmWireTokenLogprob {
    public let token: String
    public let bytes: Array<Int64>
    public let logprob: LlmWireJson
    public let topLogprobs: Array<LlmWireTokenLogprobCandidate>
    public init(token: String, logprob: LlmWireJson, bytes!: Array<Int64> = [], topLogprobs!: Array<LlmWireTokenLogprobCandidate> = []) {
        this.token = token; this.logprob = logprob; this.bytes = copyValues(bytes); this.topLogprobs = copyValues(topLogprobs)
    }
}

public class LlmWireTextBlock {
    public let text: String
    public let citations: Array<LlmWireCitation>
    public let annotations: Array<LlmWireAnnotation>
    public let logprobs: Array<LlmWireTokenLogprob>
    public let phase: LlmWireOutputPhase
    public init(
        text: String, citations!: Array<LlmWireCitation> = [], annotations!: Array<LlmWireAnnotation> = [],
        logprobs!: Array<LlmWireTokenLogprob> = [], phase!: LlmWireOutputPhase = LlmWireOutputPhase.Unspecified
    ) {
        this.text = text; this.citations = copyValues(citations); this.annotations = copyValues(annotations)
        this.logprobs = copyValues(logprobs); this.phase = phase
    }
}

public class LlmWireInstruction {
    public let role: LlmWireInstructionRole
    public let text: String
    public init(role: LlmWireInstructionRole, text: String) { this.role = role; this.text = text }
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
    Complete(LlmWireJson)
    | InvalidJson(String)
    | InvalidShape(LlmWireJson)
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

public enum LlmWireToolResultContent {
    Text(LlmWireTextBlock) | Image(LlmWireImageBlock)
}

public class LlmWireToolResultBlock {
    public let callId: String
    public let content: Array<LlmWireToolResultContent>
    public let isError: Bool
    public init(callId: String, content: Array<LlmWireToolResultContent>, isError!: Bool = false) {
        this.callId = callId
        this.content = content
        this.isError = isError
    }
}

public class LlmWireRefusalBlock {
    public let text: String
    public let category: ?String
    public let explanation: ?String
    public let logprobs: Array<LlmWireTokenLogprob>
    public init(text: String, category!: ?String = None, explanation!: ?String = None, logprobs!: Array<LlmWireTokenLogprob> = []) {
        this.text = text; this.category = category; this.explanation = explanation; this.logprobs = copyValues(logprobs)
    }
}

public class LlmWireOpaqueBlock {
    public let nativeType: String
    public let completion: LlmWireOpaqueCompletion
    private let diagnosticJson: String

    init(nativeType: String, payload: JsonNode, completion!: LlmWireOpaqueCompletion = LlmWireOpaqueCompletion.Complete) {
        if (nativeType == "" || payload.wireKind != WireJsonKind.Object) {
            throw LlmWireError(LlmWireErrorKind.InvalidWire, "llm.opaque_payload_invalid", "opaque diagnostic payload must be a typed object")
        }
        this.nativeType = nativeType
        this.completion = completion
        this.diagnosticJson = payload.stringify()
    }

    func payload(): JsonNode { parseWireJson(diagnosticJson) }
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
        if (complete.wireKind != WireJsonKind.Boolean || !complete.bool) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.native_replay_incomplete", "only complete native state can be restored for replay") }
        nativeReplayFromPayload(
            parseProtocol(wireRequiredString(root, "protocol")), wireRequiredString(root, "dialect_id"), wireRequiredString(root, "native_type"),
            wireObject(wireRequiredField(root, "payload"), "native replay payload"), schemaVersion: wireRequiredInt(root, "schema_version"),
            modelConstraint: wireOptionalString(root, "model_constraint"), scope: parseReplayScope(wireRequiredString(root, "scope")),
            assistantTurnIndex: wireRequiredInt(root, "assistant_turn_index"), blockOrder: wireRequiredInt(root, "block_order"),
            displayReasoning: wireOptionalString(root, "display_reasoning")
        )
    }

    func payload(): JsonNode { parseWireJson(canonicalReplayJson) }
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
    if (dialectId == "" || nativeType == "" || schemaVersion != 1 || assistantTurnIndex != 0 || blockOrder < 0 || payload.wireKind != WireJsonKind.Object) {
        throw LlmWireError(LlmWireErrorKind.InvalidWire, "llm.native_replay_payload_invalid", "native replay metadata and payload must be complete")
    }
    if (scope != LlmWireNativeReplayScope.AssistantTurn) {
        throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.native_replay_scope_unsupported", "conversation-scoped native replay is not supported")
    }
    match (payload.field("type")) {
        case Some(value) => if (value.wireKind != WireJsonKind.Text || value.text != nativeType) { throw LlmWireError(LlmWireErrorKind.InvalidWire, "llm.native_replay_type_mismatch", "native replay type does not match payload") }
        case None => throw LlmWireError(LlmWireErrorKind.InvalidWire, "llm.native_replay_type_missing", "native replay payload must contain type")
    }
    validateNativeReplayPayload(protocol, dialectId, nativeType, payload)
    LlmWireNativeReplayBlock(protocol, dialectId, nativeType, schemaVersion, modelConstraint, scope, assistantTurnIndex, blockOrder, completion, payload.stringify(), displayReasoning)
}

func validateNativeReplayPayload(protocol: LlmWireProtocol, dialectId: String, nativeType: String, payload: JsonNode): Unit {
    let allowed = match ((protocol, dialectId, nativeType)) {
        case (LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking") |
             (LlmWireProtocol.Messages, "anthropic.messages.v1", "redacted_thinking") |
             (LlmWireProtocol.Messages, "deepseek.messages.v1", "thinking") |
             (LlmWireProtocol.Responses, "openai.responses.v1", "reasoning") |
             (LlmWireProtocol.Responses, "deepseek.responses.v1", "reasoning") |
             (LlmWireProtocol.ChatCompletions, "deepseek.chat.v1", "reasoning_content") => true
        case _ => false
    }
    if (!allowed) {
        throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.native_replay_type_unsupported", "native type is not replayable for this protocol and dialect")
    }
    match (nativeType) {
        case "thinking" =>
            let _ = wireRequiredString(payload, "thinking")
            let _ = wireRequiredString(payload, "signature")
        case "redacted_thinking" => let _ = wireRequiredString(payload, "data")
        case "reasoning_content" => let _ = wireRequiredString(payload, "reasoning_content")
        case "reasoning" =>
            let _ = wireRequiredString(payload, "id")
            let hasSummary = payload.field("summary").isSome()
            let hasContent = payload.field("content").isSome()
            if (!hasSummary && !hasContent) { throw LlmWireError(LlmWireErrorKind.InvalidWire, "llm.native_replay_payload_invalid", "Responses reasoning replay requires summary or content") }
            if (hasSummary) { let _ = wireOptionalArray(payload, "summary") }
            if (hasContent) { let _ = wireOptionalArray(payload, "content") }
        case _ => ()
    }
}

func protocolName(value: LlmWireProtocol): String { match (value) { case LlmWireProtocol.Responses => "responses"; case LlmWireProtocol.ChatCompletions => "chat_completions"; case LlmWireProtocol.Messages => "messages" } }
func parseProtocol(value: String): LlmWireProtocol { match (value) { case "responses" => LlmWireProtocol.Responses; case "chat_completions" => LlmWireProtocol.ChatCompletions; case "messages" => LlmWireProtocol.Messages; case _ => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.native_replay_protocol_invalid", "unknown native replay protocol") } }
func replayScopeName(value: LlmWireNativeReplayScope): String { match (value) { case LlmWireNativeReplayScope.AssistantTurn => "assistant_turn"; case LlmWireNativeReplayScope.Conversation => "conversation" } }
func parseReplayScope(value: String): LlmWireNativeReplayScope { match (value) { case "assistant_turn" => LlmWireNativeReplayScope.AssistantTurn; case "conversation" => LlmWireNativeReplayScope.Conversation; case _ => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.native_replay_scope_invalid", "unknown native replay scope") } }

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

public enum LlmWireOutputBlock {
    Text(LlmWireTextBlock)
    | Reasoning(LlmWireReasoningBlock)
    | ToolCall(LlmWireToolCallBlock)
    | Refusal(LlmWireRefusalBlock)
    | NativeReplay(LlmWireNativeReplayBlock)
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
    public let inputSchema: LlmWireJson
    public init(name: String, description: String, inputSchema: LlmWireJson) {
        this.name = name
        this.description = description
        this.inputSchema = inputSchema
    }
}

public class LlmWireJsonSchema {
    public let name: String
    public let description: String
    public let schema: LlmWireJson
    public let strict: Bool
    public init(name: String, schema: LlmWireJson, description!: String = "", strict!: Bool = true) {
        this.name = name
        this.description = description
        this.schema = schema
        this.strict = strict
    }
}

public enum LlmWireStructuredOutput {
    ProviderDefault | Text | JsonObject | JsonSchema(LlmWireJsonSchema) | JsonSchemaDocument(LlmWireJson)
}

public class LlmWireRequest {
    public let model: String
    public let instructions: Array<LlmWireInstruction>
    public let messages: Array<LlmWireMessage>
    public let tools: Array<LlmWireTool>
    public let thinkingMode: LlmWireThinkingMode
    public let reasoningEffort: LlmWireReasoningEffort
    public let maxOutputTokens: ?Int64
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
        instructions!: Array<LlmWireInstruction> = [],
        tools!: Array<LlmWireTool> = [],
        thinkingMode!: LlmWireThinkingMode = LlmWireThinkingMode.ProviderDefault,
        reasoningEffort!: LlmWireReasoningEffort = LlmWireReasoningEffort.ProviderDefault,
        maxOutputTokens!: ?Int64 = None,
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
        this.instructions = instructions
        this.tools = tools
        this.thinkingMode = thinkingMode
        this.reasoningEffort = reasoningEffort
        this.maxOutputTokens = maxOutputTokens
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
    public let totalTokens: ?Int64
    public let webSearchRequests: ?Int64
    public let webFetchRequests: ?Int64
    public let serviceTier: ?String
    public init(
        inputTokens!: ?Int64 = None, outputTokens!: ?Int64 = None, reasoningTokens!: ?Int64 = None,
        cacheReadTokens!: ?Int64 = None, cacheWriteTokens!: ?Int64 = None, totalTokens!: ?Int64 = None,
        webSearchRequests!: ?Int64 = None, webFetchRequests!: ?Int64 = None, serviceTier!: ?String = None
    ) {
        this.inputTokens = inputTokens
        this.outputTokens = outputTokens
        this.reasoningTokens = reasoningTokens
        this.cacheReadTokens = cacheReadTokens
        this.cacheWriteTokens = cacheWriteTokens
        this.totalTokens = totalTokens
        this.webSearchRequests = webSearchRequests
        this.webFetchRequests = webFetchRequests
        this.serviceTier = serviceTier
    }
}

@Derive[Equatable]
public enum LlmWireIncompleteReason {
    MaxTokens | Length | ContentFilter | ModelContextWindowExceeded | PauseTurn | Other(String)
}

public enum LlmWireChoiceOutcome {
    Completed | Incomplete(LlmWireIncompleteReason) | Refused(LlmWireRefusalBlock)
}

public class LlmWireChoice {
    public let index: Int64
    public let blocks: Array<LlmWireOutputBlock>
    public let outcome: LlmWireChoiceOutcome
    public let rawStopReason: String
    public init(index: Int64, blocks: Array<LlmWireOutputBlock>, outcome: LlmWireChoiceOutcome, rawStopReason!: String = "") {
        if (index < 0) { throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.choice_index_invalid", "choice index must be non-negative") }
        this.index = index; this.blocks = copyValues(blocks); this.outcome = outcome; this.rawStopReason = rawStopReason
    }
    public func toContinuationInput(): LlmWireResult<Array<LlmWireMessage>> {
        try { LlmWireResult.Ok(projectContinuationBlocks(blocks)) }
        catch (error: LlmWireError) { LlmWireResult.Err(error) }
    }
}

public class LlmWireReply {
    public let responseId: String
    public let model: String
    public let blocks: Array<LlmWireOutputBlock>
    public let usage: LlmWireUsage
    public let rawStopReason: String
    public let choices: Array<LlmWireChoice>
    public init(
        responseId!: String = "", model!: String = "", blocks!: Array<LlmWireOutputBlock> = [],
        usage!: LlmWireUsage = LlmWireUsage(), rawStopReason!: String = "", choices!: Array<LlmWireChoice> = []
    ) {
        this.responseId = responseId
        this.model = model
        this.choices = if (choices.isEmpty()) {
            [LlmWireChoice(0, blocks, inferChoiceOutcome(rawStopReason, blocks), rawStopReason: rawStopReason)]
        } else { copyValues(choices) }
        this.blocks = if (this.choices.isEmpty()) { [] } else { copyValues(this.choices[0].blocks) }
        this.usage = usage
        this.rawStopReason = rawStopReason
    }
    public func toContinuationInput(): Array<LlmWireMessage> {
        if (choices.size != 1) {
            throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.continuation_choice_required", "multi-choice replies require an explicit choice")
        }
        projectContinuationBlocks(choices[0].blocks)
    }
    public func toContinuationInput(choiceIndex: Int64): LlmWireResult<Array<LlmWireMessage>> {
        for (choice in choices where choice.index == choiceIndex) { return choice.toContinuationInput() }
        LlmWireResult.Err(LlmWireError(LlmWireErrorKind.InvalidState, "llm.continuation_choice_missing", "reply does not contain the selected choice"))
    }
}

func projectContinuationBlocks(blocks: Array<LlmWireOutputBlock>): Array<LlmWireMessage> {
        let replayable = ArrayList<LlmWireBlock>()
        for (block in blocks) { match (block) {
            case LlmWireOutputBlock.Text(value) => replayable.add(LlmWireBlock.Text(value))
            case LlmWireOutputBlock.NativeReplay(value) =>
                if (value.blockOrder != replayable.size) {
                    throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.native_replay_projection_order_invalid", "continuation projection would change provider-native block order")
                }
                replayable.add(LlmWireBlock.NativeReplay(value))
            case LlmWireOutputBlock.ToolCall(value) => match (value.arguments) {
                case LlmWireToolArguments.Complete(_) => replayable.add(LlmWireBlock.ToolCall(value))
                case _ => throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.tool_arguments_not_executable", "diagnostic or partial tool arguments cannot be projected into continuation input")
            }
            case _ => throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.continuation_projection_lossy", "continuation projection would discard a semantic reply block")
        } }
        if (replayable.isEmpty()) { [] } else { [LlmWireMessage(LlmWireRole.Assistant, replayable.toArray())] }
}

func inferChoiceOutcome(rawStopReason: String, blocks: Array<LlmWireOutputBlock>): LlmWireChoiceOutcome {
    for (block in blocks) { match (block) { case LlmWireOutputBlock.Refusal(value) => return LlmWireChoiceOutcome.Refused(value); case _ => () } }
    match (rawStopReason) {
        case "length" => LlmWireChoiceOutcome.Incomplete(LlmWireIncompleteReason.Length)
        case "max_tokens" => LlmWireChoiceOutcome.Incomplete(LlmWireIncompleteReason.MaxTokens)
        case "content_filter" => LlmWireChoiceOutcome.Incomplete(LlmWireIncompleteReason.ContentFilter)
        case "model_context_window_exceeded" => LlmWireChoiceOutcome.Incomplete(LlmWireIncompleteReason.ModelContextWindowExceeded)
        case "pause_turn" => LlmWireChoiceOutcome.Incomplete(LlmWireIncompleteReason.PauseTurn)
        case _ => LlmWireChoiceOutcome.Completed
    }
}

public enum LlmWirePendingReply { Queued(LlmWireReply) | InProgress(LlmWireReply) }
public enum LlmWireFailureKind { ProviderError | Cancelled | InsufficientSystemResource | Other }
public class LlmWireFailure {
    public let kind: LlmWireFailureKind
    public let message: String
    public let provider: String
    public let providerErrorCode: String
    public let providerErrorType: String
    public let retryable: Bool
    public let httpStatus: ?Int64
    public let retryAfterMillis: ?Int64
    public let providerRequestId: String
    public init(
        kind: LlmWireFailureKind, message: String, provider!: String = "",
        providerErrorCode!: String = "", providerErrorType!: String = "",
        retryable!: Bool = false, httpStatus!: ?Int64 = None,
        retryAfterMillis!: ?Int64 = None, providerRequestId!: String = ""
    ) {
        this.kind = kind
        this.message = message
        this.provider = provider
        this.providerErrorCode = providerErrorCode
        this.providerErrorType = providerErrorType
        this.retryable = retryable
        this.httpStatus = httpStatus
        this.retryAfterMillis = retryAfterMillis
        this.providerRequestId = providerRequestId
    }
}
public enum LlmWireTerminal {
    Completed(LlmWireReply)
    | ProviderFailed(LlmWireFailure)
    | Cancelled(LlmWireFailure)
}
public enum LlmWireResponseState { Pending(LlmWirePendingReply) | Terminal(LlmWireTerminal) }
