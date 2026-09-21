package llm4cj_provider_probe

import llm4cj.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.io.*
func codecFor(name: String, model!: String = "probe-model"): LlmWireCodec {
    match (name) {
        case "openai-responses" => openAiResponsesCodec(openAiResponsesModelProfile(model, transcriptCapabilities: LlmWireTranscriptCapabilities("openai.responses.v1", "1")))
        case "openai-chat" => openAiChatCodec(openAiChatModelProfile(model, transcriptCapabilities: LlmWireTranscriptCapabilities("openai.chat.v1", "1")))
        case "anthropic-messages" => anthropicMessagesCodec(anthropicMessagesModelProfile(model, transcriptCapabilities: LlmWireTranscriptCapabilities("anthropic.messages.v1", "1")))
        case "deepseek-responses" => deepSeekResponsesCodec(deepSeekResponsesModelProfile(model, transcriptCapabilities: LlmWireTranscriptCapabilities("deepseek.responses.v1", "1")))
        case "deepseek-chat" => deepSeekChatCodec(deepSeekChatModelProfile(model, transcriptCapabilities: LlmWireTranscriptCapabilities("deepseek.chat.v1", "1")))
        case "deepseek-messages" => deepSeekMessagesCodec(deepSeekMessagesModelProfile(model, transcriptCapabilities: LlmWireTranscriptCapabilities("deepseek.messages.v1", "1")))
        case "kimi-chat" => kimiChatCodec(kimiChatModelProfile(model, transcriptCapabilities: LlmWireTranscriptCapabilities("kimi.chat.v1", "1")))
        case _ => throw IllegalArgumentException("unknown dialect")
    }
}

func encode(name: String, model: String, streaming: Bool): Int64 {
    let codec = codecFor(name, model: model)
    let request = LlmWireRequest(
        model,
        LlmWireTranscript(
            LlmWireInitialContext(), items: [LlmWireInputItem.Message(LlmWireMessage(
                LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello"))]
            ))]
        ),
        maxOutputTokens: Some(256)
    )
    let prepared = codec.encodeRequest(request, streaming: streaming)
    let materialized = match (prepared.materialize()) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 3
    }
    let body = match (LlmWireJson.parse(String.fromUtf8(materialized.body))) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 3
    }
    let headers = ArrayList<LlmWireJson>()
    for (header in materialized.headers) {
        let encodedHeader = match (LlmWireJson.object([
            LlmWireJsonField("name", LlmWireJson.string(header.name)),
            LlmWireJsonField("value", LlmWireJson.string(header.value))
        ])) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(_) => return 3
        }
        headers.add(encodedHeader)
    }
    let output = match (LlmWireJson.object([
        LlmWireJsonField("body", body),
        LlmWireJsonField("headers", LlmWireJson.array(headers.toArray()))
    ])) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 3
    }
    println(output.stringify())
    0
}

func decodeStream(name: String, path: String, chunkBytes: Int64): Int64 {
    if (chunkBytes < 1 || chunkBytes > 65536) { return 2 }
    let decoder = codecFor(name).newStreamDecoder(sseLimits: LlmWireSseLimits(
        maxEventBytes: 8388608, maxLineBytes: 1048576, maxBufferedBytes: 16777216,
        maxEventsPerPush: 4096, maxOutputBytesPerPush: 16777216
    ))
    let file = File(path, OpenMode.Read)
    let buffer = Array<Byte>(chunkBytes, repeat: 0)
    while (true) {
        let count = file.read(buffer)
        if (count <= 0) { break }
        let chunk = ArrayList<Byte>()
        for (index in 0..count) { chunk.add(buffer[index]) }
        match (decoder.push(chunk.toArray())) { case LlmWireResult.Ok(_) => (); case LlmWireResult.Err(_) => file.close(); return 4 }
    }
    file.close()
    match (decoder.finish()) {
        case LlmWireResult.Ok(update) => match (update.terminal) {
            case Some(LlmWireTerminal.Completed(_)) => println("ok"); 0
            case Some(LlmWireTerminal.ProviderFailed(_)) | Some(LlmWireTerminal.Cancelled(_)) => 6
            case None => 5
        }
        case LlmWireResult.Err(_) => 5
    }
}

func probeJson(source: String): LlmWireJson {
    match (LlmWireJson.parse(source)) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(error) => throw error
    }
}

func probeNumber(value: Int64): LlmWireJson {
    match (LlmWireJson.number(value.toString())) {
        case LlmWireResult.Ok(result) => result
        case LlmWireResult.Err(error) => throw error
    }
}

func addUsageNumber(fields: ArrayList<LlmWireJsonField>, name: String, value: ?Int64): Unit {
    match (value) {
        case Some(number) => fields.add(LlmWireJsonField(name, probeNumber(number)))
        case None => ()
    }
}

func usageProtocol(value: LlmWireProtocol): String {
    match (value) {
        case LlmWireProtocol.Responses => "responses"
        case LlmWireProtocol.ChatCompletions => "chat_completions"
        case LlmWireProtocol.Messages => "messages"
    }
}

func sourceJson(source: LlmWireUsageSource): LlmWireJson {
    match (LlmWireJson.object([
        LlmWireJsonField("protocol", LlmWireJson.string(usageProtocol(source.protocol))),
        LlmWireJsonField("dialect_id", LlmWireJson.string(source.dialectId)),
        LlmWireJsonField("field_path", LlmWireJson.string(source.fieldPath))
    ])) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(error) => throw error
    }
}

func usageJson(usage: LlmWireUsage): LlmWireJson {
    let fields = ArrayList<LlmWireJsonField>()
    addUsageNumber(fields, "input_tokens", usage.inputTokens)
    addUsageNumber(fields, "output_tokens", usage.outputTokens)
    addUsageNumber(fields, "reasoning_tokens", usage.reasoningTokens)
    addUsageNumber(fields, "cache_read_tokens", usage.cacheReadTokens)
    addUsageNumber(fields, "cache_write_tokens", usage.cacheWriteTokens)
    addUsageNumber(fields, "total_tokens", usage.totalTokens)
    addUsageNumber(fields, "web_search_requests", usage.webSearchRequests)
    addUsageNumber(fields, "web_fetch_requests", usage.webFetchRequests)
    match (usage.serviceTier) { case Some(value) => fields.add(LlmWireJsonField("service_tier", LlmWireJson.string(value))); case None => () }
    match (usage.cacheReadSource) { case Some(value) => fields.add(LlmWireJsonField("cache_read_source", sourceJson(value))); case None => () }
    match (usage.cacheWriteSource) { case Some(value) => fields.add(LlmWireJsonField("cache_write_source", sourceJson(value))); case None => () }
    match (LlmWireJson.object(fields.toArray())) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(error) => throw error
    }
}

func stateUsage(state: LlmWireResponseState): ?LlmWireUsage {
    match (state) {
        case LlmWireResponseState.Pending(value) => match (value) {
            case LlmWirePendingReply.Queued(reply) => Some(reply.usage)
            case LlmWirePendingReply.InProgress(reply) => Some(reply.usage)
        }
        case LlmWireResponseState.Terminal(value) => match (value) {
            case LlmWireTerminal.Completed(reply) => Some(reply.usage)
            case LlmWireTerminal.ProviderFailed(failure) => failure.usage
            case LlmWireTerminal.Cancelled(failure) => failure.usage
        }
    }
}

func printDecodedUsage(state: LlmWireResponseState): Int64 {
    let fields = ArrayList<LlmWireJsonField>()
    match (state) {
        case LlmWireResponseState.Pending(_) => fields.add(LlmWireJsonField("terminal", LlmWireJson.string("pending")))
        case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(_)) => fields.add(LlmWireJsonField("terminal", LlmWireJson.string("completed")))
        case LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(_)) => fields.add(LlmWireJsonField("terminal", LlmWireJson.string("provider_failed")))
        case LlmWireResponseState.Terminal(LlmWireTerminal.Cancelled(_)) => fields.add(LlmWireJsonField("terminal", LlmWireJson.string("cancelled")))
    }
    match (stateUsage(state)) {
        case Some(value) => fields.add(LlmWireJsonField("usage", usageJson(value)))
        case None => fields.add(LlmWireJsonField("usage", LlmWireJson.nullValue()))
    }
    match (LlmWireJson.object(fields.toArray())) {
        case LlmWireResult.Ok(value) => println(value.stringify()); 0
        case LlmWireResult.Err(_) => 3
    }
}

func decodeResponseUsage(name: String, model: String, path: String): Int64 {
    let file = File(path, OpenMode.Read)
    let source = String.fromUtf8(readToEnd(file))
    file.close()
    match (codecFor(name, model: model).decodeResponse(LlmWireHttpResponse(200, [], source.toArray()))) {
        case LlmWireResult.Ok(value) => printDecodedUsage(value)
        case LlmWireResult.Err(error) => println(error.code); 4
    }
}

func probeTool(name: String, description: String): LlmWireTool {
    LlmWireTool(name, "v1", description, probeJson("{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}}}"))
}

func probeCapabilities(): LlmWireCapabilities {
    LlmWireCapabilities(
        tools: LlmWireToolCapabilities(enabled: true),
        cache: LlmWireCacheCapabilities(lifetimes: [LlmWirePromptCacheLifetime.FiveMinutes])
    )
}

func dynamicTranscriptCapabilities(dialect: String): LlmWireTranscriptCapabilities {
    match (dialect) {
        case "openai-responses" => LlmWireTranscriptCapabilities("openai.responses.v1", "1", entries: [
            LlmWireTranscriptCapability(LlmWireTranscriptOperation.InstructionUpdate, LlmWireTranscriptEncoding.OpenAiDeveloperInput),
            LlmWireTranscriptCapability(LlmWireTranscriptOperation.ToolDeclaration, LlmWireTranscriptEncoding.OpenAiAdditionalTools),
            LlmWireTranscriptCapability(LlmWireTranscriptOperation.ToolActivation, LlmWireTranscriptEncoding.OpenAiAdditionalTools)
        ])
        case "anthropic-messages" => LlmWireTranscriptCapabilities("anthropic.messages.v1", "1", entries: [
            LlmWireTranscriptCapability(LlmWireTranscriptOperation.InstructionUpdate, LlmWireTranscriptEncoding.AnthropicSystemText),
            LlmWireTranscriptCapability(LlmWireTranscriptOperation.ToolActivation, LlmWireTranscriptEncoding.AnthropicToolReference),
            LlmWireTranscriptCapability(LlmWireTranscriptOperation.ToolDeactivation, LlmWireTranscriptEncoding.AnthropicToolReference)
        ])
        case "kimi-chat" => LlmWireTranscriptCapabilities("kimi.chat.v1", "1", entries: [
            LlmWireTranscriptCapability(LlmWireTranscriptOperation.InstructionUpdate, LlmWireTranscriptEncoding.KimiSystemText),
            LlmWireTranscriptCapability(LlmWireTranscriptOperation.ToolDeclaration, LlmWireTranscriptEncoding.KimiSystemTools),
            LlmWireTranscriptCapability(LlmWireTranscriptOperation.ToolActivation, LlmWireTranscriptEncoding.KimiSystemTools)
        ])
        case _ => throw IllegalArgumentException("unknown dynamic transcript dialect")
    }
}

func printPrepared(codec: LlmWireCodec, request: LlmWireRequest): Int64 {
    let prepared = codec.encodeRequest(request)
    let materialized = match (prepared.materialize()) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 3
    }
    let body = match (LlmWireJson.parse(String.fromUtf8(materialized.body))) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 3
    }
    let headers = ArrayList<LlmWireJson>()
    for (header in materialized.headers) {
        let encodedHeader = match (LlmWireJson.object([
            LlmWireJsonField("name", LlmWireJson.string(header.name)),
            LlmWireJsonField("value", LlmWireJson.string(header.value))
        ])) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(_) => return 3
        }
        headers.add(encodedHeader)
    }
    let output = match (LlmWireJson.object([
        LlmWireJsonField("body", body),
        LlmWireJsonField("headers", LlmWireJson.array(headers.toArray()))
    ])) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 3
    }
    println(output.stringify())
    0
}

func openAiTranscriptRequest(model: String, prompt!: String = "find"): LlmWireRequest {
    let search = probeTool("search", "find information")
    LlmWireRequest(model, LlmWireTranscript(
        LlmWireInitialContext(tools: [LlmWireToolDeclaration(search, visibility: LlmWireToolVisibility.Deferred)]), items: [
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(prompt))])),
            LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.Developer, "be concise")),
            LlmWireInputItem.ToolActivation(LlmWireToolRef("search", "v1")),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("call-1", "search", LlmWireToolArguments.Complete(probeJson("{}"))))])),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(LlmWireToolResultBlock("call-1", [LlmWireToolResultContent.Text(LlmWireTextBlock("found"))]))]))
        ]
    ), maxOutputTokens: Some(64))
}

func anthropicTranscriptRequest(model: String, prompt!: String = "start"): LlmWireRequest {
    let lookup = probeTool("lookup", "find a value")
    LlmWireRequest(model, LlmWireTranscript(
        LlmWireInitialContext(tools: [LlmWireToolDeclaration(lookup, visibility: LlmWireToolVisibility.Deferred)]), items: [
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(prompt))])),
            LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.System, "new system")),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(LlmWireTextBlock("answer"))])),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("activate"))])),
            LlmWireInputItem.ToolActivation(LlmWireToolRef("lookup", "v1")),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(LlmWireTextBlock("tool-ready"))])),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("deactivate"))])),
            LlmWireInputItem.ToolDeactivation(LlmWireToolRef("lookup", "v1"))
        ]
    ), maxOutputTokens: Some(64))
}

func kimiTranscriptRequest(model: String, prompt!: String = "start"): LlmWireRequest {
    let lookup = probeTool("lookup", "find a value")
    let fetch = probeTool("fetch", "fetch a value")
    LlmWireRequest(model, LlmWireTranscript(
        LlmWireInitialContext(tools: [LlmWireToolDeclaration(lookup)]), items: [
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(prompt))])),
            LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.System, "updated")),
            LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(fetch)),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("call-1", "fetch", LlmWireToolArguments.Complete(probeJson("{}"))))])),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(LlmWireToolResultBlock("call-1", [LlmWireToolResultContent.Text(LlmWireTextBlock("done"))]))]))
        ]
    ), maxOutputTokens: Some(64))
}

func encodeTranscriptFixture(name: String, model: String, prompt!: String = ""): Int64 {
    let effectivePrompt = if (prompt == "") {
        match (name) {
            case "openai-responses-additional-tools" => "find"
            case _ => "start"
        }
    } else { prompt }
    match (name) {
        case "openai-responses-additional-tools" => printPrepared(openAiResponsesCodec(openAiResponsesModelProfile(model, transcriptCapabilities: dynamicTranscriptCapabilities("openai-responses"), capabilities: probeCapabilities())), openAiTranscriptRequest(model, prompt: effectivePrompt))
        case "anthropic-messages-tool-changes" => printPrepared(anthropicMessagesCodec(anthropicMessagesModelProfile(model, transcriptCapabilities: dynamicTranscriptCapabilities("anthropic-messages"), capabilities: probeCapabilities())), anthropicTranscriptRequest(model, prompt: effectivePrompt))
        case "kimi-chat-dynamic-tools" => printPrepared(kimiChatCodec(kimiChatModelProfile(model, transcriptCapabilities: dynamicTranscriptCapabilities("kimi-chat"), capabilities: probeCapabilities())), kimiTranscriptRequest(model, prompt: effectivePrompt))
        case _ => 2
    }
}

func printExpectedError(codec: LlmWireCodec, request: LlmWireRequest): Int64 {
    try {
        let _ = codec.encodeRequest(request)
        println("llm.no_error")
        1
    } catch (error: LlmWireError) {
        println(error.code)
        0
    }
}

func kimiMisplacedRequest(model: String): LlmWireRequest {
    let tool = probeTool("lookup", "find a value")
    LlmWireRequest(model, LlmWireTranscript(LlmWireInitialContext(tools: [LlmWireToolDeclaration(tool)]), items: [
        LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(LlmWireTextBlock("bad"))])),
        LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(probeTool("fetch", "fetch a value")))
    ]), maxOutputTokens: Some(64))
}

func negativeTranscriptFixture(name: String, model: String): Int64 {
    match (name) {
        case "openai-responses-unverified" => printExpectedError(openAiResponsesCodec(openAiResponsesModelProfile(model, transcriptCapabilities: LlmWireTranscriptCapabilities("openai.responses.v1", "1"), capabilities: probeCapabilities())), openAiTranscriptRequest(model))
        case "anthropic-messages-cache-with-changes" => printExpectedError(anthropicMessagesCodec(anthropicMessagesModelProfile(model, transcriptCapabilities: dynamicTranscriptCapabilities("anthropic-messages"), capabilities: probeCapabilities())), LlmWireRequest(model, anthropicTranscriptRequest(model).transcript, maxOutputTokens: Some(64), promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.FiveMinutes)))
        case "kimi-chat-misplaced-update" => printExpectedError(kimiChatCodec(kimiChatModelProfile(model, transcriptCapabilities: dynamicTranscriptCapabilities("kimi-chat"), capabilities: probeCapabilities())), kimiMisplacedRequest(model))
        case _ => 2
    }
}

main(args: Array<String>): Int64 {
    if (args.size < 3) { return 2 }
    match (args[0]) {
        case "encode" => encode(args[1], args[2], true)
        case "encode-fixture" => encode(args[1], args[2], false)
        case "encode-transcript-fixture" => if (args.size == 4) { encodeTranscriptFixture(args[1], args[2], prompt: args[3]) } else { encodeTranscriptFixture(args[1], args[2]) }
        case "negative-transcript-fixture" => negativeTranscriptFixture(args[1], args[2])
        case "decode-response-usage" => if (args.size == 4) { decodeResponseUsage(args[1], args[2], args[3]) } else { 2 }
        case "decode-stream" => if (args.size == 4) { decodeStream(args[1], args[2], Int64.parse(args[3])) } else { 2 }
        case _ => 2
}
}
