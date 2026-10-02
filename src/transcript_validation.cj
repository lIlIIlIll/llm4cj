package llm4cj

import std.collection.*
import yjson.*

// Evidence is deliberately a short marker rather than a byte slice, so an
// oversized Unicode identifier cannot produce an invalid UTF-8 diagnostic.
internal func boundedTranscriptEvidence(value: String): String {
    let size = value.toArray().size
    if (size > 128) { return "<" + size.toString() + " bytes>" }
    value
}

internal func transcriptError(
    code: String, message: String, itemIndex: Int64,
    toolName!: String = "", toolVersion!: String = "", blockIndex!: Int64 = -1,
    toolCallId!: String = "", kind!: LlmWireErrorKind = LlmWireErrorKind.InvalidRequest,
    missingCapability!: String = "", profileId!: String = "", contractVersion!: Int64 = 0
): LlmWireError {
    LlmWireError(kind, code, message, phase: Some(LlmTransportPhase.Encode),
        inputItemIndex: itemIndex, toolName: toolName, toolVersion: toolVersion,
        blockIndex: blockIndex, toolCallId: boundedTranscriptEvidence(toolCallId),
        missingCapability: missingCapability, profileId: profileId, contractVersion: contractVersion)
}

internal func withInputItemContext(error: LlmWireError, itemIndex: Int64): LlmWireError {
    LlmWireError(error.kind, error.code, error.message, retryable: error.retryable,
        httpStatus: error.httpStatus, retryAfterMillis: error.retryAfterMillis,
        provider: error.provider, providerErrorCode: error.providerErrorCode,
        providerErrorType: error.providerErrorType, diagnosticJson: error.diagnosticJson,
        phase: error.phase, protocol: error.protocol, dialectId: error.dialectId,
        eventType: error.eventType, blockIndex: error.blockIndex, toolCallId: error.toolCallId,
        providerRequestId: error.providerRequestId, usage: error.usage,
        inputItemIndex: itemIndex, toolName: error.toolName, toolVersion: error.toolVersion,
        missingCapability: error.missingCapability, profileId: error.profileId, contractVersion: error.contractVersion)
}

// Object member order is not part of a JSON Schema definition. Arrays, version
// identifiers and descriptions are; they are compared without normalization.
internal func canonicalToolSchema(value: JsonNode): String {
    canonicalToolSchemaValue(value).stringify()
}

internal func canonicalToolSchemaValue(value: JsonNode): JsonNode {
    match (value.wireKind) {
        case WireJsonKind.Object =>
            let fields = ArrayList<WireJsonField>()
            for (name in toolSchemaObjectNames(value)) {
                fields.add(WireJsonField(name, canonicalToolSchemaValue(value.field(name).getOrThrow())))
            }
            wireJsonObject(fields.toArray())
        case WireJsonKind.List =>
            let values = ArrayList<JsonNode>()
            for (child in value.items) { values.add(canonicalToolSchemaValue(child)) }
            wireJsonArray(values.toArray())
        case _ => value
    }
}

internal func sameToolDeclaration(left: LlmWireToolDeclaration, right: LlmWireToolDeclaration): Bool {
    left.tool.name == right.tool.name && left.version == right.version &&
    left.tool.description == right.tool.description &&
    canonicalToolSchema(left.tool.inputSchema.jsonNode()) == canonicalToolSchema(right.tool.inputSchema.jsonNode())
}

internal class LlmWireTranscriptView {
    internal let messages: Array<LlmWireMessage>
    internal let activeTools: Array<LlmWireTool>
    internal let declaredTools: Array<LlmWireToolDeclaration>
    internal init(messages: Array<LlmWireMessage>, activeTools: Array<LlmWireTool>, declaredTools: Array<LlmWireToolDeclaration>) {
        this.messages = messages; this.activeTools = activeTools; this.declaredTools = declaredTools
    }
}

internal class TranscriptToolState {
    private let declared = HashMap<String, LlmWireToolDeclaration>()
    private let order = ArrayList<String>()
    private let active = HashSet<String>()

    internal func declare(value: LlmWireToolDeclaration, itemIndex: Int64): Unit {
        if (!validToolName(value.tool.name)) {
            throw transcriptError("llm.tool_name_invalid", "tool names must use the tool-name grammar", itemIndex, toolName: value.tool.name, toolVersion: value.version)
        }
        if (value.version == "" || value.version.toArray().size > 64) {
            throw transcriptError("llm.tool_version_invalid", "tool versions must contain 1-64 bytes", itemIndex, toolName: value.tool.name, toolVersion: value.version)
        }
        if (value.tool.inputSchema.jsonNode().wireKind != WireJsonKind.Object) {
            throw transcriptError("llm.tool_schema_invalid", "tool input schemas must be JSON objects", itemIndex, toolName: value.tool.name, toolVersion: value.version)
        }
        match (declared.get(value.tool.name)) {
            case Some(previous) =>
                if (!sameToolDeclaration(previous, value)) {
                    throw transcriptError("llm.tool_definition_conflict", "a tool name cannot refer to different definitions or versions", itemIndex, toolName: value.tool.name, toolVersion: value.version)
                }
                // Repeating a declaration never changes its visibility. A
                // separately typed activation is required to reactivate it.
            case None =>
                declared[value.tool.name] = value
                order.add(value.tool.name)
                if (!value.deferred) { active.add(value.tool.name) }
        }
    }

    private func requireDeclared(identity: LlmWireToolDefinitionIdentity, itemIndex: Int64): LlmWireToolDeclaration {
        match (declared.get(identity.name)) {
            case Some(value) =>
                if (value.version != identity.version) {
                    throw transcriptError("llm.tool_reference_unknown", "tool identity does not match a declared definition", itemIndex, toolName: identity.name, toolVersion: identity.version)
                }
                value
            case None => throw transcriptError("llm.tool_reference_unknown", "tool identity has not been declared", itemIndex, toolName: identity.name, toolVersion: identity.version)
        }
    }

    internal func activate(identity: LlmWireToolDefinitionIdentity, itemIndex: Int64): Unit {
        let _ = requireDeclared(identity, itemIndex)
        active.add(identity.name)
    }

    internal func deactivate(identity: LlmWireToolDefinitionIdentity, itemIndex: Int64): Unit {
        let _ = requireDeclared(identity, itemIndex)
        if (!active.contains(identity.name)) {
            throw transcriptError("llm.tool_not_active", "only an active tool can be deactivated", itemIndex, toolName: identity.name, toolVersion: identity.version)
        }
        active.remove(identity.name)
    }

    internal func requireActive(call: LlmWireToolCallBlock, itemIndex: Int64, blockIndex: Int64): Unit {
        match (declared.get(call.name)) {
            case None => throw transcriptError("llm.tool_reference_unknown", "tool calls must refer to a prior declaration", itemIndex, toolName: call.name, blockIndex: blockIndex, toolCallId: call.callId)
            case Some(value) =>
                if (!active.contains(call.name)) {
                    throw transcriptError("llm.tool_not_active", "tool calls must refer to a tool active at this transcript item", itemIndex, toolName: call.name, toolVersion: value.version, blockIndex: blockIndex, toolCallId: call.callId)
                }
        }
    }

    internal func activeTools(): Array<LlmWireTool> {
        let tools = ArrayList<LlmWireTool>()
        for (name in order where active.contains(name)) { tools.add(declared[name].tool) }
        tools.toArray()
    }

    internal func declaredTools(): Array<LlmWireToolDeclaration> {
        let tools = ArrayList<LlmWireToolDeclaration>()
        for (name in order) { tools.add(declared[name]) }
        tools.toArray()
    }
}

// The state transition and the call check happen in one pass. End-of-transcript
// visibility is never used to judge a historical call.
internal func replayTranscript(transcript: LlmWireTranscript): LlmWireTranscriptView {
    let state = TranscriptToolState()
    let messages = ArrayList<LlmWireMessage>()
    let items = transcript.items
    let known = HashSet<String>()
    let pending = HashSet<String>()
    for (declaration in transcript.initialContext.tools) { state.declare(declaration, -1) }
    for (itemIndex in 0..items.size) {
        match (items[itemIndex]) {
            case LlmWireInputItem.ToolDeclaration(value) => state.declare(value, itemIndex)
            case LlmWireInputItem.ToolActivation(identity) => state.activate(identity, itemIndex)
            case LlmWireInputItem.ToolDeactivation(identity) => state.deactivate(identity, itemIndex)
            case LlmWireInputItem.InstructionUpdate(_) => ()
            case LlmWireInputItem.Message(message) =>
                let blocks = message.blocks
                let hadPending = !pending.isEmpty()
                var ordinaryUserContent = false
                if (!pending.isEmpty()) {
                    if (message.role != LlmWireRole.User) {
                        throw transcriptError("llm.tool_conversation_out_of_phase", "only tool results may follow unresolved tool calls", itemIndex)
                    }
                }
                for (blockIndex in 0..blocks.size) {
                    if (hadPending) { match (blocks[blockIndex]) {
                        case LlmWireBlock.ToolResult(_) =>
                            if (ordinaryUserContent) { throw transcriptError("llm.tool_conversation_out_of_phase", "tool results must precede ordinary user content", itemIndex, blockIndex: blockIndex) }
                        case _ =>
                            if (!pending.isEmpty()) { throw transcriptError("llm.tool_conversation_out_of_phase", "ordinary content cannot appear while tool calls are unresolved", itemIndex, blockIndex: blockIndex) }
                            ordinaryUserContent = true
                    } }
                    match (blocks[blockIndex]) {
                    case LlmWireBlock.ToolCall(call) =>
                        try { validateBlockShape(blocks[blockIndex]) }
                        catch (error: LlmWireError) { throw withInputItemContext(error, itemIndex) }
                        if (message.role != LlmWireRole.Assistant) {
                            throw transcriptError("llm.tool_call_role_invalid", "tool calls must belong to assistant messages", itemIndex, blockIndex: blockIndex, toolCallId: call.callId)
                        }
                        if (call.callId == "" || known.contains(call.callId)) {
                            throw transcriptError("llm.tool_call_duplicate", "tool call IDs must be non-empty and unique", itemIndex, blockIndex: blockIndex, toolCallId: call.callId)
                        }
                        state.requireActive(call, itemIndex, blockIndex)
                        known.add(call.callId); pending.add(call.callId)
                    case LlmWireBlock.ToolResult(result) =>
                        if (message.role != LlmWireRole.User) {
                            throw transcriptError("llm.tool_result_role_invalid", "tool results must belong to user messages", itemIndex, blockIndex: blockIndex, toolCallId: result.callId)
                        }
                        if (!pending.contains(result.callId)) {
                            throw transcriptError("llm.tool_result_unmatched", "tool results must match a prior unconsumed tool call", itemIndex, blockIndex: blockIndex, toolCallId: result.callId)
                        }
                        pending.remove(result.callId)
                    case _ => ()
                } }
                if (message.role == LlmWireRole.User && !pending.isEmpty()) {
                    throw transcriptError("llm.tool_results_incomplete", "one tool-result message must close every pending parallel call", itemIndex)
                }
                messages.add(message)
        }
    }
    if (!pending.isEmpty()) {
        throw transcriptError("llm.tool_call_unresolved", "every tool call must have exactly one later result", items.size - 1)
    }
    LlmWireTranscriptView(messages.toArray(), state.activeTools(), state.declaredTools())
}

// Anthropic system updates belong after a user message and before an assistant
// message (or at the request end). Consecutive typed changes form one update
// group; it cannot split tool_use from tool_result.
internal func validateTranscriptPositions(codec: LlmWireCodec, transcript: LlmWireTranscript): Unit {
    if (codec.dialect.contract.contextUpdates.style != LlmWireContextUpdateStyle.AnthropicToolReferences) { return }
    let pending = HashSet<String>()
    let items = transcript.items
    let declared = HashMap<String, LlmWireToolDeclaration>()
    for (declaration in transcript.initialContext.tools) { declared[declaration.tool.name] = declaration }
    var previousRole: ?LlmWireRole = None
    var updateStart: Int64 = -1
    for (itemIndex in 0..items.size) {
        match (items[itemIndex]) {
            case LlmWireInputItem.ToolDeclaration(declaration) =>
                match (declared.get(declaration.tool.name)) {
                    case Some(previous) => if (sameToolDeclaration(previous, declaration)) { continue }
                    case None => declared[declaration.tool.name] = declaration
                }
            case _ => ()
        }
        match (items[itemIndex]) {
        case LlmWireInputItem.Message(message) =>
            if (updateStart >= 0 && message.role != LlmWireRole.Assistant) {
                throw transcriptError("llm.context_update_position_invalid", "Anthropic context updates must precede an assistant message or the request end", updateStart)
            }
            updateStart = -1
            for (block in message.blocks) { match (block) {
                case LlmWireBlock.ToolCall(call) => pending.add(call.callId)
                case LlmWireBlock.ToolResult(result) => pending.remove(result.callId)
                case _ => ()
            } }
            previousRole = Some(message.role)
        case _ =>
            if (!pending.isEmpty()) {
                throw transcriptError("llm.context_update_position_invalid", "context updates cannot separate Anthropic tool calls from their results", itemIndex)
            }
            if (updateStart < 0) {
                if (previousRole != Some(LlmWireRole.User)) {
                    throw transcriptError("llm.context_update_position_invalid", "Anthropic context updates must immediately follow a user message", itemIndex)
                }
                updateStart = itemIndex
            }
    } }
}
