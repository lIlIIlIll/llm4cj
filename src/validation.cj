package llm4cj

import std.convert.*
import yjson.*

func invalidWire(code: String, message: String, provider!: String = "", usage!: ?LlmWireUsage = None): Nothing {
    throw LlmWireError(LlmWireErrorKind.InvalidWire, code, message, provider: provider, phase: Some(LlmTransportPhase.WireDecode), usage: usage)
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
                try { Some(Int64.parse(found.numberText)) }
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

func validateWireRequest(codec: LlmWireCodec, request: LlmWireRequest, allowCachePrewarm!: Bool = false): ResolvedCachePlan {
    checkWireRequest(codec, request, RequestCheckSink(), allowCachePrewarm: allowCachePrewarm).getOrThrow()
}

func checkWireRequest(codec: LlmWireCodec, request: LlmWireRequest, checks: RequestCheckSink, allowCachePrewarm!: Bool = false): ?ResolvedCachePlan {
    if (codec.protocol == LlmWireProtocol.Responses) {
        checks.check("request.size", { => validateResponsesInputSize(request, codec.dialect.compatibilityId == "openai.codex.responses.v1") })
    }
    checks.check("request.model", { =>
        if (request.model == "") { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.model_missing", "model must not be empty") }
    })
    checks.check("request.model_profile", { => match (codec.modelProfile) {
        case Some(profile) => if (request.model != profile.model) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.model_profile_mismatch", "request model must match the codec model profile")
        }
        case None => ()
    } })
    checks.check("output.max_tokens", { => match (request.maxOutputTokens) {
        case Some(value) => if (value <= 0 && !(allowCachePrewarm && value == 0)) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.max_output_tokens_invalid", "maxOutputTokens must be positive")
        }
        case None => ()
    } })
    checks.check("output.max_tokens", { =>
        if (codec.dialect.contract.requireMaxOutputTokens && request.maxOutputTokens.isNone()) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.max_output_tokens_required", "this dialect requires maxOutputTokens")
        }
    })
    let view = checks.value("transcript.structure", { => replayTranscript(request.transcript, checks: checks) }, prerequisite: true)
    if (view.isSome()) {
        checks.check("context.position", { => validateTranscriptPositions(codec, request.transcript, checks: checks) }, prerequisite: true)
        validateTranscriptCapabilities(codec, request, checks: checks)
    }
    for (instruction in request.transcript.initialContext.instructions) {
        checks.check("input.instruction", { =>
            if (instruction.text.trimAscii() == "") { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.instruction_empty", "instruction text must not be empty") }
            if (codec.protocol == LlmWireProtocol.Messages && instruction.role == LlmWireInstructionRole.Developer) {
                checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.developer_instruction_unsupported", "Messages does not represent developer instructions"))
            }
        })
    }
    let items = request.transcript.items
    for (index in 0..items.size) { checks.charge(); match (items[index]) {
        case LlmWireInputItem.InstructionUpdate(instruction) => checks.check("input.instruction", { =>
            if (instruction.text.trimAscii() == "") { throw transcriptError("llm.instruction_empty", "instruction updates must not be empty", index) }
        }, itemIndex: index)
        case _ => ()
    } }
    checks.check("input.messages", { => match (codec.protocol) {
        case LlmWireProtocol.Responses =>
            if (items.isEmpty() && request.transcript.initialContext.instructions.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.responses_input_required", "Responses requires input items or instructions") }
        case LlmWireProtocol.ChatCompletions | LlmWireProtocol.Messages => match (view) {
            case Some(value) => if (value.messages.isEmpty()) {
                let code = if (codec.protocol == LlmWireProtocol.Messages) { "llm.messages_required" } else { "llm.chat_messages_required" }
                throw LlmWireError(LlmWireErrorKind.InvalidRequest, code, "the protocol requires messages")
            }
            case None => ()
        }
    } })
    checks.check("thinking", { => validateThinking(codec, request, checks: checks) })
    checks.check("request.combination", { => validateRequestCombinations(codec, request, checks: checks) })
    match (request.structuredOutput) {
        case LlmWireStructuredOutput.JsonSchema(value) =>
            checks.charge(bytes: value.name.size); checks.charge(bytes: value.description.size); value.schema.chargeInspection(checks)
        case LlmWireStructuredOutput.JsonSchemaDocument(value) => value.chargeInspection(checks)
        case _ => ()
    }
    checks.check("structured_output.schema", { => validateStructuredSchema(request) })
    match (view) {
        case Some(value) =>
            var usesTools = !value.declaredTools.isEmpty()
            for (message in value.messages) { for (block in message.blocks) { checks.charge(); match (block) {
                case LlmWireBlock.ToolCall(_) | LlmWireBlock.ToolResult(_) => usesTools = true
                case _ => ()
            } } }
            match (request.toolChoice) { case LlmWireToolChoice.ProviderDefault => (); case _ => usesTools = true }
            let toolCapabilityRequired = usesTools
            checks.check("tools", { =>
                if (toolCapabilityRequired && (!codec.dialect.contract.tools || !codec.capabilities.tools.enabled)) { unsupportedRequest("llm.tools_unsupported", "tools require an explicit dialect and model capability") }
            })
        case None => ()
    }
    validateCustomToolRequestChecks(codec, request, checks)
    checks.check("tools.choice", { => match (view) {
        case Some(value) => if ((request.toolChoice == LlmWireToolChoice.Required || request.toolChoice == LlmWireToolChoice.Auto) && value.activeTools.isEmpty()) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_choice_without_tools", "toolChoice requires active tools")
        }
        case None => ()
    } })
    checks.check("structured_output", { => validateStructuredOutput(codec, request.structuredOutput, checks: checks) })
    match (request.parallelToolCalls) {
        case Some(_) =>
            checks.check("tools.parallel", { => match (view) {
                case Some(value) => if (value.activeTools.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.parallel_tools_without_tools", "parallel tool calls require active tools") }
                case None => ()
            } })
            checks.check("tools.parallel", { =>
                if (codec.dialect.contract.parallelToolStyle == LlmWireParallelToolStyle.Unsupported || !codec.capabilities.tools.parallelCalls) { unsupportedRequest("llm.parallel_tools_unsupported", "parallel tool calls are not supported") }
            })
        case None => ()
    }
    checks.check("service_tier", { => validateServiceTier(codec, request.serviceTier) })
    checks.check("generation_speed", { => validateGenerationSpeed(codec, request.generationSpeed) })
    match (request.promptCacheRoutingKey) { case Some(value) => checks.charge(bytes: value.size); case None => () }
    checks.check("cache", { => validatePromptCache(codec, request.promptCache, request.promptCacheRoutingKey, checks: checks) })
    validateAudioRequest(codec, request, false, anyOutputMode: true, checks: checks)
    for (index in 0..items.size) { checks.charge(); match (items[index]) {
        case LlmWireInputItem.Message(message) =>
            try { validateMessageRequestChecks(codec, request, message, index, checks) }
            catch (error: LlmWireError) { throw withInputItemContext(error, index) }
        case _ => ()
    } }
    checkCachePlan(codec, request, checks, replayValid: view.isSome())
}

func validateMessageRequestChecks(codec: LlmWireCodec, request: LlmWireRequest, message: LlmWireMessage, itemIndex: Int64, checks: RequestCheckSink): Unit {
    validateMessagePhaseMetadata(codec, message, checks: checks, itemIndex: itemIndex)
    checks.check("input.message", { => if (!messageHasContent(message)) {
        throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.message_empty", "canonical messages require content")
    } }, itemIndex: itemIndex)
    var reasoningBlocks: Int64 = 0
    for (index in 0..message.blocks.size) {
        checks.charge()
        let block = message.blocks[index]
        checks.check("input.replay", { => validateBlockForReplay(codec, request, message, block, index, checks: checks) }, itemIndex: itemIndex, blockIndex: index)
        checks.check("input.shape", { => validateBlockShape(block, checks: checks) }, itemIndex: itemIndex, blockIndex: index)
        match (block) {
            case LlmWireBlock.Image(value) => checks.check("input.image", { => validateImageCapability(codec, message, value, checks: checks) }, itemIndex: itemIndex, blockIndex: index)
            case LlmWireBlock.NativeReplay(value) =>
                if (chatHasReplayReasoning(codec) && value.nativeType == "reasoning_content") {
                    reasoningBlocks++
                    let duplicateReasoning = reasoningBlocks > 1
                    checks.check("input.replay", { => if (duplicateReasoning) {
                        throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.native_replay_cardinality_invalid", "Chat permits one reasoning_content replay block")
                    } }, itemIndex: itemIndex, blockIndex: index)
                }
            case LlmWireBlock.ToolResult(value) =>
                checks.check("tools.result", { => if (value.kind == LlmWireToolKind.Function && value.content.isEmpty()) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_result_content_empty", "tool results require content") } }, itemIndex: itemIndex, blockIndex: index)
                for (part in value.content) { checks.charge(); match (part) {
                    case LlmWireToolResultContent.Text(text) =>
                        checks.check("tools.result", { => if (value.kind == LlmWireToolKind.Function && text.text == "") { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_result_content_empty", "tool-result text must not be empty") } }, itemIndex: itemIndex, blockIndex: index)
                        checks.check("tools.result_metadata", { => if (value.kind == LlmWireToolKind.Custom && (text.phase != LlmWireOutputPhase.Unspecified || !text.citations.isEmpty() || !text.annotations.isEmpty() || !text.logprobs.isEmpty())) {
                            unsupportedRequest("llm.custom_tool_result_metadata_unsupported", "custom tool result input_text cannot replay output metadata")
                        } }, itemIndex: itemIndex, blockIndex: index)
                    case LlmWireToolResultContent.Image(image) =>
                        checks.check("input.shape", { => validateBlockShape(LlmWireBlock.Image(image), checks: checks) }, itemIndex: itemIndex, blockIndex: index)
                        checks.check("input.image", { => validateImageCapability(codec, message, image, checks: checks) }, itemIndex: itemIndex, blockIndex: index)
                } }
                checks.check("tools.result", { => if (codec.dialect.contract.toolErrorStyle == LlmWireToolErrorStyle.Unsupported && value.isError) { unsupportedRequest("llm.tool_result_error_semantics_unsupported", "this dialect does not declare tool-result error semantics") } }, itemIndex: itemIndex, blockIndex: index)
            case _ => ()
        }
    }
}

func validateMessagePhaseMetadata(codec: LlmWireCodec, message: LlmWireMessage, checks!: RequestCheckSink = RequestCheckSink(), itemIndex!: Int64 = -1): Unit {
    let spans = message.messageSpans
    let layoutValid = checks.check("input.phase_layout", { =>
        validateMessageSpanLayout(spans, message.blocks.size, { index => isResponsesMessageContent(message.blocks[index]) })
    }, itemIndex: itemIndex, prerequisite: true)
    if (!spans.isEmpty()) {
        checks.check("input.phase_role", { => if (message.role != LlmWireRole.Assistant) { unsupportedRequest("llm.responses_phase_role_unsupported", "assistant message spans require assistant messages") } }, itemIndex: itemIndex)
        checks.check("input.phase_protocol", { => if (codec.protocol != LlmWireProtocol.Responses) { unsupportedRequest("llm.responses_phase_unsupported", "this protocol cannot represent Responses message boundaries") } }, itemIndex: itemIndex)
        if (layoutValid) { for (span in spans) { checks.charge()
            checks.check("input.phase", { => let _ = outputPhaseName(span.phase) }, itemIndex: itemIndex, blockIndex: span.blockStart)
            for (index in span.blockStart..span.blockStart + span.blockCount) { checks.charge(); match (message.blocks[index]) {
                case LlmWireBlock.Text(value) => checks.check("input.phase", { =>
                    if (value.phase != LlmWireOutputPhase.Unspecified && value.phase != span.phase) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.responses_phase_mismatch", "text phase conflicts with its message span") }
                }, itemIndex: itemIndex, blockIndex: index)
                case _ => ()
            } }
        } }
    }
    for (index in 0..message.blocks.size) { checks.charge(); match (message.blocks[index]) {
        case LlmWireBlock.Text(value) => if (value.phase != LlmWireOutputPhase.Unspecified) {
            checks.check("input.phase_role", { => if (message.role != LlmWireRole.Assistant) {
                unsupportedRequest(if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.OpenAiCodexResponses) { "llm.codex_phase_role_unsupported" } else { "llm.responses_phase_role_unsupported" }, "phase belongs to assistant messages")
            } }, itemIndex: itemIndex, blockIndex: index)
            checks.check("input.phase_protocol", { => if (codec.protocol != LlmWireProtocol.Responses) { unsupportedRequest("llm.responses_phase_unsupported", "this protocol cannot represent assistant message phase") } }, itemIndex: itemIndex, blockIndex: index)
            checks.check("input.phase", { => let _ = outputPhaseName(value.phase) }, itemIndex: itemIndex, blockIndex: index)
        }
        case _ => ()
    } }
}

func validateRequestCombinations(codec: LlmWireCodec, request: LlmWireRequest, checks!: RequestCheckSink = RequestCheckSink()): Unit {
    if (request.thinkingMode == LlmWireThinkingMode.Disabled && request.reasoningEffort != LlmWireReasoningEffort.ProviderDefault) {
        checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.reasoning_effort_mode_unsupported", "disabled thinking cannot use a reasoning effort"))
    }
    match (codec.dialect.contract.requestStyle) {
        case LlmWireRequestStyle.AnthropicMessages =>
            if (let LlmWireThinkingMode.Budget(_) <- request.thinkingMode) {
                if (request.toolChoice == LlmWireToolChoice.Required) {
                    checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.thinking_tool_choice_unsupported", "manual Anthropic thinking supports only automatic or disabled tool choice"))
                }
            }
            if (request.reasoningEffort != LlmWireReasoningEffort.ProviderDefault && request.thinkingMode != LlmWireThinkingMode.Adaptive) {
                checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.reasoning_effort_mode_unsupported", "Anthropic reasoning effort requires adaptive thinking"))
            }
        case LlmWireRequestStyle.DeepSeekChat =>
            match (request.thinkingMode) {
                case LlmWireThinkingMode.Enabled =>
                    if (request.toolChoice != LlmWireToolChoice.ProviderDefault) {
                        checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.thinking_tool_choice_unsupported", "DeepSeek Chat thinking mode does not accept an explicit tool_choice"))
                    }
                case _ => ()
            }
            if (request.reasoningEffort != LlmWireReasoningEffort.ProviderDefault && request.thinkingMode != LlmWireThinkingMode.Enabled) {
                checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.reasoning_effort_mode_unsupported", "DeepSeek Chat reasoning effort requires enabled thinking"))
            }
        case LlmWireRequestStyle.DeepSeekMessages =>
            if (request.reasoningEffort != LlmWireReasoningEffort.ProviderDefault && request.thinkingMode != LlmWireThinkingMode.Enabled) {
                checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.reasoning_effort_mode_unsupported", "DeepSeek Messages reasoning effort requires enabled thinking"))
            }
        case _ => ()
    }
}

func validateImageCapability(codec: LlmWireCodec, message: LlmWireMessage, value: LlmWireImageBlock, checks!: RequestCheckSink = RequestCheckSink()): Unit {
    var supported = false
    for (modality in codec.capabilities.input.modalities where modality == LlmWireInputModality.Image) { supported = true }
    if (!supported) { checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.image_input_unsupported", "image input requires an explicit model capability")) }
    let deepSeek = match (codec.dialect.contract.requestStyle) {
        case LlmWireRequestStyle.DeepSeekResponses | LlmWireRequestStyle.DeepSeekChat | LlmWireRequestStyle.DeepSeekMessages => true
        case _ => false
    }
    if (deepSeek && message.role != LlmWireRole.User) { checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.image_role_unsupported", "DeepSeek image input is supported only in user messages")) }
    if (deepSeek) { match (value.sourceKind) {
        case LlmWireImageSourceKind.Base64 =>
            if (!supportedDeepSeekImageMediaType(value.mediaType)) { checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.image_media_type_unsupported", "DeepSeek image input supports JPEG, PNG, GIF, and WebP")) }
        case _ => ()
    } }
}

func supportedDeepSeekImageMediaType(value: String): Bool {
    value == "image/jpeg" || value == "image/png" || value == "image/gif" || value == "image/webp"
}

func validateThinking(codec: LlmWireCodec, request: LlmWireRequest, checks!: RequestCheckSink = RequestCheckSink()): Unit {
    if (request.thinkingMode != LlmWireThinkingMode.ProviderDefault &&
        (!supportsThinkingMode(codec.dialect.contract.thinkingModes, request.thinkingMode) || !supportsThinkingMode(codec.capabilities.thinking.modes, request.thinkingMode))) {
        checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.thinking_unsupported", "thinking mode is not supported by the supplied dialect and capabilities"))
    }
    if (request.reasoningEffort != LlmWireReasoningEffort.ProviderDefault &&
        (!supportsReasoningEffort(codec.dialect.contract.reasoningEfforts, request.reasoningEffort) || !supportsReasoningEffort(codec.capabilities.thinking.efforts, request.reasoningEffort))) {
        checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.reasoning_effort_unsupported", "reasoning effort is not supported by the supplied dialect and capabilities"))
    }
    match (request.thinkingMode) {
        case LlmWireThinkingMode.Budget(tokens) =>
            if (tokens < 1024) { checks.reject(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.thinking_budget_invalid", "thinking budget must be at least 1024 tokens")) }
            match (request.maxOutputTokens) { case Some(maximum) => if (tokens >= maximum) { checks.reject(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.thinking_budget_exceeds_output", "thinking budget must be smaller than maxOutputTokens")) }; case None => () }
        case _ => ()
    }
    if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.AnthropicMessages && request.thinkingMode == LlmWireThinkingMode.Enabled) {
        checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.thinking_not_representable", "Anthropic enabled thinking requires an explicit budget or adaptive mode"))
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

func validateStructuredOutput(codec: LlmWireCodec, value: LlmWireStructuredOutput, checks!: RequestCheckSink = RequestCheckSink()): Unit {
    match (structuredMode(value)) {
        case None => ()
        case Some(mode) => if (!supportsStructuredMode(codec.dialect.contract.structuredOutputModes, mode) || !supportsStructuredMode(codec.capabilities.output.structuredModes, mode)) { checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.structured_output_unsupported", "structured output mode is not supported by this dialect and model")) }
    }
    match ((codec.dialect.contract.requestStyle, value)) {
        case (LlmWireRequestStyle.AnthropicMessages, LlmWireStructuredOutput.JsonSchema(_)) => checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.structured_output_metadata_unsupported", "Anthropic output_config.format cannot represent OpenAI schema name, description, or strict metadata"))
        case (LlmWireRequestStyle.AnthropicMessages, LlmWireStructuredOutput.JsonSchemaDocument(_)) => ()
        case (_, LlmWireStructuredOutput.JsonSchemaDocument(_)) => checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.structured_output_document_unsupported", "this dialect requires a named JSON schema specification"))
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

func validatePromptCache(codec: LlmWireCodec, value: LlmWirePromptCache, routingKey: ?String, checks!: RequestCheckSink = RequestCheckSink()): Unit {
    match (routingKey) {
        case Some(key) => if (key == "") { checks.reject(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.prompt_cache_routing_key_invalid", "prompt cache routing key must not be empty")) } else if (!codec.dialect.contract.promptCacheRoutingKey) { checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.prompt_cache_routing_unsupported", "prompt cache routing is not supported by this dialect")) }
        case None => ()
    }
    match (value) {
        case LlmWirePromptCache.ProviderDefault => ()
        case LlmWirePromptCache.Automatic(lifetime) =>
            if (codec.dialect.contract.promptCacheStyle == LlmWirePromptCacheStyle.Unsupported) { checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.cache_unsupported", "automatic prompt caching is not supported")) }
            if (!cacheLifetimeSupported(codec, lifetime)) { checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.cache_lifetime_unsupported", "prompt cache lifetime is not supported")) }
    }
}

func cacheLifetimeSupported(codec: LlmWireCodec, lifetime: LlmWirePromptCacheLifetime): Bool {
    var contract = false; for (candidate in codec.dialect.contract.promptCacheLifetimes where candidate == lifetime) { contract = true }
    var capability = false; for (candidate in codec.capabilities.cache.lifetimes where candidate == lifetime) { capability = true }
    contract && capability
}

func unsupportedRequest(code: String, message: String): Nothing {
    throw LlmWireError(LlmWireErrorKind.Unsupported, code, message, phase: Some(LlmTransportPhase.Encode))
}

func unsupportedWire(code: String, message: String, provider!: String = ""): Nothing {
    throw LlmWireError(LlmWireErrorKind.Unsupported, code, message, provider: provider, phase: Some(LlmTransportPhase.WireDecode))
}

func validateBlockForReplay(codec: LlmWireCodec, request: LlmWireRequest, message: LlmWireMessage, block: LlmWireBlock, blockIndex: Int64, checks!: RequestCheckSink = RequestCheckSink()): Unit {
    match (block) {
        case LlmWireBlock.NativeReplay(value) =>
            if (message.role != LlmWireRole.Assistant) { checks.reject(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.native_replay_role_invalid", "native replay state must remain in an assistant turn")) }
            if (value.completion != LlmWireOpaqueCompletion.Complete) { checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.native_replay_incomplete", "partial native state cannot be replayed")) }
            if (value.protocol != codec.protocol || value.dialectId != codec.dialect.compatibilityId) { checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.native_replay_dialect_mismatch", "native state can only be replayed by the same protocol and dialect compatibility ID")) }
            match (value.modelConstraint) { case Some(model) => if (model != request.model) { checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.native_replay_model_mismatch", "native state is constrained to another model")) }; case None => () }
            if (value.scope == LlmWireNativeReplayScope.AssistantTurn && value.blockOrder != blockIndex) { checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.native_replay_order_mismatch", "native state must retain its block order inside the assistant turn")) }
        case LlmWireBlock.Opaque(_) => checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.opaque_diagnostic_only", "unknown native diagnostics cannot be replayed"))
        case LlmWireBlock.Reasoning(_) => checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.reasoning_display_only", "display reasoning is not request-encodable"))
        case LlmWireBlock.Refusal(_) => checks.reject(LlmWireError(LlmWireErrorKind.Unsupported, "llm.refusal_display_only", "refusal output is not request-encodable"))
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

func validateStructuredSchema(request: LlmWireRequest): Unit {
    match (request.structuredOutput) {
        case LlmWireStructuredOutput.JsonSchema(value) =>
            if (value.name == "" || value.schema.jsonNode().wireKind != WireJsonKind.Object) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.structured_schema_invalid", "structured output name and object schema are required") }
        case LlmWireStructuredOutput.JsonSchemaDocument(value) =>
            if (value.jsonNode().wireKind != WireJsonKind.Object) { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.structured_schema_invalid", "structured output schema must be a JSON object") }
        case _ => ()
    }
}

func validToolName(value: String): Bool {
    if (value.size == 0 || value.size > 64) { return false }
    let bytes = value.toArray()
    for (byte in bytes) {
        let allowed = (byte >= 65u8 && byte <= 90u8) || (byte >= 97u8 && byte <= 122u8) || (byte >= 48u8 && byte <= 57u8) || byte == 95u8 || byte == 45u8
        if (!allowed) { return false }
    }
    true
}

func validateBlockShape(block: LlmWireBlock, checks!: RequestCheckSink = RequestCheckSink()): Unit {
    match (block) {
        case LlmWireBlock.ToolCall(value) =>
            if (!validToolName(value.name)) { checks.reject(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_call_name_invalid", "tool call names must use the tool-name grammar", toolName: value.name, toolCallId: boundedTranscriptEvidence(value.callId))) }
            match (value.arguments) {
                case LlmWireToolArguments.Complete(arguments) =>
                    if (arguments.jsonNode().wireKind != WireJsonKind.Object) { checks.reject(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_shape_invalid", "complete tool arguments must be a JSON object", toolName: value.name, toolCallId: boundedTranscriptEvidence(value.callId))) }
                case LlmWireToolArguments.Text(_) => ()
                case LlmWireToolArguments.Partial(_) | LlmWireToolArguments.PartialText(_) => checks.reject(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_partial", "partial tool arguments cannot be sent as an executable tool call", toolName: value.name, toolCallId: boundedTranscriptEvidence(value.callId)))
                case LlmWireToolArguments.InvalidShape(_) => checks.reject(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_shape_invalid", "invalid-shape tool arguments cannot be sent as an executable tool call", toolName: value.name, toolCallId: boundedTranscriptEvidence(value.callId)))
                case _ => checks.reject(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_not_executable", "invalid tool arguments cannot be sent as an executable tool call", toolName: value.name, toolCallId: boundedTranscriptEvidence(value.callId)))
            }
        case LlmWireBlock.Image(value) => match (value.sourceKind) {
            case LlmWireImageSourceKind.Url => if (value.data.trimAscii() == "") { checks.reject(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.image_url_invalid", "image URL must not be empty")) }
            case LlmWireImageSourceKind.Base64 => if (value.data == "" || value.mediaType == "" || !value.mediaType.contains("/")) { checks.reject(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.image_base64_invalid", "base64 images require data and a media type")) }
            case LlmWireImageSourceKind.File => if (value.data.trimAscii() == "") { checks.reject(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.image_file_invalid", "file images require a file ID")) }
        }
        case _ => ()
    }
}
