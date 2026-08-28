package llm4cj

import std.collection.*
import std.convert.*
import yjson.*

func invalidWire(code: String, message: String, provider!: String = ""): Nothing {
    throw LlmTransportError(LlmTransportErrorKind.InvalidWire, code, message, provider: provider, phase: Some(LlmTransportPhase.WireDecode))
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

func wireRequiredInt(value: JsonNode, name: String, provider!: String = ""): Int64 {
    match (wireOptionalInt(value, name, provider: provider)) {
        case Some(found) => found
        case None => invalidWire("llm.field_missing", "provider response is missing integer field: " + name, provider: provider)
    }
}

func validateWireRequest(codec: LlmWireCodec, request: LlmWireRequest): Unit {
    if (request.model == "") { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.model_missing", "model must not be empty") }
    match (request.maxOutputTokens) {
        case Some(value) => if (value < 1) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.max_output_tokens_invalid", "maxOutputTokens must be positive") }
        case None => ()
    }
    if (codec.dialect.contract.requireMaxOutputTokens && request.maxOutputTokens.isNone()) {
        throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.max_output_tokens_required", "this dialect requires maxOutputTokens")
    }
    match (codec.protocol) {
        case LlmWireProtocol.Responses =>
            if (request.messages.isEmpty() && request.system == "") { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.responses_input_required", "Responses requires input messages or instructions") }
        case LlmWireProtocol.ChatCompletions =>
            if (request.messages.isEmpty()) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.chat_messages_required", "Chat Completions requires at least one message") }
        case LlmWireProtocol.Messages =>
            if (request.messages.isEmpty()) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.messages_required", "Messages requires at least one message") }
    }
    validateThinking(codec, request)
    validateToolsAndSchemas(request)
    var usesTools = !request.tools.isEmpty()
    for (message in request.messages) { for (block in message.blocks) { match (block) { case LlmWireBlock.ToolCall(_) | LlmWireBlock.ToolResult(_) => usesTools = true; case _ => () } } }
    match (request.toolChoice) { case LlmWireToolChoice.ProviderDefault => (); case _ => usesTools = true }
    if (usesTools && (!codec.dialect.contract.tools || !codec.capabilities.tools)) { unsupportedRequest("llm.tools_unsupported", "tools require an explicit dialect and model capability") }
    if ((request.toolChoice == LlmWireToolChoice.Required || request.toolChoice == LlmWireToolChoice.Auto) && request.tools.isEmpty()) {
        throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_choice_without_tools", "toolChoice requires at least one declared tool")
    }
    validateStructuredOutput(codec, request.structuredOutput)
    match (request.parallelToolCalls) {
        case Some(_) =>
            if (request.tools.isEmpty()) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.parallel_tools_without_tools", "parallel tool calls require declared tools") }
            if (codec.dialect.contract.parallelToolStyle == LlmWireParallelToolStyle.Unsupported || !codec.capabilities.parallelToolCalls) { unsupportedRequest("llm.parallel_tools_unsupported", "parallel tool calls are not supported by this dialect and model") }
        case None => ()
    }
    validateServiceTier(codec, request.serviceTier)
    validateGenerationSpeed(codec, request.generationSpeed)
    validatePromptCache(codec, request.promptCache, request.promptCacheRoutingKey)
    for (messageIndex in 0..request.messages.size) {
        let message = request.messages[messageIndex]
        var deepSeekReasoningBlocks: Int64 = 0
        if (!messageHasContent(message)) {
            throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.message_empty", "canonical messages must contain at least one non-empty block")
        }
        for (blockIndex in 0..message.blocks.size) {
            validateBlockForReplay(codec, request, message, message.blocks[blockIndex], blockIndex)
            validateBlockShape(message.blocks[blockIndex])
            match (message.blocks[blockIndex]) {
                case LlmWireBlock.Image(value) => validateImageCapability(codec, message, value)
                case LlmWireBlock.NativeReplay(value) =>
                    if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.DeepSeekChat && value.nativeType == "reasoning_content") {
                        deepSeekReasoningBlocks++
                        if (deepSeekReasoningBlocks > 1) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.native_replay_cardinality_invalid", "DeepSeek Chat assistant turns may contain only one reasoning_content replay block") }
                    }
                case LlmWireBlock.ToolResult(value) =>
                    if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.DeepSeekMessages && value.isError) {
                        unsupportedRequest("llm.tool_result_error_semantics_unsupported", "DeepSeek Messages does not preserve tool-result error semantics")
                    }
                case _ => ()
            }
        }
    }
    validateConversation(request.messages)
}

func validateImageCapability(codec: LlmWireCodec, message: LlmWireMessage, value: LlmWireImageBlock): Unit {
    var supported = false
    for (modality in codec.capabilities.inputModalities where modality == LlmWireInputModality.Image) { supported = true }
    if (!supported) { unsupportedRequest("llm.image_input_unsupported", "image input requires an explicit model capability") }
    let deepSeek = match (codec.dialect.contract.requestStyle) {
        case LlmWireRequestStyle.DeepSeekResponses | LlmWireRequestStyle.DeepSeekChat | LlmWireRequestStyle.DeepSeekMessages => true
        case _ => false
    }
    if (deepSeek && message.role != LlmWireRole.User) { unsupportedRequest("llm.image_role_unsupported", "DeepSeek image input is supported only in user messages") }
    if (deepSeek) { match (value.sourceKind) {
        case LlmWireImageSourceKind.Base64 =>
            if (!supportedDeepSeekImageMediaType(value.mediaType)) { unsupportedRequest("llm.image_media_type_unsupported", "DeepSeek image input supports JPEG, PNG, GIF, and WebP") }
        case _ => ()
    } }
}

func supportedDeepSeekImageMediaType(value: String): Bool {
    value == "image/jpeg" || value == "image/png" || value == "image/gif" || value == "image/webp"
}

func validateThinking(codec: LlmWireCodec, request: LlmWireRequest): Unit {
    if (let LlmWireThinkingControl.ProviderDefault <- request.thinking) { return }
    if (!supportsThinkingControl(codec.dialect.contract.thinkingControls, request.thinking) || !supportsThinkingControl(codec.capabilities.thinkingControls, request.thinking)) {
        unsupportedRequest("llm.thinking_unsupported", "thinking control is not supported by the supplied dialect and capabilities")
    }
    match (request.thinking) {
        case LlmWireThinkingControl.Effort(level) =>
            if (!supportsThinkingLevel(codec.dialect.contract.thinkingLevels, level) || !supportsThinkingLevel(codec.capabilities.thinkingLevels, level)) { unsupportedRequest("llm.thinking_level_unsupported", "thinking level is not supported") }
        case LlmWireThinkingControl.Adaptive(Some(level)) =>
            if (!supportsThinkingLevel(codec.dialect.contract.thinkingLevels, level) || !supportsThinkingLevel(codec.capabilities.thinkingLevels, level)) { unsupportedRequest("llm.thinking_level_unsupported", "thinking level is not supported") }
        case LlmWireThinkingControl.Budget(tokens) =>
            if (tokens < 1024) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.thinking_budget_invalid", "thinking budget must be at least 1024 tokens") }
            match (request.maxOutputTokens) { case Some(maximum) => if (tokens >= maximum) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.thinking_budget_exceeds_output", "thinking budget must be smaller than maxOutputTokens") }; case None => () }
        case _ => ()
    }
    if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.AnthropicMessages && request.thinking == LlmWireThinkingControl.Enabled) {
        unsupportedRequest("llm.thinking_not_representable", "Anthropic enabled thinking requires an explicit budget or adaptive mode")
    }
}

func supportsThinkingControl(values: Array<LlmWireThinkingControl>, target: LlmWireThinkingControl): Bool {
    for (value in values) {
        match ((value, target)) {
            case (LlmWireThinkingControl.ProviderDefault, LlmWireThinkingControl.ProviderDefault) |
                 (LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Disabled) |
                 (LlmWireThinkingControl.Enabled, LlmWireThinkingControl.Enabled) |
                 (LlmWireThinkingControl.Effort(_), LlmWireThinkingControl.Effort(_)) |
                 (LlmWireThinkingControl.Budget(_), LlmWireThinkingControl.Budget(_)) |
                 (LlmWireThinkingControl.Adaptive(_), LlmWireThinkingControl.Adaptive(_)) => return true
            case _ => ()
        }
    }
    false
}

func supportsThinkingLevel(values: Array<LlmWireThinkingLevel>, target: LlmWireThinkingLevel): Bool {
    for (value in values where value == target) { return true }; false
}

func structuredMode(value: LlmWireStructuredOutput): ?LlmWireStructuredOutputMode {
    match (value) {
        case LlmWireStructuredOutput.ProviderDefault => None
        case LlmWireStructuredOutput.Text => Some(LlmWireStructuredOutputMode.Text)
        case LlmWireStructuredOutput.JsonObject => Some(LlmWireStructuredOutputMode.JsonObject)
        case LlmWireStructuredOutput.JsonSchema(_) => Some(LlmWireStructuredOutputMode.JsonSchema)
        case LlmWireStructuredOutput.JsonSchemaDocument(_) => Some(LlmWireStructuredOutputMode.JsonSchema)
    }
}

func validateStructuredOutput(codec: LlmWireCodec, value: LlmWireStructuredOutput): Unit {
    match (structuredMode(value)) {
        case None => ()
        case Some(mode) => if (!supportsStructuredMode(codec.dialect.contract.structuredOutputModes, mode) || !supportsStructuredMode(codec.capabilities.structuredOutputModes, mode)) { unsupportedRequest("llm.structured_output_unsupported", "structured output mode is not supported by this dialect and model") }
    }
    match ((codec.dialect.contract.requestStyle, value)) {
        case (LlmWireRequestStyle.AnthropicMessages, LlmWireStructuredOutput.JsonSchema(_)) => unsupportedRequest("llm.structured_output_metadata_unsupported", "Anthropic output_config.format cannot represent OpenAI schema name, description, or strict metadata")
        case (LlmWireRequestStyle.AnthropicMessages, LlmWireStructuredOutput.JsonSchemaDocument(_)) => ()
        case (_, LlmWireStructuredOutput.JsonSchemaDocument(_)) => unsupportedRequest("llm.structured_output_document_unsupported", "this dialect requires a named JSON schema specification")
        case _ => ()
    }
}
func supportsStructuredMode(values: Array<LlmWireStructuredOutputMode>, target: LlmWireStructuredOutputMode): Bool { for (value in values where value == target) { return true }; false }

func validateServiceTier(codec: LlmWireCodec, value: LlmWireServiceTier): Unit {
    if (value == LlmWireServiceTier.ProviderDefault) { return }
    var contract = false; for (candidate in codec.dialect.contract.serviceTiers where candidate == value) { contract = true }
    var capability = false; for (candidate in codec.capabilities.serviceTiers where candidate == value) { capability = true }
    if (!contract || !capability) { unsupportedRequest("llm.service_tier_unsupported", "service tier is not supported by this dialect and model") }
}

func validateGenerationSpeed(codec: LlmWireCodec, value: LlmWireGenerationSpeed): Unit {
    if (value == LlmWireGenerationSpeed.ProviderDefault) { return }
    var contract = false; for (candidate in codec.dialect.contract.generationSpeeds where candidate == value) { contract = true }
    var capability = false; for (candidate in codec.capabilities.generationSpeeds where candidate == value) { capability = true }
    if (!contract || !capability) { unsupportedRequest("llm.generation_speed_unsupported", "generation speed is not supported by this dialect and model") }
}

func validatePromptCache(codec: LlmWireCodec, value: LlmWirePromptCache, routingKey: ?String): Unit {
    match (routingKey) {
        case Some(key) => if (key == "") { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.prompt_cache_routing_key_invalid", "prompt cache routing key must not be empty") } else if (!codec.dialect.contract.promptCacheRoutingKey) { unsupportedRequest("llm.prompt_cache_routing_unsupported", "prompt cache routing is not supported by this dialect") }
        case None => ()
    }
    match (value) {
        case LlmWirePromptCache.ProviderDefault => ()
        case LlmWirePromptCache.Automatic(lifetime) =>
            if (codec.dialect.contract.promptCacheStyle == LlmWirePromptCacheStyle.Unsupported) { unsupportedRequest("llm.cache_unsupported", "automatic prompt caching is not supported") }
            var contract = false; for (candidate in codec.dialect.contract.promptCacheLifetimes where candidate == lifetime) { contract = true }
            var capability = false; for (candidate in codec.capabilities.promptCacheLifetimes where candidate == lifetime) { capability = true }
            if (!contract || !capability) { unsupportedRequest("llm.cache_lifetime_unsupported", "prompt cache lifetime is not supported") }
    }
}

func unsupportedRequest(code: String, message: String): Nothing {
    throw LlmTransportError(LlmTransportErrorKind.Unsupported, code, message, phase: Some(LlmTransportPhase.Encode))
}

func unsupportedWire(code: String, message: String, provider!: String = ""): Nothing {
    throw LlmTransportError(LlmTransportErrorKind.Unsupported, code, message, provider: provider, phase: Some(LlmTransportPhase.WireDecode))
}

func validateBlockForReplay(codec: LlmWireCodec, request: LlmWireRequest, message: LlmWireMessage, block: LlmWireBlock, blockIndex: Int64): Unit {
    match (block) {
        case LlmWireBlock.NativeReplay(value) =>
            if (message.role != LlmWireRole.Assistant) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.native_replay_role_invalid", "native replay state must remain in an assistant turn") }
            if (value.completion != LlmWireOpaqueCompletion.Complete) { unsupportedRequest("llm.native_replay_incomplete", "partial native state cannot be replayed") }
            if (value.protocol != codec.protocol || value.dialectId != codec.dialect.compatibilityId) { unsupportedRequest("llm.native_replay_dialect_mismatch", "native state can only be replayed by the same protocol and dialect compatibility ID") }
            match (value.modelConstraint) { case Some(model) => if (model != request.model) { unsupportedRequest("llm.native_replay_model_mismatch", "native state is constrained to another model") }; case None => () }
            if (value.scope == LlmWireNativeReplayScope.AssistantTurn && value.blockOrder != blockIndex) { unsupportedRequest("llm.native_replay_order_mismatch", "native state must retain its block order inside the assistant turn") }
        case LlmWireBlock.Opaque(_) => unsupportedRequest("llm.opaque_diagnostic_only", "unknown native diagnostics cannot be replayed")
        case LlmWireBlock.Reasoning(_) => unsupportedRequest("llm.reasoning_display_only", "display reasoning is not request-encodable")
        case LlmWireBlock.Refusal(_) => unsupportedRequest("llm.refusal_display_only", "refusal output is not request-encodable")
        case LlmWireBlock.ToolCall(value) =>
            if (!validToolName(value.name)) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_call_name_invalid", "tool call names must use the tool-name grammar") }
            match (value.arguments) {
            case LlmWireToolArguments.Complete(arguments) =>
                if (arguments.wireKind != WireJsonKind.Object) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_arguments_shape_invalid", "complete tool arguments must be a JSON object") }
            case LlmWireToolArguments.Partial(_) => throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_arguments_partial", "partial tool arguments cannot be sent as an executable tool call")
            case _ => throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_arguments_not_executable", "invalid tool arguments cannot be sent as an executable tool call")
        }
        case _ => ()
    }
}

func messageHasContent(message: LlmWireMessage): Bool {
    for (block in message.blocks) { match (block) {
        case LlmWireBlock.Text(value) => if (value.text != "") { return true }
        case _ => return true
    } }
    false
}

func validateToolsAndSchemas(request: LlmWireRequest): Unit {
    let names = HashSet<String>()
    for (tool in request.tools) {
        if (!validToolName(tool.name)) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_name_invalid", "tool names must be 1-64 ASCII letters, digits, underscore, or hyphen") }
        if (names.contains(tool.name)) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_name_duplicate", "tool names must be unique") }
        names.add(tool.name)
        if (tool.inputSchema.wireKind != WireJsonKind.Object) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_schema_invalid", "tool input schema must be a JSON object") }
    }
    match (request.structuredOutput) {
        case LlmWireStructuredOutput.JsonSchema(value) =>
            if (value.name == "" || value.schema.wireKind != WireJsonKind.Object) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.structured_schema_invalid", "structured output name and object schema are required") }
        case LlmWireStructuredOutput.JsonSchemaDocument(value) =>
            if (value.wireKind != WireJsonKind.Object) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.structured_schema_invalid", "structured output schema must be a JSON object") }
        case _ => ()
    }
}

func validToolName(value: String): Bool {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 64) { return false }
    for (byte in bytes) {
        let allowed = (byte >= 65u8 && byte <= 90u8) || (byte >= 97u8 && byte <= 122u8) || (byte >= 48u8 && byte <= 57u8) || byte == 95u8 || byte == 45u8
        if (!allowed) { return false }
    }
    true
}

func validateBlockShape(block: LlmWireBlock): Unit {
    match (block) {
        case LlmWireBlock.Image(value) => match (value.sourceKind) {
            case LlmWireImageSourceKind.Url => if (value.data.trimAscii() == "") { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.image_url_invalid", "image URL must not be empty") }
            case LlmWireImageSourceKind.Base64 => if (value.data == "" || value.mediaType == "" || !value.mediaType.contains("/")) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.image_base64_invalid", "base64 images require data and a media type") }
            case LlmWireImageSourceKind.File => if (value.data.trimAscii() == "") { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.image_file_invalid", "file images require a file ID") }
        }
        case _ => ()
    }
}

func validateConversation(messages: Array<LlmWireMessage>): Unit {
    let known = HashSet<String>()
    let pending = HashSet<String>()
    for (message in messages) {
        if (!pending.isEmpty()) {
            if (message.role != LlmWireRole.User) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_conversation_out_of_phase", "only tool results may follow unresolved tool calls", phase: Some(LlmTransportPhase.Encode)) }
            for (block in message.blocks) { match (block) {
                case LlmWireBlock.ToolResult(_) => ()
                case _ => throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_conversation_out_of_phase", "ordinary content cannot appear while tool calls are unresolved", phase: Some(LlmTransportPhase.Encode))
            } }
        }
        for (block in message.blocks) {
        match (block) {
            case LlmWireBlock.ToolCall(call) =>
                if (message.role != LlmWireRole.Assistant) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_call_role_invalid", "tool calls must belong to assistant messages") }
                if (call.callId == "" || known.contains(call.callId)) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_call_duplicate", "tool call IDs must be non-empty and unique") }
                known.add(call.callId)
                pending.add(call.callId)
            case LlmWireBlock.ToolResult(result) =>
                if (message.role != LlmWireRole.User) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_result_role_invalid", "tool results must belong to user messages") }
                if (!pending.contains(result.callId)) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_result_unmatched", "tool result must match a prior unconsumed tool call") }
                pending.remove(result.callId)
            case _ => ()
        }
        }
        if (message.role == LlmWireRole.User && !pending.isEmpty()) {
            throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_results_incomplete", "one tool-result message must close every pending parallel tool call", phase: Some(LlmTransportPhase.Encode))
        }
    }
    if (!pending.isEmpty()) { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_call_unresolved", "every tool call must have exactly one later result") }
}
