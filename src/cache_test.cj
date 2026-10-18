package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

func cacheTestCodec(explicit!: Bool = true): LlmWireCodec {
    let endpoint = nativeFixtureEndpoint(LlmWireContextUpdateStyle.AnthropicToolReferences)
    let capabilities = LlmWireCapabilities(
        input: LlmWireInputCapabilities(modalities: [LlmWireInputModality.Text, LlmWireInputModality.Image]),
        tools: LlmWireToolCapabilities(enabled: true),
        cache: LlmWireCacheCapabilities(lifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.FiveMinutes, LlmWirePromptCacheLifetime.OneHour], explicitBreakpoints: explicit))
    anthropicMessagesCodec(anthropicMessagesModelProfile(endpoint.model, capabilities: capabilities, endpoint: endpoint.endpoint, endpointProfile: Some(endpoint)))
}

func cacheTestItems(): Array<LlmWireInputItem> {
    [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [
        LlmWireBlock.Text(LlmWireTextBlock("one")), LlmWireBlock.Text(LlmWireTextBlock("two")),
        LlmWireBlock.Text(LlmWireTextBlock("three")), LlmWireBlock.Text(LlmWireTextBlock("four"))]))]
}

func cacheTestEncode(transcript: LlmWireTranscript, automatic!: LlmWirePromptCache = LlmWirePromptCache.ProviderDefault): String {
    let codec = cacheTestCodec()
    codec.encodeRequest(LlmWireRequest(codec.modelProfile.getOrThrow().model, transcript, maxOutputTokens: Some(32), promptCache: automatic)).bodyText()
}

@Test
class CacheBreakpointTests {
    @TestCase
    func emptyMetadataKeepsLegacyConstructionAndSnapshot() {
        let _ = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, []))])
        let old = LlmWireTranscript(items: cacheTestItems())
        let snapshot = nativeResult(old.snapshot())
        @Expect(parseWireJson(snapshot)["version"].numberText, "2")
        @Expect(parseWireJson(snapshot).field("cache_breakpoints").isNone(), true)
        @Expect(snapshot, nativeResult(nativeResult(LlmWireTranscript.restore(snapshot)).snapshot()))
    }

    @TestCase
    func positionsRejectNegativeOutOfBoundsWrongKindsAndDuplicates() {
        for (position in [LlmWireCachePosition.InitialTool(-1), LlmWireCachePosition.InitialInstruction(-1),
            LlmWireCachePosition.Item(-1), LlmWireCachePosition.MessageBlock(0, -1)]) {
            expectLlmError("llm.cache_position_invalid", { => let _ = LlmWireCacheBreakpoint(position) })
        }
        for (position in [LlmWireCachePosition.InitialTool(0), LlmWireCachePosition.InitialInstruction(0),
            LlmWireCachePosition.Item(1), LlmWireCachePosition.MessageBlock(0, 4)]) {
            expectLlmError("llm.cache_position_invalid", { => let _ = LlmWireTranscript(items: cacheTestItems(), cacheBreakpoints: [LlmWireCacheBreakpoint(position)]) })
        }
        expectLlmError("llm.cache_position_invalid", { =>
            let _ = LlmWireTranscript(items: [LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.System, "update"))],
                cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0))])
        })
        let point = LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0))
        expectLlmError("llm.cache_position_duplicate", { => let _ = LlmWireTranscript(items: cacheTestItems(), cacheBreakpoints: [
            point, LlmWireCacheBreakpoint(point.position, lifetime: LlmWirePromptCacheLifetime.OneHour)]) })
        expectLlmError("llm.cache_breakpoint_limit", { => let _ = LlmWireTranscript(items: cacheTestItems(), cacheBreakpoints: [point, point, point, point, point]) })
    }

    @TestCase
    func exactLocationsFollowProviderPrefixRatherThanMetadataOrder() {
        let transcript = LlmWireTranscript(LlmWireInitialContext(
            instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "system")],
            tools: [LlmWireToolDeclaration(nativeFixtureTool("A"))]),
            items: [cacheTestItems()[0], LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.System, "update"))],
            cacheBreakpoints: [
                LlmWireCacheBreakpoint(LlmWireCachePosition.Item(1)),
                LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 1)),
                LlmWireCacheBreakpoint(LlmWireCachePosition.InitialInstruction(0), lifetime: LlmWirePromptCacheLifetime.OneHour),
                LlmWireCacheBreakpoint(LlmWireCachePosition.InitialTool(0), lifetime: LlmWirePromptCacheLifetime.OneHour)])
        let body = parseWireJson(cacheTestEncode(transcript))
        let expected = parseWireJson("""
            {"model":"claude-opus-5-5","max_tokens":32,
             "tools":[{"name":"A","description":"Tool A","input_schema":{"type":"object","properties":{}},"cache_control":{"type":"ephemeral","ttl":"1h"}}],
             "system":[{"type":"text","text":"system","cache_control":{"type":"ephemeral","ttl":"1h"}}],
             "messages":[{"role":"user","content":[{"type":"text","text":"one"},{"type":"text","text":"two","cache_control":{"type":"ephemeral","ttl":"5m"}},{"type":"text","text":"three"},{"type":"text","text":"four"}]},
                         {"role":"system","content":[{"type":"text","text":"update","cache_control":{"type":"ephemeral","ttl":"5m"}}]}]}
            """)
        @Expect(canonicalToolSchema(body), canonicalToolSchema(expected))
        let restored = nativeResult(LlmWireTranscript.restore(nativeResult(transcript.snapshot())))
        @Expect(cacheTestEncode(restored), cacheTestEncode(transcript))
    }

    @TestCase
    func taggedToolsKeepOriginalCachePositionsAndUnsupportedCustomErrors() {
        let function = LlmWireToolDeclaration(nativeFixtureTool("A"))
        let custom = LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("emit")))
        let point = LlmWireCacheBreakpoint(LlmWireCachePosition.InitialTool(1))
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [function, LlmWireToolDeclaration(nativeFixtureTool("B"))]),
            items: cacheTestItems(), cacheBreakpoints: [point])
        let body = nativeResult(LlmWireJson.parse(cacheTestEncode(transcript)))
        let tools = body.field("tools").getOrThrow().values()
        @Expect(tools[0].field("name").getOrThrow().stringValue(), Some("A"))
        @Expect(tools[0].field("cache_control").isNone(), true)
        @Expect(tools[1].field("name").getOrThrow().stringValue(), Some("B"))
        @Expect(tools[1].field("cache_control").getOrThrow().field("ttl").getOrThrow().stringValue(), Some("5m"))
        for (declarations in [[function, custom], [custom, function]]) {
            let mixed = LlmWireTranscript(LlmWireInitialContext(tools: declarations), items: cacheTestItems(), cacheBreakpoints: [point])
            let restored = nativeResult(LlmWireTranscript.restore(nativeResult(mixed.snapshot())))
            @Expect(restored.cacheBreakpoints[0].position, LlmWireCachePosition.InitialTool(1))
            for (value in [mixed, restored]) {
                try {
                    let _ = cacheTestEncode(value)
                    @Fail("Anthropic cannot represent an OpenAI custom tool")
                } catch (error: LlmWireError) {
                    @Expect(error.kind, LlmWireErrorKind.Unsupported)
                    @Expect(error.code, "llm.custom_tool_format_unsupported")
                    @Expect(error.toolName, "emit")
                }
            }
        }
    }

    @TestCase
    func snapshotV3PreservesCustomInputsAndCacheMetadataTogether() {
        let declaration = LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("emit")))
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [declaration]), items: [
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("request"))])),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("raw-id", "emit", LlmWireToolArguments.Text("not { JSON")))])),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(LlmWireToolResultBlock("raw-id", [
                LlmWireToolResultContent.Text(LlmWireTextBlock("done"))], kind: LlmWireToolKind.Custom))]))],
            cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0))])
        let snapshot = nativeResult(transcript.snapshot())
        let restored = nativeResult(LlmWireTranscript.restore(snapshot))
        @Expect(nativeResult(restored.snapshot()), snapshot)
        @Expect(nativeResult(LlmWireJson.parse(snapshot)).field("version").getOrThrow().numberLiteral(), Some("3"))
        @Expect(restored.initialContext.tools[0].tool.kind, LlmWireToolKind.Custom)
        @Expect(restored.cacheBreakpoints[0].position, LlmWireCachePosition.MessageBlock(0, 0))
        let reply = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("next-id", "emit", LlmWireToolArguments.Text("raw")))])
        @Expect(validateReplyToolInputs(reply, restored, mode: LlmWireToolInputValidationMode.Strict).isOk(), true)
    }

    @TestCase
    func ttlOrderUsesToolsThenSystemThenMessages() {
        let context = LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "system")],
            tools: [LlmWireToolDeclaration(nativeFixtureTool("A"))])
        let transcript = LlmWireTranscript(context, items: cacheTestItems(), cacheBreakpoints: [
            LlmWireCacheBreakpoint(LlmWireCachePosition.InitialInstruction(0), lifetime: LlmWirePromptCacheLifetime.OneHour),
            LlmWireCacheBreakpoint(LlmWireCachePosition.InitialTool(0))])
        expectLlmError("llm.cache_ttl_order_invalid", { => let _ = cacheTestEncode(transcript) })
    }

    @TestCase
    func automaticSlotLimitPrecedesSameTargetNoop() {
        let points = [0, 1, 2, 3].map({ index: Int64 => LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, index)) })
        let four = LlmWireTranscript(items: cacheTestItems(), cacheBreakpoints: points)
        let _ = cacheTestEncode(four)
        expectLlmError("llm.cache_breakpoint_limit", { => let _ = cacheTestEncode(four, automatic: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.FiveMinutes)) })
        let three = LlmWireTranscript(items: cacheTestItems(), cacheBreakpoints: [points[0], points[1], points[3]])
        let body = parseWireJson(cacheTestEncode(three, automatic: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.FiveMinutes)))
        @Expect(body["cache_control"]["type"].text, "ephemeral")
        @Expect(body["messages"].items[0]["content"].items[3]["cache_control"]["ttl"].text, "5m")
    }

    @TestCase
    func automaticConflictAndBackwardEligibleTargetAreValidated() {
        let one = LlmWireTranscript(items: cacheTestItems(), cacheBreakpoints: [
            LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 3), lifetime: LlmWirePromptCacheLifetime.OneHour)])
        expectLlmError("llm.cache_ttl_conflict", { => let _ = cacheTestEncode(one, automatic: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.FiveMinutes)) })
        let short = LlmWireTranscript(items: cacheTestItems(), cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0))])
        expectLlmError("llm.cache_ttl_order_invalid", { => let _ = cacheTestEncode(short, automatic: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.OneHour)) })
        let replay = nativeReplayFromPayload(LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking",
            parseWireJson("{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"signature\"}"), blockOrder: 1)
        let withThinking = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [
            LlmWireBlock.Text(LlmWireTextBlock("answer")), LlmWireBlock.NativeReplay(replay)]))],
            cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0), lifetime: LlmWirePromptCacheLifetime.OneHour)])
        expectLlmError("llm.cache_ttl_conflict", { => let _ = cacheTestEncode(withThinking, automatic: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.FiveMinutes)) })
    }

    @TestCase
    func deferredAndNonemittedDeclarationsCannotReceiveMarkers() {
        let declaration = LlmWireToolDeclaration(nativeFixtureTool("A"), deferred: true)
        let deferred = LlmWireTranscript(LlmWireInitialContext(tools: [declaration]), items: cacheTestItems(),
            cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.InitialTool(0))])
        expectLlmError("llm.cache_target_invalid", { => let _ = cacheTestEncode(deferred) })
        let repeated = LlmWireTranscript(LlmWireInitialContext(tools: [LlmWireToolDeclaration(nativeFixtureTool("A"))]),
            items: [cacheTestItems()[0], LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(nativeFixtureTool("A")))],
            cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.Item(1))])
        expectLlmError("llm.cache_target_invalid", { => let _ = cacheTestEncode(repeated) })
        let duplicate = LlmWireTranscript(LlmWireInitialContext(tools: [declaration, declaration]), items: cacheTestItems(),
            cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.InitialTool(1))])
        expectLlmError("llm.cache_target_invalid", { => let _ = cacheTestEncode(duplicate) })
    }

    @TestCase
    func toolUseResultAndVisibilityOperationsRetainTheirOwnMarkers() {
        let original = nativeFixtureTranscript(LlmWireContextUpdateStyle.AnthropicToolReferences)
        let marked = LlmWireTranscript(original.initialContext, items: original.items, cacheBreakpoints: [
            LlmWireCacheBreakpoint(LlmWireCachePosition.Item(1), lifetime: LlmWirePromptCacheLifetime.OneHour),
            LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(3, 0), lifetime: LlmWirePromptCacheLifetime.OneHour),
            LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(4, 0)),
            LlmWireCacheBreakpoint(LlmWireCachePosition.Item(5))])
        let body = parseWireJson(cacheTestEncode(marked))
        @Expect(body["tools"].items[1]["defer_loading"].bool, true)
        @Expect(body["tools"].items[1].field("cache_control").isNone(), true)
        for (index in [1, 3, 4, 5]) { @Expect(body["messages"].items[index]["content"].items[0]["cache_control"]["type"].text, "ephemeral") }
        @Expect(body["messages"].items[1]["content"].items[0]["type"].text, "tool_addition")
        @Expect(body["messages"].items[5]["content"].items[0]["type"].text, "tool_removal")
    }

    @TestCase
    func imageTargetAndDefaultLifetimeAreExact() {
        let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [
            LlmWireBlock.Text(LlmWireTextBlock("image")), LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Base64, "YWJj", mediaType: "image/png"))]))],
            cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 1), lifetime: LlmWirePromptCacheLifetime.ProviderDefault)])
        let body = parseWireJson(cacheTestEncode(transcript))
        @Expect(body["messages"].items[0]["content"].items[0].field("cache_control").isNone(), true)
        @Expect(canonicalToolSchema(body["messages"].items[0]["content"].items[1]), canonicalToolSchema(parseWireJson(
            "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"YWJj\"},\"cache_control\":{\"type\":\"ephemeral\"}}")))
    }

    @TestCase
    func capabilityLifetimeAndOtherDialectAreUnsupported() {
        let transcript = LlmWireTranscript(items: cacheTestItems(), cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0))])
        let limited = cacheTestCodec(explicit: false)
        expectLlmError("llm.cache_explicit_unsupported", { => let _ = limited.encodeRequest(LlmWireRequest(limited.modelProfile.getOrThrow().model, transcript, maxOutputTokens: Some(32))) })
        for (dialect in [openAiResponsesDialect(), openAiCodexResponsesDialect(), openAiChatDialect(), deepSeekResponsesDialect(), deepSeekChatDialect(), deepSeekMessagesDialect(), kimiChatDialect()]) {
            let codec = LlmWireCodec(dialect.protocol, dialect, capabilities: cacheTestCodec().capabilities)
            expectLlmError("llm.cache_explicit_unsupported", { => let _ = codec.encodeRequest(LlmWireRequest("fixture-model", transcript, maxOutputTokens: Some(32))) })
        }
        for (lifetime in [LlmWirePromptCacheLifetime.ThirtyMinutes, LlmWirePromptCacheLifetime.TwentyFourHours]) {
            let unsupported = LlmWireTranscript(items: cacheTestItems(), cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0), lifetime: lifetime)])
            expectLlmError("llm.cache_lifetime_unsupported", { => let _ = cacheTestEncode(unsupported) })
        }
        let spoof = FrozenWireDialect(LlmWireDialectContract("fixture.cache.spoof", LlmWireProtocol.Messages,
            LlmWireRequestStyle.AnthropicMessages, LlmWireOutputTokenField.MaxTokens,
            promptCacheStyle: LlmWirePromptCacheStyle.Anthropic, promptCacheLifetimes: [LlmWirePromptCacheLifetime.FiveMinutes]))
        let spoofCodec = LlmWireCodec(LlmWireProtocol.Messages, spoof, capabilities: cacheTestCodec().capabilities)
        expectLlmError("llm.cache_explicit_unsupported", { => let _ = spoofCodec.encodeRequest(LlmWireRequest("fixture-model", transcript, maxOutputTokens: Some(32))) })
    }

    @TestCase
    func initialDeveloperAndAssistantImageAreNotCacheTargets() {
        let developer = LlmWireTranscript(LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.Developer, "instruction")]),
            items: cacheTestItems(), cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.InitialInstruction(0))])
        expectLlmError("llm.developer_instruction_unsupported", { => let _ = cacheTestEncode(developer) })
        let image = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [
            LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Base64, "YWJj", mediaType: "image/png"))]))],
            cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0))])
        expectLlmError("llm.cache_target_invalid", { => let _ = cacheTestEncode(image) })
    }

    @TestCase
    func nativeReplayCannotSmuggleCacheControlEvenNull() {
        for (nativeType in ["thinking", "redacted_thinking"]) {
            for (raw in ["null", "{\"type\":\"ephemeral\"}"]) {
                let fields = if (nativeType == "thinking") { "\"thinking\":\"why\",\"signature\":\"signature\"" } else { "\"data\":\"opaque\"" }
                expectLlmError("llm.native_replay_cache_control_unsupported", { =>
                    let _ = nativeReplayFromPayload(LlmWireProtocol.Messages, "anthropic.messages.v1", nativeType,
                        parseWireJson("{\"type\":\"" + nativeType + "\"," + fields + ",\"cache_control\":" + raw + "}"))
                })
            }
        }
        let replay = nativeReplayFromPayload(LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking", parseWireJson("{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"signature\"}"))
        let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.NativeReplay(replay)]))],
            cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0))])
        expectLlmError("llm.cache_target_invalid", { => let _ = cacheTestEncode(transcript) })
    }

    @TestCase
    func snapshotV3AndBuilderOwnMetadataWithoutSilentLoss() {
        let first = LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0))
        let points = [first]
        let transcript = LlmWireTranscript(items: cacheTestItems(), cacheBreakpoints: points)
        points[0] = LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 1))
        let observed = transcript.cacheBreakpoints
        observed[0] = points[0]
        @Expect(transcript.cacheBreakpoints[0].position, first.position)
        let snapshot = nativeResult(transcript.snapshot())
        @Expect(parseWireJson(snapshot)["version"].numberText, "3")
        @Expect(canonicalToolSchema(parseWireJson(snapshot)["cache_breakpoints"]), canonicalToolSchema(parseWireJson(
            "[{\"position\":{\"kind\":\"message_block\",\"item_index\":0,\"block_index\":0},\"lifetime\":\"5m\"}]")))
        let restored = nativeResult(LlmWireTranscript.restore(snapshot))
        @Expect(snapshot, nativeResult(restored.snapshot()))
        @Expect(cacheTestEncode(transcript), cacheTestEncode(restored))
        @Expect(transcript.append(cacheTestItems()[0]).cacheBreakpoints[0].position, first.position)
        let codec = cacheTestCodec()
        let builder = codec.newRequestBuilder()
        builder.setTranscript(restored); builder.setMaxOutputTokens(Some(32))
        @Expect(nativeResult(builder.build()).transcript.cacheBreakpoints[0].position, first.position)
        expectLlmError("llm.cache_position_invalid", { => builder.setCacheBreakpoints([LlmWireCacheBreakpoint(LlmWireCachePosition.Item(9))]) })
        @Expect(nativeResult(builder.build()).transcript.cacheBreakpoints[0].position, first.position)
        builder.setCacheBreakpoints(points)
        @Expect(nativeResult(builder.build()).transcript.cacheBreakpoints[0].position, points[0].position)
        builder.reset(); builder.append(cacheTestItems()[0]); builder.setMaxOutputTokens(Some(32))
        @Expect(nativeResult(builder.build()).transcript.cacheBreakpoints.isEmpty(), true)
    }

    @TestCase
    func v3ReaderRejectsUnknownMissingAndInvalidMetadata() {
        let base = parseWireJson(nativeResult(LlmWireTranscript(items: cacheTestItems(), cacheBreakpoints: [
            LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0))]).snapshot()))
        let sources = [
            base.stringify().replace("\"lifetime\":\"5m\"", "\"lifetime\":\"unknown\""),
            base.stringify().replace("\"block_index\":0", "\"block_index\":99"),
            base.stringify().replace("\"lifetime\":\"5m\"", "\"lifetime\":\"5m\",\"extra\":1"),
            base.stringify().replace("\"cache_breakpoints\"", "\"unknown_breakpoints\"")
        ]
        for (source in sources) { match (LlmWireTranscript.restore(source)) {
            case LlmWireResult.Err(_) => ()
            case _ => @Fail("malformed cache metadata was accepted")
        } }
    }
}
