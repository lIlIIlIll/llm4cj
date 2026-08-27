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
    private var failed: ?LlmTransportError = None

    protected func guardedPush(operation: () -> LlmWireStreamUpdate): LlmWireStreamUpdate {
        match (failed) { case Some(_) => throw LlmTransportError(LlmTransportErrorKind.InvalidState, "llm.stream_failed", "stream decoder is poisoned by an earlier error"); case None => () }
        try { operation() }
        catch (error: LlmTransportError) { failed = Some(error); throw error }
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

    protected func finish(): LlmWireTerminal {
        match (failed) { case Some(_) => throw LlmTransportError(LlmTransportErrorKind.InvalidState, "llm.stream_failed", "stream decoder is poisoned by an earlier error"); case None => () }
        if (closed) { throw LlmTransportError(LlmTransportErrorKind.InvalidState, "llm.stream_closed", "stream decoder is closed") }
        match (terminal) {
            case Some(value) => closed = true; value
            case None =>
                let error = LlmTransportError(LlmTransportErrorKind.InvalidWire, "llm.stream_terminal_missing", "stream ended without a protocol terminal")
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
class ResponsesStreamDecoder <: StreamLifecycle & LlmWireStreamDecoder {
    private let codec: LlmWireCodec
    private let calls = ArrayList<ResponseStreamCall>()
    init(codec: LlmWireCodec) { this.codec = codec }

    public func push(event: SseEvent): LlmWireStreamUpdate { guardedPush({ => pushActive(event) }) }
    private func pushActive(event: SseEvent): LlmWireStreamUpdate {
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
                    if (findResponseCall(calls, itemId).isSome()) { invalidWire("llm.responses_function_call_duplicate", "Responses function item was started twice", provider: codec.provider) }
                    let call = ResponseStreamCall(outputIndex, itemId, wireRequiredString(item, "call_id", provider: codec.provider), optionalStringOrEmpty(item, "name", codec.provider))
                    calls.add(call)
                    LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ToolCallStarted, outputIndex: outputIndex, itemId: itemId, callId: call.callId, name: call.name)])
                } else { LlmWireStreamUpdate() }
            case "response.function_call_arguments.delta" =>
                let call = responseCallForEvent(codec, calls, root)
                if (call.completed) { invalidWire("llm.responses_function_delta_after_done", "Responses function arguments arrived after done", provider: codec.provider) }
                let fragment = wireRequiredString(root, "delta", provider: codec.provider); call.arguments.append(fragment)
                LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, text: fragment, outputIndex: call.outputIndex, itemId: call.itemId, callId: call.callId, name: call.name)])
            case "response.function_call_arguments.done" => completeResponseCall(root)
            case "response.completed" | "response.incomplete" | "response.failed" =>
                for (call in calls where !call.completed) { invalidWire("llm.responses_function_call_incomplete", "Responses terminal arrived before function arguments completed", provider: codec.provider) }
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

    private func completeResponseCall(root: JsonNode): LlmWireStreamUpdate {
        let itemId = wireRequiredString(root, "item_id", provider: codec.provider)
        let call = match (findResponseCall(calls, itemId)) { case Some(value) => value; case None => invalidWire("llm.responses_function_done_without_start", "Responses function done references an unknown item", provider: codec.provider) }
        if (call.completed) { invalidWire("llm.responses_function_done_duplicate", "Responses function arguments completed twice", provider: codec.provider) }
        match (wireOptionalString(root, "name", provider: codec.provider)) { case Some(value) => if (call.name != "" && call.name != value) { invalidWire("llm.responses_function_name_mismatch", "Responses function name changed during streaming", provider: codec.provider) } else { call.name = value }; case None => () }
        if (call.name == "") { invalidWire("llm.responses_function_name_missing", "Responses function name was absent from every event", provider: codec.provider) }
        let arguments = wireRequiredString(root, "arguments", provider: codec.provider)
        let accumulated = call.arguments.toString()
        if (accumulated != "" && accumulated != arguments) { invalidWire("llm.responses_function_arguments_mismatch", "Responses function done arguments do not match streamed fragments", provider: codec.provider) }
        if (accumulated == "") { call.arguments.append(arguments) }
        call.completed = true
        LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ContentBlockCompleted, text: arguments, outputIndex: call.outputIndex, itemId: itemId, callId: call.callId, name: call.name)])
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
    private let refusal = StringBuilder()
    private let calls = ArrayList<StreamCall>()
    private var usage = LlmWireUsage()
    private var choiceFinishReason: ?String = None
    init(codec: LlmWireCodec) { this.codec = codec }

    public func push(event: SseEvent): LlmWireStreamUpdate { guardedPush({ => pushActive(event) }) }
    private func pushActive(event: SseEvent): LlmWireStreamUpdate {
        if (!beforePush(event) || event.data == "") { return LlmWireStreamUpdate() }
        if (event.data == "[DONE]") {
            let value = match (choiceFinishReason) {
                case Some(reason) => chatTerminal(reason)
                case None => invalidWire("llm.chat_choice_terminal_missing", "Chat stream ended before its choice reported finish_reason", provider: codec.provider)
            }
            terminal = Some(value)
            return LlmWireStreamUpdate(terminal: Some(value))
        }
        let root = wireObject(parseWireJson(event.data), "Chat stream event", provider: codec.provider)
        match (root.field("error")) { case Some(raw) => return providerErrorUpdate(codec, raw, { value => terminal = Some(value) }); case None => () }
        if (responseId == "") { responseId = optionalStringOrEmpty(root, "id", codec.provider); model = optionalStringOrEmpty(root, "model", codec.provider) }
        match (wireOptionalObject(root, "usage", provider: codec.provider)) { case Some(_) => usage = decodeChatUsage(codec, root); case None => () }
        let choices = match (wireOptionalArray(root, "choices", provider: codec.provider)) { case Some(value) => value; case None => return LlmWireStreamUpdate() }
        if (choices.size > 1) { unsupportedRequest("llm.chat_multiple_choices_unsupported", "only one Chat stream choice is supported") }
        if (choiceFinishReason.isSome() && !choices.isEmpty()) {
            invalidWire("llm.chat_event_after_choice_finished", "Chat content appeared after finish_reason", provider: codec.provider)
        }
        let events = ArrayList<LlmWireEvent>()
        for (raw in choices) {
            let choice = wireObject(raw, "Chat stream choice", provider: codec.provider)
            let choiceIndex = indexOr(choice, "index", 0, codec.provider)
            if (choiceIndex != 0) { unsupportedRequest("llm.chat_choice_index_unsupported", "only Chat stream choice index 0 is supported") }
            match (wireOptionalObject(choice, "delta", provider: codec.provider)) {
                case Some(delta) =>
                    match (wireOptionalString(delta, "content", provider: codec.provider)) { case Some(value) => text.append(value); events.add(LlmWireEvent(LlmWireEventKind.TextDelta, text: value, choiceIndex: choiceIndex)); case None => () }
                    match (wireOptionalString(delta, "reasoning_content", provider: codec.provider)) { case Some(value) => reasoning.append(value); events.add(LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: value, choiceIndex: choiceIndex)); case None => () }
                    match (wireOptionalString(delta, "refusal", provider: codec.provider)) { case Some(value) => refusal.append(value); events.add(LlmWireEvent(LlmWireEventKind.RefusalDelta, text: value, choiceIndex: choiceIndex)); case None => () }
                    match (wireOptionalArray(delta, "tool_calls", provider: codec.provider)) { case Some(values) => for (entry in values) { decodeChatCallDelta(codec, choiceIndex, wireObject(entry, "Chat tool call delta", provider: codec.provider), calls, events) }; case None => () }
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
        let blocks = ArrayList<LlmWireBlock>()
        let content = text.toString(); if (content != "") { blocks.add(LlmWireBlock.Text(LlmWireTextBlock(content))) }
        let thought = reasoning.toString(); if (thought != "") { blocks.add(LlmWireBlock.Reasoning(LlmWireReasoningBlock(thought))) }
        let denied = refusal.toString(); if (denied != "") { blocks.add(LlmWireBlock.Refusal(LlmWireRefusalBlock(denied))) }
        for (call in calls) {
            if (reason != "length" && reason != "content_filter" && (call.callId == "" || call.name == "")) { invalidWire("llm.chat_tool_call_incomplete", "completed Chat tool call is missing id or name", provider: codec.provider) }
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

    public func finishTransport(): LlmWireTerminal {
        if (terminal.isNone()) {
            match (choiceFinishReason) { case Some(reason) => terminal = Some(chatTerminal(reason)); case None => () }
        }
        finish()
    }
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

    public func push(event: SseEvent): LlmWireStreamUpdate { guardedPush({ => pushActive(event) }) }
    private func pushActive(event: SseEvent): LlmWireStreamUpdate {
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
                match (wireOptionalObject(root, "usage", provider: codec.provider)) { case Some(value) => usage = LlmWireUsage(inputTokens: usage.inputTokens, outputTokens: wireOptionalInt(value, "output_tokens", provider: codec.provider), reasoningTokens: usage.reasoningTokens, cacheReadTokens: usage.cacheReadTokens, cacheWriteTokens: usage.cacheWriteTokens); case None => () }
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
        let index = wireRequiredInt(root, "index", provider: codec.provider)
        if (index < 0) { invalidWire("llm.messages_block_index_invalid", "Messages block index must be non-negative", provider: codec.provider) }
        if (findMessageBlock(blocks, index).isSome()) { invalidWire("llm.messages_block_duplicate", "Messages stream started the same block index twice", provider: codec.provider) }
        let payload = wireObject(wireRequiredField(root, "content_block", provider: codec.provider), "Messages content block", provider: codec.provider)
        let nativeType = wireRequiredString(payload, "type", provider: codec.provider)
        if (nativeType != "text" && nativeType != "thinking" && nativeType != "redacted_thinking" && nativeType != "tool_use") {
            let diagnostic = wireJsonObject([
                WireJsonField("index", wireJsonNumber(index.toString())), WireJsonField("native_type", wireJsonString(nativeType)),
                WireJsonField("start_event", root)
            ])
            throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.messages_stream_block_unsupported", "unknown streamed native block cannot be reconstructed safely", provider: codec.provider, diagnosticJson: Some(diagnostic.stringify()))
        }
        let block = MessageStreamBlock(index, nativeType)
        block.initialPayload = Some(payload); block.callId = optionalStringOrEmpty(payload, "id", codec.provider); block.name = optionalStringOrEmpty(payload, "name", codec.provider)
        if (nativeType == "tool_use" && (block.callId == "" || block.name == "")) { invalidWire("llm.messages_tool_call_incomplete", "Messages tool_use start is missing id or name", provider: codec.provider) }
        match (wireOptionalString(payload, if (nativeType == "thinking") { "thinking" } else { "text" }, provider: codec.provider)) { case Some(value) => block.text.append(value); case None => () }
        blocks.add(block)
        LlmWireStreamUpdate(events: [LlmWireEvent(if (nativeType == "tool_use") { LlmWireEventKind.ToolCallStarted } else { LlmWireEventKind.ContentBlockStarted }, blockIndex: index, callId: block.callId, name: block.name)])
    }

    private func updateMessagesBlock(root: JsonNode): LlmWireStreamUpdate {
        let index = wireRequiredInt(root, "index", provider: codec.provider)
        let block = match (findMessageBlock(blocks, index)) { case Some(value) => value; case None => invalidWire("llm.messages_delta_without_start", "Messages delta references an unknown block", provider: codec.provider) }
        if (block.completed) { invalidWire("llm.messages_delta_after_stop", "Messages delta appeared after content_block_stop", provider: codec.provider) }
        let delta = wireObject(wireRequiredField(root, "delta", provider: codec.provider), "Messages content delta", provider: codec.provider)
        match ((block.nativeType, wireRequiredString(delta, "type", provider: codec.provider))) {
            case ("text", "text_delta") => let value = wireRequiredString(delta, "text", provider: codec.provider); block.text.append(value); LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.TextDelta, text: value, blockIndex: index)])
            case ("thinking", "thinking_delta") => let value = wireRequiredString(delta, "thinking", provider: codec.provider); block.text.append(value); LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ReasoningDelta, text: value, blockIndex: index)])
            case ("thinking", "signature_delta") => block.signature.append(wireRequiredString(delta, "signature", provider: codec.provider)); LlmWireStreamUpdate()
            case ("tool_use", "input_json_delta") => let value = wireRequiredString(delta, "partial_json", provider: codec.provider); block.arguments.append(value); LlmWireStreamUpdate(events: [LlmWireEvent(LlmWireEventKind.ToolArgumentsDelta, text: value, blockIndex: index, callId: block.callId, name: block.name)])
            case _ => invalidWire("llm.messages_delta_type_mismatch", "Messages delta type does not match the started native block", provider: codec.provider)
        }
    }

    private func stopMessagesBlock(root: JsonNode): LlmWireStreamUpdate {
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
