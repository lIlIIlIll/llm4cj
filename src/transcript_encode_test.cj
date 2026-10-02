package llm4cj

import std.collection.*
import std.fs.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

func nativeFixtureTool(name: String): LlmWireTool {
    LlmWireTool(name, "Tool " + name, testJson("{\"type\":\"object\",\"properties\":{}}"))
}

func nativeResult<T>(value: LlmWireResult<T>): T {
    match (value) { case LlmWireResult.Ok(result) => result; case LlmWireResult.Err(error) => throw error }
}

func nativeFixtureEndpoint(style: LlmWireContextUpdateStyle): LlmWireEndpointProfile {
    let identity = match (style) {
        case LlmWireContextUpdateStyle.ResponsesAdditionalTools => ("fixture.responses", "gpt-6-sol", "openai.responses.v1", "https://api.openai.com/v1/responses")
        case LlmWireContextUpdateStyle.AnthropicToolReferences => ("fixture.messages", "claude-opus-5-5", "anthropic.messages.v1", "https://api.anthropic.com/v1/messages")
        case _ => ("fixture.kimi", "kimi-k3", "kimi.chat.v1", "https://api.moonshot.ai/v1/chat/completions")
    }
    LlmWireEndpointProfile(identity[0], identity[1], identity[2], identity[3], 1,
        LlmWireContextUpdateContract(style: style).capabilities, "official-protocol-fixture", "2026-10-01")
}

func nativeFixtureCodec(style: LlmWireContextUpdateStyle): LlmWireCodec {
    let endpoint = nativeFixtureEndpoint(style)
    let capabilities = LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))
    match (style) {
        case LlmWireContextUpdateStyle.ResponsesAdditionalTools => openAiResponsesCodec(openAiResponsesModelProfile(endpoint.model,
            capabilities: capabilities, endpoint: endpoint.endpoint, endpointProfile: Some(endpoint)))
        case LlmWireContextUpdateStyle.AnthropicToolReferences => anthropicMessagesCodec(anthropicMessagesModelProfile(endpoint.model,
            capabilities: capabilities, endpoint: endpoint.endpoint, endpointProfile: Some(endpoint)))
        case _ => kimiChatCodec(kimiChatModelProfile(endpoint.model,
            capabilities: capabilities, endpoint: endpoint.endpoint, endpointProfile: Some(endpoint)))
    }
}

func nativeFixtureTranscript(style: LlmWireContextUpdateStyle): LlmWireTranscript {
    let anthropic = style == LlmWireContextUpdateStyle.AnthropicToolReferences
    let tool = if (anthropic) { "B" } else { "C" }
    let updates = ArrayList<LlmWireInputItem>()
    updates.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("History"))])))
    updates.add(if (anthropic) { LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity(tool)) }
        else { LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(nativeFixtureTool(tool))) })
    updates.add(LlmWireInputItem.InstructionUpdate(LlmWireInstruction(
        if (style == LlmWireContextUpdateStyle.ResponsesAdditionalTools) { LlmWireInstructionRole.Developer } else { LlmWireInstructionRole.System }, "Updated instruction")))
    updates.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(
        LlmWireToolCallBlock("call-" + tool, tool, LlmWireToolArguments.Complete(testJson("{}"))))])))
    updates.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call-" + tool, "done"))])))
    if (anthropic) { updates.add(LlmWireInputItem.ToolDeactivation(LlmWireToolDefinitionIdentity(tool))) }
    LlmWireTranscript(LlmWireInitialContext(
        instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "Initial instruction")],
        tools: [LlmWireToolDeclaration(nativeFixtureTool("A")), LlmWireToolDeclaration(nativeFixtureTool("B"), deferred: anthropic)]), items: updates.toArray())
}

func nativeGolden(style: LlmWireContextUpdateStyle, name: String): Unit {
    let codec = nativeFixtureCodec(style)
    let transcript = nativeFixtureTranscript(style)
    let model = codec.modelProfile.getOrThrow().model
    let encoded = codec.encodeRequest(LlmWireRequest(model, transcript, maxOutputTokens: Some(32)))
    let file = File("fixtures/transcripts/" + name + ".json", OpenMode.Read)
    let fixture = parseWireJson(String.fromUtf8(readToEnd(file)))
    file.close()
    @Expect(canonicalToolSchema(parseWireJson(encoded.bodyText())), canonicalToolSchema(fixture["body"]))
    let headers = encoded.requiredHeadersForTest()
    let expectedHeaders = fixture["required_headers"].items
    @Expect(headers.size, expectedHeaders.size)
    for (index in 0..headers.size) {
        @Expect(headers[index].name, expectedHeaders[index]["name"].text)
        @Expect(headers[index].value, expectedHeaders[index]["value"].text)
    }
    let restored = nativeResult(LlmWireTranscript.restore(nativeResult(transcript.snapshot())))
    @Expect(encoded.bodyText(), codec.encodeRequest(LlmWireRequest(model, restored, maxOutputTokens: Some(32))).bodyText())
}

@Test
class TranscriptNativeEncodingTest {
    @TestCase
    func responsesGolden() { nativeGolden(LlmWireContextUpdateStyle.ResponsesAdditionalTools, "openai-responses") }

    @TestCase
    func messagesGolden() { nativeGolden(LlmWireContextUpdateStyle.AnthropicToolReferences, "anthropic-messages") }

    @TestCase
    func kimiGolden() { nativeGolden(LlmWireContextUpdateStyle.KimiSystemTools, "kimi-chat") }

    @TestCase
    func defaultProfilesDenyUpdates() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("gpt-6-sol", capabilities: LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))))
        expectLlmError("llm.context_update_unsupported", { => let _ = codec.encodeRequest(LlmWireRequest("gpt-6-sol", nativeFixtureTranscript(LlmWireContextUpdateStyle.ResponsesAdditionalTools))) })
    }

    @TestCase
    func nativeOperationsHaveIndependentCapabilities() {
        for (style in [LlmWireContextUpdateStyle.ResponsesAdditionalTools, LlmWireContextUpdateStyle.KimiSystemTools]) {
            let codec = nativeFixtureCodec(style)
            let transcript = nativeFixtureTranscript(style).append(LlmWireInputItem.ToolDeactivation(LlmWireToolDefinitionIdentity("C")))
            expectLlmError("llm.context_update_unsupported", { => let _ = codec.encodeRequest(LlmWireRequest(codec.modelProfile.getOrThrow().model, transcript)) })
        }
        let codec = nativeFixtureCodec(LlmWireContextUpdateStyle.AnthropicToolReferences)
        let transcript = LlmWireTranscript(items: [
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("History"))])),
            LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(nativeFixtureTool("new")))])
        expectLlmError("llm.context_update_unsupported", { => let _ = codec.encodeRequest(LlmWireRequest(codec.modelProfile.getOrThrow().model, transcript, maxOutputTokens: Some(32))) })
    }

    @TestCase
    func endpointBindingsAndContractVersionAreExact() {
        let endpoint = nativeFixtureEndpoint(LlmWireContextUpdateStyle.ResponsesAdditionalTools)
        expectLlmError("llm.endpoint_profile_mismatch", { => let _ = openAiResponsesModelProfile("wrong-model", endpoint: endpoint.endpoint, endpointProfile: Some(endpoint)) })
        expectLlmError("llm.endpoint_profile_mismatch", { => let _ = openAiResponsesModelProfile(endpoint.model, endpoint: "https://other.example/responses", endpointProfile: Some(endpoint)) })
        expectLlmError("llm.context_contract_version_unsupported", { => let _ = LlmWireEndpointProfile("bad-version", endpoint.model, endpoint.dialectId, endpoint.endpoint, 2, endpoint.capabilities, "fixture", "2026-10-01") })
        @Expect(endpoint.evidence, LlmWireCapabilityEvidence.CallerDeclared)
    }

    @TestCase
    func appendKeepsPreviouslyEncodedFragments() {
        for (style in [LlmWireContextUpdateStyle.ResponsesAdditionalTools, LlmWireContextUpdateStyle.KimiSystemTools]) {
            let codec = nativeFixtureCodec(style)
            let transcript = nativeFixtureTranscript(style)
            let model = codec.modelProfile.getOrThrow().model
            let before = parseWireJson(codec.encodeRequest(LlmWireRequest(model, transcript)).bodyText())
            let after = parseWireJson(codec.encodeRequest(LlmWireRequest(model, transcript.append(LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(nativeFixtureTool("D")))))).bodyText())
            let field = if (style == LlmWireContextUpdateStyle.ResponsesAdditionalTools) { "input" } else { "messages" }
            let first = before[field].items; let next = after[field].items
            @Expect(next.size, first.size + 1)
            for (index in 0..first.size) { @Expect(canonicalToolSchema(first[index]), canonicalToolSchema(next[index])) }
            @Expect(canonicalToolSchema(before["tools"]), canonicalToolSchema(after["tools"]))
        }
    }

    @TestCase
    func betaCannotBeRemovedByCallerHeaders() {
        let codec = nativeFixtureCodec(LlmWireContextUpdateStyle.AnthropicToolReferences)
        let prepared = codec.encodeRequest(LlmWireRequest(codec.modelProfile.getOrThrow().model,
            nativeFixtureTranscript(LlmWireContextUpdateStyle.AnthropicToolReferences), maxOutputTokens: Some(32)))
        let sent = nativeResult(prepared.materialize(userHeaders: [LlmWireHeader("anthropic-beta", "other-beta,mid-conversation-tool-changes-2026-07-01")]))
        @Expect(headerValue(sent.headers, "anthropic-beta"), "mid-conversation-tool-changes-2026-07-01,other-beta")
        match (prepared.materialize(userHeaders: [LlmWireHeader("content-type", "text/plain")])) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.required_header_conflict")
            case _ => @Fail("required Content-Type must be retained")
        }
        let instructionOnly = LlmWireTranscript(items: [
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("History"))])),
            LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.System, "update"))])
        @Expect(codec.encodeRequest(LlmWireRequest(codec.modelProfile.getOrThrow().model, instructionOnly, maxOutputTokens: Some(32))).requiredHeadersForTest().size, 0)
    }

    @TestCase
    func anthropicAutomaticCacheHasStableOwnership() {
        let endpoint = nativeFixtureEndpoint(LlmWireContextUpdateStyle.AnthropicToolReferences)
        let capabilities = LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true), cache: LlmWireCacheCapabilities(lifetimes: [LlmWirePromptCacheLifetime.FiveMinutes]))
        let codec = anthropicMessagesCodec(anthropicMessagesModelProfile(endpoint.model, capabilities: capabilities, endpoint: endpoint.endpoint, endpointProfile: Some(endpoint)))
        let transcript = nativeFixtureTranscript(LlmWireContextUpdateStyle.AnthropicToolReferences)
        let cache = LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.FiveMinutes)
        let before = parseWireJson(codec.encodeRequest(LlmWireRequest(endpoint.model, transcript, maxOutputTokens: Some(32), promptCache: cache)).bodyText())
        let next = transcript.append(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(LlmWireTextBlock("complete"))])))
        let prepared = codec.encodeRequest(LlmWireRequest(endpoint.model, next, maxOutputTokens: Some(32), promptCache: cache))
        let after = parseWireJson(prepared.bodyText())
        for (field in ["tools", "system", "cache_control"]) { @Expect(canonicalToolSchema(before[field]), canonicalToolSchema(after[field])) }
        for (tool in after["tools"].items) { @Expect(tool.field("cache_control").isNone(), true) }
        @Expect(headerValue(prepared.requiredHeadersForTest(), "anthropic-beta"), "mid-conversation-tool-changes-2026-07-01")
        let sent = nativeResult(prepared.materialize(resolver: Some(SatisfiedRequirementResolver())))
        @Expect(parseWireJson(String.fromUtf8(sent.body)).field("cache_control").isSome(), true)
    }

    @TestCase
    func kimiReasoningFixedAndStreamedReplayRemainEquivalent() {
        let codec = nativeFixtureCodec(LlmWireContextUpdateStyle.KimiSystemTools)
        let fixed = succeededReply(codec.decodeResponse("""
            {"id":"r","model":"kimi-k3","choices":[{"index":0,"message":{"content":null,"reasoning_content":"plan","tool_calls":[{"id":"call-C","type":"function","function":{"name":"C","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}
            """))
        let decoder = codec.newStreamDecoder()
        let _ = decoder.push(event("""
            {"id":"r","model":"kimi-k3","choices":[{"index":0,"delta":{"reasoning_content":"plan"}}]}
            """))
        let _ = decoder.push(event("""
            {"id":"r","model":"kimi-k3","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-C","type":"function","function":{"name":"C","arguments":"{}"}}]}}]}
            """))
        let _ = decoder.push(event("""
            {"id":"r","model":"kimi-k3","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
            """))
        let streamed = succeededReply(decoder.push(event("[DONE]")))
        @Expect(fixed.blocks.size, 2); @Expect(streamed.blocks.size, 2)
        match ((fixed.blocks[0], streamed.blocks[0])) {
            case (LlmWireOutputBlock.NativeReplay(a), LlmWireOutputBlock.NativeReplay(b)) => @Expect(a.snapshot(), b.snapshot()); @Expect(a.dialectId, "kimi.chat.v1")
            case _ => @Fail("Kimi reasoning must retain its source-bound replay identity")
        }
        let original = nativeFixtureTranscript(LlmWireContextUpdateStyle.KimiSystemTools)
        let first = original.items
        var transcript = LlmWireTranscript(original.initialContext, items: [first[0], first[1]])
        transcript = transcript.append(LlmWireInputItem.Message(fixed.toContinuationInput()[0]))
        transcript = transcript.append(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call-C", "done"))])))
        transcript = transcript.append(LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(nativeFixtureTool("D"))))
        let prepared = codec.encodeRequest(LlmWireRequest("kimi-k3", transcript))
        let messages = parseWireJson(prepared.bodyText())["messages"].items
        @Expect(messages[3]["reasoning_content"].text, "plan")
        @Expect(messages[3]["tool_calls"].items.size, 1)
        @Expect(messages[5].field("content").isNone(), true)
        let restored = nativeResult(LlmWireTranscript.restore(nativeResult(transcript.snapshot())))
        @Expect(codec.encodeRequest(LlmWireRequest("kimi-k3", restored)).bodyText(), prepared.bodyText())
        let other = deepSeekChatCodec(deepSeekChatModelProfile("kimi-k3", capabilities: LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))))
        let resultItem = transcript.items[3]
        expectLlmError("llm.native_replay_dialect_mismatch", { => let _ = other.encodeRequest(LlmWireRequest("kimi-k3", LlmWireTranscript(
            LlmWireInitialContext(tools: [LlmWireToolDeclaration(nativeFixtureTool("C"))]),
            items: [first[0], LlmWireInputItem.Message(fixed.toContinuationInput()[0]), resultItem]))) })
    }

    @TestCase
    func malformedOrOverbroadEvidenceDoesNotGrantWireSupport() {
        let endpoint = nativeFixtureEndpoint(LlmWireContextUpdateStyle.KimiSystemTools)
        expectLlmError("llm.endpoint_profile_invalid", { => let _ = LlmWireEndpointProfile("bad", endpoint.model, endpoint.dialectId,
            "https://token@example.com/v1/chat/completions", 1, endpoint.capabilities, "caller", "2026-10-01") })
        expectLlmError("llm.endpoint_profile_invalid", { => let _ = LlmWireEndpointProfile("bad", endpoint.model, endpoint.dialectId,
            endpoint.endpoint, 1, endpoint.capabilities, "caller", "2026-02-30") })
        let claimed = LlmWireEndpointProfile("bad", endpoint.model, endpoint.dialectId, endpoint.endpoint, 1,
            LlmWireContextUpdateCapabilities(toolReplacement: true), "caller", "2026-10-01")
        let codec = kimiChatCodec(kimiChatModelProfile(endpoint.model, endpoint: endpoint.endpoint, endpointProfile: Some(claimed)))
        expectLlmError("llm.endpoint_profile_capability_unsupported", { => let _ = codec.encodeRequest(LlmWireRequest(endpoint.model,
            LlmWireTranscript(items: messageItems(validMessages())))) })
        @Expect(validProfileEvidenceDate("2024-02-29"), true)
        @Expect(validProfileEvidenceDate("2023-02-29"), false)
    }

    @TestCase
    func kimiExactModelAndNativeResultShapeAreEnforced() {
        let endpoint = nativeFixtureEndpoint(LlmWireContextUpdateStyle.KimiSystemTools)
        let claimed = LlmWireEndpointProfile("other.kimi", "kimi-k2.5", endpoint.dialectId, endpoint.endpoint, 1,
            endpoint.capabilities, "caller", "2026-10-01")
        let other = kimiChatCodec(kimiChatModelProfile(claimed.model, endpoint: endpoint.endpoint, endpointProfile: Some(claimed)))
        expectLlmError("llm.endpoint_profile_capability_unsupported", { => let _ = other.encodeRequest(LlmWireRequest(claimed.model,
            LlmWireTranscript(items: messageItems(validMessages())))) })
        let codec = nativeFixtureCodec(LlmWireContextUpdateStyle.KimiSystemTools)
        let original = nativeFixtureTranscript(LlmWireContextUpdateStyle.KimiSystemTools)
        let items = original.items
        items[4] = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(LlmWireToolResultBlock("call-C", [
            LlmWireToolResultContent.Text(LlmWireTextBlock("one")), LlmWireToolResultContent.Text(LlmWireTextBlock("two"))]))]))
        expectLlmError("llm.kimi_tool_result_content_unsupported", { => let _ = codec.encodeRequest(LlmWireRequest(endpoint.model,
            LlmWireTranscript(original.initialContext, items: items))) })
        let messages = parseWireJson(codec.encodeRequest(LlmWireRequest(endpoint.model, original)).bodyText())["messages"].items
        @Expect(messages[2].field("tools").isSome(), true)
        @Expect(messages[2].field("content").isNone(), true)
    }

    @TestCase
    func longHistoryAndRepeatedRestoreKeepAllEarlierModelFragments() {
        for (style in [LlmWireContextUpdateStyle.ResponsesAdditionalTools, LlmWireContextUpdateStyle.AnthropicToolReferences, LlmWireContextUpdateStyle.KimiSystemTools]) {
            let codec = nativeFixtureCodec(style)
            let anthropic = style == LlmWireContextUpdateStyle.AnthropicToolReferences
            let declarations = ArrayList<LlmWireToolDeclaration>()
            declarations.add(LlmWireToolDeclaration(nativeFixtureTool("A")))
            declarations.add(LlmWireToolDeclaration(nativeFixtureTool("B")))
            if (anthropic) {
                declarations.add(LlmWireToolDeclaration(nativeFixtureTool("C"), deferred: true))
                declarations.add(LlmWireToolDeclaration(nativeFixtureTool("D"), deferred: true))
            }
            let history = ArrayList<LlmWireInputItem>()
            for (index in 0..64) {
                history.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("historical input " + index.toString()))])))
                history.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(LlmWireTextBlock("historical output " + index.toString()))])))
            }
            history.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("load next tool"))])))
            var transcript = LlmWireTranscript(LlmWireInitialContext(
                instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "fixed instruction")], tools: declarations.toArray()), items: history.toArray())
            let model = codec.modelProfile.getOrThrow().model
            let field = if (style == LlmWireContextUpdateStyle.ResponsesAdditionalTools) { "input" } else { "messages" }
            var previous = parseWireJson(codec.encodeRequest(LlmWireRequest(model, transcript, maxOutputTokens: Some(32))).bodyText())
            let updates = ArrayList<LlmWireInputItem>()
            updates.add(if (anthropic) { LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity("C")) }
                else { LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(nativeFixtureTool("C"))) })
            updates.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(
                LlmWireToolCallBlock("long-C", "C", LlmWireToolArguments.Complete(testJson("{}"))))])))
            updates.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("long-C", "done"))])))
            if (anthropic) { updates.add(LlmWireInputItem.ToolDeactivation(LlmWireToolDefinitionIdentity("C"))) }
            updates.add(if (anthropic) { LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity("D")) }
                else { LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(nativeFixtureTool("D"))) })
            var pendingAppends: Int64 = 0
            for (update in updates) {
                transcript = transcript.append(update); pendingAppends++
                match (update) { case LlmWireInputItem.Message(message) => if (message.role == LlmWireRole.Assistant) { continue }; case _ => () }
                let prepared = codec.encodeRequest(LlmWireRequest(model, transcript, maxOutputTokens: Some(32)))
                let next = parseWireJson(prepared.bodyText())
                let prefix = previous[field].items; let appended = next[field].items
                @Expect(appended.size, prefix.size + pendingAppends)
                for (index in 0..prefix.size) { @Expect(canonicalToolSchema(prefix[index]), canonicalToolSchema(appended[index])) }
                @Expect(canonicalToolSchema(previous["tools"]), canonicalToolSchema(next["tools"]))
                for (_ in 0..3) {
                    transcript = nativeResult(LlmWireTranscript.restore(nativeResult(transcript.snapshot())))
                    @Expect(codec.encodeRequest(LlmWireRequest(model, transcript, maxOutputTokens: Some(32))).bodyText(), prepared.bodyText())
                }
                previous = next; pendingAppends = 0
            }
            var hasC = false; var hasD = false
            for (tool in transcript.effectiveTools) { if (tool.name == "C") { hasC = true }; if (tool.name == "D") { hasD = true } }
            @Expect(hasD, true); @Expect(hasC, !anthropic)
        }
    }

    @TestCase
    func profileIdentityBoundsAndCalendarEvidenceFailClosed() {
        let endpoint = nativeFixtureEndpoint(LlmWireContextUpdateStyle.ResponsesAdditionalTools)
        let longModel = StringBuilder(); for (_ in 0..257) { longModel.append("m") }
        let longEndpoint = StringBuilder(); for (_ in 0..2049) { longEndpoint.append("e") }
        let longEvidence = StringBuilder(); for (_ in 0..2049) { longEvidence.append("s") }
        let invalid = [
            ("INVALID", endpoint.model, endpoint.dialectId, endpoint.endpoint, "caller"),
            ("valid", endpoint.model, "INVALID", endpoint.endpoint, "caller"),
            ("valid", " ", endpoint.dialectId, endpoint.endpoint, "caller"),
            ("valid", endpoint.model, endpoint.dialectId, " ", "caller"),
            ("valid", longModel.toString(), endpoint.dialectId, endpoint.endpoint, "caller"),
            ("valid", endpoint.model, endpoint.dialectId, longEndpoint.toString(), "caller"),
            ("valid", endpoint.model, endpoint.dialectId, endpoint.endpoint, " "),
            ("valid", endpoint.model, endpoint.dialectId, endpoint.endpoint, longEvidence.toString())]
        for (value in invalid) {
            expectLlmError("llm.endpoint_profile_invalid", { => let _ = LlmWireEndpointProfile(value[0], value[1], value[2], value[3], 1,
                endpoint.capabilities, value[4], "2026-10-01") })
        }
        for (url in ["https://example.com/\nsecret", "https://example.com/\u{007f}secret", "https://example.com/?token=secret", "https://example.com/#secret"]) {
            try {
                let _ = LlmWireEndpointProfile("valid", endpoint.model, endpoint.dialectId, url, 1, endpoint.capabilities, "caller", "2026-10-01")
                @Fail("endpoint controls and credential-bearing variants must fail closed")
            } catch (error: LlmWireError) { @Expect(error.code, "llm.endpoint_profile_invalid"); @Expect(error.message.contains("secret"), false) }
        }
        for (date in ["", "20261001", "2026/10-01", "2026-10/01", "2026-1A-01", "2026-1/-01", "0000-10-01", "2026-00-01", "2026-13-01", "2026-10-00", "1900-02-29"]) {
            expectLlmError("llm.endpoint_profile_invalid", { => let _ = LlmWireEndpointProfile("valid", endpoint.model, endpoint.dialectId,
                endpoint.endpoint, 1, endpoint.capabilities, "caller", date) })
        }
        for (date in ["2000-02-29", "1900-02-28"]) {
            @Expect(LlmWireEndpointProfile("valid", endpoint.model, endpoint.dialectId, endpoint.endpoint, 1, endpoint.capabilities, "caller", date).checkedAt, date)
        }
    }

    @TestCase
    func explicitCapabilityClaimsCannotOverrideDialectHardLimits() {
        let claims = [
            LlmWireContextUpdateCapabilities(appendSystemInstruction: true), LlmWireContextUpdateCapabilities(appendDeveloperInstruction: true),
            LlmWireContextUpdateCapabilities(toolDeclaration: true), LlmWireContextUpdateCapabilities(toolActivation: true),
            LlmWireContextUpdateCapabilities(toolDeactivation: true), LlmWireContextUpdateCapabilities(toolReplacement: true),
            LlmWireContextUpdateCapabilities(deferredToolPool: true), LlmWireContextUpdateCapabilities(deferredPoolExtension: true)]
        let endpoint = "https://api.openai.com/v1/chat/completions"
        let capabilities = LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))
        for (claim in claims) {
            let profile = LlmWireEndpointProfile("hard-limits", "gpt-6-sol", "openai.chat.v1", endpoint, 1, claim, "caller", "2026-10-01")
            let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: capabilities,
                modelProfile: Some(LlmWireModelProfile(profile.model, profile.dialectId, capabilities, endpoint: endpoint, endpointProfile: Some(profile))))
            expectLlmError("llm.endpoint_profile_capability_unsupported", { => let _ = codec.encodeRequest(LlmWireRequest(profile.model,
                LlmWireTranscript(items: messageItems(validMessages())))) })
        }
        expectIllegalArgument({ => let _ = LlmWireDialectContract("mismatched.context", LlmWireProtocol.ChatCompletions,
            LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens,
            contextUpdates: LlmWireContextUpdateContract(style: LlmWireContextUpdateStyle.ResponsesAdditionalTools)) })
        @Expect(LlmWireContextUpdateContract(style: LlmWireContextUpdateStyle.ResponsesAdditionalTools).requiredHeaders.size, 0)
        @Expect(LlmWireContextUpdateContract(style: LlmWireContextUpdateStyle.KimiSystemTools).requiredHeaders.size, 0)
    }

    @TestCase
    func partialProfileDoesNotAuthorizeOtherTranscriptOperations() {
        let endpoint = nativeFixtureEndpoint(LlmWireContextUpdateStyle.ResponsesAdditionalTools)
        let profile = LlmWireEndpointProfile("declaration.only", endpoint.model, endpoint.dialectId, endpoint.endpoint, 1,
            LlmWireContextUpdateCapabilities(toolDeclaration: true), "caller", "2026-10-01")
        let codec = openAiResponsesCodec(openAiResponsesModelProfile(endpoint.model, capabilities: LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true)),
            endpoint: endpoint.endpoint, endpointProfile: Some(profile)))
        let history = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("History"))]))
        for (role in [LlmWireInstructionRole.System, LlmWireInstructionRole.Developer]) {
            try {
                let _ = codec.encodeRequest(LlmWireRequest(endpoint.model, LlmWireTranscript(items: [history,
                    LlmWireInputItem.InstructionUpdate(LlmWireInstruction(role, "update"))])))
                @Fail("declaration grant must not grant instruction updates")
            } catch (error: LlmWireError) {
                @Expect(error.code, "llm.context_update_unsupported"); @Expect(error.inputItemIndex, 1)
                @Expect(error.profileId, "declaration.only"); @Expect(error.contractVersion, 1)
            }
        }
        let deferred = LlmWireToolDeclaration(nativeFixtureTool("later"), deferred: true)
        try {
            let _ = codec.encodeRequest(LlmWireRequest(endpoint.model, LlmWireTranscript(items: [history, LlmWireInputItem.ToolDeclaration(deferred)])))
            @Fail("declaration grant must not grant pool extension")
        } catch (error: LlmWireError) {
            @Expect(error.code, "llm.context_update_unsupported"); @Expect(error.missingCapability, "deferred_pool_extension"); @Expect(error.toolName, "later")
        }
        try {
            let _ = codec.encodeRequest(LlmWireRequest(endpoint.model, LlmWireTranscript(LlmWireInitialContext(tools: [deferred]), items: [history])))
            @Fail("declaration grant must not grant initial deferred pools")
        } catch (error: LlmWireError) {
            @Expect(error.missingCapability, "deferred_tool_pool"); @Expect(error.inputItemIndex, -1)
        }
    }

    @TestCase
    func duplicateDefinitionsDoNotMutateNativeInputLayouts() {
        for (style in [LlmWireContextUpdateStyle.ResponsesAdditionalTools, LlmWireContextUpdateStyle.AnthropicToolReferences, LlmWireContextUpdateStyle.KimiSystemTools]) {
            let codec = nativeFixtureCodec(style)
            let declaration = LlmWireToolDeclaration(nativeFixtureTool("A"))
            let history = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("History"))]))
            let original = LlmWireTranscript(LlmWireInitialContext(tools: [declaration]), items: [history])
            let duplicate = LlmWireTranscript(LlmWireInitialContext(tools: [declaration, declaration]), items: [history, LlmWireInputItem.ToolDeclaration(declaration)])
            let model = codec.modelProfile.getOrThrow().model
            @Expect(codec.encodeRequest(LlmWireRequest(model, original, maxOutputTokens: Some(32))).bodyText(),
                codec.encodeRequest(LlmWireRequest(model, duplicate, maxOutputTokens: Some(32))).bodyText())
        }
    }
}
