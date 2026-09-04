package llm4cj

import std.collection.*
import std.convert.*
import yjson.*

func encodeWireRequest(codec: LlmWireCodec, request: LlmWireRequest, streaming: Bool): LlmWirePreparedRequest {
    let headers = ArrayList<LlmWireHeader>()
    let requirements = ArrayList<LlmWireFeatureRequirement>()
    let body = match (codec.protocol) {
        case LlmWireProtocol.Responses => encodeResponsesRequest(codec, request, requirements, streaming)
        case LlmWireProtocol.ChatCompletions => encodeChatRequest(codec, request, requirements, streaming)
        case LlmWireProtocol.Messages => encodeMessagesRequest(codec, request, headers, requirements, streaming)
    }
    LlmWirePreparedRequest(body, requiredHeaders: headers.toArray(), featureRequirements: requirements.toArray(), streaming: streaming)
}

internal func encodeAnthropicCachePrewarm(codec: LlmWireCodec, request: LlmWireRequest): LlmWirePreparedRequest {
    if (codec.dialect.contract.requestStyle != LlmWireRequestStyle.AnthropicMessages) {
        throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.cache_prewarm_dialect_unsupported", "cache pre-warm is experimental and only supports Anthropic Messages")
    }
    match (request.maxOutputTokens) {
        case Some(0) => ()
        case _ => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.cache_prewarm_tokens_invalid", "cache pre-warm requires max output tokens equal to zero")
    }
    match (request.promptCache) {
        case LlmWirePromptCache.Automatic(_) => ()
        case _ => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.cache_prewarm_cache_missing", "cache pre-warm requires automatic prompt caching")
    }
    if (request.thinkingMode != LlmWireThinkingMode.ProviderDefault || request.reasoningEffort != LlmWireReasoningEffort.ProviderDefault) {
        throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.cache_prewarm_thinking_unsupported", "cache pre-warm cannot enable thinking or effort")
    }
    match (request.structuredOutput) {
        case LlmWireStructuredOutput.ProviderDefault | LlmWireStructuredOutput.Text => ()
        case _ => throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.cache_prewarm_structured_output_unsupported", "cache pre-warm cannot request structured output")
    }
    if (request.toolChoice == LlmWireToolChoice.Required) {
        throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.cache_prewarm_tool_choice_unsupported", "cache pre-warm cannot require a tool")
    }
    validateWireRequest(codec, request, allowCachePrewarm: true)
    encodeWireRequest(codec, request, false)
}

func outputTokenName(value: LlmWireOutputTokenField): String {
    match (value) {
        case LlmWireOutputTokenField.MaxOutputTokens => "max_output_tokens"
        case LlmWireOutputTokenField.MaxCompletionTokens => "max_completion_tokens"
        case LlmWireOutputTokenField.MaxTokens => "max_tokens"
    }
}

func baseRequest(codec: LlmWireCodec, request: LlmWireRequest, streaming: Bool): JsonNode {
    let root = wireJsonObject([WireJsonField("model", wireJsonString(request.model))])
    match (request.maxOutputTokens) { case Some(value) => root.put(outputTokenName(codec.dialect.contract.outputTokenField), wireJsonNumber(value.toString())); case None => () }
    if (streaming) { root.put("stream", wireJsonBool(true)) }
    root
}

func addDialectOptions(codec: LlmWireCodec, root: JsonNode, request: LlmWireRequest, requirements: ArrayList<LlmWireFeatureRequirement>): Unit {
    encodeThinking(codec, root, request.thinkingMode, request.reasoningEffort)
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

func encodeResponsesRequest(codec: LlmWireCodec, request: LlmWireRequest, requirements: ArrayList<LlmWireFeatureRequirement>, streaming: Bool): String {
    let root = baseRequest(codec, request, streaming); addDialectOptions(codec, root, request, requirements)
    match (request.structuredOutput) {
        case LlmWireStructuredOutput.Text => root.put("text", wireJsonObject([WireJsonField("format", wireJsonObject([WireJsonField("type", wireJsonString("text"))]))]))
        case LlmWireStructuredOutput.JsonObject => root.put("text", wireJsonObject([WireJsonField("format", wireJsonObject([WireJsonField("type", wireJsonString("json_object"))]))]))
        case LlmWireStructuredOutput.JsonSchema(spec) => root.put("text", wireJsonObject([WireJsonField("format", encodeResponsesJsonSchemaFormat(spec))]))
        case _ => ()
    }
    let input = wireJsonArray([])
    for (instruction in request.instructions) {
        input.add(wireJsonObject([
            WireJsonField("role", wireJsonString(instructionRoleName(instruction.role))),
            WireJsonField("content", wireJsonArray([wireJsonObject([WireJsonField("type", wireJsonString("input_text")), WireJsonField("text", wireJsonString(instruction.text))])]))
        ]))
    }
    for (message in request.messages) {
        var content = wireJsonArray([])
        for (block in message.blocks) { match (block) {
            case LlmWireBlock.Text(_) | LlmWireBlock.Image(_) => content.add(encodeResponsesContent(block))
            case LlmWireBlock.ToolCall(call) =>
                flushResponsesMessage(input, message.role, content); content = wireJsonArray([])
                input.add(wireJsonObject([WireJsonField("type", wireJsonString("function_call")), WireJsonField("call_id", wireJsonString(call.callId)), WireJsonField("name", wireJsonString(call.name)), WireJsonField("arguments", wireJsonString(toolArgumentsRaw(call.arguments)))]))
            case LlmWireBlock.ToolResult(result) =>
                flushResponsesMessage(input, message.role, content); content = wireJsonArray([])
                input.add(wireJsonObject([WireJsonField("type", wireJsonString("function_call_output")), WireJsonField("call_id", wireJsonString(result.callId)), WireJsonField("output", encodeResponsesToolResult(result))]))
            case LlmWireBlock.NativeReplay(value) =>
                flushResponsesMessage(input, message.role, content); content = wireJsonArray([])
                input.add(value.payload())
            case LlmWireBlock.Reasoning(_) | LlmWireBlock.Refusal(_) | LlmWireBlock.Opaque(_) => unsupportedRequest("llm.responses_block_unsupported", "display and diagnostic blocks cannot be encoded as request input")
        } }
        flushResponsesMessage(input, message.role, content)
    }
    root.put("input", input); addResponsesTools(root, request.tools); root.stringify()
}

func encodeChatRequest(codec: LlmWireCodec, request: LlmWireRequest, requirements: ArrayList<LlmWireFeatureRequirement>, streaming: Bool): String {
    let root = baseRequest(codec, request, streaming); addDialectOptions(codec, root, request, requirements)
    match (request.structuredOutput) {
        case LlmWireStructuredOutput.Text => root.put("response_format", wireJsonObject([WireJsonField("type", wireJsonString("text"))]))
        case LlmWireStructuredOutput.JsonObject => root.put("response_format", wireJsonObject([WireJsonField("type", wireJsonString("json_object"))]))
        case LlmWireStructuredOutput.JsonSchema(spec) => root.put("response_format", wireJsonObject([WireJsonField("type", wireJsonString("json_schema")), WireJsonField("json_schema", encodeChatJsonSchemaSpec(spec))]))
        case _ => ()
    }
    let messages = wireJsonArray([])
    for (instruction in request.instructions) { messages.add(wireJsonObject([WireJsonField("role", wireJsonString(instructionRoleName(instruction.role))), WireJsonField("content", wireJsonString(instruction.text))])) }
    for (message in request.messages) {
        let content = StringBuilder()
        let contentParts = wireJsonArray([])
        var hasImage = false
        let calls = wireJsonArray([])
        var reasoningContent: ?String = None
        for (block in message.blocks) { match (block) {
            case LlmWireBlock.Text(value) => content.append(value.text); contentParts.add(wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(value.text))]))
            case LlmWireBlock.ToolResult(result) => messages.add(wireJsonObject([WireJsonField("role", wireJsonString("tool")), WireJsonField("tool_call_id", wireJsonString(result.callId)), WireJsonField("content", encodeChatToolResult(codec, result))]))
            case LlmWireBlock.ToolCall(call) => calls.add(wireJsonObject([WireJsonField("id", wireJsonString(call.callId)), WireJsonField("type", wireJsonString("function")), WireJsonField("function", wireJsonObject([WireJsonField("name", wireJsonString(call.name)), WireJsonField("arguments", wireJsonString(toolArgumentsRaw(call.arguments)))]))]))
            case LlmWireBlock.NativeReplay(value) =>
                if (codec.dialect.contract.requestStyle != LlmWireRequestStyle.DeepSeekChat || value.nativeType != "reasoning_content") { unsupportedRequest("llm.chat_opaque_unsupported", "Chat Completions cannot replay this native block") }
                reasoningContent = Some(wireRequiredString(value.payload(), "reasoning_content", provider: codec.provider))
            case LlmWireBlock.Opaque(_) => unsupportedRequest("llm.chat_opaque_unsupported", "Chat Completions cannot replay diagnostic blocks")
            case LlmWireBlock.Reasoning(_) | LlmWireBlock.Refusal(_) => unsupportedRequest("llm.chat_block_unsupported", "display-only blocks cannot be encoded as request input")
            case LlmWireBlock.Image(value) => hasImage = true; contentParts.add(encodeChatImage(codec, value))
        } }
        let text = content.toString()
        if (text != "" || hasImage || !calls.items.isEmpty() || reasoningContent.isSome()) {
            let encoded = wireJsonObject([WireJsonField("role", wireJsonString(roleName(message.role))), WireJsonField("content", if (hasImage) { contentParts } else { wireJsonString(text) })])
            match (reasoningContent) { case Some(value) => encoded.put("reasoning_content", wireJsonString(value)); case None => () }
            if (!calls.items.isEmpty()) { encoded.put("tool_calls", calls) }
            messages.add(encoded)
        }
    }
    root.put("messages", messages); addChatTools(root, request.tools); root.stringify()
}

func encodeMessagesRequest(codec: LlmWireCodec, request: LlmWireRequest, headers: ArrayList<LlmWireHeader>, requirements: ArrayList<LlmWireFeatureRequirement>, streaming: Bool): String {
    let root = baseRequest(codec, request, streaming); encodeThinking(codec, root, request.thinkingMode, request.reasoningEffort)
    if (!request.instructions.isEmpty()) {
        let system = wireJsonArray([])
        for (instruction in request.instructions) { system.add(wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(instruction.text))])) }
        root.put("system", system)
    }
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
            existing.put("format", wireJsonObject([WireJsonField("type", wireJsonString("json_schema")), WireJsonField("schema", schema.jsonNode())])); root.put("output_config", existing)
        case _ => ()
    }
    encodePromptCache(codec, root, request.promptCache, requirements)
    if (requestHasFileImage(request)) { headers.add(LlmWireHeader("anthropic-beta", "files-api-2025-04-14")) }
    let messages = wireJsonArray([])
    for (message in request.messages) { let content = wireJsonArray([]); for (block in message.blocks) { content.add(encodeMessagesContent(codec, block)) }; messages.add(wireJsonObject([WireJsonField("role", wireJsonString(roleName(message.role))), WireJsonField("content", content)])) }
    root.put("messages", messages)
    if (!request.tools.isEmpty()) { let tools = wireJsonArray([]); for (tool in request.tools) { tools.add(wireJsonObject([WireJsonField("name", wireJsonString(tool.name)), WireJsonField("description", wireJsonString(tool.description)), WireJsonField("input_schema", tool.inputSchema.jsonNode())])) }; root.put("tools", tools) }
    root.stringify()
}

func encodeResponsesJsonSchemaFormat(spec: LlmWireJsonSchema): JsonNode {
    let value = wireJsonObject([WireJsonField("type", wireJsonString("json_schema")), WireJsonField("name", wireJsonString(spec.name)), WireJsonField("schema", spec.schema.jsonNode()), WireJsonField("strict", wireJsonBool(spec.strict))])
    if (spec.description != "") { value.put("description", wireJsonString(spec.description)) }; value
}

func encodeChatJsonSchemaSpec(spec: LlmWireJsonSchema): JsonNode {
    let value = wireJsonObject([WireJsonField("name", wireJsonString(spec.name)), WireJsonField("schema", spec.schema.jsonNode()), WireJsonField("strict", wireJsonBool(spec.strict))])
    if (spec.description != "") { value.put("description", wireJsonString(spec.description)) }; value
}

func flushResponsesMessage(input: JsonNode, role: LlmWireRole, content: JsonNode): Unit {
    if (!content.items.isEmpty()) { input.add(wireJsonObject([WireJsonField("role", wireJsonString(roleName(role))), WireJsonField("content", content)])) }
}

func encodeThinking(codec: LlmWireCodec, root: JsonNode, mode: LlmWireThinkingMode, effort: LlmWireReasoningEffort): Unit {
    let style = codec.dialect.contract.requestStyle
    match ((style, mode)) {
        case (LlmWireRequestStyle.OpenAiResponses, LlmWireThinkingMode.ProviderDefault) => putReasoningEffort(root, "reasoning", effort)
        case (LlmWireRequestStyle.OpenAiChat, LlmWireThinkingMode.ProviderDefault) => putScalarReasoningEffort(root, effort)
        case (LlmWireRequestStyle.OpenAiChat, LlmWireThinkingMode.Disabled) => root.put("reasoning_effort", wireJsonString("none"))
        case (LlmWireRequestStyle.OpenAiChat, LlmWireThinkingMode.Enabled) => root.put("reasoning_effort", wireJsonString(if (effort == LlmWireReasoningEffort.ProviderDefault) { "medium" } else { wireReasoningEffort(effort) }))
        case (LlmWireRequestStyle.DeepSeekChat, LlmWireThinkingMode.Disabled) | (LlmWireRequestStyle.DeepSeekMessages, LlmWireThinkingMode.Disabled) => root.put("thinking", wireJsonObject([WireJsonField("type", wireJsonString("disabled"))]))
        case (LlmWireRequestStyle.DeepSeekChat, LlmWireThinkingMode.Enabled) =>
            root.put("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled"))]))
            putScalarReasoningEffort(root, effort)
        case (LlmWireRequestStyle.DeepSeekMessages, LlmWireThinkingMode.Enabled) =>
            root.put("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled"))]))
            if (effort != LlmWireReasoningEffort.ProviderDefault) { root.put("output_config", wireJsonObject([WireJsonField("effort", wireJsonString(wireReasoningEffort(effort)))])) }
        case (LlmWireRequestStyle.DeepSeekResponses, LlmWireThinkingMode.ProviderDefault) => putReasoningEffort(root, "reasoning", effort)
        case (LlmWireRequestStyle.DeepSeekResponses, LlmWireThinkingMode.Disabled) => root.put("reasoning", wireJsonObject([WireJsonField("effort", wireJsonString("none"))]))
        case (LlmWireRequestStyle.DeepSeekResponses, LlmWireThinkingMode.Enabled) => root.put("reasoning", wireJsonObject([WireJsonField("effort", wireJsonString(if (effort == LlmWireReasoningEffort.ProviderDefault) { "high" } else { wireReasoningEffort(effort) }))]))
        case (_, LlmWireThinkingMode.ProviderDefault) => ()
        case (LlmWireRequestStyle.AnthropicMessages, LlmWireThinkingMode.Disabled) => root.put("thinking", wireJsonObject([WireJsonField("type", wireJsonString("disabled"))]))
        case (LlmWireRequestStyle.AnthropicMessages, LlmWireThinkingMode.Budget(tokens)) => root.put("thinking", wireJsonObject([WireJsonField("type", wireJsonString("enabled")), WireJsonField("budget_tokens", wireJsonNumber(tokens.toString()))]))
        case (LlmWireRequestStyle.AnthropicMessages, LlmWireThinkingMode.Adaptive) =>
            root.put("thinking", wireJsonObject([WireJsonField("type", wireJsonString("adaptive"))]))
            if (effort != LlmWireReasoningEffort.ProviderDefault) { root.put("output_config", wireJsonObject([WireJsonField("effort", wireJsonString(wireReasoningEffort(effort)))])) }
        case _ => unsupportedRequest("llm.thinking_not_representable", "thinking mode cannot be represented by this dialect")
    }
}

func putScalarReasoningEffort(root: JsonNode, effort: LlmWireReasoningEffort): Unit {
    if (effort != LlmWireReasoningEffort.ProviderDefault) { root.put("reasoning_effort", wireJsonString(wireReasoningEffort(effort))) }
}

func putReasoningEffort(root: JsonNode, field: String, effort: LlmWireReasoningEffort): Unit {
    if (effort != LlmWireReasoningEffort.ProviderDefault) { root.put(field, wireJsonObject([WireJsonField("effort", wireJsonString(wireReasoningEffort(effort)))])) }
}

func encodePromptCache(codec: LlmWireCodec, root: JsonNode, value: LlmWirePromptCache, requirements: ArrayList<LlmWireFeatureRequirement>): Unit {
    match (value) {
        case LlmWirePromptCache.ProviderDefault => ()
        case LlmWirePromptCache.Automatic(lifetime) => match (codec.dialect.contract.promptCacheStyle) {
            case LlmWirePromptCacheStyle.OpenAi =>
                if (lifetime != LlmWirePromptCacheLifetime.ProviderDefault) { root.put("prompt_cache_options", wireJsonObject([WireJsonField("ttl", wireJsonString(cacheLifetimeName(lifetime)))])) }
                else { requirements.add(LlmWireFeatureRequirement("openai.prompt_cache_automatic", LlmWireRequirementState.Satisfied)) }
            case LlmWirePromptCacheStyle.Anthropic =>
                let cacheControl = wireJsonObject([WireJsonField("type", wireJsonString("ephemeral"))])
                if (lifetime == LlmWirePromptCacheLifetime.OneHour) { cacheControl.put("ttl", wireJsonString("1h")) }
                root.put("cache_control", cacheControl)
            case LlmWirePromptCacheStyle.ProviderAutomatic => requirements.add(LlmWireFeatureRequirement("provider.prompt_cache_automatic", LlmWireRequirementState.Satisfied))
            case LlmWirePromptCacheStyle.Unsupported => unsupportedRequest("llm.cache_unsupported", "automatic prompt caching is not supported")
        }
    }
}

func serviceTierName(value: LlmWireServiceTier): String { match (value) { case LlmWireServiceTier.Auto => "auto"; case LlmWireServiceTier.Default => "default"; case LlmWireServiceTier.StandardOnly => "standard_only"; case LlmWireServiceTier.Flex => "flex"; case LlmWireServiceTier.Priority => "priority"; case LlmWireServiceTier.Fast => "fast"; case LlmWireServiceTier.Ultrafast => "ultrafast"; case _ => "" } }
func generationSpeedName(value: LlmWireGenerationSpeed): String { match (value) { case LlmWireGenerationSpeed.Standard => "standard"; case LlmWireGenerationSpeed.Fast => "fast"; case _ => "" } }
func cacheLifetimeName(value: LlmWirePromptCacheLifetime): String { match (value) { case LlmWirePromptCacheLifetime.FiveMinutes => "5m"; case LlmWirePromptCacheLifetime.ThirtyMinutes => "30m"; case LlmWirePromptCacheLifetime.OneHour => "1h"; case LlmWirePromptCacheLifetime.TwentyFourHours => "24h"; case _ => "" } }
func wireReasoningEffort(value: LlmWireReasoningEffort): String { match (value) { case LlmWireReasoningEffort.Minimal => "minimal"; case LlmWireReasoningEffort.Low => "low"; case LlmWireReasoningEffort.Medium => "medium"; case LlmWireReasoningEffort.High => "high"; case LlmWireReasoningEffort.XHigh => "xhigh"; case LlmWireReasoningEffort.Max => "max"; case LlmWireReasoningEffort.ProviderDefault => "" } }

func addResponsesTools(root: JsonNode, values: Array<LlmWireTool>): Unit {
    if (values.isEmpty()) { return }
    let tools = wireJsonArray([])
    for (tool in values) { tools.add(wireJsonObject([
        WireJsonField("type", wireJsonString("function")), WireJsonField("name", wireJsonString(tool.name)),
        WireJsonField("description", wireJsonString(tool.description)), WireJsonField("parameters", tool.inputSchema.jsonNode())
    ])) }
    root.put("tools", tools)
}

func addChatTools(root: JsonNode, values: Array<LlmWireTool>): Unit {
    if (values.isEmpty()) { return }
    let tools = wireJsonArray([])
    for (tool in values) { tools.add(wireJsonObject([
        WireJsonField("type", wireJsonString("function")), WireJsonField("function", wireJsonObject([
            WireJsonField("name", wireJsonString(tool.name)), WireJsonField("description", wireJsonString(tool.description)), WireJsonField("parameters", tool.inputSchema.jsonNode())
        ]))
    ])) }
    root.put("tools", tools)
}

func encodeResponsesContent(block: LlmWireBlock): JsonNode {
    match (block) {
        case LlmWireBlock.Text(value) => wireJsonObject([WireJsonField("type", wireJsonString("input_text")), WireJsonField("text", wireJsonString(value.text))])
        case LlmWireBlock.Image(value) => match (value.sourceKind) {
            case LlmWireImageSourceKind.File => wireJsonObject([WireJsonField("type", wireJsonString("input_image")), WireJsonField("file_id", wireJsonString(value.data))])
            case _ => wireJsonObject([WireJsonField("type", wireJsonString("input_image")), WireJsonField("image_url", wireJsonString(imageUrl(value))), WireJsonField("detail", wireJsonString(imageDetail(value.detail)))])
        }
        case LlmWireBlock.Reasoning(value) => wireJsonObject([WireJsonField("type", wireJsonString("input_text")), WireJsonField("text", wireJsonString(value.text))])
        case LlmWireBlock.Refusal(value) => wireJsonObject([WireJsonField("type", wireJsonString("input_text")), WireJsonField("text", wireJsonString(value.text))])
        case _ => unsupportedRequest("llm.responses_block_unsupported", "block cannot be encoded as Responses message content")
    }
}

const messagesToolErrorMarker: String = "[tool_error]"

func encodeMessagesContent(codec: LlmWireCodec, block: LlmWireBlock): JsonNode {
    match (block) {
        case LlmWireBlock.Text(value) => wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(value.text))])
        case LlmWireBlock.Image(value) =>
            encodeMessagesImage(value)
        case LlmWireBlock.ToolCall(value) => wireJsonObject([
            WireJsonField("type", wireJsonString("tool_use")), WireJsonField("id", wireJsonString(value.callId)),
            WireJsonField("name", wireJsonString(value.name)), WireJsonField("input", toolArgumentsObject(value.arguments))
        ])
        case LlmWireBlock.ToolResult(value) => encodeMessagesToolResultBlock(codec, value)
        case LlmWireBlock.NativeReplay(value) => value.payload()
        case LlmWireBlock.Reasoning(_) | LlmWireBlock.Refusal(_) | LlmWireBlock.Opaque(_) => unsupportedRequest("llm.messages_block_unsupported", "display and diagnostic blocks cannot be encoded as request content")
    }
}

func encodeResponsesToolResult(value: LlmWireToolResultBlock): JsonNode {
    let output = wireJsonArray([])
    for (part in value.content) { match (part) {
        case LlmWireToolResultContent.Text(text) => output.add(wireJsonObject([WireJsonField("type", wireJsonString("input_text")), WireJsonField("text", wireJsonString(text.text))]))
        case LlmWireToolResultContent.Image(image) => output.add(match (image.sourceKind) {
            case LlmWireImageSourceKind.File => wireJsonObject([WireJsonField("type", wireJsonString("input_image")), WireJsonField("file_id", wireJsonString(image.data))])
            case _ => wireJsonObject([WireJsonField("type", wireJsonString("input_image")), WireJsonField("image_url", wireJsonString(imageUrl(image))), WireJsonField("detail", wireJsonString(imageDetail(image.detail)))])
        })
    } }
    output
}

func encodeChatToolResult(codec: LlmWireCodec, value: LlmWireToolResultBlock): JsonNode {
    let output = wireJsonArray([])
    for (part in value.content) { match (part) {
        case LlmWireToolResultContent.Text(text) => output.add(wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(text.text))]))
        case LlmWireToolResultContent.Image(image) => output.add(encodeChatImage(codec, image))
    } }
    output
}

func encodeMessagesToolResult(value: LlmWireToolResultBlock): JsonNode {
    let output = wireJsonArray([])
    for (part in value.content) { match (part) {
        case LlmWireToolResultContent.Text(text) => output.add(wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(text.text))]))
        case LlmWireToolResultContent.Image(image) => output.add(encodeMessagesImage(image))
    } }
    output
}

func encodeMessagesToolResultBlock(codec: LlmWireCodec, value: LlmWireToolResultBlock): JsonNode {
    let errorStyle = codec.dialect.contract.toolErrorStyle
    let fields = ArrayList<WireJsonField>()
    fields.add(WireJsonField("type", wireJsonString("tool_result")))
    fields.add(WireJsonField("tool_use_id", wireJsonString(value.callId)))
    fields.add(WireJsonField("content", if (value.isError && errorStyle == LlmWireToolErrorStyle.ContentMarker) { encodeMessagesErrorMarkedContent(value) } else { encodeMessagesToolResult(value) }))
    if (errorStyle == LlmWireToolErrorStyle.NativeField) { fields.add(WireJsonField("is_error", wireJsonBool(value.isError))) }
    wireJsonObject(fields.toArray())
}

func encodeMessagesErrorMarkedContent(value: LlmWireToolResultBlock): JsonNode {
    let output = wireJsonArray([])
    output.add(wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(messagesToolErrorMarker))]))
    for (part in value.content) { match (part) {
        case LlmWireToolResultContent.Text(text) => output.add(wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(text.text))]))
        case LlmWireToolResultContent.Image(image) => output.add(encodeMessagesImage(image))
    } }
    output
}

func encodeMessagesImage(value: LlmWireImageBlock): JsonNode {
    let source = match (value.sourceKind) {
        case LlmWireImageSourceKind.Url => wireJsonObject([WireJsonField("type", wireJsonString("url")), WireJsonField("url", wireJsonString(value.data))])
        case LlmWireImageSourceKind.Base64 => wireJsonObject([WireJsonField("type", wireJsonString("base64")), WireJsonField("media_type", wireJsonString(value.mediaType)), WireJsonField("data", wireJsonString(value.data))])
        case LlmWireImageSourceKind.File => wireJsonObject([WireJsonField("type", wireJsonString("file")), WireJsonField("file_id", wireJsonString(value.data))])
    }
    wireJsonObject([WireJsonField("type", wireJsonString("image")), WireJsonField("source", source)])
}

func toolArgumentsRaw(arguments: LlmWireToolArguments): String {
    match (arguments) {
        case LlmWireToolArguments.Complete(value) => value.stringify()
        case LlmWireToolArguments.InvalidJson(raw) => raw
        case LlmWireToolArguments.InvalidShape(value) => value.stringify()
        case LlmWireToolArguments.Partial(_) => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_partial", "partial tool arguments cannot be encoded")
    }
}

func toolArgumentsObject(arguments: LlmWireToolArguments): JsonNode {
    match (arguments) {
        case LlmWireToolArguments.Complete(value) => if (value.jsonNode().wireKind == WireJsonKind.Object) { value.jsonNode() } else { throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_shape_invalid", "tool arguments must be an object") }
        case LlmWireToolArguments.InvalidShape(_) => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_shape_invalid", "tool arguments must be an object")
        case LlmWireToolArguments.InvalidJson(_) => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_json_invalid", "tool arguments must contain valid JSON")
        case LlmWireToolArguments.Partial(_) => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.tool_arguments_partial", "partial tool arguments cannot be encoded")
    }
}

func roleName(role: LlmWireRole): String { match (role) { case LlmWireRole.User => "user"; case LlmWireRole.Assistant => "assistant" } }
func instructionRoleName(role: LlmWireInstructionRole): String { match (role) { case LlmWireInstructionRole.System => "system"; case LlmWireInstructionRole.Developer => "developer" } }
func imageDetail(value: LlmWireImageDetail): String { match (value) { case LlmWireImageDetail.Auto => "auto"; case LlmWireImageDetail.Low => "low"; case LlmWireImageDetail.High => "high" } }
func imageUrl(value: LlmWireImageBlock): String { match (value.sourceKind) { case LlmWireImageSourceKind.Url => value.data; case LlmWireImageSourceKind.Base64 => "data:" + value.mediaType + ";base64," + value.data; case LlmWireImageSourceKind.File => throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.image_file_shape_invalid", "file images require a provider-native file_id field") } }

func encodeChatImage(codec: LlmWireCodec, value: LlmWireImageBlock): JsonNode {
    match (value.sourceKind) {
        case LlmWireImageSourceKind.File =>
            if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.OpenAiChat) {
                wireJsonObject([
                    WireJsonField("type", wireJsonString("file")),
                    WireJsonField("file", wireJsonObject([WireJsonField("file_id", wireJsonString(value.data))]))
                ])
            } else {
                wireJsonObject([WireJsonField("type", wireJsonString("file")), WireJsonField("file_id", wireJsonString(value.data))])
            }
        case _ => wireJsonObject([WireJsonField("type", wireJsonString("image_url")), WireJsonField("image_url", wireJsonObject([WireJsonField("url", wireJsonString(imageUrl(value))), WireJsonField("detail", wireJsonString(imageDetail(value.detail)))]))])
    }
}

func requestHasFileImage(request: LlmWireRequest): Bool {
    for (message in request.messages) { for (block in message.blocks) { match (block) {
        case LlmWireBlock.Image(value) => if (value.sourceKind == LlmWireImageSourceKind.File) { return true }
        case LlmWireBlock.ToolResult(value) => for (part in value.content) { match (part) {
            case LlmWireToolResultContent.Image(image) => if (image.sourceKind == LlmWireImageSourceKind.File) { return true }
            case _ => ()
        } }
        case _ => ()
    } } }
    false
}

func decodeWireResponse(codec: LlmWireCodec, source: String): LlmWireResponseState {
    let root = wireObject(parseWireJson(source), "provider response", provider: codec.provider)
    match (codec.protocol) {
        case LlmWireProtocol.Responses => decodeResponsesResponse(codec, root)
        case LlmWireProtocol.ChatCompletions => decodeChatResponse(codec, root)
        case LlmWireProtocol.Messages => decodeMessagesResponse(codec, root)
    }
}

func decodeHttpResponse(codec: LlmWireCodec, response: LlmWireHttpResponse, nowEpochMillis: Int64): LlmWireResult<LlmWireResponseState> {
    if (response.statusCode < 100 || response.statusCode > 599) {
        return LlmWireResult.Err(withCodecContext(
            LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.http_status_invalid", "HTTP status must be between 100 and 599"),
            codec, LlmTransportPhase.ResponseHeaders
        ))
    }
    let requestId = responseHeader(response.headers, ["x-request-id", "request-id"])
    let retryAfter: ?Int64 = match (responseHeaderOption(response.headers, "retry-after")) {
        case Some(value) => parseRetryAfterMillis(value, nowEpochMillis)
        case None => None
    }
    let source = try { String.fromUtf8(response.body) } catch (_: Exception) {
        return LlmWireResult.Err(withCodecContext(LlmWireError(
            LlmWireErrorKind.InvalidWire, "llm.response_utf8_invalid", "HTTP response body is not valid UTF-8",
            httpStatus: Some(response.statusCode), providerRequestId: requestId
        ), codec, LlmTransportPhase.WireDecode))
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
        try { return LlmWireResult.Ok(decodeWireResponse(codec, source)) }
        catch (error: LlmWireError) {
            return LlmWireResult.Err(withHttpContext(withCodecContext(error, codec, LlmTransportPhase.WireDecode), response.statusCode, retryAfter, requestId))
        }
    }
    try {
        let decoded = decodeWireResponse(codec, source)
        match (decoded) {
            case LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(failure)) =>
                LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(withHttpFailureContext(failure, response.statusCode, retryAfter, requestId))))
            case _ => LlmWireResult.Ok(httpFailureState(codec, response.statusCode, retryAfter, requestId))
        }
    } catch (_: LlmWireError) {
        LlmWireResult.Ok(httpFailureState(codec, response.statusCode, retryAfter, requestId))
    }
}

func responseHeader(headers: Array<LlmWireHeader>, names: Array<String>): String {
    for (header in headers) { for (name in names where header.name == name) { return header.value } }
    ""
}

func responseHeaderOption(headers: Array<LlmWireHeader>, name: String): ?String {
    for (header in headers where header.name == name) { return Some(header.value) }
    None
}

func httpStatusRetryable(status: Int64): Bool { status == 408 || status == 409 || status == 429 || status >= 500 }

func httpFailureState(codec: LlmWireCodec, status: Int64, retryAfter: ?Int64, requestId: String): LlmWireResponseState {
    LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(LlmWireFailure(
        LlmWireFailureKind.ProviderError, "provider returned HTTP " + status.toString(),
        provider: codec.provider, retryable: httpStatusRetryable(status), httpStatus: Some(status),
        retryAfterMillis: retryAfter, providerRequestId: requestId
    )))
}

func withHttpFailureContext(failure: LlmWireFailure, status: Int64, retryAfter: ?Int64, requestId: String): LlmWireFailure {
    LlmWireFailure(
        failure.kind, failure.message, provider: failure.provider,
        providerErrorCode: failure.providerErrorCode, providerErrorType: failure.providerErrorType,
        retryable: failure.retryable || httpStatusRetryable(status), httpStatus: Some(status),
        retryAfterMillis: retryAfter, providerRequestId: requestId
    )
}

func withHttpContext(error: LlmWireError, status: Int64, retryAfter: ?Int64, requestId: String): LlmWireError {
    LlmWireError(
        error.kind, error.code, error.message, retryable: error.retryable,
        httpStatus: Some(status), retryAfterMillis: retryAfter, provider: error.provider,
        providerErrorCode: error.providerErrorCode, providerErrorType: error.providerErrorType,
        diagnosticJson: error.diagnosticJson, phase: error.phase, protocol: error.protocol,
        dialectId: error.dialectId, eventType: error.eventType, blockIndex: error.blockIndex,
        toolCallId: error.toolCallId, providerRequestId: requestId,
        usage: error.usage
    )
}

func decodeResponsesResponse(codec: LlmWireCodec, root: JsonNode): LlmWireResponseState {
    match (wireOptionalObject(root, "error", provider: codec.provider)) { case Some(error) => return LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(providerFailure(codec, error))); case None => () }
    validateOptionalIdentity(codec, root, "object", "response")
    let status = wireRequiredString(root, "status", provider: codec.provider)
    if (status == "completed" || status == "incomplete") {
        let _ = match (wireOptionalArray(root, "output", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "terminal Responses response is missing output", provider: codec.provider) }
    }
    let reply = responsesReply(codec, root)
    match (status) {
        case "queued" => LlmWireResponseState.Pending(LlmWirePendingReply.Queued(reply))
        case "in_progress" => LlmWireResponseState.Pending(LlmWirePendingReply.InProgress(reply))
        case "completed" => LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply))
        case "incomplete" => LlmWireResponseState.Terminal(LlmWireTerminal.Completed(replyWithChoiceOutcome(
            reply, LlmWireChoiceOutcome.Incomplete(incompleteReason(root))
        )))
        case "failed" => LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(match (wireOptionalObject(root, "error", provider: codec.provider)) { case Some(error) => providerFailure(codec, error); case None => LlmWireFailure(LlmWireFailureKind.ProviderError, "provider response failed", provider: codec.provider) }))
        case "cancelled" => LlmWireResponseState.Terminal(LlmWireTerminal.Cancelled(LlmWireFailure(LlmWireFailureKind.Cancelled, "provider response was cancelled", provider: codec.provider)))
        case _ => throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.responses_status_unsupported", "unknown Responses status: " + status, provider: codec.provider, usage: observedWireUsage(reply.usage))
    }
}

func replyWithChoiceOutcome(reply: LlmWireReply, outcome: LlmWireChoiceOutcome): LlmWireReply {
    LlmWireReply(
        responseId: reply.responseId, model: reply.model, usage: reply.usage,
        rawStopReason: reply.rawStopReason,
        choices: [LlmWireChoice(0, reply.blocks, outcome, rawStopReason: reply.rawStopReason)]
    )
}

func responsesReply(codec: LlmWireCodec, root: JsonNode): LlmWireReply {
    let blocks = ArrayList<LlmWireOutputBlock>()
    match (wireOptionalArray(root, "output", provider: codec.provider)) {
        case Some(items) => for (itemIndex in 0..items.size) {
            let raw = items[itemIndex]
            let item = wireObject(raw, "Responses output item", provider: codec.provider)
            let kind = wireRequiredString(item, "type", provider: codec.provider)
            match (kind) {
                case "message" =>
                    validateOptionalIdentity(codec, item, "role", "assistant")
                    let phase = decodeResponsesPhase(codec, item, itemIndex)
                    match (wireOptionalString(item, "status", provider: codec.provider)) { case Some(value) => if (value != "completed" && value != "incomplete" && value != "in_progress") { invalidWire("llm.responses_message_status_invalid", "Responses message output has an invalid status", provider: codec.provider) }; case None => () }
                    match (wireOptionalArray(item, "content", provider: codec.provider)) {
                    case Some(content) => for (contentIndex in 0..content.size) { decodeResponsesContent(codec, wireObject(content[contentIndex], "Responses content block", provider: codec.provider), blocks, contentIndex, phase) }
                    case None => invalidWire("llm.field_missing", "Responses message output is missing content", provider: codec.provider)
                }
                case "function_call" =>
                    let rawArguments = wireRequiredString(item, "arguments", provider: codec.provider)
                    blocks.add(LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock(wireRequiredString(item, "call_id", provider: codec.provider), wireRequiredString(item, "name", provider: codec.provider), classifyToolArguments(rawArguments))))
                case "reasoning" => blocks.add(LlmWireOutputBlock.NativeReplay(nativeFromNative(codec, item, kind, responsesReasoningDisplay(item, codec.provider), optionalStringOrNone(root, "model", codec.provider), blocks.size)))
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

func decodeResponsesContent(codec: LlmWireCodec, block: JsonNode, output: ArrayList<LlmWireOutputBlock>, blockIndex: Int64, phase: LlmWireOutputPhase): Unit {
    let kind = wireRequiredString(block, "type", provider: codec.provider)
    match (kind) {
        case "output_text" =>
            output.add(LlmWireOutputBlock.Text(LlmWireTextBlock(
                wireRequiredString(block, "text", provider: codec.provider),
                annotations: decodeResponsesAnnotations(codec, block, blockIndex),
                logprobs: decodeTokenLogprobs(codec, block, "logprobs", blockIndex, "response.output_text"),
                phase: phase
            )))
        case "refusal" => output.add(LlmWireOutputBlock.Refusal(LlmWireRefusalBlock(wireRequiredString(block, "refusal", provider: codec.provider))))
        case _ => unsupportedSemantic(codec, kind, block, "llm.responses_block_unsupported", blockIndex: blockIndex)
    }
}

func decodeChatResponse(codec: LlmWireCodec, root: JsonNode): LlmWireResponseState {
    match (wireOptionalObject(root, "error", provider: codec.provider)) { case Some(error) => return LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(providerFailure(codec, error))); case None => () }
    validateOptionalIdentity(codec, root, "object", "chat.completion")
    let choices = match (wireOptionalArray(root, "choices", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Chat response is missing choices", provider: codec.provider) }
    let usage = decodeChatUsage(codec, root)
    let decodedChoices = ArrayList<LlmWireChoice>()
    try {
        var position = 0
        for (choiceNode in choices) {
            let choice = wireObject(choiceNode, "Chat choice", provider: codec.provider)
            let index = wireRequiredInt(choice, "index", provider: codec.provider)
            if (index != position) { invalidWire("llm.chat_choice_index_invalid", "Chat choices must use contiguous indexes in array order", provider: codec.provider) }
            if (wireRequiredString(choice, "finish_reason", provider: codec.provider) == "insufficient_system_resource") {
                return LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(LlmWireFailure(
                    LlmWireFailureKind.InsufficientSystemResource, "provider reported insufficient system resources", provider: codec.provider, retryable: true
                )))
            }
            let decoded = decodeChatChoice(codec, root, choice, index)
            decodedChoices.add(decoded)
            position++
        }
    } catch (error: LlmWireError) {
        throw withObservedUsage(error, observedWireUsage(usage))
    }
    if (decodedChoices.isEmpty()) { invalidWire("llm.chat_choices_empty", "Chat response choices must not be empty", provider: codec.provider, usage: observedWireUsage(usage)) }
    let reply = LlmWireReply(
        responseId: optionalStringOrEmpty(root, "id", codec.provider), model: optionalStringOrEmpty(root, "model", codec.provider),
        usage: usage, rawStopReason: if (decodedChoices.size == 1) { decodedChoices[0].rawStopReason } else { "multiple" },
        choices: decodedChoices.toArray()
    )
    LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply))
}

func decodeChatChoice(codec: LlmWireCodec, root: JsonNode, choice: JsonNode, index: Int64): LlmWireChoice {
    let stop = wireRequiredString(choice, "finish_reason", provider: codec.provider)
    let message = match (wireOptionalObject(choice, "message", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Chat choice is missing message", provider: codec.provider) }
    validateOptionalIdentity(codec, message, "role", "assistant")
    rejectUnsupportedChatSemantic(codec, message, "message")
    let blocks = ArrayList<LlmWireOutputBlock>()
    let choiceLogprobs = match (wireOptionalObject(choice, "logprobs", provider: codec.provider)) { case Some(value) => value; case None => wireJsonObject([]) }
    match (wireOptionalString(message, "content", provider: codec.provider)) {
        case Some(value) => if (value != "") { blocks.add(LlmWireOutputBlock.Text(LlmWireTextBlock(
            value, logprobs: decodeTokenLogprobs(codec, choiceLogprobs, "content", 0, "chat.choice.logprobs")
        ))) }
        case None => ()
    }
    match (wireOptionalString(message, "reasoning_content", provider: codec.provider)) {
        case Some(value) => if (value != "") {
            if (codec.dialect.contract.requestStyle == LlmWireRequestStyle.DeepSeekChat) { blocks.add(LlmWireOutputBlock.NativeReplay(chatReasoningReplay(codec, value, optionalStringOrNone(root, "model", codec.provider), blocks.size))) }
            else { blocks.add(LlmWireOutputBlock.Reasoning(LlmWireReasoningBlock(value))) }
        }
        case None => ()
    }
    match (wireOptionalString(message, "refusal", provider: codec.provider)) {
        case Some(value) => if (value != "") { blocks.add(LlmWireOutputBlock.Refusal(LlmWireRefusalBlock(
            value, logprobs: decodeTokenLogprobs(codec, choiceLogprobs, "refusal", 0, "chat.choice.logprobs")
        ))) }
        case None => ()
    }
    match (wireOptionalArray(message, "tool_calls", provider: codec.provider)) {
        case Some(calls) => for (raw in calls) {
            let call = wireObject(raw, "Chat tool call", provider: codec.provider)
            let callType = wireRequiredString(call, "type", provider: codec.provider)
            if (callType != "function") { unsupportedSemantic(codec, callType, call, "llm.chat_tool_type_unsupported", eventType: "message.tool_calls") }
            let function = match (wireOptionalObject(call, "function", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Chat tool call is missing function", provider: codec.provider) }
            blocks.add(LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock(wireRequiredString(call, "id", provider: codec.provider), wireRequiredString(function, "name", provider: codec.provider), classifyToolArguments(wireRequiredString(function, "arguments", provider: codec.provider)))))
        }
        case None => ()
    }
    let reply = assembleCanonicalReply(
        optionalStringOrEmpty(root, "id", codec.provider), optionalStringOrEmpty(root, "model", codec.provider),
        blocks.toArray(), decodeChatUsage(codec, root), stop,
        requireExecutableToolCalls: stop != "length" && stop != "content_filter"
    )
    if (stop == "stop" || stop == "tool_calls") { validateReplyToolStop(reply, stop, "tool_calls", ["stop"]) }
    match (stop) {
        case "stop" | "tool_calls" => LlmWireChoice(index, reply.blocks, inferChoiceOutcome(stop, reply.blocks), rawStopReason: stop)
        case "function_call" => throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.chat_legacy_function_call_unsupported", "legacy Chat function_call responses are not supported", provider: codec.provider)
        case "length" => LlmWireChoice(index, reply.blocks, LlmWireChoiceOutcome.Incomplete(LlmWireIncompleteReason.Length), rawStopReason: stop)
        case "content_filter" => LlmWireChoice(index, reply.blocks, LlmWireChoiceOutcome.Incomplete(LlmWireIncompleteReason.ContentFilter), rawStopReason: stop)
        case _ => throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.chat_finish_reason_unsupported", "unknown Chat finish reason: " + stop, provider: codec.provider)
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
        return LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(providerFailure(codec, error)))
    }
    validateOptionalIdentity(codec, root, "type", "message")
    validateOptionalIdentity(codec, root, "role", "assistant")
    let content = match (wireOptionalArray(root, "content", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Messages response is missing content", provider: codec.provider) }
    let blocks = ArrayList<LlmWireOutputBlock>()
    let modelConstraint = optionalStringOrNone(root, "model", codec.provider)
    for (blockIndex in 0..content.size) {
        let raw = content[blockIndex]
        let block = wireObject(raw, "Messages content block", provider: codec.provider)
        let kind = wireRequiredString(block, "type", provider: codec.provider)
        match (kind) {
            case "text" =>
                blocks.add(LlmWireOutputBlock.Text(LlmWireTextBlock(
                    wireRequiredString(block, "text", provider: codec.provider),
                    citations: decodeMessagesCitations(codec, block, blockIndex)
                )))
            case "tool_use" =>
                let input = wireRequiredField(block, "input", provider: codec.provider)
                let arguments = if (input.wireKind == WireJsonKind.Object) { LlmWireToolArguments.Complete(LlmWireJson.fromJsonNode(input)) } else { LlmWireToolArguments.InvalidShape(LlmWireJson.fromJsonNode(input)) }
                blocks.add(LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock(wireRequiredString(block, "id", provider: codec.provider), wireRequiredString(block, "name", provider: codec.provider), arguments)))
            case "thinking" => blocks.add(LlmWireOutputBlock.NativeReplay(nativeFromNative(codec, block, kind, wireOptionalString(block, "thinking", provider: codec.provider), modelConstraint, blockIndex)))
            case "redacted_thinking" => blocks.add(LlmWireOutputBlock.NativeReplay(nativeFromNative(codec, block, kind, None, modelConstraint, blockIndex)))
            case _ => unsupportedSemantic(codec, kind, block, "llm.messages_block_unsupported", blockIndex: blockIndex)
        }
    }
    let stop = wireRequiredString(root, "stop_reason", provider: codec.provider)
    let stopRefusal = decodeMessagesStopDetails(codec, root, stop, "message")
    match (stopRefusal) { case Some(value) => blocks.add(LlmWireOutputBlock.Refusal(value)); case None => () }
    let reply = assembleCanonicalReply(
        optionalStringOrEmpty(root, "id", codec.provider), optionalStringOrEmpty(root, "model", codec.provider),
        blocks.toArray(), decodeMessagesUsage(codec, root), stop,
        requireExecutableToolCalls: stop != "max_tokens" && stop != "model_context_window_exceeded" && stop != "pause_turn"
    )
    if (stop == "tool_use" || stop == "end_turn" || stop == "stop_sequence" || stop == "refusal") { validateReplyToolStop(reply, stop, "tool_use", ["end_turn", "stop_sequence", "refusal"]) }
    match (stop) {
        case "end_turn" | "stop_sequence" | "tool_use" => LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply))
        case "refusal" => LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply))
        case "max_tokens" | "model_context_window_exceeded" | "pause_turn" => LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply))
        case _ => throw LlmWireError(LlmWireErrorKind.Unsupported, "llm.messages_stop_reason_unsupported", "unknown Messages stop reason: " + stop, provider: codec.provider)
    }
}

func decodeResponsesPhase(codec: LlmWireCodec, item: JsonNode, blockIndex: Int64): LlmWireOutputPhase {
    match (wireOptionalString(item, "phase", provider: codec.provider)) {
        case Some("analysis") => LlmWireOutputPhase.Analysis
        case Some("commentary") => LlmWireOutputPhase.Commentary
        case Some("final") => LlmWireOutputPhase.Final
        case Some(value) => unsupportedSemantic(codec, "phase:" + value, item["phase"], "llm.responses_semantic_unsupported", blockIndex: blockIndex, eventType: "response.output_item")
        case None => LlmWireOutputPhase.Unspecified
    }
}

// Streaming keeps failing closed until phase is represented in its payload events.
func rejectResponsesItemSemantic(codec: LlmWireCodec, item: JsonNode, blockIndex: Int64): Unit {
    match (wireOptionalString(item, "phase", provider: codec.provider)) {
        case Some(_) => unsupportedSemantic(codec, "phase", item["phase"], "llm.responses_semantic_unsupported", blockIndex: blockIndex, eventType: "response.output_item")
        case None => ()
    }
}

// Streaming keeps failing closed until annotations and logprobs are represented in payload events.
func rejectResponsesContentSemantic(codec: LlmWireCodec, block: JsonNode, blockIndex: Int64, eventType: String): Unit {
    rejectNonEmptySemanticArray(codec, block, "annotations", "llm.responses_semantic_unsupported", blockIndex, eventType)
    rejectNonEmptySemanticArray(codec, block, "logprobs", "llm.responses_semantic_unsupported", blockIndex, eventType)
}

func decodeResponsesAnnotations(codec: LlmWireCodec, block: JsonNode, blockIndex: Int64): Array<LlmWireAnnotation> {
    let output = ArrayList<LlmWireAnnotation>()
    match (wireOptionalArray(block, "annotations", provider: codec.provider)) {
        case None => ()
        case Some(values) => for (raw in values) {
            let value = wireObject(raw, "Responses output annotation", provider: codec.provider)
            let kind = wireRequiredString(value, "type", provider: codec.provider)
            match (kind) {
                case "url_citation" => output.add(LlmWireAnnotation.UrlCitation(LlmWireCitation(
                    LlmWireCitationKind.Url, startIndex: wireOptionalInt(value, "start_index", provider: codec.provider),
                    endIndex: wireOptionalInt(value, "end_index", provider: codec.provider),
                    url: wireRequiredString(value, "url", provider: codec.provider),
                    title: match (wireOptionalString(value, "title", provider: codec.provider)) { case Some(found) => found; case None => "" }
                )))
                case "file_citation" => output.add(LlmWireAnnotation.FileCitation(LlmWireCitation(
                    LlmWireCitationKind.File, startIndex: wireOptionalInt(value, "index", provider: codec.provider),
                    fileId: wireRequiredString(value, "file_id", provider: codec.provider),
                    filename: match (wireOptionalString(value, "filename", provider: codec.provider)) { case Some(found) => found; case None => "" }
                )))
                case _ => unsupportedSemantic(codec, kind, value, "llm.responses_annotation_unsupported", blockIndex: blockIndex, eventType: "response.output_text")
            }
        }
    }
    output.toArray()
}

func decodeTokenLogprobs(codec: LlmWireCodec, value: JsonNode, field: String, blockIndex: Int64, eventType: String): Array<LlmWireTokenLogprob> {
    let _ = blockIndex
    let _ = eventType
    let output = ArrayList<LlmWireTokenLogprob>()
    match (wireOptionalArray(value, field, provider: codec.provider)) {
        case None => ()
        case Some(items) => for (raw in items) {
            let item = wireObject(raw, "token logprob", provider: codec.provider)
            let candidates = ArrayList<LlmWireTokenLogprobCandidate>()
            match (wireOptionalArray(item, "top_logprobs", provider: codec.provider)) {
                case Some(values) => for (candidateRaw in values) {
                    let candidate = wireObject(candidateRaw, "top token logprob", provider: codec.provider)
                    candidates.add(LlmWireTokenLogprobCandidate(
                        wireRequiredString(candidate, "token", provider: codec.provider),
                        numericJsonField(candidate, "logprob", codec.provider), bytes: decodeLogprobBytes(candidate, codec.provider)
                    ))
                }
                case None => ()
            }
            output.add(LlmWireTokenLogprob(
                wireRequiredString(item, "token", provider: codec.provider),
                numericJsonField(item, "logprob", codec.provider), bytes: decodeLogprobBytes(item, codec.provider),
                topLogprobs: candidates.toArray()
            ))
        }
    }
    output.toArray()
}

func numericJsonField(value: JsonNode, name: String, provider: String): LlmWireJson {
    let found = wireRequiredField(value, name, provider: provider)
    if (found.wireKind != WireJsonKind.Number) { invalidWire("llm.field_type_invalid", name + " must be a number", provider: provider) }
    LlmWireJson.fromJsonNode(found)
}

func decodeLogprobBytes(value: JsonNode, provider: String): Array<Int64> {
    let output = ArrayList<Int64>()
    match (wireOptionalArray(value, "bytes", provider: provider)) {
        case Some(items) => for (raw in items) {
            if (raw.wireKind != WireJsonKind.Number) { invalidWire("llm.field_type_invalid", "logprob bytes must contain integers", provider: provider) }
            let byte = try { Int64.parse(raw.number) } catch (_: Exception) { invalidWire("llm.integer_invalid", "logprob byte is not an integer", provider: provider) }
            if (byte < 0 || byte > 255) { invalidWire("llm.logprob_byte_invalid", "logprob byte must be between 0 and 255", provider: provider) }
            output.add(byte)
        }
        case None => ()
    }
    output.toArray()
}

func decodeMessagesCitations(codec: LlmWireCodec, block: JsonNode, blockIndex: Int64): Array<LlmWireCitation> {
    let output = ArrayList<LlmWireCitation>()
    match (wireOptionalArray(block, "citations", provider: codec.provider)) {
        case None => ()
        case Some(items) => for (raw in items) {
            let value = wireObject(raw, "Messages citation", provider: codec.provider)
            output.add(decodeMessagesCitation(codec, value, blockIndex, "message.content"))
        }
    }
    output.toArray()
}

func decodeMessagesCitation(codec: LlmWireCodec, value: JsonNode, blockIndex: Int64, eventType: String): LlmWireCitation {
    let kind = wireRequiredString(value, "type", provider: codec.provider)
    let citedText = wireRequiredString(value, "cited_text", provider: codec.provider)
    match (kind) {
        case "char_location" => LlmWireCitation(
            LlmWireCitationKind.CharacterRange, citedText: citedText,
            documentIndex: Some(wireRequiredInt(value, "document_index", provider: codec.provider)),
            documentTitle: wireRequiredString(value, "document_title", provider: codec.provider),
            startIndex: Some(wireRequiredInt(value, "start_char_index", provider: codec.provider)),
            endIndex: Some(wireRequiredInt(value, "end_char_index", provider: codec.provider)),
            fileId: match (wireOptionalString(value, "file_id", provider: codec.provider)) { case Some(found) => found; case None => "" }
        )
        case "page_location" => LlmWireCitation(
            LlmWireCitationKind.PageRange, citedText: citedText,
            documentIndex: Some(wireRequiredInt(value, "document_index", provider: codec.provider)),
            documentTitle: wireRequiredString(value, "document_title", provider: codec.provider),
            startPage: Some(wireRequiredInt(value, "start_page_number", provider: codec.provider)),
            endPage: Some(wireRequiredInt(value, "end_page_number", provider: codec.provider)),
            fileId: match (wireOptionalString(value, "file_id", provider: codec.provider)) { case Some(found) => found; case None => "" }
        )
        case "content_block_location" => LlmWireCitation(
            LlmWireCitationKind.ContentBlockRange, citedText: citedText,
            documentIndex: Some(wireRequiredInt(value, "document_index", provider: codec.provider)),
            documentTitle: wireRequiredString(value, "document_title", provider: codec.provider),
            startBlock: Some(wireRequiredInt(value, "start_block_index", provider: codec.provider)),
            endBlock: Some(wireRequiredInt(value, "end_block_index", provider: codec.provider)),
            fileId: match (wireOptionalString(value, "file_id", provider: codec.provider)) { case Some(found) => found; case None => "" }
        )
        case "web_search_result_location" => LlmWireCitation(
            LlmWireCitationKind.WebSearchResult, citedText: citedText,
            url: wireRequiredString(value, "url", provider: codec.provider),
            title: wireRequiredString(value, "title", provider: codec.provider)
        )
        case "search_result_location" => LlmWireCitation(
            LlmWireCitationKind.SearchResult, citedText: citedText,
            documentIndex: wireOptionalInt(value, "search_result_index", provider: codec.provider),
            documentTitle: match (wireOptionalString(value, "source", provider: codec.provider)) { case Some(found) => found; case None => "" },
            startBlock: wireOptionalInt(value, "start_block_index", provider: codec.provider),
            endBlock: wireOptionalInt(value, "end_block_index", provider: codec.provider)
        )
        case _ => unsupportedSemantic(codec, kind, value, "llm.messages_citation_unsupported", blockIndex: blockIndex, eventType: eventType)
    }
}

func rejectNonEmptySemanticArray(codec: LlmWireCodec, value: JsonNode, field: String, code: String, blockIndex: Int64, eventType: String): Unit {
    match (wireOptionalArray(value, field, provider: codec.provider)) {
        case Some(items) => if (!items.isEmpty()) { unsupportedSemantic(codec, field, value[field], code, blockIndex: blockIndex, eventType: eventType) }
        case None => ()
    }
}

func decodeMessagesStopDetails(codec: LlmWireCodec, value: JsonNode, stopReason: String, eventType: String): ?LlmWireRefusalBlock {
    match (value.field("stop_details")) {
        case Some(details) =>
            if (details.wireKind == WireJsonKind.Null) {
                if (stopReason == "refusal") { invalidWire("llm.messages_refusal_details_missing", "Messages refusal is missing stop_details", provider: codec.provider) }
                None
            } else {
                let object = wireObject(details, "Messages stop_details", provider: codec.provider)
                let kind = wireRequiredString(object, "type", provider: codec.provider)
                if (stopReason != "refusal" || kind != "refusal") {
                    unsupportedSemantic(codec, kind, object, "llm.messages_stop_details_unsupported", eventType: eventType)
                }
                Some(LlmWireRefusalBlock(
                    "", category: wireOptionalString(object, "category", provider: codec.provider),
                    explanation: wireOptionalString(object, "explanation", provider: codec.provider)
                ))
            }
        case None => if (stopReason == "refusal") {
            invalidWire("llm.messages_refusal_details_missing", "Messages refusal is missing stop_details", provider: codec.provider)
        } else { None }
    }
}

func validateOptionalIdentity(codec: LlmWireCodec, value: JsonNode, field: String, expected: String): Unit {
    match (wireOptionalString(value, field, provider: codec.provider)) {
        case Some(actual) => if (actual != expected) { invalidWire("llm.envelope_identity_mismatch", "provider response identity field " + field + " did not match " + expected, provider: codec.provider) }
        case None => ()
    }
}

func classifyToolArguments(raw: String): LlmWireToolArguments {
    try {
        let value = parseWireJson(raw)
        if (value.wireKind == WireJsonKind.Object) { LlmWireToolArguments.Complete(LlmWireJson.fromJsonNode(value)) }
        else { LlmWireToolArguments.InvalidShape(LlmWireJson.fromJsonNode(value)) }
    } catch (_: LlmWireError) { LlmWireToolArguments.InvalidJson(raw) }
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
            LlmWireUsage(
                inputTokens: wireOptionalUsageInt(usage, "input_tokens", codec.provider), outputTokens: wireOptionalUsageInt(usage, "output_tokens", codec.provider),
                reasoningTokens: wireOptionalUsageInt(outputDetails, "reasoning_tokens", codec.provider), cacheReadTokens: wireOptionalUsageInt(inputDetails, "cached_tokens", codec.provider),
                cacheWriteTokens: wireOptionalUsageInt(inputDetails, "cache_write_tokens", codec.provider), totalTokens: wireOptionalUsageInt(usage, "total_tokens", codec.provider),
                serviceTier: wireOptionalString(root, "service_tier", provider: codec.provider)
            )
    }
}

func decodeChatUsage(codec: LlmWireCodec, root: JsonNode): LlmWireUsage {
    match (wireOptionalObject(root, "usage", provider: codec.provider)) {
        case None => LlmWireUsage()
        case Some(usage) =>
            let inputDetails = match (wireOptionalObject(usage, "prompt_tokens_details", provider: codec.provider)) { case Some(value) => value; case None => wireJsonObject([]) }
            let outputDetails = match (wireOptionalObject(usage, "completion_tokens_details", provider: codec.provider)) { case Some(value) => value; case None => wireJsonObject([]) }
            LlmWireUsage(
                inputTokens: wireOptionalUsageInt(usage, "prompt_tokens", codec.provider), outputTokens: wireOptionalUsageInt(usage, "completion_tokens", codec.provider),
                reasoningTokens: wireOptionalUsageInt(outputDetails, "reasoning_tokens", codec.provider), cacheReadTokens: wireOptionalUsageInt(inputDetails, "cached_tokens", codec.provider),
                cacheWriteTokens: wireOptionalUsageInt(inputDetails, "cache_write_tokens", codec.provider), totalTokens: wireOptionalUsageInt(usage, "total_tokens", codec.provider),
                serviceTier: wireOptionalString(root, "service_tier", provider: codec.provider)
            )
    }
}

func decodeMessagesUsage(codec: LlmWireCodec, root: JsonNode): LlmWireUsage {
    match (wireOptionalObject(root, "usage", provider: codec.provider)) {
        case None => LlmWireUsage()
        case Some(usage) =>
            let serverTools = match (wireOptionalObject(usage, "server_tool_use", provider: codec.provider)) { case Some(value) => value; case None => wireJsonObject([]) }
            LlmWireUsage(
                inputTokens: wireOptionalUsageInt(usage, "input_tokens", codec.provider), outputTokens: wireOptionalUsageInt(usage, "output_tokens", codec.provider),
                cacheReadTokens: wireOptionalUsageInt(usage, "cache_read_input_tokens", codec.provider), cacheWriteTokens: wireOptionalUsageInt(usage, "cache_creation_input_tokens", codec.provider),
                webSearchRequests: wireOptionalUsageInt(serverTools, "web_search_requests", codec.provider), webFetchRequests: wireOptionalUsageInt(serverTools, "web_fetch_requests", codec.provider),
                serviceTier: wireOptionalString(root, "service_tier", provider: codec.provider)
            )
    }
}

func wireOptionalUsageInt(value: JsonNode, name: String, provider: String): ?Int64 {
    match (wireOptionalInt(value, name, provider: provider)) {
        case Some(found) => if (found < 0) { invalidWire("llm.usage_negative", name + " must be non-negative", provider: provider) } else { Some(found) }
        case None => None
    }
}
