package llm4cj

import std.collection.*

class TranscriptToolState {
    public let tool: LlmWireTool
    public let visibility: LlmWireToolVisibility
    public var active: Bool
    public init(tool: LlmWireTool, visibility: LlmWireToolVisibility, active: Bool) {
        this.tool = tool
        this.visibility = visibility
        this.active = active
    }
}

func validToolVersion(value: String): Bool {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 64) { return false }
    for (byte in bytes) {
        let allowed = (byte >= 33u8 && byte <= 126u8)
        if (!allowed) { return false }
    }
    true
}

func transcriptToolIdentityEqual(left: LlmWireTool, right: LlmWireTool): Bool {
    left.name == right.name && left.version == right.version &&
        left.description == right.description && left.inputSchema.stringify() == right.inputSchema.stringify()
}

func transcriptDeclarationEqual(left: LlmWireToolDeclaration, right: LlmWireToolDeclaration): Bool {
    transcriptToolIdentityEqual(left.tool, right.tool) && left.visibility == right.visibility
}

func transcriptRefMatches(ref: LlmWireToolRef, tool: LlmWireTool): Bool {
    ref.name == tool.name && ref.version == tool.version
}

func transcriptFindExact(states: ArrayList<TranscriptToolState>, ref: LlmWireToolRef): ?TranscriptToolState {
    for (state in states where transcriptRefMatches(ref, state.tool)) { return Some(state) }
    None
}


func transcriptActiveTool(states: ArrayList<TranscriptToolState>, name: String): ?TranscriptToolState {
    var found: ?TranscriptToolState = None
    for (state in states where state.active && state.tool.name == name) {
        if (found.isSome()) {
            throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.tool_state_invalid", "more than one active tool version has the same name")
        }
        found = Some(state)
    }
    found
}

func transcriptToolDefinitionConflict(name: String): Nothing {
    throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_definition_conflict", "a tool name cannot change its definition without an explicit replacement: " + name)
}

func transcriptUnknownReference(ref: LlmWireToolRef): Nothing {
    throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_reference_unknown", "tool reference is not declared: " + ref.name + "@" + ref.version)
}

func transcriptStateError(message: String): Nothing {
    throw LlmWireError(LlmWireErrorKind.InvalidState, "llm.tool_state_invalid", message)
}

func validateTranscriptTool(tool: LlmWireTool): Unit {
    if (!validToolVersion(tool.version)) {
        throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_version_invalid", "tool versions must be 1-64 ASCII identity bytes")
    }
    if (tool.inputSchema.kind != LlmWireJsonKind.Object) {
        throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_schema_invalid", "tool input schema must be a JSON object")
    }
}

func addInitialTranscriptDeclaration(states: ArrayList<TranscriptToolState>, declaration: LlmWireToolDeclaration): Unit {
    validateTranscriptTool(declaration.tool)
    for (state in states where state.tool.name == declaration.tool.name) {
        let existing = LlmWireToolDeclaration(state.tool, visibility: state.visibility)
        if (!transcriptDeclarationEqual(existing, declaration)) { transcriptToolDefinitionConflict(declaration.tool.name) }
        return
    }
    states.add(TranscriptToolState(declaration.tool, declaration.visibility, declaration.visibility == LlmWireToolVisibility.Active))
}

func applyTranscriptDeclaration(states: ArrayList<TranscriptToolState>, declaration: LlmWireToolDeclaration): Unit {
    validateTranscriptTool(declaration.tool)
    for (state in states where state.tool.name == declaration.tool.name) {
        let existing = LlmWireToolDeclaration(state.tool, visibility: state.visibility)
        if (!transcriptDeclarationEqual(existing, declaration)) { transcriptToolDefinitionConflict(declaration.tool.name) }
        return
    }
    states.add(TranscriptToolState(declaration.tool, declaration.visibility, declaration.visibility == LlmWireToolVisibility.Active))
}

func applyTranscriptActivation(states: ArrayList<TranscriptToolState>, ref: LlmWireToolRef): Unit {
    let state = match (transcriptFindExact(states, ref)) { case Some(value) => value; case None => transcriptUnknownReference(ref) }
    if (state.active) { transcriptStateError("tool is already active: " + ref.name) }
    for (other in states where other.active && other.tool.name == ref.name && other.tool.version != ref.version) {
        transcriptStateError("a different version is already active: " + ref.name)
    }
    state.active = true
}

func applyTranscriptDeactivation(states: ArrayList<TranscriptToolState>, ref: LlmWireToolRef): Unit {
    let state = match (transcriptFindExact(states, ref)) { case Some(value) => value; case None => transcriptUnknownReference(ref) }
    if (!state.active) { transcriptStateError("tool is already inactive: " + ref.name) }
    state.active = false
}

func applyTranscriptReplacement(states: ArrayList<TranscriptToolState>, previous: LlmWireToolRef, replacement: LlmWireTool): Unit {
    let previousState = match (transcriptFindExact(states, previous)) { case Some(value) => value; case None => transcriptUnknownReference(previous) }
    validateTranscriptTool(replacement)
    if (replacement.name != previous.name) { transcriptToolDefinitionConflict(previous.name) }
    for (state in states where state.tool.name == replacement.name && state.tool.version == replacement.version) {
        if (!transcriptToolIdentityEqual(state.tool, replacement)) { transcriptToolDefinitionConflict(replacement.name) }
        transcriptStateError("replacement target version is already declared: " + replacement.name + "@" + replacement.version)
    }
    let visibility = if (previousState.active) { LlmWireToolVisibility.Active } else { LlmWireToolVisibility.Deferred }
    states.add(TranscriptToolState(replacement, visibility, previousState.active))
    previousState.active = false
}

func validateTranscriptCall(call: LlmWireToolCallBlock, states: ArrayList<TranscriptToolState>): Unit {
    let active = match (transcriptActiveTool(states, call.name)) {
        case Some(value) => value
        case None => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_reference_unknown", "tool call refers to a tool that is not active: " + call.name, toolCallId: call.callId)
    }
    match (call.arguments) {
        case LlmWireToolArguments.Complete(arguments) =>
            if (arguments.kind != LlmWireJsonKind.Object) {
                throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_shape_invalid", "complete tool arguments must be an object", toolCallId: call.callId)
            }
            match (checkToolInputValue(active.tool.inputSchema.jsonNode(), arguments.jsonNode(), "", "", false)) {
                case ToolInputCheck.Valid => ()
                case ToolInputCheck.Violation(value) => throw toolInputViolationError(call, value)
                case ToolInputCheck.Unsupported(feature) => throw toolInputUnsupportedError(call, feature)
            }
        case LlmWireToolArguments.InvalidJson(_) => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_json_invalid", "tool call arguments must contain valid JSON", toolCallId: call.callId)
        case LlmWireToolArguments.InvalidShape(_) => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_shape_invalid", "tool call arguments must be a JSON object", toolCallId: call.callId)
        case LlmWireToolArguments.Partial(_) => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_partial", "partial tool arguments cannot be sent as an executable tool call", toolCallId: call.callId)
}
}
func validateTranscriptMessage(
    message: LlmWireMessage, states: ArrayList<TranscriptToolState>, known: HashSet<String>, pending: HashSet<String>
): Unit {
    if (!messageHasContent(message)) {
        throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.message_empty", "messages must contain semantic content")
    }
    if (!pending.isEmpty()) {
        if (message.role != LlmWireRole.User) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_conversation_out_of_phase", "only tool results may follow unresolved tool calls")
        }
        for (block in message.blocks) {
            match (block) {
                case LlmWireBlock.ToolResult(_) => ()
                case _ => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_conversation_out_of_phase", "ordinary content cannot appear while tool calls are unresolved")
            }
        }
    }
    for (block in message.blocks) {
        validateBlockShape(block)
        match (block) {
            case LlmWireBlock.ToolCall(call) =>
                if (message.role != LlmWireRole.Assistant) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_call_role_invalid", "tool calls must belong to assistant messages") }
                if (call.callId == "" || known.contains(call.callId)) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_call_duplicate", "tool call IDs must be non-empty and unique") }
                validateTranscriptCall(call, states)
                known.add(call.callId)
                pending.add(call.callId)
            case LlmWireBlock.ToolResult(result) =>
                if (message.role != LlmWireRole.User) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_result_role_invalid", "tool results must belong to user messages") }
                if (!pending.contains(result.callId)) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_result_unmatched", "tool result must match a prior unconsumed tool call") }
                if (result.content.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_result_content_empty", "tool results require at least one content part") }
                pending.remove(result.callId)
            case _ => ()
        }
    }
    if (message.role == LlmWireRole.User && !pending.isEmpty()) {
        throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_results_incomplete", "one tool-result message must close every pending parallel tool call")
    }
}

func transcriptStates(transcript: LlmWireTranscript): ArrayList<TranscriptToolState> {
    let states = ArrayList<TranscriptToolState>()
    for (declaration in transcript.initialContext.tools) { addInitialTranscriptDeclaration(states, declaration) }
    let known = HashSet<String>()
    let pending = HashSet<String>()
    let items = transcript.items
    for (index in 0..items.size) {
        match (items[index]) {
            case LlmWireInputItem.Message(message) => validateTranscriptMessage(message, states, known, pending)
            case LlmWireInputItem.InstructionUpdate(instruction) =>
                if (instruction.text.trimAscii() == "") { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.instruction_empty", "instruction text must not be empty") }
                if (!pending.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.context_update_position_invalid", "instruction updates cannot interrupt unresolved tool calls") }
            case LlmWireInputItem.ToolDeclaration(declaration) =>
                if (!pending.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.context_update_position_invalid", "tool declarations cannot interrupt unresolved tool calls") }
                applyTranscriptDeclaration(states, declaration)
            case LlmWireInputItem.ToolActivation(ref) =>
                if (!pending.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.context_update_position_invalid", "tool activation cannot interrupt unresolved tool calls") }
                applyTranscriptActivation(states, ref)
            case LlmWireInputItem.ToolDeactivation(ref) =>
                if (!pending.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.context_update_position_invalid", "tool deactivation cannot interrupt unresolved tool calls") }
                applyTranscriptDeactivation(states, ref)
            case LlmWireInputItem.ToolReplacement(previous, replacement) =>
                if (!pending.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.context_update_position_invalid", "tool replacement cannot interrupt unresolved tool calls") }
                applyTranscriptReplacement(states, previous, replacement)
        }
    }
    if (!pending.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_call_unresolved", "every tool call must have exactly one later result") }
    states
}

func validateTranscript(transcript: LlmWireTranscript): Unit {
    let _ = transcriptStates(transcript)
}

func effectiveToolsForTranscript(transcript: LlmWireTranscript): LlmWireResult<Array<LlmWireTool>> {
    try {
        let output = ArrayList<LlmWireTool>()
        for (state in transcriptStates(transcript) where state.active) { output.add(state.tool) }
        LlmWireResult.Ok(output.toArray())
    } catch (error: LlmWireError) {
        LlmWireResult.Err(error)
    }
}

func validToolNameForGrammar(value: String, grammar: LlmWireToolNameGrammar): Bool {
    let bytes = value.toArray()
    let maximum = match (grammar) { case LlmWireToolNameGrammar.StandardAscii64 => 64; case LlmWireToolNameGrammar.KimiAscii128 => 128 }
    if (bytes.isEmpty() || bytes.size > maximum) { return false }
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        let letter = (byte >= 65u8 && byte <= 90u8) || (byte >= 97u8 && byte <= 122u8)
        let digit = byte >= 48u8 && byte <= 57u8
        let punctuation = byte == 95u8 || (grammar == LlmWireToolNameGrammar.StandardAscii64 && byte == 45u8)
        if (!letter && !digit && !punctuation) { return false }
        if (grammar == LlmWireToolNameGrammar.KimiAscii128 && index == 0 && !letter && byte != 95u8) { return false }
    }
    true
}

func transcriptInitialActiveTools(context: LlmWireInitialContext): Array<LlmWireTool> {
    let output = ArrayList<LlmWireTool>()
    for (declaration in context.tools where declaration.visibility == LlmWireToolVisibility.Active) { output.add(declaration.tool) }
    output.toArray()
}

func transcriptEncodingFor(codec: LlmWireCodec, operation: LlmWireTranscriptOperation): LlmWireResult<LlmWireTranscriptEncoding> {
    match (codec.modelProfile) {
        case Some(profile) => profile.transcriptCapabilities.encodingFor(operation)
        case None => LlmWireResult.Err(LlmWireError(LlmWireErrorKind.Unsupported, "llm.context_update_unsupported", "dynamic transcript operations require a bound model profile"))
    }
}

func requireTranscriptEncoding(codec: LlmWireCodec, operation: LlmWireTranscriptOperation, expected: LlmWireTranscriptEncoding): Unit {
    match (transcriptEncodingFor(codec, operation)) {
        case LlmWireResult.Ok(value) => if (value != expected) { unsupportedRequest("llm.context_update_unsupported", "the bound profile does not provide the required transcript encoding") }
        case LlmWireResult.Err(error) => throw error
    }
}