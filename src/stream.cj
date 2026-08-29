package llm4cj

import std.collection.*
import std.deriving.Derive
import yjson.*

@Derive[Equatable]
public enum LlmWireEventKind {
    StreamStarted | ContentBlockStarted | TextDelta | ReasoningDelta | RefusalDelta |
    ToolCallStarted | ToolArgumentsDelta | ContentBlockCompleted |
    UsageDelta | UsageCompleted | ProviderError | MessageTerminalObserved
}

public class LlmWireEvent {
    public let kind: LlmWireEventKind
    public let text: String
    public let blockIndex: Int64
    public let choiceIndex: Int64
    public let toolCallIndex: Int64
    public let outputIndex: Int64
    public let contentIndex: Int64
    public let summaryIndex: Int64
    public let itemId: String
    public let callId: String
    public let name: String
    public let rawStopReason: String
    public let usage: ?LlmWireUsage
    public init(
        kind: LlmWireEventKind, text!: String = "", blockIndex!: Int64 = -1,
        choiceIndex!: Int64 = -1, toolCallIndex!: Int64 = -1,
        outputIndex!: Int64 = -1, contentIndex!: Int64 = -1, summaryIndex!: Int64 = -1,
        itemId!: String = "", callId!: String = "",
        name!: String = "", rawStopReason!: String = "", usage!: ?LlmWireUsage = None
    ) {
        this.kind = kind; this.text = text; this.blockIndex = blockIndex
        this.choiceIndex = choiceIndex; this.toolCallIndex = toolCallIndex
        this.outputIndex = outputIndex; this.contentIndex = contentIndex; this.summaryIndex = summaryIndex
        this.itemId = itemId; this.callId = callId
        this.name = name; this.rawStopReason = rawStopReason; this.usage = usage
    }
}

public class LlmWireStreamUpdate {
    public let events: Array<LlmWireEvent>
    public let terminal: ?LlmWireTerminal
    public init(events!: Array<LlmWireEvent> = [], terminal!: ?LlmWireTerminal = None) {
        this.events = events; this.terminal = terminal
    }
}

public interface LlmWireStreamDecoder {
    func push(event: SseEvent): LlmWireStreamUpdate
    func finishTransport(): LlmWireTerminal
}

public class LlmWireStreamLimits {
    public let maxTotalSemanticBytes: Int64
    public let maxTextBytes: Int64
    public let maxReasoningBytes: Int64
    public let maxToolArgumentsBytes: Int64
    public let maxRetainedStateBytes: Int64
    public let maxBlocks: Int64
    public let maxToolCalls: Int64
    public let maxEvents: Int64
    public init(
        maxTotalSemanticBytes!: Int64 = 67108864, maxTextBytes!: Int64 = 33554432,
        maxReasoningBytes!: Int64 = 33554432, maxToolArgumentsBytes!: Int64 = 8388608,
        maxRetainedStateBytes!: Int64 = 67108864,
        maxBlocks!: Int64 = 4096, maxToolCalls!: Int64 = 1024, maxEvents!: Int64 = 1048576
    ) {
        if (maxTotalSemanticBytes < 1 || maxTextBytes < 1 || maxReasoningBytes < 1 || maxToolArgumentsBytes < 1 || maxRetainedStateBytes < 1 || maxBlocks < 1 || maxToolCalls < 1 || maxEvents < 1) {
            throw IllegalArgumentException("invalid stream limits")
        }
        this.maxTotalSemanticBytes = maxTotalSemanticBytes; this.maxTextBytes = maxTextBytes
        this.maxReasoningBytes = maxReasoningBytes; this.maxToolArgumentsBytes = maxToolArgumentsBytes
        this.maxRetainedStateBytes = maxRetainedStateBytes
        this.maxBlocks = maxBlocks; this.maxToolCalls = maxToolCalls; this.maxEvents = maxEvents
    }
}

class StreamBudget {
    private let limits: LlmWireStreamLimits
    private var totalBytes: Int64 = 0
    private var textBytes: Int64 = 0
    private var reasoningBytes: Int64 = 0
    private var toolArgumentBytes: Int64 = 0
    private var retainedBytes: Int64 = 0
    private var blocks: Int64 = 0
    private var toolCalls: Int64 = 0
    private var events: Int64 = 0
    init(limits: LlmWireStreamLimits) { this.limits = limits }
    func semantic(value: String, kind: String): Unit {
        let size = Int64(value.toArray().size); totalBytes += size; retainBytes(size)
        if (totalBytes > limits.maxTotalSemanticBytes) { limit("llm.stream_semantic_too_large", "stream semantic output exceeds configured limit") }
        match (kind) {
            case "text" => textBytes += size; if (textBytes > limits.maxTextBytes) { limit("llm.stream_text_too_large", "stream text exceeds configured limit") }
            case "reasoning" => reasoningBytes += size; if (reasoningBytes > limits.maxReasoningBytes) { limit("llm.stream_reasoning_too_large", "stream reasoning exceeds configured limit") }
            case "tool" => toolArgumentBytes += size; if (toolArgumentBytes > limits.maxToolArgumentsBytes) { limit("llm.stream_tool_arguments_too_large", "stream tool arguments exceed configured limit") }
            case _ => ()
        }
    }
    func retain(value: String): Unit { retainBytes(Int64(value.toArray().size)) }
    private func retainBytes(size: Int64): Unit {
        if (size > limits.maxRetainedStateBytes - retainedBytes) { limit("llm.stream_retained_state_too_large", "stream retained state exceeds configured limit") }
        retainedBytes += size
    }
    func block(): Unit { blocks++; if (blocks > limits.maxBlocks) { limit("llm.stream_blocks_too_many", "stream produced too many content blocks") } }
    func toolCall(): Unit { toolCalls++; if (toolCalls > limits.maxToolCalls) { limit("llm.stream_tool_calls_too_many", "stream produced too many tool calls") } }
    func terminalReply(reply: LlmWireReply): Unit {
        for (entry in reply.blocks) { match (entry) {
            case LlmWireBlock.Text(value) => block(); semantic(value.text, "text")
            case LlmWireBlock.Reasoning(value) => block(); semantic(value.text, "reasoning")
            case LlmWireBlock.Refusal(value) => block(); semantic(value.text, "text")
            case LlmWireBlock.ToolCall(value) =>
                block(); toolCall()
                match (value.arguments) {
                    case LlmWireToolArguments.Complete(arguments) => semantic(arguments.stringify(), "tool")
                    case LlmWireToolArguments.InvalidJson(raw) => semantic(raw, "tool")
                    case LlmWireToolArguments.Partial(raw) => semantic(raw, "tool")
                    case LlmWireToolArguments.InvalidShape(arguments) => semantic(arguments.stringify(), "tool")
                }
            case LlmWireBlock.NativeReplay(value) =>
                block(); retain(value.payload().stringify())
                match (value.displayReasoning) { case Some(display) => semantic(display, "reasoning"); case None => () }
            case _ => block()
        } }
    }
    func inputEvent(): Unit { events++; if (events > limits.maxEvents) { limit("llm.stream_events_too_many", "stream consumed too many provider events") } }
    private func limit(code: String, message: String): Nothing { throw LlmTransportError(LlmTransportErrorKind.LimitExceeded, code, message) }
}

func newWireStreamDecoder(codec: LlmWireCodec, limits: LlmWireStreamLimits): LlmWireStreamDecoder {
    match (codec.protocol) {
        case LlmWireProtocol.Responses => ResponsesStreamDecoder(codec, limits)
        case LlmWireProtocol.ChatCompletions => ChatStreamDecoder(codec, limits)
        case LlmWireProtocol.Messages => MessagesStreamDecoder(codec, limits)
    }
}

open class StreamLifecycle {
    protected var terminal: ?LlmWireTerminal = None
    protected var closed = false
    private var failed: ?LlmTransportError = None

    protected func guardedPush(codec: LlmWireCodec, operation: () -> LlmWireStreamUpdate): LlmWireStreamUpdate {
        match (failed) { case Some(_) => throw withCodecContext(LlmTransportError(LlmTransportErrorKind.InvalidState, "llm.stream_failed", "stream decoder is poisoned by an earlier error"), codec, LlmTransportPhase.SemanticAssembly); case None => () }
        try { operation() }
        catch (error: LlmTransportError) { let contextual = withCodecContext(error, codec, LlmTransportPhase.SemanticAssembly); failed = Some(contextual); throw contextual }
    }

    protected func beforePush(event: SseEvent): Bool {
        if (closed) { throw LlmTransportError(LlmTransportErrorKind.InvalidState, "llm.stream_closed", "stream decoder is closed") }
        match (terminal) {
            case Some(_) =>
                if (event.data == "[DONE]") { return false }
                throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.stream_event_after_terminal", "semantic stream event appeared after terminal")
            case None => true
        }
    }

    protected func finish(codec: LlmWireCodec): LlmWireTerminal {
        match (failed) { case Some(_) => throw withCodecContext(LlmTransportError(LlmTransportErrorKind.InvalidState, "llm.stream_failed", "stream decoder is poisoned by an earlier error"), codec, LlmTransportPhase.SemanticAssembly); case None => () }
        if (closed) { throw withCodecContext(LlmTransportError(LlmTransportErrorKind.InvalidState, "llm.stream_closed", "stream decoder is closed"), codec, LlmTransportPhase.SemanticAssembly) }
        match (terminal) {
            case Some(value) => closed = true; value
            case None =>
                let error = LlmTransportError(
                    LlmTransportErrorKind.InvalidWire, "llm.stream_terminal_missing", "stream ended without a protocol terminal",
                    provider: codec.provider, phase: Some(LlmTransportPhase.SemanticAssembly), protocol: Some(codec.protocol), dialectId: codec.dialect.compatibilityId
                )
                failed = Some(error); throw error
        }
    }
}

class ResponseStreamCall {
    let outputIndex: Int64
    let itemId: String
    let callId: String
    var name: String
    let arguments = StringBuilder()
    var completed = false
    init(outputIndex: Int64, itemId: String, callId: String, name: String) { this.outputIndex = outputIndex; this.itemId = itemId; this.callId = callId; this.name = name }
}
class ResponseStreamPart {
    let index: Int64
    let nativeType: String
    let summary: Bool
    let text = StringBuilder()
    var valueCompleted = false
    var completed = false
    init(index: Int64, nativeType: String, summary!: Bool = false) { this.index = index; this.nativeType = nativeType; this.summary = summary }
}
class ResponseStreamItem {
    let outputIndex: Int64
    let itemId: String
    let nativeType: String
    let parts = ArrayList<ResponseStreamPart>()
    var completed = false
    init(outputIndex: Int64, itemId: String, nativeType: String) { this.outputIndex = outputIndex; this.itemId = itemId; this.nativeType = nativeType }
}
class ResponsesStreamDecoder <: StreamLifecycle & LlmWireStreamDecoder {
    private let codec: LlmWireCodec
    private let calls = ArrayList<ResponseStreamCall>()
    private let items = ArrayList<ResponseStreamItem>()
    private let budget: StreamBudget
    private var started = false
    private var createdObserved = false
    private var inProgressObserved = false
    private var responseId = ""
    private var model = ""
    init(codec: LlmWireCodec, limits: LlmWireStreamLimits) { this.codec = codec; this.budget = StreamBudget(limits) }

    public func push(event: SseEvent): LlmWireStreamUpdate { guardedPush(codec, { => budget.inputEvent(); pushActive(event) }) }
    private func pushActive(event: SseEvent): LlmWireStreamUpdate {
        if (!beforePush(event) || event.data == "") { return LlmWireStreamUpdate() }
        let root = wireObject(parseWireJson(event.data), "Responses stream event", provider: codec.provider)
        let kind = wireRequiredString(root, "type", provider: codec.provider)
        if (!started && kind != "response.created" && kind != "response.in_progress" && kind != "response.completed" && kind != "response.incomplete" && kind != "response.failed" && kind != "error") {
            invalidWire("llm.responses_event_before_start", "Responses semantic event appeared before response start", provider: codec.provider)
        }
        match (kind) {
            case "response.created" | "response.in_progress" => startResponsesStream(root, kind)
            case "response.output_text.delta" =>
                let delta = wireRequiredString(root, "delta", provider: codec.provider); budget.semantic(delta, "text")
                appendResponsesPart(root, "output_text", delta, false)
                LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.TextDelta, text: delta, outputIndex: requiredIndex(root, "output_index", codec.provider), contentIndex: requiredIndex(root, "content_index", codec.provider), itemId: wireRequiredString(root, "item_id", provider: codec.provider))])
            case "response.reasoning_summary_text.delta" =>
                let delta = wireRequiredString(root, "delta", provider: codec.provider); budget.semantic(delta, "reasoning")
                appendResponsesPart(root, "summary_text", delta, true)
                LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: delta, outputIndex: requiredIndex(root, "output_index", codec.provider), summaryIndex: requiredIndex(root, "summary_index", codec.provider), itemId: wireRequiredString(root, "item_id", provider: codec.provider))])
            case "response.reasoning_text.delta" =>
                let delta = wireRequiredString(root, "delta", provider: codec.provider); budget.semantic(delta, "reasoning")
                appendResponsesPart(root, "reasoning_text", delta, false)
                LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: delta, outputIndex: requiredIndex(root, "output_index", codec.provider), contentIndex: requiredIndex(root, "content_index", codec.provider), itemId: wireRequiredString(root, "item_id", provider: codec.provider))])
            case "response.refusal.delta" =>
                let delta = wireRequiredString(root, "delta", provider: codec.provider); budget.semantic(delta, "text")
                appendResponsesPart(root, "refusal", delta, false)
                LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.RefusalDelta, text: delta, outputIndex: requiredIndex(root, "output_index", codec.provider), contentIndex: requiredIndex(root, "content_index", codec.provider), itemId: wireRequiredString(root, "item_id", provider: codec.provider))])
            case "response.content_part.added" => startResponsesPart(root, false)
            case "response.content_part.done" => completeResponsesPart(root, false)
            case "response.output_item.added" =>
                let item = wireObject(wireRequiredField(root, "item", provider: codec.provider), "Responses output item", provider: codec.provider)
                let itemType = wireRequiredString(item, "type", provider: codec.provider)
                let outputIndex = requiredIndex(root, "output_index", codec.provider)
                rejectResponsesItemSemantic(codec, item, outputIndex)
                let itemId = wireRequiredString(item, "id", provider: codec.provider)
                if (outputIndex != items.size || findResponseItem(items, itemId).isSome() || findResponseItemAt(items, outputIndex).isSome()) { invalidWire("llm.responses_output_item_order_invalid", "Responses output item indexes must be contiguous and identities unique", provider: codec.provider) }
                budget.retain(itemId); budget.retain(itemType)
                items.add(ResponseStreamItem(outputIndex, itemId, itemType))
                if (itemType == "function_call") {
                    budget.block(); budget.toolCall()
                    if (findResponseCall(calls, itemId).isSome()) { invalidWire("llm.responses_function_call_duplicate", "Responses function item was started twice", provider: codec.provider) }
                    let call = ResponseStreamCall(outputIndex, itemId, wireRequiredString(item, "call_id", provider: codec.provider), optionalStringOrEmpty(item, "name", codec.provider))
                    budget.retain(call.callId); budget.retain(call.name)
                    calls.add(call)
                    LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ToolCallStarted, outputIndex: outputIndex, itemId: itemId, callId: call.callId, name: call.name)])
                } else if (itemType == "message" || itemType == "reasoning") { LlmWireStreamUpdate() }
                else { unsupportedSemantic(codec, itemType, item, "llm.responses_stream_block_unsupported", blockIndex: indexOr(root, "output_index", -1, codec.provider), eventType: kind) }
            case "response.function_call_arguments.delta" =>
                let call = responseCallForEvent(codec, calls, root)
                if (call.completed) { invalidWire("llm.responses_function_delta_after_done", "Responses function arguments arrived after done", provider: codec.provider) }
                let fragment = wireRequiredString(root, "delta", provider: codec.provider); budget.semantic(fragment, "tool"); call.arguments.append(fragment)
                LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, text: fragment, outputIndex: call.outputIndex, itemId: call.itemId, callId: call.callId, name: call.name)])
            case "response.function_call_arguments.done" => completeResponseCall(root)
            case "response.completed" | "response.incomplete" | "response.failed" =>
                let terminalResponse = wireObject(wireRequiredField(root, "response", provider: codec.provider), "Responses terminal response", provider: codec.provider)
                reconcileResponsesMetadata(terminalResponse)
                let state = decodeResponsesResponse(codec, terminalResponse)
                match (state) {
                    case LlmWireResponseState.Terminal(value) =>
                        if (!responsesEventMatchesTerminal(kind, value)) {
                            invalidWire("llm.responses_terminal_mismatch", "Responses terminal event type does not match the response status", provider: codec.provider)
                        }
                        match (value) {
                            case LlmWireTerminal.Succeeded(_) =>
                                for (call in calls where !call.completed) { invalidWire("llm.responses_function_call_incomplete", "successful Responses terminal arrived before function arguments completed", provider: codec.provider) }
                                for (item in items where !item.completed) { invalidWire("llm.responses_output_item_incomplete", "successful Responses terminal arrived before output_item.done", provider: codec.provider) }
                                reconcileResponsesTerminal(codec, terminalResponse, items, calls)
                            case LlmWireTerminal.Incomplete(_, _) => reconcileResponsesTerminal(codec, terminalResponse, items, calls)
                            case LlmWireTerminal.Failed(_) =>
                                if (wireOptionalArray(terminalResponse, "output", provider: codec.provider).isSome()) { reconcileResponsesTerminal(codec, terminalResponse, items, calls) }
                        }
                        if (items.isEmpty()) { match (value) {
                            case LlmWireTerminal.Succeeded(reply) => budget.terminalReply(reply)
                            case LlmWireTerminal.Incomplete(reply, _) => budget.terminalReply(reply)
                            case _ => ()
                        } }
                        terminal = Some(value)
                        let finalUsage: ?LlmWireUsage = match (value) { case LlmWireTerminal.Succeeded(reply) => Some(reply.usage); case LlmWireTerminal.Incomplete(reply, _) => Some(reply.usage); case _ => None }
                        LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.MessageTerminalObserved, rawStopReason: kind), LlmWireEvent(LlmWireEventKind.UsageCompleted, usage: finalUsage)], terminal: Some(value))
                    case _ => invalidWire("llm.responses_terminal_invalid", "terminal event contains a non-terminal response", provider: codec.provider)
                }
            case "error" => providerErrorUpdate(codec, match (root.field("error")) { case Some(value) => value; case None => root }, { value => terminal = Some(value) })
            case "response.output_item.done" => completeResponsesItem(root)
            case "response.output_text.done" => completeResponsesText(root, "output_text", false)
            case "response.refusal.done" => completeResponsesText(root, "refusal", false)
            case "response.reasoning_summary_part.added" => startResponsesPart(root, true)
            case "response.reasoning_summary_part.done" => completeResponsesPart(root, true)
            case "response.reasoning_summary_text.done" => completeResponsesText(root, "summary_text", true)
            case "response.reasoning_text.done" => completeResponsesText(root, "reasoning_text", false)
            case _ => unsupportedSemantic(codec, kind, root, "llm.responses_stream_event_unsupported", eventType: kind)
        }
    }

    private func startResponsesStream(root: JsonNode, kind: String): LlmWireStreamUpdate {
        let response = wireObject(wireRequiredField(root, "response", provider: codec.provider), "Responses stream metadata", provider: codec.provider)
        reconcileResponsesMetadata(response)
        if (kind == "response.created") {
            if (createdObserved || inProgressObserved) { invalidWire("llm.responses_start_duplicate", "Responses response.created appeared more than once or after response.in_progress", provider: codec.provider) }
            createdObserved = true
        } else {
            if (inProgressObserved) { invalidWire("llm.responses_start_duplicate", "Responses response.in_progress appeared more than once", provider: codec.provider) }
            inProgressObserved = true
        }
        if (started) { return LlmWireStreamUpdate() }
        started = true
        LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.StreamStarted)])
    }

    private func reconcileResponsesMetadata(response: JsonNode): Unit {
        match (wireOptionalString(response, "id", provider: codec.provider)) { case Some(value) => if (responseId != "" && responseId != value) { invalidWire("llm.responses_id_mismatch", "Responses response ID changed during streaming", provider: codec.provider) } else if (responseId == "") { budget.retain(value); responseId = value }; case None => () }
        match (wireOptionalString(response, "model", provider: codec.provider)) { case Some(value) => if (model != "" && model != value) { invalidWire("llm.responses_model_mismatch", "Responses model changed during streaming", provider: codec.provider) } else if (model == "") { budget.retain(value); model = value }; case None => () }
    }

    private func startResponsesPart(root: JsonNode, summary: Bool): LlmWireStreamUpdate {
        let item = responseItemForEvent(codec, items, root)
        let part = wireObject(wireRequiredField(root, "part", provider: codec.provider), "Responses content part", provider: codec.provider)
        let nativeType = wireRequiredString(part, "type", provider: codec.provider)
        rejectResponsesContentSemantic(codec, part, requiredIndex(root, if (summary) { "summary_index" } else { "content_index" }, codec.provider), wireRequiredString(root, "type", provider: codec.provider))
        validateResponsePartType(codec, nativeType, summary, part, root)
        let parentCompatible = if (summary) {
            item.nativeType == "reasoning"
        } else if (nativeType == "reasoning_text") {
            item.nativeType == "reasoning"
        } else {
            item.nativeType == "message"
        }
        if (!parentCompatible) { invalidWire("llm.responses_content_parent_mismatch", "Responses content part type does not match its parent output item", provider: codec.provider) }
        let index = requiredIndex(root, if (summary) { "summary_index" } else { "content_index" }, codec.provider)
        if (index != countResponseParts(item.parts, summary)) { invalidWire("llm.responses_content_index_invalid", "Responses content indexes must be contiguous", provider: codec.provider) }
        item.parts.add(ResponseStreamPart(index, nativeType, summary: summary)); budget.block()
        LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ContentBlockStarted, outputIndex: item.outputIndex, contentIndex: if (summary) { -1 } else { index }, summaryIndex: if (summary) { index } else { -1 }, itemId: item.itemId)])
    }

    private func appendResponsesPart(root: JsonNode, nativeType: String, value: String, summary: Bool): Unit {
        let part = responsePartForEvent(codec, items, root, summary)
        if (part.nativeType != nativeType || part.valueCompleted || part.completed) { invalidWire("llm.responses_delta_out_of_phase", "Responses delta does not match an active content part", provider: codec.provider) }
        part.text.append(value)
    }

    private func completeResponsesText(root: JsonNode, nativeType: String, summary: Bool): LlmWireStreamUpdate {
        let part = responsePartForEvent(codec, items, root, summary)
        if (part.nativeType != nativeType) { invalidWire("llm.responses_done_type_mismatch", "Responses done event does not match its content part", provider: codec.provider) }
        if (part.valueCompleted || part.completed) { invalidWire("llm.responses_value_done_duplicate", "Responses content value completed twice or after content_part.done", provider: codec.provider) }
        let value = wireRequiredString(root, "text", provider: codec.provider)
        if (part.text.toString() != value) { invalidWire("llm.responses_text_mismatch", "Responses done text does not match streamed deltas", provider: codec.provider) }
        part.valueCompleted = true
        LlmWireStreamUpdate()
    }

    private func completeResponsesPart(root: JsonNode, summary: Bool): LlmWireStreamUpdate {
        let part = responsePartForEvent(codec, items, root, summary)
        if (part.completed) { invalidWire("llm.responses_content_part_done_duplicate", "Responses content part completed twice", provider: codec.provider) }
        if (!part.valueCompleted) { invalidWire("llm.responses_content_value_incomplete", "Responses content_part.done arrived before its value done event", provider: codec.provider) }
        let payload = wireObject(wireRequiredField(root, "part", provider: codec.provider), "Responses content part", provider: codec.provider)
        let nativeType = wireRequiredString(payload, "type", provider: codec.provider)
        rejectResponsesContentSemantic(codec, payload, part.index, wireRequiredString(root, "type", provider: codec.provider))
        if (nativeType != part.nativeType) { invalidWire("llm.responses_done_type_mismatch", "Responses content part type changed at completion", provider: codec.provider) }
        part.completed = true
        LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ContentBlockCompleted, outputIndex: requiredIndex(root, "output_index", codec.provider), contentIndex: if (summary) { -1 } else { part.index }, summaryIndex: if (summary) { part.index } else { -1 }, itemId: wireRequiredString(root, "item_id", provider: codec.provider))])
    }

    private func completeResponsesItem(root: JsonNode): LlmWireStreamUpdate {
        let item = responseItemForEvent(codec, items, root)
        if (item.completed) { invalidWire("llm.responses_output_item_done_duplicate", "Responses output item completed twice", provider: codec.provider) }
        for (part in item.parts where !part.completed) { invalidWire("llm.responses_content_part_incomplete", "Responses output item completed with an open content part", provider: codec.provider) }
        match (findResponseCall(calls, item.itemId)) { case Some(call) => if (!call.completed) { invalidWire("llm.responses_function_call_incomplete", "Responses function item completed before arguments", provider: codec.provider) }; case None => () }
        let payload = wireObject(wireRequiredField(root, "item", provider: codec.provider), "Responses output item", provider: codec.provider)
        if (wireRequiredString(payload, "id", provider: codec.provider) != item.itemId || wireRequiredString(payload, "type", provider: codec.provider) != item.nativeType) { invalidWire("llm.responses_output_item_mismatch", "Responses output item identity changed at completion", provider: codec.provider) }
        item.completed = true
        LlmWireStreamUpdate()
    }

    private func completeResponseCall(root: JsonNode): LlmWireStreamUpdate {
        let itemId = wireRequiredString(root, "item_id", provider: codec.provider)
        let call = responseCallForEvent(codec, calls, root)
        if (call.completed) { invalidWire("llm.responses_function_done_duplicate", "Responses function arguments completed twice", provider: codec.provider) }
        match (wireOptionalString(root, "name", provider: codec.provider)) { case Some(value) => if (call.name != "" && call.name != value) { invalidWire("llm.responses_function_name_mismatch", "Responses function name changed during streaming", provider: codec.provider) } else { call.name = value }; case None => () }
        if (call.name == "") { invalidWire("llm.responses_function_name_missing", "Responses function name was absent from every event", provider: codec.provider) }
        let arguments = wireRequiredString(root, "arguments", provider: codec.provider)
        let accumulated = call.arguments.toString()
        if (accumulated != "" && accumulated != arguments) { invalidWire("llm.responses_function_arguments_mismatch", "Responses function done arguments do not match streamed fragments", provider: codec.provider) }
        if (accumulated == "") { budget.semantic(arguments, "tool"); call.arguments.append(arguments) }
        call.completed = true
        LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ContentBlockCompleted, text: arguments, outputIndex: call.outputIndex, itemId: itemId, callId: call.callId, name: call.name)])
    }

    public func finishTransport(): LlmWireTerminal { finish(codec) }
}

func findResponseItem(values: ArrayList<ResponseStreamItem>, itemId: String): ?ResponseStreamItem {
    for (value in values where value.itemId == itemId) { return Some(value) }
    None
}

func findResponseItemAt(values: ArrayList<ResponseStreamItem>, outputIndex: Int64): ?ResponseStreamItem {
    for (value in values where value.outputIndex == outputIndex) { return Some(value) }
    None
}

func responseItemForEvent(codec: LlmWireCodec, values: ArrayList<ResponseStreamItem>, root: JsonNode): ResponseStreamItem {
    let itemId = wireRequiredString(root, "item_id", provider: codec.provider)
    let item = match (findResponseItem(values, itemId)) {
        case Some(value) => value
        case None => invalidWire("llm.responses_event_without_item", "Responses event references an unknown output item", provider: codec.provider)
    }
    if (requiredIndex(root, "output_index", codec.provider) != item.outputIndex) { invalidWire("llm.responses_output_index_mismatch", "Responses output index changed for an item", provider: codec.provider) }
    if (item.completed) { invalidWire("llm.responses_event_after_item_done", "Responses event appeared after output_item.done", provider: codec.provider) }
    item
}

func responsePartForEvent(codec: LlmWireCodec, values: ArrayList<ResponseStreamItem>, root: JsonNode, summary: Bool): ResponseStreamPart {
    let item = responseItemForEvent(codec, values, root)
    let index = requiredIndex(root, if (summary) { "summary_index" } else { "content_index" }, codec.provider)
    for (part in item.parts where part.summary == summary && part.index == index) { return part }
    invalidWire("llm.responses_event_without_content_part", "Responses event references an unknown content part", provider: codec.provider)
}

func countResponseParts(values: ArrayList<ResponseStreamPart>, summary: Bool): Int64 {
    var count: Int64 = 0
    for (value in values where value.summary == summary) { count++ }
    count
}

func validateResponsePartType(codec: LlmWireCodec, nativeType: String, summary: Bool, payload: JsonNode, root: JsonNode): Unit {
    let allowed = if (summary) { nativeType == "summary_text" } else { nativeType == "output_text" || nativeType == "refusal" || nativeType == "reasoning_text" }
    if (!allowed) { unsupportedSemantic(codec, nativeType, payload, "llm.responses_stream_block_unsupported", blockIndex: indexOr(root, if (summary) { "summary_index" } else { "content_index" }, -1, codec.provider), eventType: wireRequiredString(root, "type", provider: codec.provider)) }
}

func reconcileResponsesTerminal(codec: LlmWireCodec, response: JsonNode, streamed: ArrayList<ResponseStreamItem>, calls: ArrayList<ResponseStreamCall>): Unit {
    if (streamed.isEmpty()) { return }
    let output = match (wireOptionalArray(response, "output", provider: codec.provider)) {
        case Some(values) => values
        case None => invalidWire("llm.responses_terminal_output_missing", "Responses terminal omitted streamed output items", provider: codec.provider)
    }
    if (output.size != streamed.size) { invalidWire("llm.responses_terminal_output_mismatch", "Responses terminal output count does not match streamed items", provider: codec.provider) }
    for (expected in streamed) {
        if (expected.outputIndex < 0 || expected.outputIndex >= output.size) { invalidWire("llm.responses_terminal_output_mismatch", "Responses terminal omitted a streamed output index", provider: codec.provider) }
        let actual = wireObject(output[expected.outputIndex], "Responses terminal output item", provider: codec.provider)
        if (wireRequiredString(actual, "type", provider: codec.provider) != expected.nativeType) { invalidWire("llm.responses_terminal_output_mismatch", "Responses terminal output type changed", provider: codec.provider) }
        match (wireOptionalString(actual, "id", provider: codec.provider)) { case Some(value) => if (value != expected.itemId) { invalidWire("llm.responses_terminal_output_mismatch", "Responses terminal output ID changed", provider: codec.provider) }; case None => () }
        match (findResponseCall(calls, expected.itemId)) {
            case Some(call) =>
                if (wireRequiredString(actual, "call_id", provider: codec.provider) != call.callId || wireRequiredString(actual, "name", provider: codec.provider) != call.name || wireRequiredString(actual, "arguments", provider: codec.provider) != call.arguments.toString()) {
                    invalidWire("llm.responses_terminal_function_mismatch", "Responses terminal function call differs from streamed identity or arguments", provider: codec.provider)
                }
            case None => ()
        }
        reconcileResponsesTerminalParts(codec, expected, actual, false)
        reconcileResponsesTerminalParts(codec, expected, actual, true)
    }
}

func reconcileResponsesTerminalParts(codec: LlmWireCodec, expected: ResponseStreamItem, actual: JsonNode, summary: Bool): Unit {
    let expectedCount = countResponseParts(expected.parts, summary)
    let field = if (summary) { "summary" } else { "content" }
    let parts: Array<JsonNode> = match (wireOptionalArray(actual, field, provider: codec.provider)) { case Some(values) => values; case None => [] }
    if (parts.size != expectedCount) { invalidWire("llm.responses_terminal_content_mismatch", "Responses terminal content count differs from streamed parts", provider: codec.provider) }
    for (streamed in expected.parts where streamed.summary == summary) {
        let terminalPart = wireObject(parts[streamed.index], "Responses terminal content part", provider: codec.provider)
        if (wireRequiredString(terminalPart, "type", provider: codec.provider) != streamed.nativeType) { invalidWire("llm.responses_terminal_content_mismatch", "Responses terminal content type differs from streamed part", provider: codec.provider) }
        let fieldName = if (streamed.nativeType == "refusal") { "refusal" } else { "text" }
        match (wireOptionalString(terminalPart, fieldName, provider: codec.provider)) {
            case Some(value) => if (value != streamed.text.toString()) { invalidWire("llm.responses_terminal_content_mismatch", "Responses terminal content differs from streamed deltas", provider: codec.provider) }
            case None => if (streamed.text.toString() != "") { invalidWire("llm.responses_terminal_content_mismatch", "Responses terminal omitted streamed content", provider: codec.provider) }
        }
    }
}

func findResponseCall(values: ArrayList<ResponseStreamCall>, itemId: String): ?ResponseStreamCall {
    for (value in values where value.itemId == itemId) { return Some(value) }
    None
}

func responseCallForEvent(codec: LlmWireCodec, values: ArrayList<ResponseStreamCall>, root: JsonNode): ResponseStreamCall {
    let itemId = wireRequiredString(root, "item_id", provider: codec.provider)
    let call = match (findResponseCall(values, itemId)) {
        case Some(value) => value
        case None => invalidWire("llm.responses_arguments_without_item", "Responses function arguments reference an unknown output item", provider: codec.provider)
    }
    if (requiredIndex(root, "output_index", codec.provider) != call.outputIndex) {
        invalidWire("llm.responses_output_index_mismatch", "Responses output index changed for a function-call item", provider: codec.provider)
    }
    call
}

func responsesEventMatchesTerminal(kind: String, terminal: LlmWireTerminal): Bool {
    match ((kind, terminal)) {
        case ("response.completed", LlmWireTerminal.Succeeded(_)) => true
        case ("response.incomplete", LlmWireTerminal.Incomplete(_, _)) => true
        case ("response.failed", LlmWireTerminal.Failed(_)) => true
        case _ => false
    }
}
class StreamCall {
    let choiceIndex: Int64
    let toolCallIndex: Int64
    var callId = ""
    var name = ""
    var nativeType = ""
    var started = false
    let arguments = StringBuilder()
    init(choiceIndex: Int64, toolCallIndex: Int64) { this.choiceIndex = choiceIndex; this.toolCallIndex = toolCallIndex }
}

class ChatStreamDecoder <: StreamLifecycle & LlmWireStreamDecoder {
    private let codec: LlmWireCodec
    private let budget: StreamBudget
    private var responseId = ""
    private var model = ""
    private let text = StringBuilder()
    private let reasoning = StringBuilder()
    private let refusal = StringBuilder()
    private let calls = ArrayList<StreamCall>()
    private var usage = LlmWireUsage()
    private var choiceFinishReason: ?String = None
    private var textBlockAccounted = false
    private var reasoningBlockAccounted = false
    private var refusalBlockAccounted = false
    init(codec: LlmWireCodec, limits: LlmWireStreamLimits) { this.codec = codec; this.budget = StreamBudget(limits) }

    public func push(event: SseEvent): LlmWireStreamUpdate { guardedPush(codec, { => budget.inputEvent(); pushActive(event) }) }
    private func pushActive(event: SseEvent): LlmWireStreamUpdate {
        if (!beforePush(event) || event.data == "") { return LlmWireStreamUpdate() }
        if (event.data == "[DONE]") {
            let value = match (choiceFinishReason) {
                case Some(reason) => chatTerminal(reason)
                case None => invalidWire("llm.chat_choice_terminal_missing", "Chat stream ended before its choice reported finish_reason", provider: codec.provider)
            }
            terminal = Some(value)
            return LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.UsageCompleted, usage: Some(usage))], terminal: Some(value))
        }
        let root = wireObject(parseWireJson(event.data), "Chat stream event", provider: codec.provider)
        match (root.field("error")) { case Some(raw) => return providerErrorUpdate(codec, raw, { value => terminal = Some(value) }); case None => () }
        match (wireOptionalString(root, "id", provider: codec.provider)) {
            case Some(value) => if (responseId != "" && responseId != value) { invalidWire("llm.chat_id_mismatch", "Chat response ID changed during streaming", provider: codec.provider) } else if (responseId == "") { budget.retain(value); responseId = value }
            case None => ()
        }
        match (wireOptionalString(root, "model", provider: codec.provider)) {
            case Some(value) => if (model != "" && model != value) { invalidWire("llm.chat_model_mismatch", "Chat model changed during streaming", provider: codec.provider) } else if (model == "") { budget.retain(value); model = value }
            case None => ()
        }
        var usageEvent: ?LlmWireEvent = None
        match (wireOptionalObject(root, "usage", provider: codec.provider)) { case Some(_) => usage = mergeWireUsage(usage, decodeChatUsage(codec, root), codec.dialect.contract.usageMergeStyle); usageEvent = Some(LlmWireEvent(LlmWireEventKind.UsageDelta, usage: Some(usage))); case None => () }
        let choices = match (wireOptionalArray(root, "choices", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Chat stream event is missing choices", provider: codec.provider) }
        if (choices.size > 1) { unsupportedWire("llm.chat_multiple_choices_unsupported", "only one Chat stream choice is supported", provider: codec.provider) }
        if (choiceFinishReason.isSome() && !choices.isEmpty()) {
            invalidWire("llm.chat_event_after_choice_finished", "Chat content appeared after finish_reason", provider: codec.provider)
        }
        let events = ArrayList<LlmWireEvent>()
        match (usageEvent) { case Some(value) => events.add(value); case None => () }
        for (raw in choices) {
            let choice = wireObject(raw, "Chat stream choice", provider: codec.provider)
            let choiceIndex = wireRequiredInt(choice, "index", provider: codec.provider)
            if (choiceIndex != 0) { unsupportedWire("llm.chat_choice_index_unsupported", "only Chat stream choice index 0 is supported", provider: codec.provider) }
            match (wireOptionalObject(choice, "delta", provider: codec.provider)) {
                case Some(delta) =>
                    rejectUnsupportedChatSemantic(codec, delta, "chat.delta")
                    match (wireOptionalString(delta, "content", provider: codec.provider)) { case Some(value) => if (value != "" && !textBlockAccounted) { budget.block(); textBlockAccounted = true }; budget.semantic(value, "text"); text.append(value); events.add(LlmWireEvent(LlmWireEventKind.TextDelta, text: value, choiceIndex: choiceIndex)); case None => () }
                    match (wireOptionalString(delta, "reasoning_content", provider: codec.provider)) { case Some(value) => if (value != "" && !reasoningBlockAccounted) { budget.block(); reasoningBlockAccounted = true }; budget.semantic(value, "reasoning"); reasoning.append(value); events.add(LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: value, choiceIndex: choiceIndex)); case None => () }
                    match (wireOptionalString(delta, "refusal", provider: codec.provider)) { case Some(value) => if (value != "" && !refusalBlockAccounted) { budget.block(); refusalBlockAccounted = true }; budget.semantic(value, "text"); refusal.append(value); events.add(LlmWireEvent(LlmWireEventKind.RefusalDelta, text: value, choiceIndex: choiceIndex)); case None => () }
                    match (wireOptionalArray(delta, "tool_calls", provider: codec.provider)) {
                        case Some(values) => for (entry in values) {
                            let before = calls.size
                            decodeChatCallDelta(codec, choiceIndex, wireObject(entry, "Chat tool call delta", provider: codec.provider), calls, events, budget)
                            if (calls.size > before) { budget.block(); budget.toolCall() }
                        }
                        case None => ()
                    }
                case None => ()
            }
            match (wireOptionalString(choice, "finish_reason", provider: codec.provider)) {
                case Some(reason) =>
                    if (choiceFinishReason.isSome()) { invalidWire("llm.chat_choice_terminal_duplicate", "Chat choice reported finish_reason twice", provider: codec.provider) }
                    let _ = chatTerminal(reason)
                    choiceFinishReason = Some(reason)
                    events.add(LlmWireEvent(LlmWireEventKind.MessageTerminalObserved, choiceIndex: choiceIndex, rawStopReason: reason))
                case None => ()
            }
        }
        LlmWireStreamUpdate(events: events.toArray())
    }

    private func chatTerminal(reason: String): LlmWireTerminal {
        if (reason == "insufficient_system_resource") {
            return LlmWireTerminal.Failed(LlmWireFailure(LlmWireFailureKind.InsufficientSystemResource, "provider reported insufficient system resources", provider: codec.provider, retryable: true))
        }
        let blocks = ArrayList<LlmWireBlock>()
        let content = text.toString(); if (content != "") { blocks.add(LlmWireBlock.Text(LlmWireTextBlock(content))) }
        let thought = reasoning.toString(); if (thought != "") {
            if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.DeepSeekChat) { blocks.add(LlmWireBlock.NativeReplay(chatReasoningReplay(codec, thought, if (model == "") { None } else { Some(model) }, blocks.size))) }
            else { blocks.add(LlmWireBlock.Reasoning(LlmWireReasoningBlock(thought))) }
        }
        let denied = refusal.toString(); if (denied != "") { blocks.add(LlmWireBlock.Refusal(LlmWireRefusalBlock(denied))) }
        for (toolCallIndex in 0..calls.size) {
            let call = match (findExistingChatCall(calls, 0, toolCallIndex)) { case Some(value) => value; case None => invalidWire("llm.chat_tool_call_index_gap", "Chat tool call indexes must be contiguous", provider: codec.provider) }
            if (reason != "length" && reason != "content_filter" && call.nativeType == "") { invalidWire("llm.chat_tool_call_type_missing", "completed Chat tool call never declared its type", provider: codec.provider) }
            if (reason != "length" && reason != "content_filter" && (call.callId == "" || call.name == "")) { invalidWire("llm.chat_tool_call_incomplete", "completed Chat tool call is missing id or name", provider: codec.provider) }
            let raw = call.arguments.toString()
            let arguments = if (reason == "length" || reason == "content_filter") { LlmWireToolArguments.Partial(raw) } else { classifyToolArguments(raw) }
            blocks.add(LlmWireBlock.ToolCall(LlmWireToolCallBlock(call.callId, call.name, arguments)))
        }
        let reply = assembleCanonicalReply(
            responseId, model, blocks.toArray(), usage, reason,
            requireExecutableToolCalls: reason != "length" && reason != "content_filter"
        )
        if (reason == "stop" || reason == "tool_calls") { validateReplyToolStop(reply, reason, "tool_calls", ["stop"]) }
        match (reason) {
            case "stop" | "tool_calls" => LlmWireTerminal.Succeeded(reply)
            case "function_call" => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.chat_legacy_function_call_unsupported", "legacy Chat function_call streams are not supported", provider: codec.provider)
            case "length" => LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.Length)
            case "content_filter" => LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.ContentFilter)
            case _ => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.chat_finish_reason_unsupported", "unknown Chat finish reason: " + reason, provider: codec.provider)
        }
    }

    public func finishTransport(): LlmWireTerminal {
        finish(codec)
    }
}

func decodeChatCallDelta(codec: LlmWireCodec, choiceIndex: Int64, item: JsonNode, calls: ArrayList<StreamCall>, events: ArrayList<LlmWireEvent>, budget: StreamBudget): Unit {
    let index = match (wireOptionalInt(item, "index", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Chat tool call delta is missing index", provider: codec.provider) }
    if (index < 0) { invalidWire("llm.chat_tool_call_index_invalid", "Chat tool call index must be non-negative", provider: codec.provider) }
    let call = findChatCall(calls, choiceIndex, index)
    match (wireOptionalString(item, "type", provider: codec.provider)) {
        case Some(value) =>
            if (value != "function") { unsupportedSemantic(codec, value, item, "llm.chat_tool_type_unsupported", blockIndex: index, eventType: "chat.delta.tool_calls") }
            if (call.nativeType == "") { budget.retain(value); call.nativeType = value }
        case None => ()
    }
    let id = optionalStringOrEmpty(item, "id", codec.provider)
    if (id != "") {
        if (call.callId != "" && call.callId != id) { invalidWire("llm.chat_tool_call_id_mismatch", "Chat tool call ID changed during streaming", provider: codec.provider) }
        if (call.callId == "") { budget.retain(id); call.callId = id }
    }
    match (wireOptionalObject(item, "function", provider: codec.provider)) {
        case Some(function) =>
            let name = optionalStringOrEmpty(function, "name", codec.provider)
            if (name != "") {
                if (call.name != "" && call.name != name) { invalidWire("llm.chat_tool_call_name_mismatch", "Chat tool call name changed during streaming", provider: codec.provider) }
                if (call.name == "") { budget.retain(name); call.name = name }
            }
            let fragment = optionalStringOrEmpty(function, "arguments", codec.provider)
            if (fragment != "") {
                budget.semantic(fragment, "tool")
                call.arguments.append(fragment)
                if (call.started) { events.add(LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, text: fragment, choiceIndex: choiceIndex, toolCallIndex: index, callId: call.callId, name: call.name)) }
            }
        case None => ()
    }
    maybeStartChatCall(call, events)
}

func maybeStartChatCall(call: StreamCall, events: ArrayList<LlmWireEvent>): Unit {
    if (call.started || call.nativeType != "function" || call.callId == "" || call.name == "") { return }
    call.started = true
    events.add(LlmWireEvent(LlmWireEventKind.ToolCallStarted, choiceIndex: call.choiceIndex, toolCallIndex: call.toolCallIndex, callId: call.callId, name: call.name))
    let pending = call.arguments.toString()
    if (pending != "") { events.add(LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, text: pending, choiceIndex: call.choiceIndex, toolCallIndex: call.toolCallIndex, callId: call.callId, name: call.name)) }
}

func findChatCall(values: ArrayList<StreamCall>, choiceIndex: Int64, toolCallIndex: Int64): StreamCall {
    match (findExistingChatCall(values, choiceIndex, toolCallIndex)) { case Some(value) => return value; case None => () }
    let created = StreamCall(choiceIndex, toolCallIndex); values.add(created); created
}

func findExistingChatCall(values: ArrayList<StreamCall>, choiceIndex: Int64, toolCallIndex: Int64): ?StreamCall {
    for (value in values where value.choiceIndex == choiceIndex && value.toolCallIndex == toolCallIndex) { return Some(value) }
    None
}

class MessageStreamBlock {
    let index: Int64
    let nativeType: String
    var callId = ""
    var name = ""
    let text = StringBuilder()
    let arguments = StringBuilder()
    let signature = StringBuilder()
    var initialPayload: ?JsonNode = None
    var completed = false
    init(index: Int64, nativeType: String) { this.index = index; this.nativeType = nativeType }
}

@Derive[Equatable]
enum MessagesStreamPhase { AwaitingMessageStart | AcceptingBlocks | AcceptingMessageDeltas }

class MessagesStreamDecoder <: StreamLifecycle & LlmWireStreamDecoder {
    private let codec: LlmWireCodec
    private let budget: StreamBudget
    private var responseId = ""
    private var model = ""
    private var stopReason = ""
    private var usage = LlmWireUsage()
    private var phase = MessagesStreamPhase.AwaitingMessageStart
    private let blocks = ArrayList<MessageStreamBlock>()
    init(codec: LlmWireCodec, limits: LlmWireStreamLimits) { this.codec = codec; this.budget = StreamBudget(limits) }

    public func push(event: SseEvent): LlmWireStreamUpdate { guardedPush(codec, { => budget.inputEvent(); pushActive(event) }) }
    private func pushActive(event: SseEvent): LlmWireStreamUpdate {
        if (!beforePush(event) || event.data == "" || event.data == "[DONE]") { return LlmWireStreamUpdate() }
        let root = wireObject(parseWireJson(event.data), "Messages stream event", provider: codec.provider)
        let kind = wireRequiredString(root, "type", provider: codec.provider)
        match (kind) {
            case "message_start" =>
                match (phase) { case MessagesStreamPhase.AwaitingMessageStart => phase = MessagesStreamPhase.AcceptingBlocks; case _ => invalidWire("llm.messages_start_duplicate", "Messages stream started more than once", provider: codec.provider) }
                let message = wireObject(wireRequiredField(root, "message", provider: codec.provider), "Messages start message", provider: codec.provider)
                responseId = optionalStringOrEmpty(message, "id", codec.provider); model = optionalStringOrEmpty(message, "model", codec.provider)
                budget.retain(responseId); budget.retain(model)
                usage = mergeWireUsage(usage, decodeMessagesUsage(codec, message), codec.dialect.contract.usageMergeStyle)
                LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.StreamStarted)])
            case "content_block_start" => startMessagesBlock(root)
            case "content_block_delta" => updateMessagesBlock(root)
            case "content_block_stop" => stopMessagesBlock(root)
            case "message_delta" =>
                if (phase != MessagesStreamPhase.AcceptingBlocks && phase != MessagesStreamPhase.AcceptingMessageDeltas) {
                    invalidWire("llm.messages_delta_out_of_phase", "Messages message_delta appeared outside the message-delta phase", provider: codec.provider)
                }
                for (block in blocks where !block.completed) { invalidWire("llm.messages_content_block_incomplete", "Messages message_delta arrived before all content blocks stopped", provider: codec.provider) }
                let delta = wireObject(wireRequiredField(root, "delta", provider: codec.provider), "Messages message delta", provider: codec.provider)
                var observedStopReason = ""
                match (wireOptionalString(delta, "stop_reason", provider: codec.provider)) {
                    case Some(value) =>
                        if (stopReason != "" && stopReason != value) { invalidWire("llm.messages_stop_reason_mismatch", "Messages stop reason changed across message_delta events", provider: codec.provider) }
                        observedStopReason = value
                        stopReason = value
                    case None => ()
                }
                rejectMessagesStopSemantic(codec, delta, observedStopReason, "message_delta")
                phase = MessagesStreamPhase.AcceptingMessageDeltas
                match (wireOptionalObject(root, "usage", provider: codec.provider)) {
                    case Some(value) => usage = mergeWireUsage(usage, LlmWireUsage(outputTokens: wireOptionalUsageInt(value, "output_tokens", codec.provider)), codec.dialect.contract.usageMergeStyle); LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.UsageDelta, rawStopReason: stopReason, usage: Some(usage))])
                    case None => LlmWireStreamUpdate()
                }
            case "message_stop" =>
                requireMessagesPhase(MessagesStreamPhase.AcceptingMessageDeltas, "llm.messages_stop_out_of_phase", "Messages message_stop must follow one or more message_delta events")
                if (stopReason == "") { invalidWire("llm.messages_stop_reason_missing", "Messages stream ended without a stop reason", provider: codec.provider) }
                let value = messagesTerminal()
                terminal = Some(value)
                LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.MessageTerminalObserved, rawStopReason: stopReason), LlmWireEvent(LlmWireEventKind.UsageCompleted, usage: Some(usage))], terminal: Some(value))
            case "error" => providerErrorUpdate(codec, match (root.field("error")) { case Some(value) => value; case None => root }, { value => terminal = Some(value) })
            case "ping" => LlmWireStreamUpdate()
            case _ => unsupportedSemantic(codec, kind, root, "llm.messages_stream_event_unsupported", eventType: kind)
        }
    }

    private func startMessagesBlock(root: JsonNode): LlmWireStreamUpdate {
        requireMessagesPhase(MessagesStreamPhase.AcceptingBlocks, "llm.messages_block_out_of_phase", "Messages content block started outside the block phase")
        let index = wireRequiredInt(root, "index", provider: codec.provider)
        if (index < 0) { invalidWire("llm.messages_block_index_invalid", "Messages block index must be non-negative", provider: codec.provider) }
        if (findMessageBlock(blocks, index).isSome()) { invalidWire("llm.messages_block_duplicate", "Messages stream started the same block index twice", provider: codec.provider) }
        if (index != blocks.size) { invalidWire("llm.messages_block_index_gap", "Messages block indexes must be contiguous and ordered", provider: codec.provider) }
        let payload = wireObject(wireRequiredField(root, "content_block", provider: codec.provider), "Messages content block", provider: codec.provider)
        budget.retain(payload.stringify())
        let nativeType = wireRequiredString(payload, "type", provider: codec.provider)
        if (nativeType != "text" && nativeType != "thinking" && nativeType != "redacted_thinking" && nativeType != "tool_use") {
            unsupportedSemantic(codec, nativeType, root, "llm.messages_stream_block_unsupported", blockIndex: index, eventType: "content_block_start")
        }
        let block = MessageStreamBlock(index, nativeType)
        if (nativeType == "text") { rejectNonEmptySemanticArray(codec, payload, "citations", "llm.messages_semantic_unsupported", index, "content_block_start") }
        budget.block(); if (nativeType == "tool_use") { budget.toolCall() }
        block.initialPayload = Some(payload); block.callId = optionalStringOrEmpty(payload, "id", codec.provider); block.name = optionalStringOrEmpty(payload, "name", codec.provider)
        if (nativeType == "tool_use" && (block.callId == "" || block.name == "")) { invalidWire("llm.messages_tool_call_incomplete", "Messages tool_use start is missing id or name", provider: codec.provider) }
        if (nativeType == "tool_use") {
            let input = wireRequiredField(payload, "input", provider: codec.provider)
            if (input.wireKind != WireJsonKind.Object || input.stringify() != "{}") { invalidWire("llm.messages_tool_input_start_nonempty", "Messages streamed tool_use must start with an empty input object", provider: codec.provider) }
        }
        match (wireOptionalString(payload, if (nativeType == "thinking") { "thinking" } else { "text" }, provider: codec.provider)) { case Some(value) => budget.semantic(value, if (nativeType == "thinking") { "reasoning" } else { "text" }); block.text.append(value); case None => () }
        if (nativeType == "thinking") { match (wireOptionalString(payload, "signature", provider: codec.provider)) { case Some(value) => budget.retain(value); block.signature.append(value); case None => () } }
        blocks.add(block)
        LlmWireStreamUpdate(events: [LlmWireEvent(if (nativeType == "tool_use") { LlmWireEventKind.ToolCallStarted } else { LlmWireEventKind.ContentBlockStarted }, blockIndex: index, callId: block.callId, name: block.name)])
    }

    private func updateMessagesBlock(root: JsonNode): LlmWireStreamUpdate {
        requireMessagesPhase(MessagesStreamPhase.AcceptingBlocks, "llm.messages_block_out_of_phase", "Messages content delta appeared outside the block phase")
        let index = wireRequiredInt(root, "index", provider: codec.provider)
        let block = match (findMessageBlock(blocks, index)) { case Some(value) => value; case None => invalidWire("llm.messages_delta_without_start", "Messages delta references an unknown block", provider: codec.provider) }
        if (block.completed) { invalidWire("llm.messages_delta_after_stop", "Messages delta appeared after content_block_stop", provider: codec.provider) }
        let delta = wireObject(wireRequiredField(root, "delta", provider: codec.provider), "Messages content delta", provider: codec.provider)
        match ((block.nativeType, wireRequiredString(delta, "type", provider: codec.provider))) {
            case ("text", "text_delta") => let value = wireRequiredString(delta, "text", provider: codec.provider); budget.semantic(value, "text"); block.text.append(value); LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.TextDelta, text: value, blockIndex: index)])
            case ("thinking", "thinking_delta") => let value = wireRequiredString(delta, "thinking", provider: codec.provider); budget.semantic(value, "reasoning"); block.text.append(value); LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: value, blockIndex: index)])
            case ("thinking", "signature_delta") => let value = wireRequiredString(delta, "signature", provider: codec.provider); budget.retain(value); block.signature.append(value); LlmWireStreamUpdate()
            case ("tool_use", "input_json_delta") => let value = wireRequiredString(delta, "partial_json", provider: codec.provider); budget.semantic(value, "tool"); block.arguments.append(value); LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, text: value, blockIndex: index, callId: block.callId, name: block.name)])
            case ("text", "citations_delta") => unsupportedSemantic(codec, "citations_delta", delta, "llm.messages_semantic_unsupported", blockIndex: index, eventType: "content_block_delta")
            case _ => invalidWire("llm.messages_delta_type_mismatch", "Messages delta type does not match the started native block", provider: codec.provider)
        }
    }

    private func stopMessagesBlock(root: JsonNode): LlmWireStreamUpdate {
        requireMessagesPhase(MessagesStreamPhase.AcceptingBlocks, "llm.messages_block_out_of_phase", "Messages content block stopped outside the block phase")
        let index = wireRequiredInt(root, "index", provider: codec.provider)
        let block = match (findMessageBlock(blocks, index)) { case Some(value) => value; case None => invalidWire("llm.messages_block_stop_without_start", "Messages stop references an unknown block", provider: codec.provider) }
        if (block.completed) { invalidWire("llm.messages_block_stop_duplicate", "Messages block stopped twice", provider: codec.provider) }
        block.completed = true
        LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ContentBlockCompleted, blockIndex: index, callId: block.callId, name: block.name)])
    }

    private func messagesTerminal(): LlmWireTerminal {
        let incomplete = stopReason == "max_tokens" || stopReason == "model_context_window_exceeded" || stopReason == "pause_turn"
        if (!incomplete) { for (block in blocks where !block.completed) { invalidWire("llm.messages_content_block_incomplete", "Messages succeeded with an incomplete content block", provider: codec.provider) } }
        let output = ArrayList<LlmWireBlock>()
        for (block in blocks) { output.add(materializeMessageBlock(codec, block, model: if (model == "") { None } else { Some(model) })) }
        let reply = assembleCanonicalReply(
            responseId, model, output.toArray(), usage, stopReason,
            requireExecutableToolCalls: !incomplete
        )
        if (stopReason == "tool_use" || stopReason == "end_turn" || stopReason == "stop_sequence") { validateReplyToolStop(reply, stopReason, "tool_use", ["end_turn", "stop_sequence"]) }
        match (stopReason) {
            case "end_turn" | "stop_sequence" | "tool_use" => LlmWireTerminal.Succeeded(reply)
            case "max_tokens" => LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.MaxTokens)
            case "model_context_window_exceeded" => LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.ModelContextWindowExceeded)
            case "pause_turn" => LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.PauseTurn)
            case _ => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.messages_stop_reason_unsupported", "unknown Messages stop reason: " + stopReason, provider: codec.provider)
        }
    }

    public func finishTransport(): LlmWireTerminal { finish(codec) }

    private func requireMessagesPhase(expected: MessagesStreamPhase, code: String, message: String): Unit {
        let matches = match ((phase, expected)) {
            case (MessagesStreamPhase.AwaitingMessageStart, MessagesStreamPhase.AwaitingMessageStart) |
                 (MessagesStreamPhase.AcceptingBlocks, MessagesStreamPhase.AcceptingBlocks) |
                 (MessagesStreamPhase.AcceptingMessageDeltas, MessagesStreamPhase.AcceptingMessageDeltas) => true
            case _ => false
        }
        if (!matches) { invalidWire(code, message, provider: codec.provider) }
    }
}

func findMessageBlock(values: ArrayList<MessageStreamBlock>, index: Int64): ?MessageStreamBlock {
    for (value in values where value.index == index) { return Some(value) }
    None
}

func materializeMessageBlock(codec: LlmWireCodec, block: MessageStreamBlock, model!: ?String = None): LlmWireBlock {
    match (block.nativeType) {
        case "text" => LlmWireBlock.Text(LlmWireTextBlock(block.text.toString()))
        case "tool_use" =>
            let raw = block.arguments.toString()
            LlmWireBlock.ToolCall(LlmWireToolCallBlock(block.callId, block.name, if (!block.completed) { LlmWireToolArguments.Partial(raw) } else { classifyToolArguments(raw) }))
        case "thinking" =>
            let payload = match (block.initialPayload) { case Some(value) => parseWireJson(value.stringify()); case None => wireJsonObject([WireJsonField("type", wireJsonString("thinking"))]) }
            payload.put("thinking", wireJsonString(block.text.toString())); payload.put("signature", wireJsonString(block.signature.toString()))
            LlmWireBlock.NativeReplay(nativeReplayFromPayload(codec.protocol, codec.dialect.compatibilityId, "thinking", payload, modelConstraint: model, blockOrder: block.index, completion: if (block.completed) { LlmWireOpaqueCompletion.Complete } else { LlmWireOpaqueCompletion.Partial }, displayReasoning: Some(block.text.toString())))
        case "redacted_thinking" =>
            let payload = match (block.initialPayload) { case Some(value) => value; case None => wireJsonObject([WireJsonField("type", wireJsonString("redacted_thinking"))]) }
            LlmWireBlock.NativeReplay(nativeReplayFromPayload(codec.protocol, codec.dialect.compatibilityId, "redacted_thinking", payload, modelConstraint: model, blockOrder: block.index, completion: if (block.completed) { LlmWireOpaqueCompletion.Complete } else { LlmWireOpaqueCompletion.Partial }))
        case _ => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.messages_stream_block_unsupported", "unknown streamed block cannot be materialized")
    }
}

func providerErrorUpdate(codec: LlmWireCodec, raw: JsonNode, storeTerminal: (LlmWireTerminal) -> Unit): LlmWireStreamUpdate {
    let failure = providerFailure(codec, raw)
    let value = LlmWireTerminal.Failed(failure)
    storeTerminal(value)
    LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ProviderError, text: failure.message)], terminal: Some(value))
}

func indexOr(value: JsonNode, name: String, fallback: Int64, provider: String): Int64 {
    match (wireOptionalInt(value, name, provider: provider)) { case Some(found) => found; case None => fallback }
}

func requiredIndex(value: JsonNode, name: String, provider: String): Int64 {
    match (wireOptionalInt(value, name, provider: provider)) {
        case Some(found) => found
        case None => invalidWire("llm.field_missing", "provider stream event is missing integer field: " + name, provider: provider)
    }
}
