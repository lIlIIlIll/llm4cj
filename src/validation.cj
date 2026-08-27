package llm4cj

import std.collection.*
import std.convert.*
import yjson.*

func invalidWire(code: String, message: String, provider!: String = ""): Nothing {
    throw LlmTransportError(LlmTransportErrorKind.InvalidWire, code, message, provider: provider)
}

func wireObject(value: JsonNode, name: String, provider!: String = ""): JsonNode {
    if (value.wireKind != WireJsonKind.Object) { invalidWire("llm.object_expected", name + " must be an object", provider: provider) }
    value
}

func wireRequiredField(value: JsonNode, name: String, provider!: String = ""): JsonNode {
    match (value.field(name)) {
        case Some(found) => found
        case None => invalidWire("llm.field_missing", "provider response is missing field: " + name, provider: provider)
    }
}

func wireOptionalString(value: JsonNode, name: String, provider!: String = ""): ?String {
    match (value.field(name)) {
        case None => None
        case Some(found) =>
            if (found.wireKind == WireJsonKind.Null) { None }
            else if (found.wireKind == WireJsonKind.Text) { Some(found.text) }
            else { invalidWire("llm.field_type_invalid", name + " must be a string or null", provider: provider) }
    }
}

func wireRequiredString(value: JsonNode, name: String, provider!: String = ""): String {
    match (wireOptionalString(value, name, provider: provider)) {
        case Some(found) => found
        case None => invalidWire("llm.field_missing", "provider response is missing string field: " + name, provider: provider)
    }
}

func wireOptionalObject(value: JsonNode, name: String, provider!: String = ""): ?JsonNode {
    match (value.field(name)) {
        case None => None
        case Some(found) =>
            if (found.wireKind == WireJsonKind.Null) { None }
            else if (found.wireKind == WireJsonKind.Object) { Some(found) }
            else { invalidWire("llm.field_type_invalid", name + " must be an object or null", provider: provider) }
    }
}

func wireOptionalArray(value: JsonNode, name: String, provider!: String = ""): ?Array<JsonNode> {
    match (value.field(name)) {
        case None => None
        case Some(found) =>
            if (found.wireKind == WireJsonKind.Null) { None }
            else if (found.wireKind == WireJsonKind.List) { Some(found.items) }
            else { invalidWire("llm.field_type_invalid", name + " must be an array or null", provider: provider) }
    }
}

func wireOptionalInt(value: JsonNode, name: String, provider!: String = ""): ?Int64 {
    match (value.field(name)) {
        case None => None
        case Some(found) =>
            if (found.wireKind == WireJsonKind.Null) { None }
            else if (found.wireKind != WireJsonKind.Number) { invalidWire("llm.field_type_invalid", name + " must be an integer or null", provider: provider) }
            else {
                try { Some(Int64.parse(found.number)) }
                catch (_: Exception) { invalidWire("llm.integer_invalid", name + " is outside the Int64 range or is not an integer", provider: provider) }
            }
    }
}

func wireIntOrZero(value: JsonNode, name: String, provider!: String = ""): Int64 {
    match (wireOptionalInt(value, name, provider: provider)) { case Some(found) => found; case None => 0 }
}

func validateWireRequest(codec: LlmWireCodec, request: LlmWireRequest): Unit {
    if (request.model == "") { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.model_missing", "model must not be empty") }
    match (request.maxOutputTokens) {
        case Some(value) => if (value < 1) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.max_output_tokens_invalid", "maxOutputTokens must be positive") }
        case None => ()
    }
    codec.dialect.validateThinking(request.thinking, codec.capabilities)
    var usesTools = !request.tools.isEmpty()
    for (message in request.messages) { for (block in message.blocks) { match (block) { case LlmWireBlock.ToolCall(_) | LlmWireBlock.ToolResult(_) => usesTools = true; case _ => () } } }
    match (request.toolChoice) { case LlmWireToolChoice.ProviderDefault => (); case _ => usesTools = true }
    if (usesTools && !codec.capabilities.tools) { unsupportedRequest("llm.tools_unsupported", "tools require an explicit capability") }
    match (request.structuredOutput) { case Some(_) => if (!codec.capabilities.structuredOutput) { unsupportedRequest("llm.structured_output_unsupported", "structured output requires an explicit capability") }; case None => () }
    match (request.parallelToolCalls) { case Some(_) => if (!codec.capabilities.parallelToolCalls) { unsupportedRequest("llm.parallel_tools_unsupported", "parallel tool calls require an explicit capability") }; case None => () }
    match (request.serviceTier) { case Some(_) => if (!codec.capabilities.serviceTier) { unsupportedRequest("llm.service_tier_unsupported", "service tier requires an explicit capability") }; case None => () }
    if (let LlmWireCachePolicy.StablePrefix <- request.cachePolicy) {
        if (!codec.capabilities.stableCache) { unsupportedRequest("llm.cache_unsupported", "stable cache requires an explicit capability") }
    }
    if (let LlmWireValidationPolicy.Strict <- codec.validationPolicy) { validateConversation(request.messages) }
    for (message in request.messages) { for (block in message.blocks) { validateBlockForReplay(codec, block) } }
}

func unsupportedRequest(code: String, message: String): Nothing {
    throw LlmTransportError(LlmTransportErrorKind.Unsupported, code, message)
}

func validateBlockForReplay(codec: LlmWireCodec, block: LlmWireBlock): Unit {
    match (block) {
        case LlmWireBlock.Opaque(value) =>
            if (let LlmWireOpaqueCompletion.Partial <- value.completion) { unsupportedRequest("llm.opaque_partial", "partial opaque blocks cannot be replayed") }
            if (value.protocol != codec.protocol || value.dialectId != codec.dialect.compatibilityId) { unsupportedRequest("llm.opaque_dialect_mismatch", "opaque block can only be replayed by the same protocol and dialect compatibility ID") }
        case LlmWireBlock.ToolCall(value) => match (value.arguments) {
            case LlmWireToolArguments.Partial(_) => throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_arguments_partial", "partial tool arguments cannot be sent as an executable tool call")
            case _ => ()
        }
        case _ => ()
    }
}

func validateConversation(messages: Array<LlmWireMessage>): Unit {
    let known = HashSet<String>()
    let pending = HashSet<String>()
    for (message in messages) { for (block in message.blocks) {
        match (block) {
            case LlmWireBlock.ToolCall(call) =>
                if (call.callId == "" || known.contains(call.callId)) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_call_duplicate", "tool call IDs must be non-empty and unique") }
                known.add(call.callId)
                pending.add(call.callId)
            case LlmWireBlock.ToolResult(result) =>
                if (!pending.contains(result.callId)) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_result_unmatched", "tool result must match a prior unconsumed tool call") }
                pending.remove(result.callId)
            case _ => ()
        }
    } }
}
