package llm4cj

import std.collection.*
import std.convert.*
import yjson.*

func invalidWire(code: String, message: String, provider!: String = ""): Nothing {
    throw LlmWireError(LlmWireErrorKind.InvalidWire, code, message, provider: provider, phase: Some(LlmTransportPhase.WireDecode))
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
    if (request.model == "") { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.model_missing", "model must not be empty") }
    match (codec.modelProfile) {
        case Some(profile) =>
            if (request.model != profile.model) {
                throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.model_profile_mismatch", "request model must match the codec model profile")
            }
        case None => ()
    }
    match (request.maxOutputTokens) {
        case Some(value) =>
            if (value <= 0) {
                throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.max_output_tokens_invalid", "maxOutputTokens must be positive")
            }
        case None => ()
    }
    if (codec.dialect.contract.requireMaxOutputTokens && request.maxOutputTokens.isNone()) {
        throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.max_output_tokens_required", "this dialect requires maxOutputTokens")
    }
    for (instruction in request.instructions) {
        if (instruction.text.trimAscii() == "") { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.instruction_empty", "instruction text must not be empty") }
        if (codec.protocol == LlmWireProtocol.Messages && instruction.role == LlmWireInstructionRole.Developer) {
            unsupportedRequest("llm.developer_instruction_unsupported", "Messages does not represent developer instructions")
        }
    }
    match (codec.protocol) {
        case LlmWireProtocol.Responses =>
            if (request.messages.isEmpty() && request.instructions.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.responses_input_required", "Responses requires input messages or instructions") }
        case LlmWireProtocol.ChatCompletions =>
            if (request.messages.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.chat_messages_required", "Chat Completions requires at least one message") }
        case LlmWireProtocol.Messages =>
            if (request.messages.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.messages_required", "Messages requires at least one message") }
    }
    validateThinking(codec, request)
    validateRequestCombinations(codec, request)
    validateToolsAndSchemas(request)
    var usesTools = !request.tools.isEmpty()
    for (message in request.messages) { for (block in message.blocks) { match (block) { case LlmWireBlock.ToolCall(_) | LlmWireBlock.ToolResult(_) => usesTools = true; case _ => () } } }
    match (request.toolChoice) { case LlmWireToolChoice.ProviderDefault => (); case _ => usesTools = true }
    if (usesTools && (!codec.dialect.contract.tools || !codec.capabilities.tools.enabled)) { unsupportedRequest("llm.tools_unsupported", "tools require an explicit dialect and model capability") }
    if ((request.toolChoice == LlmWireToolChoice.Required || request.toolChoice == LlmWireToolChoice.Auto) && request.tools.isEmpty()) {
        throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_choice_without_tools", "toolChoice requires at least one declared tool")
    }
    validateStructuredOutput(codec, request.structuredOutput)
    match (request.parallelToolCalls) {
        case Some(_) =>
            if (request.tools.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.parallel_tools_without_tools", "parallel tool calls require declared tools") }
            if (codec.dialect.contract.parallelToolStyle == LlmWireParallelToolStyle.Unsupported || !codec.capabilities.tools.parallelCalls) { unsupportedRequest("llm.parallel_tools_unsupported", "parallel tool calls are not supported by this dialect and model") }
        case None => ()
    }
    validateServiceTier(codec, request.serviceTier)
    validateGenerationSpeed(codec, request.generationSpeed)
    validatePromptCache(codec, request.promptCache, request.promptCacheRoutingKey)
    for (messageIndex in 0..request.messages.size) {
        let message = request.messages[messageIndex]
        var deepSeekReasoningBlocks: Int64 = 0
        if (!messageHasContent(message)) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.message_empty", "canonical messages must contain at least one non-empty block")
        }
        for (blockIndex in 0..message.blocks.size) {
            validateBlockForReplay(codec, request, message, message.blocks[blockIndex], blockIndex)
            validateBlockShape(message.blocks[blockIndex])
            match (message.blocks[blockIndex]) {
                case LlmWireBlock.Image(value) => validateImageCapability(codec, message, value)
                case LlmWireBlock.NativeReplay(value) =>
                    if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.DeepSeekChat && value.nativeType == "reasoning_content") {
                        deepSeekReasoningBlocks++
                        if (deepSeekReasoningBlocks > 1) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.native_replay_cardinality_invalid", "DeepSeek Chat assistant turns may contain only one reasoning_content replay block") }
                    }
                case LlmWireBlock.ToolResult(value) =>
                    if (value.content.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_result_content_empty", "tool results require at least one content part") }
                    for (part in value.content) { match (part) {
                        case LlmWireToolResultContent.Text(text) => if (text.text == "") { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_result_content_empty", "tool-result text must not be empty") }
                        case LlmWireToolResultContent.Image(image) => validateBlockShape(LlmWireBlock.Image(image)); validateImageCapability(codec, message, image)
                    } }
                    if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.DeepSeekMessages && value.isError) {
                        unsupportedRequest("llm.tool_result_error_semantics_unsupported", "DeepSeek Messages does not preserve tool-result error semantics")
                    }
                case _ => ()
            }
        }
    }
    validateConversation(request.messages)
}

func validateRequestCombinations(codec: LlmWireCodec, request: LlmWireRequest): Unit {
    if (request.thinkingMode == LlmWireThinkingMode.Disabled && request.reasoningEffort != LlmWireReasoningEffort.ProviderDefault) {
        unsupportedRequest("llm.reasoning_effort_mode_unsupported", "disabled thinking cannot use a reasoning effort")
    }
    match (codec.dialect.contract.requestStyle) {
        case LlmWireRequestStyle.AnthropicMessages =>
            if (let LlmWireThinkingMode.Budget(_) <- request.thinkingMode) {
                if (request.toolChoice == LlmWireToolChoice.Required) {
                    unsupportedRequest("llm.thinking_tool_choice_unsupported", "manual Anthropic thinking supports only automatic or disabled tool choice")
                }
            }
            if (request.reasoningEffort != LlmWireReasoningEffort.ProviderDefault && request.thinkingMode != LlmWireThinkingMode.Adaptive) {
                unsupportedRequest("llm.reasoning_effort_mode_unsupported", "Anthropic reasoning effort requires adaptive thinking")
            }
        case LlmWireRequestStyle.DeepSeekChat =>
            match (request.thinkingMode) {
                case LlmWireThinkingMode.Enabled =>
                    if (request.toolChoice != LlmWireToolChoice.ProviderDefault) {
                        unsupportedRequest("llm.thinking_tool_choice_unsupported", "DeepSeek Chat thinking mode does not accept an explicit tool_choice")
                    }
                case _ => ()
            }
            if (request.reasoningEffort != LlmWireReasoningEffort.ProviderDefault && request.thinkingMode != LlmWireThinkingMode.Enabled) {
                unsupportedRequest("llm.reasoning_effort_mode_unsupported", "DeepSeek Chat reasoning effort requires enabled thinking")
            }
        case LlmWireRequestStyle.DeepSeekMessages =>
            if (request.reasoningEffort != LlmWireReasoningEffort.ProviderDefault && request.thinkingMode != LlmWireThinkingMode.Enabled) {
                unsupportedRequest("llm.reasoning_effort_mode_unsupported", "DeepSeek Messages reasoning effort requires enabled thinking")
            }
        case _ => ()
    }
}

func validateImageCapability(codec: LlmWireCodec, message: LlmWireMessage, value: LlmWireImageBlock): Unit {
    var supported = false
    for (modality in codec.capabilities.input.modalities where modality == LlmWireInputModality.Image) { supported = true }
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
    if (request.thinkingMode != LlmWireThinkingMode.ProviderDefault &&
        (!supportsThinkingMode(codec.dialect.contract.thinkingModes, request.thinkingMode) || !supportsThinkingMode(codec.capabilities.thinking.modes, request.thinkingMode))) {
        unsupportedRequest("llm.thinking_unsupported", "thinking mode is not supported by the supplied dialect and capabilities")
    }
    if (request.reasoningEffort != LlmWireReasoningEffort.ProviderDefault &&
        (!supportsReasoningEffort(codec.dialect.contract.reasoningEfforts, request.reasoningEffort) || !supportsReasoningEffort(codec.capabilities.thinking.efforts, request.reasoningEffort))) {
        unsupportedRequest("llm.reasoning_effort_unsupported", "reasoning effort is not supported by the supplied dialect and capabilities")
    }
    match (request.thinkingMode) {
        case LlmWireThinkingMode.Budget(tokens) =>
            if (tokens < 1024) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.thinking_budget_invalid", "thinking budget must be at least 1024 tokens") }
            match (request.maxOutputTokens) { case Some(maximum) => if (tokens >= maximum) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.thinking_budget_exceeds_output", "thinking budget must be smaller than maxOutputTokens") }; case None => () }
        case _ => ()
    }
    if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.AnthropicMessages && request.thinkingMode == LlmWireThinkingMode.Enabled) {
        unsupportedRequest("llm.thinking_not_representable", "Anthropic enabled thinking requires an explicit budget or adaptive mode")
    }
}

func supportsThinkingMode(values: Array<LlmWireThinkingMode>, target: LlmWireThinkingMode): Bool {
    for (value in values) {
        match ((value, target)) {
            case (LlmWireThinkingMode.ProviderDefault, LlmWireThinkingMode.ProviderDefault) |
                 (LlmWireThinkingMode.Disabled, LlmWireThinkingMode.Disabled) |
                 (LlmWireThinkingMode.Enabled, LlmWireThinkingMode.Enabled) |
                 (LlmWireThinkingMode.Budget(_), LlmWireThinkingMode.Budget(_)) |
                 (LlmWireThinkingMode.Adaptive, LlmWireThinkingMode.Adaptive) => return true
            case _ => ()
        }
    }
    false
}

func supportsReasoningEffort(values: Array<LlmWireReasoningEffort>, target: LlmWireReasoningEffort): Bool {
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
        case Some(mode) => if (!supportsStructuredMode(codec.dialect.contract.structuredOutputModes, mode) || !supportsStructuredMode(codec.capabilities.output.structuredModes, mode)) { unsupportedRequest("llm.structured_output_unsupported", "structured output mode is not supported by this dialect and model") }
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
    var capability = false; for (candidate in codec.capabilities.output.serviceTiers where candidate == value) { capability = true }
    if (!contract || !capability) { unsupportedRequest("llm.service_tier_unsupported", "service tier is not supported by this dialect and model") }
}

func validateGenerationSpeed(codec: LlmWireCodec, value: LlmWireGenerationSpeed): Unit {
    if (value == LlmWireGenerationSpeed.ProviderDefault) { return }
    var contract = false; for (candidate in codec.dialect.contract.generationSpeeds where candidate == value) { contract = true }
    var capability = false; for (candidate in codec.capabilities.output.generationSpeeds where candidate == value) { capability = true }
    if (!contract || !capability) { unsupportedRequest("llm.generation_speed_unsupported", "generation speed is not supported by this dialect and model") }
}

func validatePromptCache(codec: LlmWireCodec, value: LlmWirePromptCache, routingKey: ?String): Unit {
    match (routingKey) {
        case Some(key) => if (key == "") { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.prompt_cache_routing_key_invalid", "prompt cache routing key must not be empty") } else if (!codec.dialect.contract.promptCacheRoutingKey) { unsupportedRequest("llm.prompt_cache_routing_unsupported", "prompt cache routing is not supported by this dialect") }
        case None => ()
    }
    match (value) {
        case LlmWirePromptCache.ProviderDefault => ()
        case LlmWirePromptCache.Automatic(lifetime) =>
            if (codec.dialect.contract.promptCacheStyle == LlmWirePromptCacheStyle.Unsupported) { unsupportedRequest("llm.cache_unsupported", "automatic prompt caching is not supported") }
            var contract = false; for (candidate in codec.dialect.contract.promptCacheLifetimes where candidate == lifetime) { contract = true }
            var capability = false; for (candidate in codec.capabilities.cache.lifetimes where candidate == lifetime) { capability = true }
            if (!contract || !capability) { unsupportedRequest("llm.cache_lifetime_unsupported", "prompt cache lifetime is not supported") }
    }
}

func unsupportedRequest(code: String, message: String): Nothing {
    throw LlmWireError(LlmWireErrorKind.Unsupported, code, message, phase: Some(LlmTransportPhase.Encode))
}

func unsupportedWire(code: String, message: String, provider!: String = ""): Nothing {
    throw LlmWireError(LlmWireErrorKind.Unsupported, code, message, provider: provider, phase: Some(LlmTransportPhase.WireDecode))
}

func validateBlockForReplay(codec: LlmWireCodec, request: LlmWireRequest, message: LlmWireMessage, block: LlmWireBlock, blockIndex: Int64): Unit {
    match (block) {
        case LlmWireBlock.NativeReplay(value) =>
            if (message.role != LlmWireRole.Assistant) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.native_replay_role_invalid", "native replay state must remain in an assistant turn") }
            if (value.completion != LlmWireOpaqueCompletion.Complete) { unsupportedRequest("llm.native_replay_incomplete", "partial native state cannot be replayed") }
            if (value.protocol != codec.protocol || value.dialectId != codec.dialect.compatibilityId) { unsupportedRequest("llm.native_replay_dialect_mismatch", "native state can only be replayed by the same protocol and dialect compatibility ID") }
            match (value.modelConstraint) { case Some(model) => if (model != request.model) { unsupportedRequest("llm.native_replay_model_mismatch", "native state is constrained to another model") }; case None => () }
            if (value.scope == LlmWireNativeReplayScope.AssistantTurn && value.blockOrder != blockIndex) { unsupportedRequest("llm.native_replay_order_mismatch", "native state must retain its block order inside the assistant turn") }
        case LlmWireBlock.Opaque(_) => unsupportedRequest("llm.opaque_diagnostic_only", "unknown native diagnostics cannot be replayed")
        case LlmWireBlock.Reasoning(_) => unsupportedRequest("llm.reasoning_display_only", "display reasoning is not request-encodable")
        case LlmWireBlock.Refusal(_) => unsupportedRequest("llm.refusal_display_only", "refusal output is not request-encodable")
        case LlmWireBlock.ToolCall(value) =>
            if (!validToolName(value.name)) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_call_name_invalid", "tool call names must use the tool-name grammar") }
            match (value.arguments) {
            case LlmWireToolArguments.Complete(arguments) =>
                if (arguments.jsonNode().wireKind != WireJsonKind.Object) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_shape_invalid", "complete tool arguments must be a JSON object") }
            case LlmWireToolArguments.Partial(_) => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_partial", "partial tool arguments cannot be sent as an executable tool call")
            case _ => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_not_executable", "invalid tool arguments cannot be sent as an executable tool call")
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
        if (!validToolName(tool.name)) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_name_invalid", "tool names must be 1-64 ASCII letters, digits, underscore, or hyphen") }
        if (names.contains(tool.name)) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_name_duplicate", "tool names must be unique") }
        names.add(tool.name)
        if (tool.inputSchema.jsonNode().wireKind != WireJsonKind.Object) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_schema_invalid", "tool input schema must be a JSON object") }
    }
    match (request.structuredOutput) {
        case LlmWireStructuredOutput.JsonSchema(value) =>
            if (value.name == "" || value.schema.jsonNode().wireKind != WireJsonKind.Object) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.structured_schema_invalid", "structured output name and object schema are required") }
        case LlmWireStructuredOutput.JsonSchemaDocument(value) =>
            if (value.jsonNode().wireKind != WireJsonKind.Object) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.structured_schema_invalid", "structured output schema must be a JSON object") }
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
            case LlmWireImageSourceKind.Url => if (value.data.trimAscii() == "") { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.image_url_invalid", "image URL must not be empty") }
            case LlmWireImageSourceKind.Base64 => if (value.data == "" || value.mediaType == "" || !value.mediaType.contains("/")) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.image_base64_invalid", "base64 images require data and a media type") }
            case LlmWireImageSourceKind.File => if (value.data.trimAscii() == "") { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.image_file_invalid", "file images require a file ID") }
        }
        case _ => ()
    }
}

func validateConversation(messages: Array<LlmWireMessage>): Unit {
    let known = HashSet<String>()
    let pending = HashSet<String>()
    for (message in messages) {
        if (!pending.isEmpty()) {
            if (message.role != LlmWireRole.User) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_conversation_out_of_phase", "only tool results may follow unresolved tool calls", phase: Some(LlmTransportPhase.Encode)) }
            for (block in message.blocks) { match (block) {
                case LlmWireBlock.ToolResult(_) => ()
                case _ => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_conversation_out_of_phase", "ordinary content cannot appear while tool calls are unresolved", phase: Some(LlmTransportPhase.Encode))
            } }
        }
        for (block in message.blocks) {
        match (block) {
            case LlmWireBlock.ToolCall(call) =>
                if (message.role != LlmWireRole.Assistant) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_call_role_invalid", "tool calls must belong to assistant messages") }
                if (call.callId == "" || known.contains(call.callId)) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_call_duplicate", "tool call IDs must be non-empty and unique") }
                known.add(call.callId)
                pending.add(call.callId)
            case LlmWireBlock.ToolResult(result) =>
                if (message.role != LlmWireRole.User) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_result_role_invalid", "tool results must belong to user messages") }
                if (!pending.contains(result.callId)) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_result_unmatched", "tool result must match a prior unconsumed tool call") }
                pending.remove(result.callId)
            case _ => ()
        }
        }
        if (message.role == LlmWireRole.User && !pending.isEmpty()) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_results_incomplete", "one tool-result message must close every pending parallel tool call", phase: Some(LlmTransportPhase.Encode))
        }
    }
    if (!pending.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_call_unresolved", "every tool call must have exactly one later result") }
}
