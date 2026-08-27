package llm4cj

import std.collection.*
import std.deriving.Derive
import yjson.*

@Derive[Equatable]
public enum LlmWireEventKind {
    StreamStarted | ContentBlockStarted | TextDelta | ReasoningDelta |
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
    public let itemId: String
    public let callId: String
    public let name: String
    public let rawStopReason: String
    public init(
        kind: LlmWireEventKind, text!: String = "", blockIndex!: Int64 = -1,
        choiceIndex!: Int64 = -1, toolCallIndex!: Int64 = -1,
        outputIndex!: Int64 = -1, itemId!: String = "", callId!: String = "",
        name!: String = "", rawStopReason!: String = ""
    ) {
        this.kind = kind; this.text = text; this.blockIndex = blockIndex
        this.choiceIndex = choiceIndex; this.toolCallIndex = toolCallIndex
        this.outputIndex = outputIndex; this.itemId = itemId; this.callId = callId
        this.name = name; this.rawStopReason = rawStopReason
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

func newWireStreamDecoder(codec: LlmWireCodec): LlmWireStreamDecoder {
    match (codec.protocol) {
        case LlmWireProtocol.Responses => ResponsesStreamDecoder(codec)
        case LlmWireProtocol.ChatCompletions => ChatStreamDecoder(codec)
        case LlmWireProtocol.Messages => MessagesStreamDecoder(codec)
    }
}

open class StreamLifecycle {
    protected var terminal: ?LlmWireTerminal = None
    protected var closed = false

    protected func beforePush(event: SseEvent): Bool {
        if (closed) { throw LlmTransportError(LlmTransportErrorKind.InvalidState, "llm.stream_closed", "stream decoder is closed") }
        match (terminal) {
            case Some(_) =>
                if (event.data == "[DONE]") { return false }
                throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.stream_event_after_terminal", "semantic stream event appeared after terminal")
            case None => true
        }
    }

    protected func finish(): LlmWireTerminal {
        if (closed) { throw LlmTransportError(LlmTransportErrorKind.InvalidState, "llm.stream_closed", "stream decoder is closed") }
        closed = true
        match (terminal) {
            case Some(value) => value
            case None => throw LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.stream_terminal_missing", "stream ended without a protocol terminal")
        }
    }
}

class ResponseStreamCall {
    let outputIndex: Int64
    let itemId: String
    let callId: String
    let name: String
    let arguments = StringBuilder()
    var completed = false
    init(outputIndex: Int64, itemId: String, callId: String, name: String) {
        this.outputIndex = outputIndex
        this.itemId = itemId
        this.callId = callId
        this.name = name
    }
}

class ResponsesStreamDecoder <: StreamLifecycle & LlmWireStreamDecoder {
    private let codec: LlmWireCodec
    private let calls = ArrayList<ResponseStreamCall>()
    init(codec: LlmWireCodec) { this.codec = codec }

    public func push(event: SseEvent): LlmWireStreamUpdate {
        if (!beforePush(event) || event.data == "") { return LlmWireStreamUpdate() }
        let root = wireObject(parseWireJson(event.data), "Responses stream event", provider: codec.provider)
        let kind = wireRequiredString(root, "type", provider: codec.provider)
        match (kind) {
            case "response.created" | "response.in_progress" => LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.StreamStarted)])
            case "response.output_text.delta" => LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.TextDelta, text: wireRequiredString(root, "delta", provider: codec.provider), outputIndex: indexOr(root, "output_index", -1, codec.provider), itemId: optionalStringOrEmpty(root, "item_id", codec.provider))])
            case "response.reasoning_summary_text.delta" | "response.reasoning_text.delta" => LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: wireRequiredString(root, "delta", provider: codec.provider), outputIndex: requiredIndex(root, "output_index", codec.provider), itemId: wireRequiredString(root, "item_id", provider: codec.provider))])
            case "response.output_item.added" =>
                let item = wireObject(wireRequiredField(root, "item", provider: codec.provider), "Responses output item", provider: codec.provider)
                if (wireRequiredString(item, "type", provider: codec.provider) == "function_call") {
                    let outputIndex = requiredIndex(root, "output_index", codec.provider)
                    let itemId = wireRequiredString(item, "id", provider: codec.provider)
                    if (findResponseCall(calls, itemId).isSome()) {
                        invalidWire("llm.responses_item_duplicate", "Responses stream added the same function-call item twice", provider: codec.provider)
                    }
                    let call = ResponseStreamCall(
                        outputIndex,
                        itemId,
                        wireRequiredString(item, "call_id", provider: codec.provider),
                        wireRequiredString(item, "name", provider: codec.provider)
                    )
                    calls.add(call)
                    LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ToolCallStarted, outputIndex: outputIndex, itemId: itemId, callId: call.callId, name: call.name)])
                } else { LlmWireStreamUpdate() }
            case "response.function_call_arguments.delta" =>
                let call = responseCallForEvent(codec, calls, root)
                if (call.completed) {
                    invalidWire("llm.responses_delta_after_done", "Responses function-call arguments delta appeared after done", provider: codec.provider)
                }
                let fragment = wireRequiredString(root, "delta", provider: codec.provider)
                call.arguments.append(fragment)
                LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, text: fragment, outputIndex: call.outputIndex, itemId: call.itemId, callId: call.callId, name: call.name)])
            case "response.function_call_arguments.done" =>
                let call = responseCallForEvent(codec, calls, root)
                if (call.completed) {
                    invalidWire("llm.responses_done_duplicate", "Responses function-call arguments completed twice", provider: codec.provider)
                }
                let arguments = wireRequiredString(root, "arguments", provider: codec.provider)
                if (call.arguments.toString() != arguments) {
                    invalidWire("llm.responses_arguments_mismatch", "Responses final function arguments do not match accumulated deltas", provider: codec.provider)
                }
                let name = wireRequiredString(root, "name", provider: codec.provider)
                if (name != call.name) {
                    invalidWire("llm.responses_call_name_mismatch", "Responses function-call name changed during streaming", provider: codec.provider)
                }
                call.completed = true
                LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ContentBlockCompleted, text: arguments, outputIndex: call.outputIndex, itemId: call.itemId, callId: call.callId, name: call.name)])
            case "response.completed" | "response.incomplete" | "response.failed" =>
                let state = decodeResponsesResponse(codec, wireObject(wireRequiredField(root, "response", provider: codec.provider), "Responses terminal response", provider: codec.provider))
                match (state) {
                    case LlmWireResponseState.Terminal(value) =>
                        if (!responsesEventMatchesTerminal(kind, value)) {
                            invalidWire("llm.responses_terminal_mismatch", "Responses terminal event type does not match the response status", provider: codec.provider)
                        }
                        terminal = Some(value)
                        LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.MessageTerminalObserved, rawStopReason: kind)], terminal: Some(value))
                    case _ => invalidWire("llm.responses_terminal_invalid", "terminal event contains a non-terminal response", provider: codec.provider)
                }
            case "error" => providerErrorUpdate(codec, match (root.field("error")) { case Some(value) => value; case None => root }, { value => terminal = Some(value) })
            case _ => LlmWireStreamUpdate()
        }
    }

    public func finishTransport(): LlmWireTerminal { finish() }
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
    let arguments = StringBuilder()
    init(choiceIndex: Int64, toolCallIndex: Int64) { this.choiceIndex = choiceIndex; this.toolCallIndex = toolCallIndex }
}

class ChatStreamDecoder <: StreamLifecycle & LlmWireStreamDecoder {
    private let codec: LlmWireCodec
    private var responseId = ""
    private var model = ""
    private let text = StringBuilder()
    private let reasoning = StringBuilder()
    private let calls = ArrayList<StreamCall>()
    private var usage = LlmWireUsage()
    init(codec: LlmWireCodec) { this.codec = codec }

    public func push(event: SseEvent): LlmWireStreamUpdate {
        if (!beforePush(event) || event.data == "" || event.data == "[DONE]") { return LlmWireStreamUpdate() }
        let root = wireObject(parseWireJson(event.data), "Chat stream event", provider: codec.provider)
        match (root.field("error")) { case Some(raw) => return providerErrorUpdate(codec, raw, { value => terminal = Some(value) }); case None => () }
        if (responseId == "") { responseId = optionalStringOrEmpty(root, "id", codec.provider); model = optionalStringOrEmpty(root, "model", codec.provider) }
        match (wireOptionalObject(root, "usage", provider: codec.provider)) { case Some(_) => usage = decodeChatUsage(codec, root); case None => () }
        let choices = match (wireOptionalArray(root, "choices", provider: codec.provider)) { case Some(value) => value; case None => return LlmWireStreamUpdate() }
        let events = ArrayList<LlmWireEvent>()
        var observedTerminal: ?LlmWireTerminal = None
        for (raw in choices) {
            let choice = wireObject(raw, "Chat stream choice", provider: codec.provider)
            let choiceIndex = indexOr(choice, "index", 0, codec.provider)
            match (wireOptionalObject(choice, "delta", provider: codec.provider)) {
                case Some(delta) =>
                    match (wireOptionalString(delta, "content", provider: codec.provider)) { case Some(value) => text.append(value); events.add(LlmWireEvent(LlmWireEventKind.TextDelta, text: value, choiceIndex: choiceIndex)); case None => () }
                    match (codec.dialect.chatReasoningField) {
                        case Some(field) => match (wireOptionalString(delta, field, provider: codec.provider)) { case Some(value) => reasoning.append(value); events.add(LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: value, choiceIndex: choiceIndex)); case None => () }
                        case None => ()
                    }
                    match (wireOptionalArray(delta, "tool_calls", provider: codec.provider)) { case Some(values) => for (entry in values) { decodeChatCallDelta(codec, choiceIndex, wireObject(entry, "Chat tool call delta", provider: codec.provider), calls, events) }; case None => () }
                case None => ()
            }
            match (wireOptionalString(choice, "finish_reason", provider: codec.provider)) {
                case Some(reason) =>
                    let value = chatTerminal(reason)
                    observedTerminal = Some(value)
                    events.add(LlmWireEvent(LlmWireEventKind.MessageTerminalObserved, choiceIndex: choiceIndex, rawStopReason: reason))
                case None => ()
            }
        }
        match (observedTerminal) { case Some(value) => terminal = Some(value); LlmWireStreamUpdate(events: events.toArray(), terminal: Some(value)); case None => LlmWireStreamUpdate(events: events.toArray()) }
    }

    private func chatTerminal(reason: String): LlmWireTerminal {
        let blocks = ArrayList<LlmWireBlock>()
        let content = text.toString(); if (content != "") { blocks.add(LlmWireBlock.Text(LlmWireTextBlock(content))) }
        let thought = reasoning.toString(); if (thought != "") { blocks.add(LlmWireBlock.Reasoning(LlmWireReasoningBlock(thought, replayDialectId: codec.dialect.compatibilityId))) }
        for (call in calls) {
            let raw = call.arguments.toString()
            let arguments = if (reason == "length" || reason == "content_filter") { LlmWireToolArguments.Partial(raw) } else { classifyToolArguments(raw) }
            blocks.add(LlmWireBlock.ToolCall(LlmWireToolCallBlock(call.callId, call.name, arguments)))
        }
        let reply = LlmWireReply(responseId: responseId, model: model, blocks: blocks.toArray(), usage: usage, rawStopReason: reason)
        match (reason) {
            case "stop" | "tool_calls" | "function_call" => LlmWireTerminal.Succeeded(reply)
            case "length" => LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.Length)
            case "content_filter" => LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.ContentFilter)
            case "insufficient_system_resource" => LlmWireTerminal.Failed(LlmWireFailure(LlmWireFailureKind.InsufficientSystemResource, "provider reported insufficient system resources", provider: codec.provider, retryable: true))
            case _ => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.chat_finish_reason_unsupported", "unknown Chat finish reason: " + reason, provider: codec.provider)
        }
    }

    public func finishTransport(): LlmWireTerminal { finish() }
}

func decodeChatCallDelta(codec: LlmWireCodec, choiceIndex: Int64, item: JsonNode, calls: ArrayList<StreamCall>, events: ArrayList<LlmWireEvent>): Unit {
    let index = match (wireOptionalInt(item, "index", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Chat tool call delta is missing index", provider: codec.provider) }
    let call = findChatCall(calls, choiceIndex, index)
    let id = optionalStringOrEmpty(item, "id", codec.provider)
    if (id != "") { call.callId = id }
    match (wireOptionalObject(item, "function", provider: codec.provider)) {
        case Some(function) =>
            let name = optionalStringOrEmpty(function, "name", codec.provider)
            if (name != "") { call.name = name }
            let fragment = optionalStringOrEmpty(function, "arguments", codec.provider)
            if (fragment != "") { call.arguments.append(fragment); events.add(LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, text: fragment, choiceIndex: choiceIndex, toolCallIndex: index, callId: call.callId, name: call.name)) }
        case None => ()
    }
}

func findChatCall(values: ArrayList<StreamCall>, choiceIndex: Int64, toolCallIndex: Int64): StreamCall {
    for (value in values where value.choiceIndex == choiceIndex && value.toolCallIndex == toolCallIndex) { return value }
    let created = StreamCall(choiceIndex, toolCallIndex); values.add(created); created
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

class MessagesStreamDecoder <: StreamLifecycle & LlmWireStreamDecoder {
    private let codec: LlmWireCodec
    private var responseId = ""
    private var model = ""
    private var stopReason = ""
    private var usage = LlmWireUsage()
    private let blocks = ArrayList<MessageStreamBlock>()
    init(codec: LlmWireCodec) { this.codec = codec }

    public func push(event: SseEvent): LlmWireStreamUpdate {
        if (!beforePush(event) || event.data == "" || event.data == "[DONE]") { return LlmWireStreamUpdate() }
        let root = wireObject(parseWireJson(event.data), "Messages stream event", provider: codec.provider)
        let kind = wireRequiredString(root, "type", provider: codec.provider)
        match (kind) {
            case "message_start" =>
                let message = wireObject(wireRequiredField(root, "message", provider: codec.provider), "Messages start message", provider: codec.provider)
                responseId = optionalStringOrEmpty(message, "id", codec.provider); model = optionalStringOrEmpty(message, "model", codec.provider)
                usage = decodeMessagesUsage(codec, message)
                LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.StreamStarted)])
            case "content_block_start" => startMessagesBlock(root)
            case "content_block_delta" => updateMessagesBlock(root)
            case "content_block_stop" => stopMessagesBlock(root)
            case "message_delta" =>
                let delta = wireObject(wireRequiredField(root, "delta", provider: codec.provider), "Messages message delta", provider: codec.provider)
                stopReason = optionalStringOrEmpty(delta, "stop_reason", codec.provider)
                match (wireOptionalObject(root, "usage", provider: codec.provider)) { case Some(value) => usage = LlmWireUsage(inputTokens: usage.inputTokens, outputTokens: wireIntOrZero(value, "output_tokens", provider: codec.provider), cacheReadTokens: usage.cacheReadTokens, cacheWriteTokens: usage.cacheWriteTokens); case None => () }
                LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.UsageDelta, rawStopReason: stopReason)])
            case "message_stop" =>
                let value = messagesTerminal()
                terminal = Some(value)
                LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.MessageTerminalObserved, rawStopReason: stopReason)], terminal: Some(value))
            case "error" => providerErrorUpdate(codec, match (root.field("error")) { case Some(value) => value; case None => root }, { value => terminal = Some(value) })
            case _ => LlmWireStreamUpdate()
        }
    }

    private func startMessagesBlock(root: JsonNode): LlmWireStreamUpdate {
        let index = indexOr(root, "index", -1, codec.provider)
        if (findMessageBlock(blocks, index).isSome()) { invalidWire("llm.messages_block_duplicate", "Messages stream started the same block index twice", provider: codec.provider) }
        let payload = wireObject(wireRequiredField(root, "content_block", provider: codec.provider), "Messages content block", provider: codec.provider)
        let nativeType = wireRequiredString(payload, "type", provider: codec.provider)
        if (nativeType != "text" && nativeType != "thinking" && nativeType != "redacted_thinking" && nativeType != "tool_use") {
            throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.messages_stream_block_unsupported", "unknown streamed native block cannot be reconstructed safely", provider: codec.provider)
        }
        let block = MessageStreamBlock(index, nativeType)
        block.initialPayload = Some(payload); block.callId = optionalStringOrEmpty(payload, "id", codec.provider); block.name = optionalStringOrEmpty(payload, "name", codec.provider)
        match (wireOptionalString(payload, if (nativeType == "thinking") { "thinking" } else { "text" }, provider: codec.provider)) { case Some(value) => block.text.append(value); case None => () }
        blocks.add(block)
        LlmWireStreamUpdate(events: [LlmWireEvent(if (nativeType == "tool_use") { LlmWireEventKind.ToolCallStarted } else { LlmWireEventKind.ContentBlockStarted }, blockIndex: index, callId: block.callId, name: block.name)])
    }

    private func updateMessagesBlock(root: JsonNode): LlmWireStreamUpdate {
        let index = indexOr(root, "index", -1, codec.provider)
        let block = match (findMessageBlock(blocks, index)) { case Some(value) => value; case None => invalidWire("llm.messages_delta_without_start", "Messages delta references an unknown block", provider: codec.provider) }
        if (block.completed) { invalidWire("llm.messages_delta_after_stop", "Messages delta appeared after content_block_stop", provider: codec.provider) }
        let delta = wireObject(wireRequiredField(root, "delta", provider: codec.provider), "Messages content delta", provider: codec.provider)
        match (wireRequiredString(delta, "type", provider: codec.provider)) {
            case "text_delta" => let value = wireRequiredString(delta, "text", provider: codec.provider); block.text.append(value); LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.TextDelta, text: value, blockIndex: index)])
            case "thinking_delta" => let value = wireRequiredString(delta, "thinking", provider: codec.provider); block.text.append(value); LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: value, blockIndex: index)])
            case "signature_delta" => block.signature.append(wireRequiredString(delta, "signature", provider: codec.provider)); LlmWireStreamUpdate()
            case "input_json_delta" => let value = wireRequiredString(delta, "partial_json", provider: codec.provider); block.arguments.append(value); LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, text: value, blockIndex: index, callId: block.callId, name: block.name)])
            case _ => LlmWireStreamUpdate()
        }
    }

    private func stopMessagesBlock(root: JsonNode): LlmWireStreamUpdate {
        let index = indexOr(root, "index", -1, codec.provider)
        let block = match (findMessageBlock(blocks, index)) { case Some(value) => value; case None => invalidWire("llm.messages_block_stop_without_start", "Messages stop references an unknown block", provider: codec.provider) }
        if (block.completed) { invalidWire("llm.messages_block_stop_duplicate", "Messages block stopped twice", provider: codec.provider) }
        block.completed = true
        LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ContentBlockCompleted, blockIndex: index, callId: block.callId, name: block.name)])
    }

    private func messagesTerminal(): LlmWireTerminal {
        let incomplete = stopReason == "max_tokens" || stopReason == "model_context_window_exceeded" || stopReason == "pause_turn"
        if (!incomplete) { for (block in blocks where !block.completed) { invalidWire("llm.messages_content_block_incomplete", "Messages succeeded with an incomplete content block", provider: codec.provider) } }
        let output = ArrayList<LlmWireBlock>()
        for (block in blocks) { output.add(materializeMessageBlock(codec, block)) }
        let reply = LlmWireReply(responseId: responseId, model: model, blocks: output.toArray(), usage: usage, rawStopReason: stopReason)
        match (stopReason) {
            case "end_turn" | "stop_sequence" | "tool_use" | "refusal" => LlmWireTerminal.Succeeded(reply)
            case "max_tokens" => LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.MaxTokens)
            case "model_context_window_exceeded" => LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.ModelContextWindowExceeded)
            case "pause_turn" => LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.PauseTurn)
            case _ => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.messages_stop_reason_unsupported", "unknown Messages stop reason: " + stopReason, provider: codec.provider)
        }
    }

    public func finishTransport(): LlmWireTerminal { finish() }
}

func findMessageBlock(values: ArrayList<MessageStreamBlock>, index: Int64): ?MessageStreamBlock {
    for (value in values where value.index == index) { return Some(value) }
    None
}

func materializeMessageBlock(codec: LlmWireCodec, block: MessageStreamBlock): LlmWireBlock {
    match (block.nativeType) {
        case "text" => LlmWireBlock.Text(LlmWireTextBlock(block.text.toString()))
        case "tool_use" =>
            let raw = block.arguments.toString()
            LlmWireBlock.ToolCall(LlmWireToolCallBlock(block.callId, block.name, if (!block.completed) { LlmWireToolArguments.Partial(raw) } else { classifyToolArguments(raw) }))
        case "thinking" =>
            let payload = wireJsonObject([WireJsonField("type", wireJsonString("thinking")), WireJsonField("thinking", wireJsonString(block.text.toString())), WireJsonField("signature", wireJsonString(block.signature.toString()))])
            LlmWireBlock.Opaque(LlmWireOpaqueBlock.fromPayload(codec.protocol, codec.dialect.compatibilityId, "thinking", payload, completion: if (block.completed) { LlmWireOpaqueCompletion.Complete } else { LlmWireOpaqueCompletion.Partial }, displayReasoning: Some(block.text.toString())))
        case "redacted_thinking" =>
            let payload = match (block.initialPayload) { case Some(value) => value; case None => wireJsonObject([WireJsonField("type", wireJsonString("redacted_thinking"))]) }
            LlmWireBlock.Opaque(LlmWireOpaqueBlock.fromPayload(codec.protocol, codec.dialect.compatibilityId, "redacted_thinking", payload, completion: if (block.completed) { LlmWireOpaqueCompletion.Complete } else { LlmWireOpaqueCompletion.Partial }))
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
