package llm4cj

import std.collection.*
import yjson.*

class CodexRequestBudget {
    private var size: Int64 = 0
    func add(value: String): Unit {
        if (value.size > LLM_JSON_MAX_BYTES - size) {
            throw LlmWireError(LlmWireErrorKind.BodyLimit, "llm.codex_request_too_large", "Codex request input exceeds 8 MiB")
        }
        size += value.size
    }
}

func validateCodexInputSize(request: LlmWireRequest): Unit {
    let budget = CodexRequestBudget()
    let add = { value: String => budget.add(value) }
    add(request.model)
    for (instruction in request.transcript.initialContext.instructions) { add(instruction.text) }
    for (tool in request.transcript.initialContext.tools) { add(tool.tool.name); add(tool.tool.description); add(tool.tool.inputSchema.stringify()) }
    for (item in request.transcript.items) { match (item) {
        case LlmWireInputItem.InstructionUpdate(value) => add(value.text)
        case LlmWireInputItem.ToolDeclaration(value) => add(value.tool.name); add(value.tool.description); add(value.tool.inputSchema.stringify())
        case LlmWireInputItem.Message(message) =>
        for (block in message.blocks) {
            match (block) {
                case LlmWireBlock.Text(value) => add(value.text)
                case LlmWireBlock.Image(value) => add(value.data)
                case LlmWireBlock.NativeReplay(value) => add(value.payload().stringify())
                case LlmWireBlock.ToolCall(value) => add(value.callId); add(value.name); add(toolArgumentsRaw(value.arguments))
                case LlmWireBlock.ToolResult(value) =>
                    add(value.callId)
                    for (part in value.content) {
                        match (part) {
                            case LlmWireToolResultContent.Text(text) => add(text.text)
                            case LlmWireToolResultContent.Image(image) => add(image.data)
                        }
                    }
                case _ => ()
            }
        }
        case _ => ()
    } }
}

// SIWC is a distinct Responses dialect, not a configurable backend URL.
func encodeCodexRequest(codec: LlmWireCodec, request: LlmWireRequest, requirements: ArrayList<LlmWireFeatureRequirement>, streaming: Bool): String {
    if (!streaming) { unsupportedRequest("llm.codex_stream_required", "Codex HTTP requests require streaming: true") }
    if (request.maxOutputTokens.isSome()) { unsupportedRequest("llm.codex_max_output_tokens_unsupported", "SIWC does not accept max_output_tokens") }
    let root = baseRequest(codec, request, true)
    root.put("store", wireJsonBool(false))
    root.put("include", wireJsonArray([wireJsonString("reasoning.encrypted_content")]))
    addDialectOptions(codec, root, request, requirements)
    match (request.structuredOutput) {
        case LlmWireStructuredOutput.Text => root.put("text", wireJsonObject([WireJsonField("format", wireJsonObject([WireJsonField("type", wireJsonString("text"))]))]))
        case LlmWireStructuredOutput.JsonObject => root.put("text", wireJsonObject([WireJsonField("format", wireJsonObject([WireJsonField("type", wireJsonString("json_object"))]))]))
        case LlmWireStructuredOutput.JsonSchema(spec) => root.put("text", wireJsonObject([WireJsonField("format", encodeResponsesJsonSchemaFormat(spec))]))
        case _ => ()
    }
    var systemSeen = false
    var developerSeen = false
    for (instruction in request.transcript.initialContext.instructions) {
        if (instruction.role == LlmWireInstructionRole.System) {
            if (systemSeen || developerSeen) { unsupportedRequest("llm.codex_instruction_order_unsupported", "Codex represents one System instruction preceding all Developer instructions") }
            systemSeen = true; root.put("instructions", wireJsonString(instruction.text))
        } else {
            developerSeen = true
        }
    }
    root.put("input", encodeResponsesTranscript(codec, request.transcript))
    let body = root.stringify()
    if (body.size > LLM_JSON_MAX_BYTES) { throw LlmWireError(LlmWireErrorKind.BodyLimit, "llm.codex_request_too_large", "Codex request exceeds the 8 MiB JSON limit") }
    body
}

func outputPhaseName(value: LlmWireOutputPhase): String {
    match (value) {
        case LlmWireOutputPhase.Analysis => unsupportedRequest("llm.responses_phase_unsupported", "Responses assistant messages do not support the analysis phase")
        case LlmWireOutputPhase.Commentary => "commentary"
        case LlmWireOutputPhase.Final => "final_answer"
        case LlmWireOutputPhase.Unspecified => ""
    }
}

func encodeResponsesMessages(codec: LlmWireCodec, messages: Array<LlmWireMessage>): JsonNode {
    let input = wireJsonArray([])
    for (message in messages) { appendResponsesMessage(codec, input, message) }
    input
}

public class LlmWirePreparedWebSocketEvent {
    private let bodyValue: Array<Byte>
    init(body: Array<Byte>) { bodyValue = copyValues(body) }
    public prop body: Array<Byte> { get() { copyValues(bodyValue) } }
}

// One instance belongs to one authenticated physical socket. No network or
// credential handling is performed here; replacing the socket replaces this object.
public class LlmWireResponsesWebSocketSession {
    private let codec: LlmWireCodec
    private let limits: LlmWireStreamLimits
    private var decoder: ?ResponsesStreamDecoder = None
    private var closed = false
    private var poisoned = false
    private var checkpointId = ""
    private var checkpointConfig = ""
    private var checkpointInput: Array<String> = []
    private var pendingConfig = ""
    private var pendingInput: Array<String> = []
    private var lastObservedUsage: ?LlmWireUsage = None

    init(codec: LlmWireCodec, limits: LlmWireStreamLimits) {
        if (codec.dialect.compatibilityId != "openai.codex.responses.v1") {
            unsupportedRequest("llm.websocket_dialect_unsupported", "WebSocket sessions currently support the built-in SIWC Codex dialect")
        }
        this.codec = codec; this.limits = limits
    }

    public func prepare(request: LlmWireRequest): LlmWirePreparedWebSocketEvent {
        try { prepareActive(request) }
        catch (error: LlmWireError) { throw withObservedUsage(withCodecContext(error, codec, LlmTransportPhase.Encode), observedUsage()) }
    }

    private func prepareActive(request: LlmWireRequest): LlmWirePreparedWebSocketEvent {
        ensureOpen()
        if (decoder.isSome()) {
            throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.websocket_response_active", "finish the active response before preparing another")
        }
        lastObservedUsage = None
        let prepared = codec.encodeRequest(request, streaming: true)
        prepared.validateForSend(None)
        let root = parseWireJson(prepared.bodyText())
        let config = wireJsonObject([])
        for (field in root.fields where field.name != "input" && field.name != "stream") {
            config.put(field.name, field.value)
        }
        let currentInput = jsonItemStrings(root["input"])
        let currentConfig = config.stringify()
        let incremental = checkpointId != "" && currentConfig == checkpointConfig && stringPrefix(checkpointInput, currentInput)
        let frame = parseWireJson(currentConfig)
        frame.put("type", wireJsonString("response.create")); frame.put("stream_id", wireJsonString("main"))
        let sentInput = wireJsonArray([])
        let first = if (incremental) {
            checkpointInput.size
        } else { 0 }
        for (index in first..currentInput.size) { sentInput.add(parseWireJson(currentInput[index])) }
        frame.put("input", sentInput)
        if (incremental) {
            frame.put("previous_response_id", wireJsonString(checkpointId))
        }
        let body = frame.stringify().toArray()
        if (body.size > LLM_JSON_MAX_BYTES) {
            throw LlmWireError(LlmWireErrorKind.BodyLimit, "llm.codex_request_too_large", "WebSocket request exceeds the 8 MiB JSON limit")
        }
        checkRetained(currentInput, currentConfig)
        pendingInput = currentInput; pendingConfig = currentConfig
        clearCheckpoint()
        decoder = Some(ResponsesStreamDecoder(codec, limits))
        LlmWirePreparedWebSocketEvent(body)
    }

    public func push(message: Array<Byte>): LlmWireResult<LlmWireStreamUpdate> {
        try { LlmWireResult.Ok(consume(message)) }
        catch (error: LlmWireError) {
            lastObservedUsage = observedUsage()
            poisoned = true
            clearCheckpoint(); pendingInput = []; pendingConfig = ""; decoder = None
            LlmWireResult.Err(withObservedUsage(withCodecContext(error, codec, LlmTransportPhase.SemanticAssembly), lastObservedUsage))
        }
    }

    private func consume(message: Array<Byte>): LlmWireStreamUpdate {
        ensureOpen()
        let active = match (decoder) {
            case Some(value) => value
            case None => throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.websocket_response_missing", "prepare a response before accepting messages")
        }
        if (message.size > LLM_JSON_MAX_BYTES) {
            throw LlmWireError(LlmWireErrorKind.BodyLimit, "llm.websocket_message_too_large", "WebSocket JSON message exceeds 8 MiB")
        }
        let text = try { String.fromUtf8(message) } catch (_: Exception) { throw LlmWireError(LlmWireErrorKind.InvalidWire, "llm.response_utf8_invalid", "WebSocket message is not valid UTF-8") }
        let root = wireObject(parseWireJson(text), "WebSocket event", provider: codec.provider)
        match (wireOptionalString(root, "stream_id", provider: codec.provider)) {
            case Some(value) =>
                if (value != "main") {
                    invalidWire("llm.websocket_stream_id_mismatch", "WebSocket event belongs to another stream", provider: codec.provider)
                }
            case None => ()
        }
        let update = active.pushJson(root)
        lastObservedUsage = active.observedUsage()
        match (update.terminal) {
            case Some(value) =>
                let _ = active.finishTransport()
                match (value) {
                    case LlmWireTerminal.Completed(reply) =>
                        if (!replyHasIncompleteChoice(reply) && wireRequiredString(root, "type") == "response.completed" && reply.responseId != "") {
                            commitCheckpoint(reply)
                        }
                    case _ => clearCheckpoint()
                }
                decoder = None; pendingInput = []; pendingConfig = ""; lastObservedUsage = None
            case None => ()
        }
        update
    }

    public func finish(): LlmWireResult<LlmWireStreamUpdate> {
        try { LlmWireResult.Ok(finishActive()) }
        catch (error: LlmWireError) {
            poisoned = true
            LlmWireResult.Err(withObservedUsage(withCodecContext(error, codec, LlmTransportPhase.SemanticAssembly), observedUsage()))
        }
    }

    public func cancel(): LlmWireResult<LlmWireTerminal> {
        try { LlmWireResult.Ok(cancelActive()) }
        catch (error: LlmWireError) { LlmWireResult.Err(withObservedUsage(withCodecContext(error, codec, LlmTransportPhase.SemanticAssembly), observedUsage())) }
    }

    private func finishActive(): LlmWireStreamUpdate {
        match (closeActive()) {
            case Some(active) => LlmWireStreamUpdate(terminal: Some(active.finishTransport()))
            case None => LlmWireStreamUpdate()
        }
    }
    private func cancelActive(): LlmWireTerminal {
        match (closeActive()) {
            case Some(active) => active.cancel()
            case None => LlmWireTerminal.Cancelled(LlmWireFailure(LlmWireFailureKind.Cancelled, "WebSocket session cancelled", provider: codec.provider))
        }
    }
    private func closeActive(): ?ResponsesStreamDecoder {
        ensureOpen()
        closed = true
        clearCheckpoint(); pendingInput = []; pendingConfig = ""
        let active = decoder
        lastObservedUsage = observedUsage()
        decoder = None
        active
    }

    private func observedUsage(): ?LlmWireUsage {
        match (decoder) { case Some(active) => active.observedUsage(); case None => lastObservedUsage }
    }

    private func commitCheckpoint(reply: LlmWireReply): Unit {
        let suffix = try { jsonItemStrings(encodeResponsesMessages(codec, reply.toContinuationInput())) } catch (_: LlmWireError) { clearCheckpoint(); return }
        let expected = ArrayList<String>()
        for (item in pendingInput) { expected.add(item) }
        for (item in suffix) { expected.add(item) }
        checkRetained(expected.toArray(), pendingConfig)
        checkpointInput = expected.toArray(); checkpointConfig = pendingConfig; checkpointId = reply.responseId
    }
    private func checkRetained(input: Array<String>, config: String): Unit {
        var size = Int64(config.size)
        if (size > limits.maxRetainedStateBytes) {
            throw LlmWireError(LlmWireErrorKind.LimitExceeded, "llm.websocket_retained_state_too_large", "WebSocket continuation state exceeds configured limit")
        }
        for (item in input) {
            if (item.size > limits.maxRetainedStateBytes - size) {
                throw LlmWireError(LlmWireErrorKind.LimitExceeded, "llm.websocket_retained_state_too_large", "WebSocket continuation state exceeds configured limit")
            }
            size += item.size
        }
    }
    private func clearCheckpoint(): Unit { checkpointId = ""; checkpointConfig = ""; checkpointInput = [] }
    private func ensureOpen(): Unit {
        if (poisoned) { throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.stream_failed", "WebSocket session is poisoned by an earlier error") }
        if (closed) { throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.stream_closed", "WebSocket session is closed") }
    }
}

func jsonItemStrings(input: JsonNode): Array<String> {
    let result = ArrayList<String>()
    for (item in input.items) { result.add(item.stringify()) }
    result.toArray()
}
func stringPrefix(prefix: Array<String>, values: Array<String>): Bool {
    if (prefix.size > values.size) { return false }
    for (index in 0..prefix.size where prefix[index] != values[index]) {
        return false
    }
    true
}
