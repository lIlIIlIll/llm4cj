package llm4cj

import std.collection.*
import yjson.*

func encodeWireRequest(codec: LlmWireCodec, request: LlmWireRequest): LlmWireEncodedRequest {
    let headers = ArrayList<LlmWireHeader>()
    let requirements = ArrayList<LlmWireFeatureRequirement>()
    let body = match (codec.protocol) {
        case LlmWireProtocol.Responses => encodeResponsesRequest(codec, request, requirements)
        case LlmWireProtocol.ChatCompletions => encodeChatRequest(codec, request, requirements)
        case LlmWireProtocol.Messages => encodeMessagesRequest(codec, request, headers, requirements)
    }
    LlmWireEncodedRequest(body, requiredHeaders: headers.toArray(), featureRequirements: requirements.toArray())
}

func outputTokenName(value: LlmWireOutputTokenField): String {
    match (value) {
        case LlmWireOutputTokenField.MaxOutputTokens => "max_output_tokens"
        case LlmWireOutputTokenField.MaxCompletionTokens => "max_completion_tokens"
        case LlmWireOutputTokenField.MaxTokens => "max_tokens"
    }
}

func baseRequest(codec: LlmWireCodec, request: LlmWireRequest): JsonNode {
    let root = wireJsonObject([WireJsonField("model", wireJsonString(request.model))])
    match (request.maxOutputTokens) { case Some(value) => root.put(outputTokenName(codec.dialect.contract.outputTokenField), wireJsonNumber(value.toString())); case None => () }
    match (request.streaming) { case Some(value) => root.put("stream", wireJsonBool(value)); case None => () }
    root
}

func addDialectOptions(codec: LlmWireCodec, root: JsonNode, request: LlmWireRequest, requirements: ArrayList<LlmWireFeatureRequirement>): Unit {
    encodeThinking(codec, root, request.thinking)
    match ((codec.dialect.contract.parallelToolStyle, request.parallelToolCalls)) {
        case (LlmWireParallelToolStyle.OpenAiTopLevel, Some(value)) => root.put("parallel_tool_calls", wireJsonBool(value))
        case _ => ()
    }
    if (request.serviceTier != LlmWireServiceTier.ProviderDefault) { root.put("service_tier", wireJsonString(serviceTierName(request.serviceTier))) }
    match (request.toolChoice) {
        case LlmWireToolChoice.ProviderDefault => ()
        case LlmWireToolChoice.Auto => root.put("tool_choice", wireJsonString("auto"))
        case LlmWireToolChoice.NoTools => root.put("tool_choice", wireJsonString("none"))
        case LlmWireToolChoice.Required => root.put("tool_choice", wireJsonString("required"))
    }
    match (request.promptCacheRoutingKey) { case Some(value) => root.put("prompt_cache_key", wireJsonString(value)); case None => () }
    encodePromptCache(codec, root, request.promptCache, requirements)
}

func encodeResponsesRequest(codec: LlmWireCodec, request: LlmWireRequest, requirements: ArrayList<LlmWireFeatureRequirement>): String {
    let root = baseRequest(codec, request); addDialectOptions(codec, root, request, requirements)
    if (request.system != "") { root.put("instructions", wireJsonString(request.system)) }
    match (request.structuredOutput) {
        case LlmWireStructuredOutput.Text => root.put("text", wireJsonObject([WireJsonField("format", wireJsonObject([WireJsonField("type", wireJsonString("text"))]))]))
        case LlmWireStructuredOutput.JsonObject => root.put("text", wireJsonObject([WireJsonField("format", wireJsonObject([WireJsonField("type", wireJsonString("json_object"))]))]))
        case LlmWireStructuredOutput.JsonSchema(spec) => root.put("text", wireJsonObject([WireJsonField("format", encodeResponsesJsonSchemaFormat(spec))]))
        case _ => ()
    }
    let input = wireJsonArray([])
    for (message in request.messages) {
        var content = wireJsonArray([])
        for (block in message.blocks) { match (block) {
            case LlmWireBlock.Text(_) | LlmWireBlock.Image(_) => content.add(encodeResponsesContent(block))
            case LlmWireBlock.ToolCall(call) =>
                flushResponsesMessage(input, message.role, content); content = wireJsonArray([])
                input.add(wireJsonObject([WireJsonField("type", wireJsonString("function_call")), WireJsonField("call_id", wireJsonString(call.callId)), WireJsonField("name", wireJsonString(call.name)), WireJsonField("arguments", wireJsonString(toolArgumentsRaw(call.arguments)))]))
            case LlmWireBlock.ToolResult(result) =>
                flushResponsesMessage(input, message.role, content); content = wireJsonArray([])
                input.add(wireJsonObject([WireJsonField("type", wireJsonString("function_call_output")), WireJsonField("call_id", wireJsonString(result.callId)), WireJsonField("output", wireJsonString(result.content))]))
            case LlmWireBlock.NativeReplay(value) =>
                flushResponsesMessage(input, message.role, content); content = wireJsonArray([])
                input.add(value.payload())
            case LlmWireBlock.Reasoning(_) | LlmWireBlock.Refusal(_) | LlmWireBlock.Opaque(_) => unsupportedRequest("llm.responses_block_unsupported", "display and diagnostic blocks cannot be encoded as request input")
        } }
        flushResponsesMessage(input, message.role, content)
    }
    root.put("input", input); addResponsesTools(root, request.tools); root.stringify()
}

func encodeChatRequest(codec: LlmWireCodec, request: LlmWireRequest, requirements: ArrayList<LlmWireFeatureRequirement>): String {
    let root = baseRequest(codec, request); addDialectOptions(codec, root, request, requirements)
    match (request.structuredOutput) {
        case LlmWireStructuredOutput.Text => root.put("response_format", wireJsonObject([WireJsonField("type", wireJsonString("text"))]))
        case LlmWireStructuredOutput.JsonObject => root.put("response_format", wireJsonObject([WireJsonField("type", wireJsonString("json_object"))]))
        case LlmWireStructuredOutput.JsonSchema(spec) => root.put("response_format", wireJsonObject([WireJsonField("type", wireJsonString("json_schema")), WireJsonField("json_schema", encodeChatJsonSchemaSpec(spec))]))
        case _ => ()
    }
    let messages = wireJsonArray([])
    if (request.system != "") { messages.add(wireJsonObject([WireJsonField("role", wireJsonString("system")), WireJsonField("content", wireJsonString(request.system))])) }
    for (message in request.messages) {
        let content = StringBuilder()
        let calls = wireJsonArray([])
        var reasoningContent: ?String = None
        for (block in message.blocks) { match (block) {
            case LlmWireBlock.Text(value) => content.append(value.text)
            case LlmWireBlock.ToolResult(result) => messages.add(wireJsonObject([WireJsonField("role", wireJsonString("tool")), WireJsonField("tool_call_id", wireJsonString(result.callId)), WireJsonField("content", wireJsonString(result.content))]))
            case LlmWireBlock.ToolCall(call) => calls.add(wireJsonObject([WireJsonField("id", wireJsonString(call.callId)), WireJsonField("type", wireJsonString("function")), WireJsonField("function", wireJsonObject([WireJsonField("name", wireJsonString(call.name)), WireJsonField("arguments", wireJsonString(toolArgumentsRaw(call.arguments)))]))]))
            case LlmWireBlock.NativeReplay(value) =>
                if (codec.dialect.contract.requestStyle != LlmWireRequestStyle.DeepSeekChat || value.nativeType != "reasoning_content") { unsupportedRequest("llm.chat_opaque_unsupported", "Chat Completions cannot replay this native block") }
                reasoningContent = Some(wireRequiredString(value.payload(), "reasoning_content", provider: codec.provider))
            case LlmWireBlock.Opaque(_) => unsupportedRequest("llm.chat_opaque_unsupported", "Chat Completions cannot replay diagnostic blocks")
            case LlmWireBlock.Reasoning(_) | LlmWireBlock.Refusal(_) => unsupportedRequest("llm.chat_block_unsupported", "display-only blocks cannot be encoded as request input")
            case LlmWireBlock.Image(_) => unsupportedRequest("llm.chat_image_unsupported", "Chat image encoding requires a multipart content block")
        } }
        let text = content.toString()
        if (text != "" || !calls.items.isEmpty() || reasoningContent.isSome()) {
            let encoded = wireJsonObject([WireJsonField("role", wireJsonString(roleName(message.role))), WireJsonField("content", wireJsonString(text))])
            match (reasoningContent) { case Some(value) => encoded.put("reasoning_content", wireJsonString(value)); case None => () }
            if (!calls.items.isEmpty()) { encoded.put("tool_calls", calls) }
            messages.add(encoded)
        }
    }
    root.put("messages", messages); addChatTools(root, request.tools); root.stringify()
}

func encodeMessagesRequest(codec: LlmWireCodec, request: LlmWireRequest, headers: ArrayList<LlmWireHeader>, requirements: ArrayList<LlmWireFeatureRequirement>): String {
    let root = baseRequest(codec, request); encodeThinking(codec, root, request.thinking)
    if (request.system != "") { root.put("system", wireJsonString(request.system)) }
    if (request.serviceTier != LlmWireServiceTier.ProviderDefault) { root.put("service_tier", wireJsonString(serviceTierName(request.serviceTier))) }
    if (request.generationSpeed != LlmWireGenerationSpeed.ProviderDefault) {
        root.put("speed", wireJsonString(generationSpeedName(request.generationSpeed)))
        if (request.generationSpeed == LlmWireGenerationSpeed.Fast) {
            headers.add(LlmWireHeader("anthropic-beta", "fast-mode-2026-02-01"))
            requirements.add(LlmWireFeatureRequirement("anthropic.fast_mode", LlmWireRequirementState.Unknown("fast mode requires a supported model, platform, and account")))
        }
    }
    var toolChoice: ?JsonNode = match (request.toolChoice) {
        case LlmWireToolChoice.ProviderDefault => None
        case LlmWireToolChoice.Auto => Some(wireJsonObject([WireJsonField("type", wireJsonString("auto"))]))
        case LlmWireToolChoice.NoTools => Some(wireJsonObject([WireJsonField("type", wireJsonString("none"))]))
        case LlmWireToolChoice.Required => Some(wireJsonObject([WireJsonField("type", wireJsonString("any"))]))
    }
    match (request.parallelToolCalls) {
        case Some(value) =>
            let choice = match (toolChoice) { case Some(found) => found; case None => wireJsonObject([WireJsonField("type", wireJsonString("auto"))]) }
            choice.put("disable_parallel_tool_use", wireJsonBool(!value)); toolChoice = Some(choice)
        case None => ()
    }
    match (toolChoice) { case Some(value) => root.put("tool_choice", value); case None => () }
    match (request.structuredOutput) {
        case LlmWireStructuredOutput.JsonSchemaDocument(schema) =>
            let existing = match (root.field("output_config")) { case Some(value) => value; case None => wireJsonObject([]) }
            existing.put("format", wireJsonObject([WireJsonField("type", wireJsonString("json_schema")), WireJsonField("schema", schema)])); root.put("output_config", existing)
        case _ => ()
    }
    encodePromptCache(codec, root, request.promptCache, requirements)
    let messages = wireJsonArray([])
    for (message in request.messages) { let content = wireJsonArray([]); for (block in message.blocks) { content.add(encodeMessagesContent(block)) }; messages.add(wireJsonObject([WireJsonField("role", wireJsonString(roleName(message.role))), WireJsonField("content", content)])) }
    root.put("messages", messages)
    if (!request.tools.isEmpty()) { let tools = wireJsonArray([]); for (tool in request.tools) { tools.add(wireJsonObject([WireJsonField("name", wireJsonString(tool.name)), WireJsonField("description", wireJsonString(tool.description)), WireJsonField("input_schema", tool.inputSchema)])) }; root.put("tools", tools) }
    root.stringify()
}

func encodeResponsesJsonSchemaFormat(spec: LlmWireJsonSchema): JsonNode {
    let value = wireJsonObject([WireJsonField("type", wireJsonString("json_schema")), WireJsonField("name", wireJsonString(spec.name)), WireJsonField("schema", spec.schema), WireJsonField("strict", wireJsonBool(spec.strict))])
    if (spec.description != "") { value.put("description", wireJsonString(spec.description)) }; value
}

func encodeChatJsonSchemaSpec(spec: LlmWireJsonSchema): JsonNode {
    let value = wireJsonObject([WireJsonField("name", wireJsonString(spec.name)), WireJsonField("schema", spec.schema), WireJsonField("strict", wireJsonBool(spec.strict))])
    if (spec.description != "") { value.put("description", wireJsonString(spec.description)) }; value
}

func flushResponsesMessage(input: JsonNode, role: LlmWireRole, content: JsonNode): Unit {
    if (!content.items.isEmpty()) { input.add(wireJsonObject([WireJsonField("role", wireJsonString(roleName(role))), WireJsonField("content", content)])) }
}

func encodeThinking(codec: LlmWireCodec, root: JsonNode, control: LlmWireThinkingControl): Unit {
    let style = codec.dialect.contract.requestStyle
    match ((style, control)) {
        case (_, LlmWireThinkingControl.ProviderDefault) => ()
        case (LlmWireRequestStyle.OpenAiResponses, LlmWireThinkingControl.Effort(level)) => root.put("reasoning", wireJsonObject([WireJsonField("effort", wireJsonString(wireThinkingLevel(level)))]))
        case (LlmWireRequestStyle.OpenAiChat, LlmWireThinkingControl.Disabled) => root.put("reasoning_effort", wireJsonString("none"))
        case (LlmWireRequestStyle.OpenAiChat, LlmWireThinkingControl.Enabled) => root.put("reasoning_effort", wireJsonString("medium"))
        case (LlmWireRequestStyle.OpenAiChat, LlmWireThinkingControl.Effort(level)) => root.put("reasoning_effort", wireJsonString(wireThinkingLevel(level)))
        case (LlmWireRequestStyle.DeepSeekChat, LlmWireThinkingControl.Disabled) | (LlmWireRequestStyle.DeepSeekMessages, LlmWireThinkingControl.Disabled) => root.put("thinking", wireJsonObject([WireJsonField("type", wireJsonString("disabled"))]))
        case (LlmWireRequestStyle.DeepSeekChat, LlmWireThinkingControl.Enabled) | (LlmWireRequestStyle.DeepSeekMessages, LlmWireThinkingControl.Enabled) => root.put("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled"))]))
        case (LlmWireRequestStyle.DeepSeekChat, LlmWireThinkingControl.Effort(level)) =>
            root.put("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled"))]))
            root.put("reasoning_effort", wireJsonString(wireThinkingLevel(level)))
        case (LlmWireRequestStyle.DeepSeekMessages, LlmWireThinkingControl.Effort(level)) =>
            root.put("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled"))]))
            root.put("output_config", wireJsonObject([WireJsonField("effort", wireJsonString(wireThinkingLevel(level)))]))
        case (LlmWireRequestStyle.DeepSeekResponses, LlmWireThinkingControl.Disabled) => root.put("reasoning", wireJsonObject([WireJsonField("effort", wireJsonString("none"))]))
        case (LlmWireRequestStyle.DeepSeekResponses, LlmWireThinkingControl.Enabled) => root.put("reasoning", wireJsonObject([WireJsonField("effort", wireJsonString("high"))]))
        case (LlmWireRequestStyle.DeepSeekResponses, LlmWireThinkingControl.Effort(level)) => root.put("reasoning", wireJsonObject([WireJsonField("effort", wireJsonString(wireThinkingLevel(level)))]))
        case (LlmWireRequestStyle.AnthropicMessages, LlmWireThinkingControl.Disabled) => root.put("thinking", wireJsonObject([WireJsonField("type", wireJsonString("disabled"))]))
        case (LlmWireRequestStyle.AnthropicMessages, LlmWireThinkingControl.Budget(tokens)) => root.put("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled")), WireJsonField("budget_tokens", wireJsonNumber(tokens.toString()))]))
        case (LlmWireRequestStyle.AnthropicMessages, LlmWireThinkingControl.Adaptive(level)) =>
            root.put("thinking", wireJsonObject([WireJsonField("type", wireJsonString("adaptive"))]))
            match (level) { case Some(value) => root.put("output_config", wireJsonObject([WireJsonField("effort", wireJsonString(wireThinkingLevel(value)))])); case None => () }
        case _ => unsupportedRequest("llm.thinking_not_representable", "thinking control cannot be represented by this dialect")
    }
}

func encodePromptCache(codec: LlmWireCodec, root: JsonNode, value: LlmWirePromptCache, requirements: ArrayList<LlmWireFeatureRequirement>): Unit {
    match (value) {
        case LlmWirePromptCache.ProviderDefault => ()
        case LlmWirePromptCache.Automatic(lifetime) => match (codec.dialect.contract.promptCacheStyle) {
            case LlmWirePromptCacheStyle.OpenAi =>
                if (lifetime != LlmWirePromptCacheLifetime.ProviderDefault) { root.put("prompt_cache_retention", wireJsonString(cacheLifetimeName(lifetime))) }
                else { requirements.add(LlmWireFeatureRequirement("openai.prompt_cache_automatic", LlmWireRequirementState.Satisfied)) }
            case LlmWirePromptCacheStyle.Anthropic => unsupportedRequest("llm.cache_unsupported", "Anthropic cache breakpoints require provider-native content blocks")
            case LlmWirePromptCacheStyle.ProviderAutomatic => requirements.add(LlmWireFeatureRequirement("provider.prompt_cache_automatic", LlmWireRequirementState.Satisfied))
            case LlmWirePromptCacheStyle.Unsupported => unsupportedRequest("llm.cache_unsupported", "automatic prompt caching is not supported")
        }
    }
}

func serviceTierName(value: LlmWireServiceTier): String { match (value) { case LlmWireServiceTier.Auto => "auto"; case LlmWireServiceTier.Default => "default"; case LlmWireServiceTier.StandardOnly => "standard_only"; case LlmWireServiceTier.Flex => "flex"; case LlmWireServiceTier.Priority => "priority"; case LlmWireServiceTier.Fast => "fast"; case LlmWireServiceTier.Ultrafast => "ultrafast"; case _ => "" } }
func generationSpeedName(value: LlmWireGenerationSpeed): String { match (value) { case LlmWireGenerationSpeed.Standard => "standard"; case LlmWireGenerationSpeed.Fast => "fast"; case _ => "" } }
func cacheLifetimeName(value: LlmWirePromptCacheLifetime): String { match (value) { case LlmWirePromptCacheLifetime.FiveMinutes => "5m"; case LlmWirePromptCacheLifetime.ThirtyMinutes => "30m"; case LlmWirePromptCacheLifetime.OneHour => "1h"; case LlmWirePromptCacheLifetime.TwentyFourHours => "24h"; case _ => "" } }
func wireThinkingLevel(value: LlmWireThinkingLevel): String { match (value) { case LlmWireThinkingLevel.Minimal => "minimal"; case LlmWireThinkingLevel.Low => "low"; case LlmWireThinkingLevel.Medium => "medium"; case LlmWireThinkingLevel.High => "high"; case LlmWireThinkingLevel.XHigh => "xhigh"; case LlmWireThinkingLevel.Max => "max" } }

func addResponsesTools(root: JsonNode, values: Array<LlmWireTool>): Unit {
    if (values.isEmpty()) { return }
    let tools = wireJsonArray([])
    for (tool in values) { tools.add(wireJsonObject([
        WireJsonField("type", wireJsonString("function")), WireJsonField("name", wireJsonString(tool.name)),
        WireJsonField("description", wireJsonString(tool.description)), WireJsonField("parameters", tool.inputSchema)
    ])) }
    root.put("tools", tools)
}

func addChatTools(root: JsonNode, values: Array<LlmWireTool>): Unit {
    if (values.isEmpty()) { return }
    let tools = wireJsonArray([])
    for (tool in values) { tools.add(wireJsonObject([
        WireJsonField("type", wireJsonString("function")), WireJsonField("function", wireJsonObject([
            WireJsonField("name", wireJsonString(tool.name)), WireJsonField("description", wireJsonString(tool.description)), WireJsonField("parameters", tool.inputSchema)
        ]))
    ])) }
    root.put("tools", tools)
}

func encodeResponsesContent(block: LlmWireBlock): JsonNode {
    match (block) {
        case LlmWireBlock.Text(value) => wireJsonObject([WireJsonField("type", wireJsonString("input_text")), WireJsonField("text", wireJsonString(value.text))])
        case LlmWireBlock.Image(value) => wireJsonObject([WireJsonField("type", wireJsonString("input_image")), WireJsonField("image_url", wireJsonString(imageUrl(value))), WireJsonField("detail", wireJsonString(imageDetail(value.detail)))])
        case LlmWireBlock.Reasoning(value) => wireJsonObject([WireJsonField("type", wireJsonString("input_text")), WireJsonField("text", wireJsonString(value.text))])
        case LlmWireBlock.Refusal(value) => wireJsonObject([WireJsonField("type", wireJsonString("input_text")), WireJsonField("text", wireJsonString(value.text))])
        case _ => unsupportedRequest("llm.responses_block_unsupported", "block cannot be encoded as Responses message content")
    }
}

func encodeMessagesContent(block: LlmWireBlock): JsonNode {
    match (block) {
        case LlmWireBlock.Text(value) => wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(value.text))])
        case LlmWireBlock.Image(value) =>
            let source = match (value.sourceKind) {
                case LlmWireImageSourceKind.Url => wireJsonObject([WireJsonField("type", wireJsonString("url")), WireJsonField("url", wireJsonString(value.data))])
                case LlmWireImageSourceKind.Base64 => wireJsonObject([WireJsonField("type", wireJsonString("base64")), WireJsonField("media_type", wireJsonString(value.mediaType)), WireJsonField("data", wireJsonString(value.data))])
            }
            wireJsonObject([WireJsonField("type", wireJsonString("image")), WireJsonField("source", source)])
        case LlmWireBlock.ToolCall(value) => wireJsonObject([
            WireJsonField("type", wireJsonString("tool_use")), WireJsonField("id", wireJsonString(value.callId)),
            WireJsonField("name", wireJsonString(value.name)), WireJsonField("input", toolArgumentsObject(value.arguments))
        ])
        case LlmWireBlock.ToolResult(value) => wireJsonObject([
            WireJsonField("type", wireJsonString("tool_result")), WireJsonField("tool_use_id", wireJsonString(value.callId)),
            WireJsonField("content", wireJsonString(value.content)), WireJsonField("is_error", wireJsonBool(value.isError))
        ])
        case LlmWireBlock.NativeReplay(value) => value.payload()
        case LlmWireBlock.Reasoning(_) | LlmWireBlock.Refusal(_) | LlmWireBlock.Opaque(_) => unsupportedRequest("llm.messages_block_unsupported", "display and diagnostic blocks cannot be encoded as request content")
    }
}

func toolArgumentsRaw(arguments: LlmWireToolArguments): String {
    match (arguments) {
        case LlmWireToolArguments.Complete(value) => value.stringify()
        case LlmWireToolArguments.InvalidJson(raw) => raw
        case LlmWireToolArguments.InvalidShape(value) => value.stringify()
        case LlmWireToolArguments.Partial(_) => throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_arguments_partial", "partial tool arguments cannot be encoded")
    }
}

func toolArgumentsObject(arguments: LlmWireToolArguments): JsonNode {
    match (arguments) {
        case LlmWireToolArguments.Complete(value) => if (value.wireKind == WireJsonKind.Object) { value } else { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_arguments_shape_invalid", "tool arguments must be an object") }
        case LlmWireToolArguments.InvalidShape(_) => throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_arguments_shape_invalid", "tool arguments must be an object")
        case LlmWireToolArguments.InvalidJson(_) => throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_arguments_json_invalid", "tool arguments must contain valid JSON")
        case LlmWireToolArguments.Partial(_) => throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_arguments_partial", "partial tool arguments cannot be encoded")
    }
}

func roleName(role: LlmWireRole): String { match (role) { case LlmWireRole.User => "user"; case LlmWireRole.Assistant => "assistant" } }
func imageDetail(value: LlmWireImageDetail): String { match (value) { case LlmWireImageDetail.Auto => "auto"; case LlmWireImageDetail.Low => "low"; case LlmWireImageDetail.High => "high" } }
func imageUrl(value: LlmWireImageBlock): String { match (value.sourceKind) { case LlmWireImageSourceKind.Url => value.data; case LlmWireImageSourceKind.Base64 => "data:" + value.mediaType + ";base64," + value.data } }

func decodeWireResponse(codec: LlmWireCodec, source: String): LlmWireResponseState {
    let root = wireObject(parseWireJson(source), "provider response", provider: codec.provider)
    match (codec.protocol) {
        case LlmWireProtocol.Responses => decodeResponsesResponse(codec, root)
        case LlmWireProtocol.ChatCompletions => decodeChatResponse(codec, root)
        case LlmWireProtocol.Messages => decodeMessagesResponse(codec, root)
    }
}

func decodeResponsesResponse(codec: LlmWireCodec, root: JsonNode): LlmWireResponseState {
    match (wireOptionalObject(root, "error", provider: codec.provider)) { case Some(error) => return LlmWireResponseState.Terminal(LlmWireTerminal.Failed(providerFailure(codec, error))); case None => () }
    let status = wireRequiredString(root, "status", provider: codec.provider)
    if (status == "completed" || status == "incomplete") {
        let _ = match (wireOptionalArray(root, "output", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "terminal Responses response is missing output", provider: codec.provider) }
    }
    let reply = responsesReply(codec, root)
    match (status) {
        case "queued" => LlmWireResponseState.Pending(LlmWirePendingReply.Queued(reply))
        case "in_progress" => LlmWireResponseState.Pending(LlmWirePendingReply.InProgress(reply))
        case "completed" => LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply))
        case "incomplete" => LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(reply, incompleteReason(root)))
        case "failed" => LlmWireResponseState.Terminal(LlmWireTerminal.Failed(match (wireOptionalObject(root, "error", provider: codec.provider)) { case Some(error) => providerFailure(codec, error); case None => LlmWireFailure(LlmWireFailureKind.ProviderError, "provider response failed", provider: codec.provider) }))
        case "cancelled" => LlmWireResponseState.Terminal(LlmWireTerminal.Failed(LlmWireFailure(LlmWireFailureKind.Cancelled, "provider response was cancelled", provider: codec.provider)))
        case _ => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.responses_status_unsupported", "unknown Responses status: " + status, provider: codec.provider)
    }
}

func responsesReply(codec: LlmWireCodec, root: JsonNode): LlmWireReply {
    let blocks = ArrayList<LlmWireBlock>()
    match (wireOptionalArray(root, "output", provider: codec.provider)) {
        case Some(items) => for (itemIndex in 0..items.size) {
            let raw = items[itemIndex]
            let item = wireObject(raw, "Responses output item", provider: codec.provider)
            let kind = wireRequiredString(item, "type", provider: codec.provider)
            match (kind) {
                case "message" => match (wireOptionalArray(item, "content", provider: codec.provider)) {
                    case Some(content) => for (contentIndex in 0..content.size) { decodeResponsesContent(codec, wireObject(content[contentIndex], "Responses content block", provider: codec.provider), blocks, contentIndex) }
                    case None => invalidWire("llm.field_missing", "Responses message output is missing content", provider: codec.provider)
                }
                case "function_call" =>
                    let rawArguments = wireRequiredString(item, "arguments", provider: codec.provider)
                    blocks.add(LlmWireBlock.ToolCall(LlmWireToolCallBlock(wireRequiredString(item, "call_id", provider: codec.provider), wireRequiredString(item, "name", provider: codec.provider), classifyToolArguments(rawArguments))))
                case "reasoning" => blocks.add(LlmWireBlock.NativeReplay(nativeFromNative(codec, item, kind, responsesReasoningDisplay(item, codec.provider), optionalStringOrNone(root, "model", codec.provider), blocks.size)))
                case _ => unsupportedSemantic(codec, kind, item, "llm.responses_block_unsupported", blockIndex: itemIndex)
            }
        }
        case None => ()
    }
    assembleCanonicalReply(
        optionalStringOrEmpty(root, "id", codec.provider), optionalStringOrEmpty(root, "model", codec.provider),
        blocks.toArray(), decodeResponsesUsage(codec, root), wireRequiredString(root, "status", provider: codec.provider),
        requireExecutableToolCalls: wireRequiredString(root, "status", provider: codec.provider) == "completed"
    )
}

func decodeResponsesContent(codec: LlmWireCodec, block: JsonNode, output: ArrayList<LlmWireBlock>, blockIndex: Int64): Unit {
    let kind = wireRequiredString(block, "type", provider: codec.provider)
    match (kind) {
        case "output_text" => output.add(LlmWireBlock.Text(LlmWireTextBlock(wireRequiredString(block, "text", provider: codec.provider))))
        case "refusal" => output.add(LlmWireBlock.Refusal(LlmWireRefusalBlock(wireRequiredString(block, "refusal", provider: codec.provider))))
        case _ => unsupportedSemantic(codec, kind, block, "llm.responses_block_unsupported", blockIndex: blockIndex)
    }
}

func decodeChatResponse(codec: LlmWireCodec, root: JsonNode): LlmWireResponseState {
    match (wireOptionalObject(root, "error", provider: codec.provider)) { case Some(error) => return LlmWireResponseState.Terminal(LlmWireTerminal.Failed(providerFailure(codec, error))); case None => () }
    let choices = match (wireOptionalArray(root, "choices", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Chat response is missing choices", provider: codec.provider) }
    if (choices.isEmpty()) { invalidWire("llm.chat_choices_empty", "Chat response choices must not be empty", provider: codec.provider) }
    if (choices.size != 1) { unsupportedRequest("llm.chat_multiple_choices_unsupported", "only one Chat choice is supported") }
    let choice = wireObject(choices[0], "Chat choice", provider: codec.provider)
    match (wireOptionalInt(choice, "index", provider: codec.provider)) { case Some(0) | None => (); case Some(_) => unsupportedRequest("llm.chat_choice_index_unsupported", "only Chat choice index 0 is supported") }
    let message = match (wireOptionalObject(choice, "message", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Chat choice is missing message", provider: codec.provider) }
    rejectUnsupportedChatSemantic(codec, message, "message")
    let blocks = ArrayList<LlmWireBlock>()
    match (wireOptionalString(message, "content", provider: codec.provider)) { case Some(value) => if (value != "") { blocks.add(LlmWireBlock.Text(LlmWireTextBlock(value))) }; case None => () }
    match (wireOptionalString(message, "reasoning_content", provider: codec.provider)) {
        case Some(value) => if (value != "") {
            if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.DeepSeekChat) { blocks.add(LlmWireBlock.NativeReplay(chatReasoningReplay(codec, value, optionalStringOrNone(root, "model", codec.provider), blocks.size))) }
            else { blocks.add(LlmWireBlock.Reasoning(LlmWireReasoningBlock(value))) }
        }
        case None => ()
    }
    match (wireOptionalString(message, "refusal", provider: codec.provider)) { case Some(value) => if (value != "") { blocks.add(LlmWireBlock.Refusal(LlmWireRefusalBlock(value))) }; case None => () }
    match (wireOptionalArray(message, "tool_calls", provider: codec.provider)) {
        case Some(calls) => for (raw in calls) {
            let call = wireObject(raw, "Chat tool call", provider: codec.provider)
            let function = match (wireOptionalObject(call, "function", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Chat tool call is missing function", provider: codec.provider) }
            blocks.add(LlmWireBlock.ToolCall(LlmWireToolCallBlock(wireRequiredString(call, "id", provider: codec.provider), wireRequiredString(function, "name", provider: codec.provider), classifyToolArguments(wireRequiredString(function, "arguments", provider: codec.provider)))))
        }
        case None => ()
    }
    let stop = wireRequiredString(choice, "finish_reason", provider: codec.provider)
    let reply = assembleCanonicalReply(
        optionalStringOrEmpty(root, "id", codec.provider), optionalStringOrEmpty(root, "model", codec.provider),
        blocks.toArray(), decodeChatUsage(codec, root), stop,
        requireExecutableToolCalls: stop != "length" && stop != "content_filter"
    )
    match (stop) {
        case "stop" | "tool_calls" => LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply))
        case "function_call" => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.chat_legacy_function_call_unsupported", "legacy Chat function_call responses are not supported", provider: codec.provider)
        case "length" => LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.Length))
        case "content_filter" => LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.ContentFilter))
        case "insufficient_system_resource" => LlmWireResponseState.Terminal(LlmWireTerminal.Failed(LlmWireFailure(LlmWireFailureKind.InsufficientSystemResource, "provider reported insufficient system resources", provider: codec.provider, retryable: true)))
        case _ => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.chat_finish_reason_unsupported", "unknown Chat finish reason: " + stop, provider: codec.provider)
    }
}

func rejectUnsupportedChatSemantic(codec: LlmWireCodec, value: JsonNode, eventType: String): Unit {
    for (field in ["function_call", "audio"]) {
        match (value.field(field)) {
            case Some(payload) => if (payload.wireKind != WireJsonKind.Null) {
                unsupportedSemantic(codec, field, payload, "llm.chat_semantic_unsupported", eventType: eventType)
            }
            case None => ()
        }
    }
    match (wireOptionalArray(value, "annotations", provider: codec.provider)) {
        case Some(items) => if (!items.isEmpty()) { unsupportedSemantic(codec, "annotations", value["annotations"], "llm.chat_semantic_unsupported", eventType: eventType) }
        case None => ()
    }
}

func decodeMessagesResponse(codec: LlmWireCodec, root: JsonNode): LlmWireResponseState {
    if (optionalStringOrEmpty(root, "type", codec.provider) == "error") {
        let error = match (root.field("error")) { case Some(value) => value; case None => root }
        return LlmWireResponseState.Terminal(LlmWireTerminal.Failed(providerFailure(codec, error)))
    }
    let content = match (wireOptionalArray(root, "content", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Messages response is missing content", provider: codec.provider) }
    let blocks = ArrayList<LlmWireBlock>()
    let modelConstraint = optionalStringOrNone(root, "model", codec.provider)
    for (blockIndex in 0..content.size) {
        let raw = content[blockIndex]
        let block = wireObject(raw, "Messages content block", provider: codec.provider)
        let kind = wireRequiredString(block, "type", provider: codec.provider)
        match (kind) {
            case "text" => blocks.add(LlmWireBlock.Text(LlmWireTextBlock(wireRequiredString(block, "text", provider: codec.provider))))
            case "tool_use" =>
                let input = wireRequiredField(block, "input", provider: codec.provider)
                let arguments = if (input.wireKind == WireJsonKind.Object) { LlmWireToolArguments.Complete(input) } else { LlmWireToolArguments.InvalidShape(input) }
                blocks.add(LlmWireBlock.ToolCall(LlmWireToolCallBlock(wireRequiredString(block, "id", provider: codec.provider), wireRequiredString(block, "name", provider: codec.provider), arguments)))
            case "thinking" => blocks.add(LlmWireBlock.NativeReplay(nativeFromNative(codec, block, kind, wireOptionalString(block, "thinking", provider: codec.provider), modelConstraint, blockIndex)))
            case "redacted_thinking" => blocks.add(LlmWireBlock.NativeReplay(nativeFromNative(codec, block, kind, None, modelConstraint, blockIndex)))
            case _ => unsupportedSemantic(codec, kind, block, "llm.messages_block_unsupported", blockIndex: blockIndex)
        }
    }
    let stop = wireRequiredString(root, "stop_reason", provider: codec.provider)
    let reply = assembleCanonicalReply(
        optionalStringOrEmpty(root, "id", codec.provider), optionalStringOrEmpty(root, "model", codec.provider),
        blocks.toArray(), decodeMessagesUsage(codec, root), stop,
        requireExecutableToolCalls: stop != "max_tokens" && stop != "model_context_window_exceeded" && stop != "pause_turn"
    )
    match (stop) {
        case "end_turn" | "stop_sequence" | "tool_use" | "refusal" => LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply))
        case "max_tokens" => LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.MaxTokens))
        case "model_context_window_exceeded" => LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.ModelContextWindowExceeded))
        case "pause_turn" => LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.PauseTurn))
        case _ => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.messages_stop_reason_unsupported", "unknown Messages stop reason: " + stop, provider: codec.provider)
    }
}

func classifyToolArguments(raw: String): LlmWireToolArguments {
    try {
        let value = parseWireJson(raw)
        if (value.wireKind == WireJsonKind.Object) { LlmWireToolArguments.Complete(value) }
        else { LlmWireToolArguments.InvalidShape(value) }
    } catch (_: LlmTransportError) { LlmWireToolArguments.InvalidJson(raw) }
}

func nativeFromNative(codec: LlmWireCodec, payload: JsonNode, nativeType: String, display: ?String, modelConstraint: ?String, blockOrder: Int64): LlmWireNativeReplayBlock {
    nativeReplayFromPayload(codec.protocol, codec.dialect.compatibilityId, nativeType, payload, modelConstraint: modelConstraint, blockOrder: blockOrder, displayReasoning: display)
}

func chatReasoningReplay(codec: LlmWireCodec, text: String, modelConstraint: ?String, blockOrder: Int64): LlmWireNativeReplayBlock {
    nativeReplayFromPayload(
        LlmWireProtocol.ChatCompletions, codec.dialect.compatibilityId, "reasoning_content",
        wireJsonObject([WireJsonField("type", wireJsonString("reasoning_content")), WireJsonField("reasoning_content", wireJsonString(text))]),
        modelConstraint: modelConstraint, blockOrder: blockOrder, displayReasoning: Some(text)
    )
}

func responsesReasoningDisplay(item: JsonNode, provider: String): ?String {
    let output = StringBuilder()
    for (fieldName in ["summary", "content"]) {
        match (item.field(fieldName)) {
            case None => ()
            case Some(value) =>
                if (value.wireKind == WireJsonKind.Null) { continue }
                if (value.wireKind == WireJsonKind.Text) { output.append(value.text); continue }
                if (value.wireKind != WireJsonKind.List) {
                    invalidWire("llm.field_type_invalid", fieldName + " must be a string, array, or null", provider: provider)
                }
                for (raw in value.items) {
                    let part = wireObject(raw, "Responses reasoning part", provider: provider)
                    match (wireOptionalString(part, "text", provider: provider)) {
                        case Some(text) => output.append(text)
                        case None => ()
                    }
                }
        }
    }
    let value = output.toString()
    if (value == "") { None } else { Some(value) }
}

func providerFailure(codec: LlmWireCodec, raw: JsonNode): LlmWireFailure {
    let error = wireObject(raw, "provider error", provider: codec.provider)
    LlmWireFailure(
        LlmWireFailureKind.ProviderError,
        match (wireOptionalString(error, "message", provider: codec.provider)) { case Some(value) => value; case None => "provider returned an error" },
        provider: codec.provider,
        providerErrorCode: match (wireOptionalString(error, "code", provider: codec.provider)) { case Some(value) => value; case None => "" },
        providerErrorType: match (wireOptionalString(error, "type", provider: codec.provider)) { case Some(value) => value; case None => "" }
    )
}

func optionalStringOrEmpty(value: JsonNode, name: String, provider: String): String {
    match (wireOptionalString(value, name, provider: provider)) { case Some(found) => found; case None => "" }
}

func optionalStringOrNone(value: JsonNode, name: String, provider: String): ?String { wireOptionalString(value, name, provider: provider) }

func incompleteReason(root: JsonNode): LlmWireIncompleteReason {
    match (wireOptionalObject(root, "incomplete_details")) {
        case Some(details) => match (wireOptionalString(details, "reason")) {
            case Some("max_output_tokens") => LlmWireIncompleteReason.MaxTokens
            case Some("content_filter") => LlmWireIncompleteReason.ContentFilter
            case Some(value) => LlmWireIncompleteReason.Other(value)
            case None => LlmWireIncompleteReason.Other("incomplete")
        }
        case None => LlmWireIncompleteReason.Other("incomplete")
    }
}

func decodeResponsesUsage(codec: LlmWireCodec, root: JsonNode): LlmWireUsage {
    match (wireOptionalObject(root, "usage", provider: codec.provider)) {
        case None => LlmWireUsage()
        case Some(usage) =>
            let inputDetails = match (wireOptionalObject(usage, "input_tokens_details", provider: codec.provider)) { case Some(value) => value; case None => wireJsonObject([]) }
            let outputDetails = match (wireOptionalObject(usage, "output_tokens_details", provider: codec.provider)) { case Some(value) => value; case None => wireJsonObject([]) }
            LlmWireUsage(inputTokens: wireOptionalUsageInt(usage, "input_tokens", codec.provider), outputTokens: wireOptionalUsageInt(usage, "output_tokens", codec.provider), reasoningTokens: wireOptionalUsageInt(outputDetails, "reasoning_tokens", codec.provider), cacheReadTokens: wireOptionalUsageInt(inputDetails, "cached_tokens", codec.provider), cacheWriteTokens: wireOptionalUsageInt(inputDetails, "cache_write_tokens", codec.provider))
    }
}

func decodeChatUsage(codec: LlmWireCodec, root: JsonNode): LlmWireUsage {
    match (wireOptionalObject(root, "usage", provider: codec.provider)) {
        case None => LlmWireUsage()
        case Some(usage) =>
            let inputDetails = match (wireOptionalObject(usage, "prompt_tokens_details", provider: codec.provider)) { case Some(value) => value; case None => wireJsonObject([]) }
            let outputDetails = match (wireOptionalObject(usage, "completion_tokens_details", provider: codec.provider)) { case Some(value) => value; case None => wireJsonObject([]) }
            LlmWireUsage(inputTokens: wireOptionalUsageInt(usage, "prompt_tokens", codec.provider), outputTokens: wireOptionalUsageInt(usage, "completion_tokens", codec.provider), reasoningTokens: wireOptionalUsageInt(outputDetails, "reasoning_tokens", codec.provider), cacheReadTokens: wireOptionalUsageInt(inputDetails, "cached_tokens", codec.provider), cacheWriteTokens: wireOptionalUsageInt(inputDetails, "cache_write_tokens", codec.provider))
    }
}

func decodeMessagesUsage(codec: LlmWireCodec, root: JsonNode): LlmWireUsage {
    match (wireOptionalObject(root, "usage", provider: codec.provider)) {
        case None => LlmWireUsage()
        case Some(usage) => LlmWireUsage(inputTokens: wireOptionalUsageInt(usage, "input_tokens", codec.provider), outputTokens: wireOptionalUsageInt(usage, "output_tokens", codec.provider), cacheReadTokens: wireOptionalUsageInt(usage, "cache_read_input_tokens", codec.provider), cacheWriteTokens: wireOptionalUsageInt(usage, "cache_creation_input_tokens", codec.provider))
    }
}

func wireOptionalUsageInt(value: JsonNode, name: String, provider: String): ?Int64 {
    match (wireOptionalInt(value, name, provider: provider)) {
        case Some(found) => if (found < 0) { invalidWire("llm.usage_negative", name + " must be non-negative", provider: provider) } else { Some(found) }
        case None => None
    }
}
