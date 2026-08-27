package llm4cj

import std.collection.*
import yjson.*

func encodeWireRequest(codec: LlmWireCodec, request: LlmWireRequest): String {
    match (codec.protocol) {
        case LlmWireProtocol.Responses => encodeResponsesRequest(codec, request)
        case LlmWireProtocol.ChatCompletions => encodeChatRequest(codec, request)
        case LlmWireProtocol.Messages => encodeMessagesRequest(codec, request)
    }
}

func baseRequest(request: LlmWireRequest, tokenField: String): JsonNode {
    let root = wireJsonObject([WireJsonField("model", wireJsonString(request.model))])
    match (request.maxOutputTokens) { case Some(value) => root.put(tokenField, wireJsonNumber(value.toString())); case None => () }
    match (request.streaming) { case Some(value) => root.put("stream", wireJsonBool(value)); case None => () }
    root
}

func addDialectOptions(codec: LlmWireCodec, root: JsonNode, request: LlmWireRequest): Unit {
    for (field in codec.dialect.encodeThinking(request.thinking).fields) { root.put(field.name, field.value) }
    match (request.parallelToolCalls) { case Some(value) => root.put("parallel_tool_calls", wireJsonBool(value)); case None => () }
    match (request.serviceTier) { case Some(value) => root.put("service_tier", wireJsonString(value)); case None => () }
    match (request.toolChoice) {
        case LlmWireToolChoice.ProviderDefault => ()
        case LlmWireToolChoice.Auto => root.put("tool_choice", wireJsonString("auto"))
        case LlmWireToolChoice.NoTools => root.put("tool_choice", wireJsonString("none"))
        case LlmWireToolChoice.Required => root.put("tool_choice", wireJsonString("required"))
    }
    if (let LlmWireCachePolicy.StablePrefix <- request.cachePolicy) {
        match (request.cacheKey) { case Some(value) => root.put("prompt_cache_key", wireJsonString(value)); case None => () }
    }
}

func encodeResponsesRequest(codec: LlmWireCodec, request: LlmWireRequest): String {
    let root = baseRequest(request, "max_output_tokens")
    addDialectOptions(codec, root, request)
    if (request.system != "") { root.put("instructions", wireJsonString(request.system)) }
    match (request.structuredOutput) {
        case Some(spec) => root.put("text", wireJsonObject([WireJsonField("format", responseFormat(spec))]))
        case None => ()
    }
    let input = wireJsonArray([])
    for (message in request.messages) { for (block in message.blocks) {
        match (block) {
            case LlmWireBlock.ToolCall(call) => input.add(wireJsonObject([
                WireJsonField("type", wireJsonString("function_call")),
                WireJsonField("call_id", wireJsonString(call.callId)),
                WireJsonField("name", wireJsonString(call.name)),
                WireJsonField("arguments", wireJsonString(toolArgumentsRaw(call.arguments)))
            ]))
            case LlmWireBlock.ToolResult(result) => input.add(wireJsonObject([
                WireJsonField("type", wireJsonString("function_call_output")),
                WireJsonField("call_id", wireJsonString(result.callId)),
                WireJsonField("output", wireJsonString(result.content))
            ]))
            case LlmWireBlock.Opaque(value) => input.add(value.payload())
            case _ => input.add(wireJsonObject([
                WireJsonField("role", wireJsonString(roleName(message.role))),
                WireJsonField("content", wireJsonArray([encodeResponsesContent(block)]))
            ]))
        }
    } }
    root.put("input", input)
    addResponsesTools(root, request.tools)
    root.stringify()
}

func encodeChatRequest(codec: LlmWireCodec, request: LlmWireRequest): String {
    let root = baseRequest(request, "max_tokens")
    addDialectOptions(codec, root, request)
    match (request.structuredOutput) {
        case Some(spec) => root.put("response_format", wireJsonObject([
            WireJsonField("type", wireJsonString("json_schema")),
            WireJsonField("json_schema", responseFormat(spec))
        ]))
        case None => ()
    }
    let messages = wireJsonArray([])
    if (request.system != "") { messages.add(wireJsonObject([WireJsonField("role", wireJsonString("system")), WireJsonField("content", wireJsonString(request.system))])) }
    for (message in request.messages) { encodeChatMessage(codec, message, messages) }
    root.put("messages", messages)
    addChatTools(root, request.tools)
    root.stringify()
}

func encodeChatMessage(codec: LlmWireCodec, message: LlmWireMessage, output: JsonNode): Unit {
    var containsToolResult = false
    for (block in message.blocks) { if (let LlmWireBlock.ToolResult(_) <- block) { containsToolResult = true } }
    if (containsToolResult) {
        for (block in message.blocks) {
            match (block) {
                case LlmWireBlock.ToolResult(result) => output.add(wireJsonObject([
                    WireJsonField("role", wireJsonString("tool")),
                    WireJsonField("tool_call_id", wireJsonString(result.callId)),
                    WireJsonField("content", wireJsonString(result.content))
                ]))
                case _ => unsupportedRequest("llm.chat_tool_result_mixed", "Chat tool-result messages cannot contain non-result blocks")
            }
        }
        return
    }

    let content = StringBuilder()
    let reasoning = StringBuilder()
    let toolCalls = wireJsonArray([])
    for (block in message.blocks) {
        match (block) {
            case LlmWireBlock.Text(value) => content.append(value.text)
            case LlmWireBlock.Refusal(value) => content.append(value.text)
            case LlmWireBlock.Reasoning(value) =>
                match (codec.dialect.chatReasoningField) {
                    case Some(_) =>
                        if (value.replayDialectId != "" && value.replayDialectId != codec.dialect.compatibilityId) {
                            unsupportedRequest("llm.reasoning_dialect_mismatch", "provider-native reasoning can only be replayed by the same dialect")
                        }
                        reasoning.append(value.text)
                    case None => unsupportedRequest("llm.chat_reasoning_replay_unsupported", "this Chat dialect has no provider-native reasoning replay field")
                }
            case LlmWireBlock.ToolCall(call) => toolCalls.add(wireJsonObject([
                WireJsonField("id", wireJsonString(call.callId)),
                WireJsonField("type", wireJsonString("function")),
                WireJsonField("function", wireJsonObject([
                    WireJsonField("name", wireJsonString(call.name)),
                    WireJsonField("arguments", wireJsonString(toolArgumentsRaw(call.arguments)))
                ]))
            ]))
            case LlmWireBlock.Image(_) => unsupportedRequest("llm.chat_image_unsupported", "Chat image encoding requires a multipart content block")
            case LlmWireBlock.Opaque(_) => unsupportedRequest("llm.chat_opaque_unsupported", "Chat Completions cannot replay opaque native blocks")
            case LlmWireBlock.ToolResult(_) => ()
        }
    }
    let encoded = wireJsonObject([
        WireJsonField("role", wireJsonString(roleName(message.role))),
        WireJsonField("content", wireJsonString(content.toString()))
    ])
    match (codec.dialect.chatReasoningField) {
        case Some(field) => if (reasoning.toString() != "") { encoded.put(field, wireJsonString(reasoning.toString())) }
        case None => ()
    }
    if (!toolCalls.items.isEmpty()) { encoded.put("tool_calls", toolCalls) }
    output.add(encoded)
}

func encodeMessagesRequest(codec: LlmWireCodec, request: LlmWireRequest): String {
    let root = baseRequest(request, "max_tokens")
    for (field in codec.dialect.encodeThinking(request.thinking).fields) { root.put(field.name, field.value) }
    if (request.system != "") { root.put("system", wireJsonString(request.system)) }
    match (request.serviceTier) { case Some(value) => root.put("speed", wireJsonString(value)); case None => () }
    match (request.toolChoice) {
        case LlmWireToolChoice.ProviderDefault => ()
        case LlmWireToolChoice.Auto => root.put("tool_choice", wireJsonObject([WireJsonField("type", wireJsonString("auto"))]))
        case LlmWireToolChoice.NoTools => root.put("tool_choice", wireJsonObject([WireJsonField("type", wireJsonString("none"))]))
        case LlmWireToolChoice.Required => root.put("tool_choice", wireJsonObject([WireJsonField("type", wireJsonString("any"))]))
    }
    match (request.structuredOutput) {
        case Some(spec) =>
            let existing = match (root.field("output_config")) { case Some(value) => value; case None => wireJsonObject([]) }
            existing.put("format", wireJsonObject([WireJsonField("type", wireJsonString("json_schema")), WireJsonField("schema", spec.schema)]))
            root.put("output_config", existing)
        case None => ()
    }
    let messages = wireJsonArray([])
    for (message in request.messages) {
        let content = wireJsonArray([])
        for (block in message.blocks) { content.add(encodeMessagesContent(block)) }
        messages.add(wireJsonObject([WireJsonField("role", wireJsonString(roleName(message.role))), WireJsonField("content", content)]))
    }
    root.put("messages", messages)
    if (!request.tools.isEmpty()) {
        let tools = wireJsonArray([])
        for (tool in request.tools) { tools.add(wireJsonObject([
            WireJsonField("name", wireJsonString(tool.name)), WireJsonField("description", wireJsonString(tool.description)), WireJsonField("input_schema", tool.inputSchema)
        ])) }
        root.put("tools", tools)
    }
    root.stringify()
}

func responseFormat(spec: LlmWireStructuredOutput): JsonNode {
    let value = wireJsonObject([
        WireJsonField("type", wireJsonString("json_schema")), WireJsonField("name", wireJsonString(spec.name)),
        WireJsonField("schema", spec.schema), WireJsonField("strict", wireJsonBool(spec.strict))
    ])
    if (spec.description != "") { value.put("description", wireJsonString(spec.description)) }
    value
}

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
        case LlmWireBlock.Reasoning(value) => wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(value.text))])
        case LlmWireBlock.ToolCall(value) => wireJsonObject([
            WireJsonField("type", wireJsonString("tool_use")), WireJsonField("id", wireJsonString(value.callId)),
            WireJsonField("name", wireJsonString(value.name)), WireJsonField("input", toolArgumentsObject(value.arguments))
        ])
        case LlmWireBlock.ToolResult(value) => wireJsonObject([
            WireJsonField("type", wireJsonString("tool_result")), WireJsonField("tool_use_id", wireJsonString(value.callId)),
            WireJsonField("content", wireJsonString(value.content)), WireJsonField("is_error", wireJsonBool(value.isError))
        ])
        case LlmWireBlock.Refusal(value) => wireJsonObject([WireJsonField("type", wireJsonString("text")), WireJsonField("text", wireJsonString(value.text))])
        case LlmWireBlock.Opaque(value) => value.payload()
    }
}

func toolArgumentsRaw(arguments: LlmWireToolArguments): String {
    match (arguments) {
        case LlmWireToolArguments.Complete(_, raw) => raw
        case LlmWireToolArguments.InvalidJson(raw) => raw
        case LlmWireToolArguments.InvalidShape(_, raw) => raw
        case LlmWireToolArguments.Partial(_) => throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_arguments_partial", "partial tool arguments cannot be encoded")
    }
}

func toolArgumentsObject(arguments: LlmWireToolArguments): JsonNode {
    match (arguments) {
        case LlmWireToolArguments.Complete(value, _) => if (value.wireKind == WireJsonKind.Object) { value } else { throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_arguments_shape_invalid", "tool arguments must be an object") }
        case LlmWireToolArguments.InvalidShape(_, _) => throw LlmTransportError(LlmTransportErrorKind.InvalidRequest, "llm.tool_arguments_shape_invalid", "tool arguments must be an object")
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
        case Some(items) => for (raw in items) {
            let item = wireObject(raw, "Responses output item", provider: codec.provider)
            let kind = wireRequiredString(item, "type", provider: codec.provider)
            match (kind) {
                case "message" => match (wireOptionalArray(item, "content", provider: codec.provider)) {
                    case Some(content) => for (rawBlock in content) { decodeResponsesContent(codec, wireObject(rawBlock, "Responses content block", provider: codec.provider), blocks) }
                    case None => invalidWire("llm.field_missing", "Responses message output is missing content", provider: codec.provider)
                }
                case "function_call" =>
                    let rawArguments = wireRequiredString(item, "arguments", provider: codec.provider)
                    blocks.add(LlmWireBlock.ToolCall(LlmWireToolCallBlock(wireRequiredString(item, "call_id", provider: codec.provider), wireRequiredString(item, "name", provider: codec.provider), classifyToolArguments(rawArguments))))
                case "reasoning" => blocks.add(LlmWireBlock.Opaque(opaqueFromNative(codec, item, kind, responsesReasoningDisplay(item, codec.provider))))
                case _ => blocks.add(LlmWireBlock.Opaque(opaqueFromNative(codec, item, kind, None)))
            }
        }
        case None => ()
    }
    LlmWireReply(
        responseId: optionalStringOrEmpty(root, "id", codec.provider),
        model: optionalStringOrEmpty(root, "model", codec.provider),
        blocks: blocks.toArray(), usage: decodeResponsesUsage(codec, root),
        rawStopReason: wireRequiredString(root, "status", provider: codec.provider)
    )
}

func decodeResponsesContent(codec: LlmWireCodec, block: JsonNode, output: ArrayList<LlmWireBlock>): Unit {
    let kind = wireRequiredString(block, "type", provider: codec.provider)
    match (kind) {
        case "output_text" => output.add(LlmWireBlock.Text(LlmWireTextBlock(wireRequiredString(block, "text", provider: codec.provider))))
        case "refusal" => output.add(LlmWireBlock.Refusal(LlmWireRefusalBlock(wireRequiredString(block, "refusal", provider: codec.provider))))
        case _ => output.add(LlmWireBlock.Opaque(opaqueFromNative(codec, block, kind, None)))
    }
}

func decodeChatResponse(codec: LlmWireCodec, root: JsonNode): LlmWireResponseState {
    match (wireOptionalObject(root, "error", provider: codec.provider)) { case Some(error) => return LlmWireResponseState.Terminal(LlmWireTerminal.Failed(providerFailure(codec, error))); case None => () }
    let choices = match (wireOptionalArray(root, "choices", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Chat response is missing choices", provider: codec.provider) }
    if (choices.isEmpty()) { invalidWire("llm.chat_choices_empty", "Chat response choices must not be empty", provider: codec.provider) }
    let choice = wireObject(choices[0], "Chat choice", provider: codec.provider)
    let message = match (wireOptionalObject(choice, "message", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Chat choice is missing message", provider: codec.provider) }
    let blocks = ArrayList<LlmWireBlock>()
    match (wireOptionalString(message, "content", provider: codec.provider)) { case Some(value) => if (value != "") { blocks.add(LlmWireBlock.Text(LlmWireTextBlock(value))) }; case None => () }
    match (wireOptionalString(message, "reasoning_content", provider: codec.provider)) { case Some(value) => if (value != "") { blocks.add(LlmWireBlock.Reasoning(LlmWireReasoningBlock(value, replayDialectId: codec.dialect.compatibilityId))) }; case None => () }
    match (wireOptionalArray(message, "tool_calls", provider: codec.provider)) {
        case Some(calls) => for (raw in calls) {
            let call = wireObject(raw, "Chat tool call", provider: codec.provider)
            let function = match (wireOptionalObject(call, "function", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Chat tool call is missing function", provider: codec.provider) }
            blocks.add(LlmWireBlock.ToolCall(LlmWireToolCallBlock(wireRequiredString(call, "id", provider: codec.provider), wireRequiredString(function, "name", provider: codec.provider), classifyToolArguments(wireRequiredString(function, "arguments", provider: codec.provider)))))
        }
        case None => ()
    }
    let stop = wireRequiredString(choice, "finish_reason", provider: codec.provider)
    let reply = LlmWireReply(responseId: optionalStringOrEmpty(root, "id", codec.provider), model: optionalStringOrEmpty(root, "model", codec.provider), blocks: blocks.toArray(), usage: decodeChatUsage(codec, root), rawStopReason: stop)
    match (stop) {
        case "stop" | "tool_calls" | "function_call" => LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply))
        case "length" => LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.Length))
        case "content_filter" => LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.ContentFilter))
        case "insufficient_system_resource" => LlmWireResponseState.Terminal(LlmWireTerminal.Failed(LlmWireFailure(LlmWireFailureKind.InsufficientSystemResource, "provider reported insufficient system resources", provider: codec.provider, retryable: true)))
        case _ => throw LlmTransportError(LlmTransportErrorKind.Unsupported, "llm.chat_finish_reason_unsupported", "unknown Chat finish reason: " + stop, provider: codec.provider)
    }
}

func decodeMessagesResponse(codec: LlmWireCodec, root: JsonNode): LlmWireResponseState {
    if (optionalStringOrEmpty(root, "type", codec.provider) == "error") {
        let error = match (root.field("error")) { case Some(value) => value; case None => root }
        return LlmWireResponseState.Terminal(LlmWireTerminal.Failed(providerFailure(codec, error)))
    }
    let content = match (wireOptionalArray(root, "content", provider: codec.provider)) { case Some(value) => value; case None => invalidWire("llm.field_missing", "Messages response is missing content", provider: codec.provider) }
    let blocks = ArrayList<LlmWireBlock>()
    for (raw in content) {
        let block = wireObject(raw, "Messages content block", provider: codec.provider)
        let kind = wireRequiredString(block, "type", provider: codec.provider)
        match (kind) {
            case "text" => blocks.add(LlmWireBlock.Text(LlmWireTextBlock(wireRequiredString(block, "text", provider: codec.provider))))
            case "tool_use" =>
                let input = wireRequiredField(block, "input", provider: codec.provider)
                let rawInput = input.stringify()
                let arguments = if (input.wireKind == WireJsonKind.Object) { LlmWireToolArguments.Complete(input, rawInput) } else { LlmWireToolArguments.InvalidShape(input, rawInput) }
                blocks.add(LlmWireBlock.ToolCall(LlmWireToolCallBlock(wireRequiredString(block, "id", provider: codec.provider), wireRequiredString(block, "name", provider: codec.provider), arguments)))
            case "thinking" => blocks.add(LlmWireBlock.Opaque(opaqueFromNative(codec, block, kind, wireOptionalString(block, "thinking", provider: codec.provider))))
            case "redacted_thinking" => blocks.add(LlmWireBlock.Opaque(opaqueFromNative(codec, block, kind, None)))
            case _ => blocks.add(LlmWireBlock.Opaque(opaqueFromNative(codec, block, kind, None)))
        }
    }
    let stop = wireRequiredString(root, "stop_reason", provider: codec.provider)
    let reply = LlmWireReply(responseId: optionalStringOrEmpty(root, "id", codec.provider), model: optionalStringOrEmpty(root, "model", codec.provider), blocks: blocks.toArray(), usage: decodeMessagesUsage(codec, root), rawStopReason: stop)
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
        if (value.wireKind == WireJsonKind.Object) { LlmWireToolArguments.Complete(value, raw) }
        else { LlmWireToolArguments.InvalidShape(value, raw) }
    } catch (_: LlmTransportError) { LlmWireToolArguments.InvalidJson(raw) }
}

func opaqueFromNative(codec: LlmWireCodec, payload: JsonNode, nativeType: String, display: ?String): LlmWireOpaqueBlock {
    LlmWireOpaqueBlock.fromPayload(codec.protocol, codec.dialect.compatibilityId, nativeType, payload, displayReasoning: display)
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
            LlmWireUsage(inputTokens: wireIntOrZero(usage, "input_tokens", provider: codec.provider), outputTokens: wireIntOrZero(usage, "output_tokens", provider: codec.provider), reasoningTokens: wireIntOrZero(outputDetails, "reasoning_tokens", provider: codec.provider), cacheReadTokens: wireIntOrZero(inputDetails, "cached_tokens", provider: codec.provider), cacheWriteTokens: wireIntOrZero(inputDetails, "cache_write_tokens", provider: codec.provider))
    }
}

func decodeChatUsage(codec: LlmWireCodec, root: JsonNode): LlmWireUsage {
    match (wireOptionalObject(root, "usage", provider: codec.provider)) {
        case None => LlmWireUsage()
        case Some(usage) =>
            let inputDetails = match (wireOptionalObject(usage, "prompt_tokens_details", provider: codec.provider)) { case Some(value) => value; case None => wireJsonObject([]) }
            let outputDetails = match (wireOptionalObject(usage, "completion_tokens_details", provider: codec.provider)) { case Some(value) => value; case None => wireJsonObject([]) }
            LlmWireUsage(inputTokens: wireIntOrZero(usage, "prompt_tokens", provider: codec.provider), outputTokens: wireIntOrZero(usage, "completion_tokens", provider: codec.provider), reasoningTokens: wireIntOrZero(outputDetails, "reasoning_tokens", provider: codec.provider), cacheReadTokens: wireIntOrZero(inputDetails, "cached_tokens", provider: codec.provider), cacheWriteTokens: wireIntOrZero(inputDetails, "cache_write_tokens", provider: codec.provider))
    }
}

func decodeMessagesUsage(codec: LlmWireCodec, root: JsonNode): LlmWireUsage {
    match (wireOptionalObject(root, "usage", provider: codec.provider)) {
        case None => LlmWireUsage()
        case Some(usage) => LlmWireUsage(inputTokens: wireIntOrZero(usage, "input_tokens", provider: codec.provider), outputTokens: wireIntOrZero(usage, "output_tokens", provider: codec.provider), cacheReadTokens: wireIntOrZero(usage, "cache_read_input_tokens", provider: codec.provider), cacheWriteTokens: wireIntOrZero(usage, "cache_creation_input_tokens", provider: codec.provider))
    }
}
