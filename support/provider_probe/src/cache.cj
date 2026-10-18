package llm4cj_provider_probe

import llm4cj.*
import llm4cj.experimental.*
import std.collection.*

func cacheFixtureTool(name: String, deferred!: Bool = false): LlmWireToolDeclaration {
    LlmWireToolDeclaration(LlmWireTool(name, "Tool " + name, jp("{\"type\":\"object\",\"properties\":{}}")), deferred: deferred)
}

func cacheFixtureCodec(name: String): LlmWireCodec {
    let capabilities = LlmWireCapabilities(
        input: LlmWireInputCapabilities(modalities: [LlmWireInputModality.Text, LlmWireInputModality.Image]),
        tools: LlmWireToolCapabilities(enabled: true),
        cache: LlmWireCacheCapabilities(lifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.FiveMinutes, LlmWirePromptCacheLifetime.OneHour],
            explicitBreakpoints: name != "missing-capability"))
    if (name == "deepseek-rejected") { return deepSeekMessagesCodec(deepSeekMessagesModelProfile("fixture-model", capabilities: capabilities)) }
    if (name == "spoof-rejected") {
        return customDialectCodec(LlmWireProtocol.Messages, LlmWireStandardDialect(LlmWireDialectContract(
            "fixture.cache.spoof", LlmWireProtocol.Messages, LlmWireRequestStyle.AnthropicMessages, LlmWireOutputTokenField.MaxTokens,
            promptCacheStyle: LlmWirePromptCacheStyle.Anthropic, promptCacheLifetimes: [LlmWirePromptCacheLifetime.FiveMinutes])),
            capabilities: capabilities)
    }
    let endpoint = LlmWireEndpointProfile("fixture.cache", "fixture-model", "anthropic.messages.v1", "https://example.test/v1/messages", 1,
        LlmWireContextUpdateCapabilities(appendSystemInstruction: true, toolActivation: true, toolDeactivation: true, deferredToolPool: true),
        "https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages", "2026-10-18")
    anthropicMessagesCodec(anthropicMessagesModelProfile("fixture-model", capabilities: capabilities,
        endpoint: endpoint.endpoint, endpointProfile: Some(endpoint)))
}

func cacheFixture(name: String): LlmWireTranscript {
    let items = ArrayList<LlmWireInputItem>()
    items.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [
        LlmWireBlock.Text(LlmWireTextBlock("one")), LlmWireBlock.Text(LlmWireTextBlock("two")),
        LlmWireBlock.Text(LlmWireTextBlock("three")), LlmWireBlock.Text(LlmWireTextBlock("four"))])))
    var context = LlmWireInitialContext()
    var points: Array<LlmWireCacheBreakpoint> = [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0))]
    match (name) {
        case "no-markers" => points = []
        case "marker-five" | "missing-capability" | "deepseek-rejected" | "spoof-rejected" => ()
        case "marker-hour" => points = [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0), lifetime: LlmWirePromptCacheLifetime.OneHour)]
        case "marker-moved" => points = [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 1))]
        case "second-tool-target" =>
            context = LlmWireInitialContext(tools: [cacheFixtureTool("A"), cacheFixtureTool("B")])
            points = [LlmWireCacheBreakpoint(LlmWireCachePosition.InitialTool(1))]
        case "custom-target-rejected" | "custom-neighbor-rejected" =>
            let custom = LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("emit")))
            let function = cacheFixtureTool("A")
            context = LlmWireInitialContext(tools: if (name == "custom-target-rejected") { [function, custom] } else { [custom, function] })
            points = [LlmWireCacheBreakpoint(LlmWireCachePosition.InitialTool(1))]
        case "four-locations" =>
            context = LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "system")], tools: [cacheFixtureTool("A")])
            items.add(LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.System, "update")))
            points = [
                LlmWireCacheBreakpoint(LlmWireCachePosition.Item(1)),
                LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 1)),
                LlmWireCacheBreakpoint(LlmWireCachePosition.InitialInstruction(0), lifetime: LlmWirePromptCacheLifetime.OneHour),
                LlmWireCacheBreakpoint(LlmWireCachePosition.InitialTool(0), lifetime: LlmWirePromptCacheLifetime.OneHour)]
        case "automatic-three" => points = [0, 1, 3].map({ index: Int64 => LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, index)) })
        case "automatic-four" => points = [0, 1, 2, 3].map({ index: Int64 => LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, index)) })
        case "ttl-order" => points = [points[0], LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 1), lifetime: LlmWirePromptCacheLifetime.OneHour)]
        case "ttl-conflict" => points = [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 3), lifetime: LlmWirePromptCacheLifetime.OneHour)]
        case "deferred-target" =>
            context = LlmWireInitialContext(tools: [cacheFixtureTool("A", deferred: true)])
            points = [LlmWireCacheBreakpoint(LlmWireCachePosition.InitialTool(0))]
        case "duplicate-target" => points = [points[0], points[0]]
        case "out-of-bounds" => points = [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 99))]
        case "image-target" =>
            return LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [
                LlmWireBlock.Text(LlmWireTextBlock("image")),
                LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Base64, "YWJj", mediaType: "image/png"))]))],
                cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 1))])
        case "tool-lifecycle" =>
            context = LlmWireInitialContext(tools: [cacheFixtureTool("A"), cacheFixtureTool("B", deferred: true)])
            return LlmWireTranscript(context, items: [
                LlmWireInputItem.Message(userMessage("request")),
                LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity("B")),
                LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("call-B", "B", LlmWireToolArguments.Complete(jp("{}"))))])),
                LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(LlmWireToolResultBlock("call-B", [LlmWireToolResultContent.Text(LlmWireTextBlock("done"))]))])),
                LlmWireInputItem.ToolDeactivation(LlmWireToolDefinitionIdentity("B"))],
                cacheBreakpoints: [
                    LlmWireCacheBreakpoint(LlmWireCachePosition.Item(1), lifetime: LlmWirePromptCacheLifetime.OneHour),
                    LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(2, 0), lifetime: LlmWirePromptCacheLifetime.OneHour),
                    LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(3, 0)),
                    LlmWireCacheBreakpoint(LlmWireCachePosition.Item(4))])
        case _ => throw IllegalArgumentException("unknown cache fixture")
    }
    LlmWireTranscript(context, items: items.toArray(), cacheBreakpoints: points)
}

func inspectCache(name: String, mode: String): Int64 {
    if (mode != "direct" && mode != "restored" && mode != "builder") { return 2 }
    try {
        var transcript = cacheFixture(name)
        if (mode == "restored") { transcript = probeValue(LlmWireTranscript.restore(probeValue(transcript.snapshot()))) }
        let codec = cacheFixtureCodec(name)
        let automatic = name == "automatic-three" || name == "automatic-four" || name == "ttl-conflict"
        let cache = if (automatic) { LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.FiveMinutes) } else { LlmWirePromptCache.ProviderDefault }
        let request = if (mode == "builder") {
            let builder = codec.newRequestBuilder(model: "fixture-model")
            builder.setTranscript(transcript); builder.setMaxOutputTokens(Some(32)); builder.setPromptCache(cache)
            probeValue(builder.build())
        } else { LlmWireRequest("fixture-model", transcript, maxOutputTokens: Some(32), promptCache: cache) }
        let prepared = codec.encodeRequest(request)
        let materialized = probeValue(prepared.materialize())
        let headers = ArrayList<LlmWireJson>()
        for (header in materialized.headers) { headers.add(jo([jf("name", js(header.name)), jf("value", js(header.value))])) }
        let snapshot = jp(probeValue(transcript.snapshot()))
        let points = match (snapshot.field("cache_breakpoints")) { case Some(value) => value; case None => ja([]) }
        println(jo([jf("kind", js("request")), jf("body", jp(String.fromUtf8(materialized.body))),
            jf("headers", ja(headers.toArray())), jf("snapshot_version", snapshot.field("version").getOrThrow()),
            jf("cache_breakpoints", points)]).stringify())
    } catch (error: LlmWireError) { println(jo([jf("kind", js("error")), jf("error", errorJson(error))]).stringify()) }
    0
}
