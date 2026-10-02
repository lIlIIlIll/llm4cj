package llm4cj_transcript_probe

import llm4cj.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.io.*

func jsonObject(fields: Array<LlmWireJsonField>): LlmWireJson {
    match (LlmWireJson.object(fields)) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(error) => throw error
    }
}

func jsonNumber(value: ?Int64): LlmWireJson {
    match (value) {
        case None => LlmWireJson.nullValue()
        case Some(number) => match (LlmWireJson.number(number.toString())) {
            case LlmWireResult.Ok(result) => result
            case LlmWireResult.Err(error) => throw error
        }
    }
}

func capabilitiesFor(path: String): LlmWireContextUpdateCapabilities {
    match (path) {
        case "openai-responses" => LlmWireContextUpdateCapabilities(appendSystemInstruction: true, appendDeveloperInstruction: true, toolDeclaration: true)
        case "anthropic-messages" => LlmWireContextUpdateCapabilities(appendSystemInstruction: true, toolActivation: true, toolDeactivation: true, deferredToolPool: true)
        case "kimi-chat" => LlmWireContextUpdateCapabilities(appendSystemInstruction: true, toolDeclaration: true)
        case _ => throw IllegalArgumentException("unknown experiment path")
    }
}

func codecFor(path: String, model: String, endpoint: String): LlmWireCodec {
    let dialectId = match (path) {
        case "openai-responses" => "openai.responses.v1"
        case "anthropic-messages" => "anthropic.messages.v1"
        case "kimi-chat" => "kimi.chat.v1"
        case _ => throw IllegalArgumentException("unknown experiment path")
    }
    let evidenceSource = match (path) {
        case "openai-responses" => "https://developers.openai.com/api/docs/guides/tools-tool-search"
        case "anthropic-messages" => "https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages"
        case _ => "https://platform.kimi.ai/docs/guide/use-dynamic-tool-loading"
    }
    let profile = LlmWireEndpointProfile("cache-experiment.v1", model, dialectId, endpoint, 1,
        capabilitiesFor(path), evidenceSource, "2026-10-02")
    let cacheLifetimes: Array<LlmWirePromptCacheLifetime> = if (path == "kimi-chat") { [] } else { [LlmWirePromptCacheLifetime.ProviderDefault] }
    let capabilities = LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true), cache: LlmWireCacheCapabilities(lifetimes: cacheLifetimes))
    match (path) {
        case "openai-responses" => openAiResponsesCodec(openAiResponsesModelProfile(model, capabilities: capabilities, endpoint: endpoint, endpointProfile: Some(profile)))
        case "anthropic-messages" => anthropicMessagesCodec(anthropicMessagesModelProfile(model, capabilities: capabilities, endpoint: endpoint, endpointProfile: Some(profile)))
        case _ => kimiChatCodec(kimiChatModelProfile(model, capabilities: capabilities, endpoint: endpoint, endpointProfile: Some(profile)))
    }
}

func declaration(name: String, description: String, deferred!: Bool = false): LlmWireToolDeclaration {
    let schema = match (LlmWireJson.parse("{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}")) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(error) => throw error
    }
    LlmWireToolDeclaration(LlmWireTool(name, description, schema), deferred: deferred)
}

func encode(path: String, model: String, endpoint: String, arm: String, seed: String, historyBytes: Int64, cache: String, maxTokens: Int64): Int64 {
    if ((arm != "warm" && arm != "native" && arm != "control") || historyBytes < 16384 || historyBytes > 1048576 || maxTokens < 1 || maxTokens > 512) { return 2 }
    let revision = if (arm == "control") { " changed baseline" } else { " stable baseline" }
    let prefix = "cache experiment " + seed + revision
    let initial = ArrayList<LlmWireToolDeclaration>()
    initial.add(declaration("probe_a", "Unused tool A; " + prefix))
    initial.add(declaration("probe_b", "Unused tool B"))
    let added = declaration("probe_c", "Unused tool C", deferred: path == "anthropic-messages")
    if (path == "anthropic-messages") { initial.add(added) }
    let history = StringBuilder()
    for (index in 0..(historyBytes / 64)) {
        history.append("Context record " + index.toString() + " for trial " + seed + ": preserve the recorded input ordering.\n")
    }
    history.append("Reply with exactly OK. Do not call tools.")
    var transcript = LlmWireTranscript(LlmWireInitialContext(
        instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "Reply briefly. " + prefix)],
        tools: initial.toArray()
    ), items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(history.toString()))]))])
    if (arm != "warm") {
        transcript = transcript.append(if (path == "anthropic-messages") {
            LlmWireInputItem.ToolActivation(added.identity)
        } else { LlmWireInputItem.ToolDeclaration(added) })
    }
    let promptCache = match (cache) {
        case "provider-default" => LlmWirePromptCache.ProviderDefault
        case "automatic-default" => LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault)
        case _ => return 2
    }
    let plan = match (codecFor(path, model, endpoint).encodeRequest(LlmWireRequest(model, transcript,
        maxOutputTokens: Some(maxTokens), promptCache: promptCache, toolChoice: LlmWireToolChoice.NoTools)).materialize()) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(error) => println(jsonObject([LlmWireJsonField("error", LlmWireJson.string(error.code))]).stringify()); return 3
    }
    let body = match (LlmWireJson.parse(String.fromUtf8(plan.body))) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(error) => throw error
    }
    let headers = ArrayList<LlmWireJson>()
    for (header in plan.headers) { headers.add(jsonObject([
        LlmWireJsonField("name", LlmWireJson.string(header.name)), LlmWireJsonField("value", LlmWireJson.string(header.value))
    ])) }
    println(jsonObject([LlmWireJsonField("body", body), LlmWireJsonField("headers", LlmWireJson.array(headers.toArray()))]).stringify())
    0
}

func usageJson(usage: LlmWireUsage): LlmWireJson {
    let source = match (usage.source) {
        case LlmWireUsageSource.Unknown => LlmWireJson.nullValue()
        case LlmWireUsageSource.ProviderReported(provider, dialect) => jsonObject([
            LlmWireJsonField("provider", LlmWireJson.string(provider)), LlmWireJsonField("dialect", LlmWireJson.string(dialect))
        ])
    }
    jsonObject([
        LlmWireJsonField("input_tokens", jsonNumber(usage.inputTokens)),
        LlmWireJsonField("output_tokens", jsonNumber(usage.outputTokens)),
        LlmWireJsonField("cache_read_tokens", jsonNumber(usage.cacheReadTokens)),
        LlmWireJsonField("cache_write_tokens", jsonNumber(usage.cacheWriteTokens)),
        LlmWireJsonField("source", source)
    ])
}

func decoded(outcome: String, usage: ?LlmWireUsage, error!: String = ""): Int64 {
    println(jsonObject([
        LlmWireJsonField("outcome", LlmWireJson.string(outcome)),
        LlmWireJsonField("error", LlmWireJson.string(error)),
        LlmWireJsonField("usage", usageJson(match (usage) { case Some(value) => value; case None => LlmWireUsage() }))
    ]).stringify())
    0
}

func decode(path: String, model: String, endpoint: String, status: Int64, responsePath: String): Int64 {
    let file = File(responsePath, OpenMode.Read)
    let body = readToEnd(file)
    file.close()
    match (codecFor(path, model, endpoint).decodeResponse(LlmWireHttpResponse(status, [], body))) {
        case LlmWireResult.Err(error) => decoded("codec_error", error.usage, error: error.code)
        case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply))) => decoded("completed", Some(reply.usage))
        case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(failure))) => decoded("provider_failed", failure.usage)
        case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.Cancelled(failure))) => decoded("cancelled", failure.usage)
        case LlmWireResult.Ok(LlmWireResponseState.Pending(LlmWirePendingReply.Queued(reply))) => decoded("queued", Some(reply.usage))
        case LlmWireResult.Ok(LlmWireResponseState.Pending(LlmWirePendingReply.InProgress(reply))) => decoded("in_progress", Some(reply.usage))
    }
}

main(args: Array<String>): Int64 {
    try {
        if (args.size == 9 && args[0] == "encode") {
            return encode(args[1], args[2], args[3], args[4], args[5], Int64.parse(args[6]), args[7], Int64.parse(args[8]))
        }
        if (args.size == 6 && args[0] == "decode") {
            return decode(args[1], args[2], args[3], Int64.parse(args[4]), args[5])
        }
        2
    } catch (error: LlmWireError) {
        println(jsonObject([LlmWireJsonField("error", LlmWireJson.string(error.code))]).stringify())
        3
    }
}
