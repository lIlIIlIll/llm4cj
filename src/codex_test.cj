package llm4cj

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func codexRequest(
    model: String, messages: Array<LlmWireMessage>, instructions!: Array<LlmWireInstruction> = [], tools!: Array<LlmWireTool> = [],
    maxOutputTokens!: ?Int64 = None, promptCache!: LlmWirePromptCache = LlmWirePromptCache.ProviderDefault,
    structuredOutput!: LlmWireStructuredOutput = LlmWireStructuredOutput.ProviderDefault,
    reasoningEffort!: LlmWireReasoningEffort = LlmWireReasoningEffort.ProviderDefault,
    parallelToolCalls!: ?Bool = None, serviceTier!: LlmWireServiceTier = LlmWireServiceTier.ProviderDefault
): LlmWireRequest {
    LlmWireRequest(model, LlmWireTranscript(LlmWireInitialContext(instructions: instructions,
        tools: tools.map({ tool: LlmWireTool => LlmWireToolDeclaration(tool) })), items: messageItems(messages)),
        maxOutputTokens: maxOutputTokens, promptCache: promptCache, structuredOutput: structuredOutput,
        reasoningEffort: reasoningEffort, parallelToolCalls: parallelToolCalls, serviceTier: serviceTier)
}

func codexTestCodec(): LlmWireCodec { openAiCodexResponsesCodec(openAiCodexResponsesModelProfile("model", capabilities: allCapabilities())) }
func codexText(text: String): LlmWireMessage { LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(text))]) }
func codexJson(text: String): LlmWireJson { match (LlmWireJson.parse(text)) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error } }
func codexHttpBody(codec: LlmWireCodec, request: LlmWireRequest): String {
    match (codec.encodeRequest(request, streaming: true).materialize()) {
        case LlmWireResult.Ok(value) => String.fromUtf8(value.body)
        case LlmWireResult.Err(error) => throw error
    }
}
func codexUpdate(value: LlmWireResult<LlmWireStreamUpdate>): LlmWireStreamUpdate { match (value) { case LlmWireResult.Ok(update) => update; case LlmWireResult.Err(error) => throw error } }
func codexError(value: LlmWireResult<LlmWireStreamUpdate>): String { match (value) { case LlmWireResult.Err(error) => error.code; case _ => @Fail("expected stream error") } }
func codexStreamError(value: LlmWireResult<LlmWireStreamUpdate>): LlmWireError {
    match (value) { case LlmWireResult.Err(error) => error; case _ => @Fail("expected WebSocket error") }
}
func expectCodexUsage(error: LlmWireError, code: String, input: Int64, output!: ?Int64 = None): Unit {
    @Expect(error.code, code)
    @Expect(error.protocol, Some(LlmWireProtocol.Responses)); @Expect(error.dialectId, "openai.codex.responses.v1")
    @Expect(error.usage.isSome(), true)
    match (error.usage) {
        case Some(usage) => @Expect(usage.inputTokens, Some(input)); @Expect(usage.outputTokens, output)
        case None => ()
    }
}
func codexFinalResponse(): String {
    "{\"id\":\"resp_1\",\"model\":\"model\",\"status\":\"completed\",\"output\":[{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}"
}
func codexTextEvents(): Array<String> {
    [
        "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"model\":\"model\"}}",
        "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"phase\":\"final_answer\"}}",
        "{\"type\":\"response.content_part.added\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"part\":{\"type\":\"output_text\"}}",
        "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"delta\":\"ok\"}",
        "{\"type\":\"response.output_text.done\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"text\":\"ok\"}",
        "{\"type\":\"response.content_part.done\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"ok\"}}",
        "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}}",
        "{\"type\":\"response.completed\",\"response\":" + codexFinalResponse() + "}"
    ]
}

@Test
class CodexTest {
    @TestCase
    func checkpointRetentionFailureKeepsLatestUsageAfterDecoderDisposal() {
        let codec = codexTestCodec()
        let ws = codec.newResponsesWebSocketSession(limits: LlmWireStreamLimits(maxRetainedStateBytes: 1024))
        let prompt = String.fromUtf8(Array<Byte>(400, repeat: 112u8))
        let answer = String.fromUtf8(Array<Byte>(600, repeat: 97u8))
        let _ = ws.prepare(codexRequest("model", [codexText(prompt)]))
        let terminal = codexFinalResponse().replace("\"ok\"", "\"" + answer + "\"").replace("\"output\":[", "\"usage\":{\"input_tokens\":7,\"output_tokens\":9},\"output\":[")
        let error = codexStreamError(ws.push(("{\"type\":\"response.completed\",\"response\":" + terminal + "}").toArray()))
        expectCodexUsage(error, "llm.websocket_retained_state_too_large", 7, output: Some(9))
        expectCodexUsage(codexStreamError(ws.push([])), "llm.stream_failed", 7, output: Some(9))
        expectCodexUsage(codexStreamError(ws.finish()), "llm.stream_failed", 7, output: Some(9))
        match (ws.cancel()) {
            case LlmWireResult.Err(value) => expectCodexUsage(value, "llm.stream_failed", 7, output: Some(9))
            case _ => @Fail("poisoned session cannot be cancelled as a new attempt")
        }
        try { let _ = ws.prepare(codexRequest("model", [codexText("again")])); @Fail("poisoned session cannot prepare") }
        catch (value: LlmWireError) { expectCodexUsage(value, "llm.stream_failed", 7, output: Some(9)) }
    }

    @TestCase
    func framingPrepareFinishAndCancellationKeepOnlyCurrentAttemptUsage() {
        let codec = codexTestCodec()
        let created = "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"model\":\"model\",\"usage\":{\"input_tokens\":7}}}"
        for (newerUsage in [false, true]) {
            let ws = codec.newResponsesWebSocketSession(); let _ = ws.prepare(codexRequest("model", [codexText("hi")]))
            let _ = codexUpdate(ws.push(created.toArray()))
            if (newerUsage) { let _ = codexUpdate(ws.push("{\"type\":\"response.in_progress\",\"response\":{\"id\":\"resp_1\",\"model\":\"model\",\"usage\":{\"input_tokens\":8,\"output_tokens\":2}}}".toArray())) }
            let input = if (newerUsage) { 8 } else { 7 }; let output: ?Int64 = if (newerUsage) { Some(2) } else { None }
            try { let _ = ws.prepare(codexRequest("model", [codexText("again")])); @Fail("active response must reject prepare") }
            catch (error: LlmWireError) { expectCodexUsage(error, "llm.websocket_response_active", input, output: output) }
            expectCodexUsage(codexStreamError(ws.push([255u8])), "llm.response_utf8_invalid", input, output: output)
        }
        let truncated = codec.newResponsesWebSocketSession(); let _ = truncated.prepare(codexRequest("model", [codexText("hi")]))
        let _ = codexUpdate(truncated.push(created.toArray()))
        expectCodexUsage(codexStreamError(truncated.finish()), "llm.stream_terminal_missing", 7)
        match (truncated.cancel()) { case LlmWireResult.Err(error) => expectCodexUsage(error, "llm.stream_failed", 7); case _ => @Fail("failed finish must poison the session") }
        let cancelled = codec.newResponsesWebSocketSession(); let _ = cancelled.prepare(codexRequest("model", [codexText("hi")]))
        let _ = codexUpdate(cancelled.push(created.toArray()))
        match (cancelled.cancel()) {
            case LlmWireResult.Ok(LlmWireTerminal.Cancelled(failure)) => @Expect(failure.usage.getOrThrow().inputTokens, Some(7))
            case _ => @Fail("active cancellation must retain usage")
        }
        expectCodexUsage(codexStreamError(cancelled.finish()), "llm.stream_closed", 7)
        let fresh = codec.newResponsesWebSocketSession(); let _ = fresh.prepare(codexRequest("model", [codexText("hi")]))
        let terminal = codexFinalResponse().replace("\"output\":[", "\"usage\":{\"input_tokens\":7},\"output\":[")
        let _ = codexUpdate(fresh.push(("{\"type\":\"response.completed\",\"response\":" + terminal + "}").toArray()))
        try { let _ = fresh.prepare(codexRequest("", [])); @Fail("invalid next request must fail") }
        catch (error: LlmWireError) { @Expect(error.code, "llm.model_missing"); @Expect(error.usage.isNone(), true) }
        let _ = fresh.prepare(codexRequest("model", [codexText("next")]))
        @Expect(codexStreamError(fresh.push([255u8])).usage.isNone(), true)
        for (cancelIdle in [false, true]) {
            let idle = codec.newResponsesWebSocketSession(); let _ = idle.prepare(codexRequest("model", [codexText("hi")]))
            let _ = codexUpdate(idle.push(("{\"type\":\"response.completed\",\"response\":" + terminal + "}").toArray()))
            if (cancelIdle) {
                match (idle.cancel()) {
                    case LlmWireResult.Ok(LlmWireTerminal.Cancelled(failure)) => @Expect(failure.usage.isNone(), true)
                    case _ => @Fail("idle cancellation must not inherit completed usage")
                }
            } else {
                let error = codexStreamError(idle.push([]))
                @Expect(error.code, "llm.websocket_response_missing"); @Expect(error.usage.isNone(), true)
            }
        }
    }

    @TestCase
    func requestRulesAndInstructions() {
        let codec = codexTestCodec()
        let request = codexRequest("model", [codexText("hello")], instructions: [
            LlmWireInstruction(LlmWireInstructionRole.System, "system"), LlmWireInstruction(LlmWireInstructionRole.Developer, "developer")
        ])
        let body = codexJson(codexHttpBody(codec, request))
        @Expect(body.field("store").getOrThrow().booleanValue(), Some(false))
        @Expect(body.field("stream").getOrThrow().booleanValue(), Some(true))
        @Expect(body.field("instructions").getOrThrow().stringValue(), Some("system"))
        @Expect(body.field("input").getOrThrow().values()[0].field("role").getOrThrow().stringValue(), Some("developer"))
        @Expect(body.field("input").getOrThrow().values()[1].field("type").getOrThrow().stringValue(), Some("message"))
        let regular = openAiResponsesCodec(openAiResponsesModelProfile("model", capabilities: allCapabilities()))
        let regularInput = codexJson(codexHttpBody(regular, request)).field("input").getOrThrow().values()
        @Expect(regularInput[2].field("type").isNone(), true)
        @Expect(body.field("include").getOrThrow().values()[0].stringValue(), Some("reasoning.encrypted_content"))
        @Expect(body.field("previous_response_id").isNone(), true)
        expectLlmError("llm.codex_stream_required", { => let _ = codec.encodeRequest(request) })
        expectLlmError("llm.codex_max_output_tokens_unsupported", { => let _ = codexHttpBody(codec, codexRequest("model", [codexText("hi")], maxOutputTokens: Some(32))) })
        expectLlmError("llm.codex_instruction_order_unsupported", { => let _ = codexHttpBody(codec, codexRequest("model", [codexText("hi")], instructions: [LlmWireInstruction(LlmWireInstructionRole.Developer, "dev"), LlmWireInstruction(LlmWireInstructionRole.System, "sys")])) })
        expectLlmError("llm.cache_unsupported", { => let _ = codexHttpBody(codec, codexRequest("model", [codexText("hi")], promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault))) })
        @Expect(openAiCodexResponsesDialect().compatibilityId, "openai.codex.responses.v1")
    }

    @TestCase
    func functionToolsAndEncryptedReplay() {
        let codec = codexTestCodec()
        let response = "{\"id\":\"resp_tool\",\"model\":\"model\",\"status\":\"completed\",\"output\":[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"opaque-ciphertext\"},{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"echo\",\"arguments\":\"{}\"}]}"
        let reply = succeededReply(codec.decodeResponse(response))
        let history = ArrayList<LlmWireMessage>(); history.add(codexText("hello"))
        for (message in reply.toContinuationInput()) { history.add(message) }
        history.add(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call_1", "hello"))]))
        let tools = [LlmWireTool("echo", "Echo", codexJson("{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}"))]
        let body = codexJson(codexHttpBody(codec, codexRequest("model", history.toArray(), tools: tools)))
        let input = body.field("input").getOrThrow().values()
        @Expect(input[0].field("type").getOrThrow().stringValue(), Some("additional_tools"))
        @Expect(body.field("tools").isNone(), true)
        @Expect(input[2].field("encrypted_content").getOrThrow().stringValue(), Some("opaque-ciphertext"))
        @Expect(input[4].field("type").getOrThrow().stringValue(), Some("function_call_output"))
        let wrongCodec = openAiResponsesCodec(openAiResponsesModelProfile("model", capabilities: allCapabilities()))
        expectLlmError("llm.native_replay_dialect_mismatch", { => let _ = wrongCodec.encodeRequest(codexRequest("model", history.toArray(), tools: tools)) })
    }

    @TestCase
    func sseWebSocketAndFixedAgree() {
        let codec = codexTestCodec(); let sse = codec.newStreamDecoder(); let ws = codec.newResponsesWebSocketSession()
        let _ = ws.prepare(codexRequest("model", [codexText("hello")]))
        var sseTerminal = LlmWireStreamUpdate(); var wsTerminal = LlmWireStreamUpdate()
        for (json in codexTextEvents()) {
            let bytes = ("data: " + json + "\n\n").toArray()
            for (byte in bytes) { let update = codexUpdate(sse.push([byte])); if (update.terminal.isSome()) { sseTerminal = update } }
            let update = codexUpdate(ws.push(json.toArray())); if (update.terminal.isSome()) { wsTerminal = update }
            for (event in update.events) { match (event) {
                case LlmWireEvent.TextDelta(text, identity) => @Expect(text, "ok"); @Expect(identity.phase, LlmWireOutputPhase.Final)
                case _ => ()
            } }
        }
        let fixed = succeededReply(codec.decodeResponse(codexFinalResponse()))
        for (reply in [fixed, succeededReply(sseTerminal), succeededReply(wsTerminal)]) {
            @Expect(reply.responseId, "resp_1")
            match (reply.blocks[0]) { case LlmWireOutputBlock.Text(value) => @Expect(value.text, "ok"); @Expect(value.phase, LlmWireOutputPhase.Final); case _ => @Fail("expected text") }
            let body = codexHttpBody(codec, codexRequest("model", reply.toContinuationInput()))
            @Expect(body.contains("\"phase\":\"final_answer\""), true)
            @Expect(body.contains("\"type\":\"message\""), true)
        }
        let _ = codexUpdate(sse.finish()); let _ = codexUpdate(ws.finish())
    }

    @TestCase
    func incrementalAndChangedHistory() {
        let codec = codexTestCodec(); let ws = codec.newResponsesWebSocketSession()
        let first = ws.prepare(codexRequest("model", [codexText("hello")]))
        let firstJson = codexJson(String.fromUtf8(first.body))
        @Expect(firstJson.field("stream").isNone(), true)
        @Expect(firstJson.field("type").getOrThrow().stringValue(), Some("response.create"))
        expectLlmError("llm.websocket_response_active", { => let _ = ws.prepare(codexRequest("model", [codexText("again")])) })
        let reply = succeededReply(codexUpdate(ws.push(("{\"type\":\"response.completed\",\"response\":" + codexFinalResponse() + "}").toArray())))
        let history = ArrayList<LlmWireMessage>(); history.add(codexText("hello")); for (message in reply.toContinuationInput()) { history.add(message) }; history.add(codexText("next"))
        let second = codexJson(String.fromUtf8(ws.prepare(codexRequest("model", history.toArray())).body))
        @Expect(second.field("previous_response_id").getOrThrow().stringValue(), Some("resp_1"))
        @Expect(second.field("input").getOrThrow().values().size, 1)
        let _ = codexUpdate(ws.push("{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_2\",\"status\":\"completed\",\"output\":[]}}".toArray()))
        let changed = codexJson(String.fromUtf8(ws.prepare(codexRequest("model", [codexText("different")])).body))
        @Expect(changed.field("previous_response_id").isNone(), true)
        let fresh = codec.newResponsesWebSocketSession()
        @Expect(codexJson(String.fromUtf8(fresh.prepare(codexRequest("model", history.toArray())).body)).field("previous_response_id").isNone(), true)
    }

    @TestCase
    func failureIncompleteAndTruncationClearState() {
        for (terminal in ["{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"usage_limit\",\"message\":\"stop\"}}}", "{\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_partial\",\"status\":\"incomplete\",\"output\":[]}}", "{\"type\":\"error\",\"status\":400,\"error\":{\"code\":\"previous_response_not_found\",\"message\":\"missing\"}}"] ) {
            let ws = codexTestCodec().newResponsesWebSocketSession(); let _ = ws.prepare(codexRequest("model", [codexText("hi")]))
            let update = codexUpdate(ws.push(terminal.toArray())); @Expect(update.terminal.isSome(), true)
            @Expect(codexJson(String.fromUtf8(ws.prepare(codexRequest("model", [codexText("hi")])).body)).field("previous_response_id").isNone(), true)
        }
        let ws = codexTestCodec().newResponsesWebSocketSession(); let _ = ws.prepare(codexRequest("model", [codexText("hi")]))
        @Expect(codexError(ws.finish()), "llm.stream_terminal_missing")
        let cancelled = codexTestCodec().newResponsesWebSocketSession(); let _ = cancelled.prepare(codexRequest("model", [codexText("hi")]))
        let _ = cancelled.cancel()
        expectLlmError("llm.stream_closed", { => let _ = cancelled.prepare(codexRequest("model", [codexText("hi")])) })
    }

    @TestCase
    func phaseMismatchAndMalformedMessages() {
        let ws = codexTestCodec().newResponsesWebSocketSession(); let _ = ws.prepare(codexRequest("model", [codexText("hi")]))
        for (json in codexTextEvents()[0..7]) { let _ = codexUpdate(ws.push(json.toArray())) }
        @Expect(codexError(ws.push(("{\"type\":\"response.completed\",\"response\":" + codexFinalResponse().replace("final_answer", "commentary") + "}").toArray())), "llm.responses_phase_mismatch")
        @Expect(codexError(ws.push("{}".toArray())), "llm.stream_failed")
        for (message in ["{\"type\":\"future\"}", "{\"type\":\"error\",\"type\":\"error\"}", "{\"type\":\"error\",\"stream_id\":\"other\"}"]) {
            let malformed = codexTestCodec().newResponsesWebSocketSession(); let _ = malformed.prepare(codexRequest("model", [codexText("hi")]))
            match (malformed.push(message.toArray())) { case LlmWireResult.Err(_) => (); case _ => @Fail("malformed message accepted") }
        }
        let utf8 = codexTestCodec().newResponsesWebSocketSession(); let _ = utf8.prepare(codexRequest("model", [codexText("hi")]))
        @Expect(codexError(utf8.push([255u8])), "llm.response_utf8_invalid")
    }

    @TestCase
    func boundedRequestsEventsAndState() {
        let codec = codexTestCodec()
        expectLlmError("llm.codex_request_too_large", { => let _ = codexHttpBody(codec, codexRequest("model", [codexText(String.fromUtf8(Array<Byte>(8388609, repeat: 65u8)))])) })
        let bounded = codec.newResponsesWebSocketSession(limits: LlmWireStreamLimits(maxRetainedStateBytes: 8))
        expectLlmError("llm.websocket_retained_state_too_large", { => let _ = bounded.prepare(codexRequest("model", [codexText("hi")])) })
        let ws = codec.newResponsesWebSocketSession(limits: LlmWireStreamLimits(maxEvents: 1)); let _ = ws.prepare(codexRequest("model", [codexText("hi")]))
        let _ = codexUpdate(ws.push(codexTextEvents()[0].toArray()))
        @Expect(codexError(ws.push(codexTextEvents()[1].toArray())), "llm.stream_events_too_many")
        let oversized = codec.newResponsesWebSocketSession(); let _ = oversized.prepare(codexRequest("model", [codexText("hi")]))
        @Expect(codexError(oversized.push(Array<Byte>(8388609, repeat: 65u8))), "llm.websocket_message_too_large")
    }

    @TestCase
    func detailHttpErrorsRetainDiagnostics() {
        let value = codexTestCodec().decodeResponse(LlmWireHttpResponse(403, [LlmWireHeader("x-request-id", "req_test")], "{\"detail\":{\"message\":\"not eligible\",\"code\":\"subscription_sharing_user_not_eligible\"}}".toArray()))
        match (value) {
            case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(failure))) =>
                @Expect(failure.httpStatus, Some(403)); @Expect(failure.providerErrorCode, "subscription_sharing_user_not_eligible"); @Expect(failure.providerRequestId, "req_test")
                @Expect(failure.diagnosticJson.getOrThrow().contains("detail"), true); @Expect(failure.retryable, false)
            case _ => @Fail("expected HTTP failure")
        }
        expectLlmError("llm.websocket_dialect_unsupported", { => let _ = openAiResponsesCodec(openAiResponsesModelProfile("model")).newResponsesWebSocketSession() })
    }

    @TestCase
    func explicitOptionsAndOrderedBlocks() {
        let codec = codexTestCodec(); let schema = codexJson("{\"type\":\"object\"}")
        let tools = [LlmWireTool("echo", "Echo", schema)]
        for (format in [LlmWireStructuredOutput.Text, LlmWireStructuredOutput.JsonObject, LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("answer", schema))]) {
            let body = codexJson(codexHttpBody(codec, codexRequest("model", [codexText("hi")], tools: tools,
                structuredOutput: format, reasoningEffort: LlmWireReasoningEffort.High, parallelToolCalls: Some(false), serviceTier: LlmWireServiceTier.Priority)))
            @Expect(body.field("text").getOrThrow().field("format").isSome(), true)
            @Expect(body.field("reasoning").getOrThrow().field("effort").getOrThrow().stringValue(), Some("high"))
            @Expect(body.field("parallel_tool_calls").getOrThrow().booleanValue(), Some(false))
            @Expect(body.field("service_tier").getOrThrow().stringValue(), Some("priority"))
        }
        let image = LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "https://example.test/image.png"))
        let input = codexJson(codexHttpBody(codec, codexRequest("model", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("before")), image, LlmWireBlock.Text(LlmWireTextBlock("after"))])]))).field("input").getOrThrow().values()
        @Expect(input.size, 1)
        @Expect(input[0].field("content").getOrThrow().values()[1].field("type").getOrThrow().stringValue(), Some("input_image"))
        @Expect(input[0].field("content").getOrThrow().values()[2].field("text").getOrThrow().stringValue(), Some("after"))
        for (phase in [LlmWireOutputPhase.Commentary, LlmWireOutputPhase.Final]) {
            let body = codexJson(codexHttpBody(codec, codexRequest("model", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(LlmWireTextBlock("text", phase: phase))])]))).field("input").getOrThrow().values()[0]
            @Expect(body.field("phase").isSome(), true)
            @Expect(body.field("content").getOrThrow().values()[0].field("type").getOrThrow().stringValue(), Some("output_text"))
        }
        expectLlmError("llm.codex_phase_role_unsupported", { => let _ = codexHttpBody(codec, codexRequest("model", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hi", phase: LlmWireOutputPhase.Final))])])) })
        expectLlmError("llm.codex_instruction_order_unsupported", { => let _ = codexHttpBody(codec, codexRequest("model", [codexText("hi")], instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "one"), LlmWireInstruction(LlmWireInstructionRole.System, "two")])) })
        let annotated = LlmWireTextBlock("text", citations: [LlmWireCitation(LlmWireCitationKind.Url, url: "https://example.test")])
        expectLlmError("llm.codex_text_metadata_unsupported", { => let _ = codexHttpBody(codec, codexRequest("model", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(annotated)])])) })
        let escaped = String.fromUtf8(Array<Byte>(4194305, repeat: 10u8))
        expectLlmError("llm.codex_request_too_large", { => let _ = codexHttpBody(codec, codexRequest("model", [codexText(escaped)])) })
    }

    @TestCase
    func changedConfigurationAndImmutableFrames() {
        let ws = codexTestCodec().newResponsesWebSocketSession()
        let first = ws.prepare(codexRequest("model", [codexText("hello")]))
        let copy = first.body; copy[0] = 0u8; @Expect(first.body[0], 123u8)
        let reply = succeededReply(codexUpdate(ws.push(("{\"type\":\"response.completed\",\"response\":" + codexFinalResponse() + "}").toArray())))
        let history = ArrayList<LlmWireMessage>(); history.add(codexText("hello")); for (message in reply.toContinuationInput()) { history.add(message) }; history.add(codexText("next"))
        let changed = codexJson(String.fromUtf8(ws.prepare(codexRequest("model", history.toArray(), instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "changed")])).body))
        @Expect(changed.field("previous_response_id").isNone(), true); @Expect(changed.field("input").getOrThrow().values().size, 3)
        let _ = ws.cancel()
        @Expect(codexError(ws.push("{}".toArray())), "llm.stream_closed")
        @Expect(codexError(ws.finish()), "llm.stream_failed")
        let empty = codexTestCodec().newResponsesWebSocketSession()
        @Expect(codexError(empty.push("{}".toArray())), "llm.websocket_response_missing")
        match (empty.cancel()) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.stream_failed"); case _ => @Fail("poisoned session accepted cancellation") }
        let inactive = codexTestCodec().newResponsesWebSocketSession(); let _ = inactive.cancel()
        expectLlmError("llm.stream_closed", { => let _ = inactive.prepare(codexRequest("model", [codexText("hi")])) })
    }

    @TestCase
    func toolResultIncrementAndRefusalFallback() {
        let codec = codexTestCodec(); let ws = codec.newResponsesWebSocketSession()
        let tools = [LlmWireTool("echo", "Echo", codexJson("{\"type\":\"object\"}"))]
        let _ = ws.prepare(codexRequest("model", [codexText("hello")], tools: tools))
        let response = "{\"id\":\"resp_tool\",\"status\":\"completed\",\"output\":[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"ciphertext\"},{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"echo\",\"arguments\":\"{}\"}]}"
        let reply = succeededReply(codexUpdate(ws.push(("{\"type\":\"response.completed\",\"response\":" + response + "}").toArray())))
        let history = ArrayList<LlmWireMessage>(); history.add(codexText("hello")); for (message in reply.toContinuationInput()) { history.add(message) }; history.add(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call_1", "result"))]))
        let frame = codexJson(String.fromUtf8(ws.prepare(codexRequest("model", history.toArray(), tools: tools)).body))
        @Expect(frame.field("previous_response_id").getOrThrow().stringValue(), Some("resp_tool"))
        @Expect(frame.field("input").getOrThrow().values().size, 1)
        @Expect(frame.field("input").getOrThrow().values()[0].field("type").getOrThrow().stringValue(), Some("function_call_output"))
        let _ = ws.cancel()
        let refused = codec.newResponsesWebSocketSession(); let _ = refused.prepare(codexRequest("model", [codexText("hi")]))
        let _ = codexUpdate(refused.push("{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_refused\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"denied\"}]}]}}".toArray()))
        @Expect(codexJson(String.fromUtf8(refused.prepare(codexRequest("model", [codexText("new")])).body)).field("previous_response_id").isNone(), true)
    }

    @TestCase
    func reasoningAndPhaseLifecycleReconciliation() {
        let codec = codexTestCodec()
        for (cipher in ["ciphertext", "different"]) {
            let ws = codec.newResponsesWebSocketSession(); let _ = ws.prepare(codexRequest("model", [codexText("hi")]))
            let _ = codexUpdate(ws.push(codexTextEvents()[0].toArray()))
            let _ = codexUpdate(ws.push("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\"}}".toArray()))
            let _ = codexUpdate(ws.push("{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"ciphertext\"}}".toArray()))
            let result = ws.push(("{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"output\":[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"" + cipher + "\"}]}}").toArray())
            if (cipher == "ciphertext") { @Expect(succeededReply(codexUpdate(result)).blocks.size, 1) } else { @Expect(codexError(result), "llm.responses_reasoning_mismatch") }
        }
        let phase = codec.newResponsesWebSocketSession(); let _ = phase.prepare(codexRequest("model", [codexText("hi")]))
        for (event in codexTextEvents()[0..6]) { let _ = codexUpdate(phase.push(event.toArray())) }
        @Expect(codexError(phase.push(codexTextEvents()[6].replace("final_answer", "commentary").toArray())), "llm.responses_phase_mismatch")
        for (payload in ["{\"type\":\"function_call\",\"namespace\":\"tools\",\"call_id\":\"call_1\",\"name\":\"echo\",\"arguments\":\"{}\"}", "{\"type\":\"function_call\",\"phase\":\"final_answer\",\"call_id\":\"call_1\",\"name\":\"echo\",\"arguments\":\"{}\"}"]) {
            expectLlmError("llm.responses_semantic_unsupported", { => let _ = codec.decodeResponse("{\"status\":\"completed\",\"output\":[" + payload + "]}") })
        }
        expectLlmError("llm.field_type_invalid", { => let _ = codec.decodeResponse("{\"status\":\"completed\",\"output\":[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":42}]}") })
    }

    @TestCase
    func structuredErrorsAndRetainedCheckpointLimits() {
        let codec = codexTestCodec()
        let ws = codec.newResponsesWebSocketSession(); let _ = ws.prepare(codexRequest("model", [codexText("hi")]))
        match (codexUpdate(ws.push("{\"type\":\"error\",\"status\":429,\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"quota\"}}".toArray())).terminal.getOrThrow()) {
            case LlmWireTerminal.ProviderFailed(failure) => @Expect(failure.httpStatus, Some(429)); @Expect(failure.retryable, true); @Expect(failure.diagnosticJson.isSome(), true)
            case _ => @Fail("expected WS provider failure")
        }
        let invalid = codec.newResponsesWebSocketSession(); let _ = invalid.prepare(codexRequest("model", [codexText("hi")]))
        @Expect(codexError(invalid.push("{\"type\":\"error\",\"status\":999,\"error\":{\"message\":\"bad\"}}".toArray())), "llm.http_status_invalid")
        match (codec.decodeResponse(LlmWireHttpResponse(401, [], "{\"detail\":\"Sign in again\"}".toArray()))) {
            case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(failure))) => @Expect(failure.message, "Sign in again"); @Expect(failure.httpStatus, Some(401))
            case _ => @Fail("expected detail failure")
        }
        let retained = codec.newResponsesWebSocketSession(limits: LlmWireStreamLimits(maxRetainedStateBytes: 512))
        let _ = retained.prepare(codexRequest("model", [codexText(String.fromUtf8(Array<Byte>(200, repeat: 65u8)))]))
        let response = codexFinalResponse().replace("\"ok\"", "\"" + String.fromUtf8(Array<Byte>(200, repeat: 66u8)) + "\"")
        @Expect(codexError(retained.push(("{\"type\":\"response.completed\",\"response\":" + response + "}").toArray())), "llm.websocket_retained_state_too_large")
        let oversizeDiagnostic = "{\"detail\":\"" + String.fromUtf8(Array<Byte>(65537, repeat: 65u8)) + "\"}"
        match (codec.decodeResponse(LlmWireHttpResponse(403, [], oversizeDiagnostic.toArray()))) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.failure_diagnostic_too_large"); case _ => @Fail("unbounded diagnostic accepted") }
    }

    @TestCase
    func httpErrorShapesAndTransportBounds() {
        let codec = codexTestCodec()
        for (body in ["{\"detail\":null}", "{\"detail\":[\"quota\"]}", "{\"error\":{\"code\":\"denied\",\"message\":\"stop\"}}", "{\"status\":\"completed\",\"output\":[]}"]) {
            match (codec.decodeResponse(LlmWireHttpResponse(503, [LlmWireHeader("retry-after", "2")], body.toArray()))) {
                case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(failure))) => @Expect(failure.httpStatus, Some(503)); @Expect(failure.retryAfterMillis, Some(2000)); @Expect(failure.retryable, true)
                case _ => @Fail("expected structured HTTP failure")
            }
        }
        match (codec.decodeResponse(LlmWireHttpResponse(400, [], "malformed".toArray()))) { case LlmWireResult.Err(_) => (); case _ => @Fail("invalid detail body accepted") }
        match (codec.decodeResponse(LlmWireHttpResponse(200, [], Array<Byte>(8388609, repeat: 65u8)))) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.body_too_large"); case _ => @Fail("oversized HTTP body accepted") }
        for (status in [99, 600]) {
            let ws = codec.newResponsesWebSocketSession(); let _ = ws.prepare(codexRequest("model", [codexText("hi")]))
            @Expect(codexError(ws.push(("{\"type\":\"error\",\"status\":" + status.toString() + ",\"error\":{\"message\":\"bad\"}}").toArray())), "llm.http_status_invalid")
        }
        let namespaced = "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"namespace\":\"\",\"call_id\":\"call_1\",\"name\":\"echo\",\"arguments\":\"{}\"}]}"
        @Expect(succeededReply(codec.decodeResponse(namespaced)).blocks.size, 1)
        for (metadata in ["\"annotations\":[{\"type\":\"url_citation\",\"url\":\"https://example.test\"}]", "\"logprobs\":[{\"token\":\"ok\",\"logprob\":0}]"]) {
            expectLlmError("llm.responses_semantic_unsupported", { => let _ = codec.decodeResponse(codexFinalResponse().replace("\"text\":\"ok\"", "\"text\":\"ok\"," + metadata)) })
        }
    }

    @TestCase
    func refusalAndEmptyReasoningLifecycle() {
        let codec = codexTestCodec(); let ws = codec.newResponsesWebSocketSession(); let _ = ws.prepare(codexRequest("model", [codexText("hi")]))
        let sse = codec.newStreamDecoder()
        for (event in [codexTextEvents()[0], codexTextEvents()[1],
            "{\"type\":\"response.content_part.added\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"part\":{\"type\":\"refusal\"}}",
            "{\"type\":\"response.refusal.delta\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"delta\":\"denied\"}",
            "{\"type\":\"response.refusal.done\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"refusal\":\"denied\"}",
            "{\"type\":\"response.content_part.done\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"part\":{\"type\":\"refusal\",\"refusal\":\"denied\"}}", codexTextEvents()[6].replace("\"type\":\"output_text\",\"text\":\"ok\"", "\"type\":\"refusal\",\"refusal\":\"denied\"")]) {
            let update = codexUpdate(ws.push(event.toArray()))
            let _ = codexUpdate(sse.push(("data: " + event + "\n\n").toArray()))
            for (value in update.events) { match (value) { case LlmWireEvent.RefusalDelta(text, identity) => @Expect(text, "denied"); @Expect(identity.phase, LlmWireOutputPhase.Final); case _ => () } }
        }
        let terminal = codexFinalResponse().replace("\"type\":\"output_text\",\"text\":\"ok\"", "\"type\":\"refusal\",\"refusal\":\"denied\"")
        let wsReply = succeededReply(codexUpdate(ws.push(("{\"type\":\"response.completed\",\"response\":" + terminal + "}").toArray())))
        let sseReply = succeededReply(codexUpdate(sse.push(("data: {\"type\":\"response.completed\",\"response\":" + terminal + "}\n\n").toArray())))
        for (reply in [sseReply, wsReply]) { match (reply.choices[0].outcome) { case LlmWireChoiceOutcome.Refused(_) => (); case _ => @Fail("expected refused choice") } }
        let _ = codexUpdate(sse.finish())
        let _ = codexUpdate(ws.finish())
        let emptyReasoning = codec.newResponsesWebSocketSession(); let _ = emptyReasoning.prepare(codexRequest("model", [codexText("hi")]))
        for (event in [codexTextEvents()[0], "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[]}}", "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[]}}", "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"output\":[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[]}]}}"] ) { let _ = codexUpdate(emptyReasoning.push(event.toArray())) }
        let _ = codexUpdate(emptyReasoning.finish())
    }

    @TestCase
    func rejectedMetadataAndShortenedHistory() {
        let codec = codexTestCodec(); let citation = LlmWireCitation(LlmWireCitationKind.Url, url: "https://example.test")
        for (text in [LlmWireTextBlock("hi", annotations: [LlmWireAnnotation.UrlCitation(citation)]), LlmWireTextBlock("hi", logprobs: [LlmWireTokenLogprob("hi", codexJson("0"))])]) {
            expectLlmError("llm.codex_text_metadata_unsupported", { => let _ = codexHttpBody(codec, codexRequest("model", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(text)])])) })
        }
        expectLlmError("llm.reasoning_display_only", { => let _ = codexHttpBody(codec, codexRequest("model", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Reasoning(LlmWireReasoningBlock("display"))])])) })
        let ws = codec.newResponsesWebSocketSession(); let _ = ws.prepare(codexRequest("model", [codexText("hello")]))
        let _ = codexUpdate(ws.push(("{\"type\":\"response.completed\",\"stream_id\":\"main\",\"response\":" + codexFinalResponse() + "}").toArray()))
        @Expect(codexJson(String.fromUtf8(ws.prepare(codexRequest("model", [codexText("hello")])).body)).field("previous_response_id").isNone(), true)
        let _ = codexUpdate(ws.push("{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}".toArray()))
        @Expect(codexJson(String.fromUtf8(ws.prepare(codexRequest("model", [codexText("hello"), codexText("again")])).body)).field("previous_response_id").isNone(), true)
        let _ = ws.cancel()
        let tools = [LlmWireTool("echo", "Echo", codexJson("{\"type\":\"object\"}"))]
        let call = LlmWireBlock.ToolCall(LlmWireToolCallBlock("call_1", "echo", LlmWireToolArguments.Complete(codexJson("{}"))))
        let result = LlmWireBlock.ToolResult(LlmWireToolResultBlock("call_1", [LlmWireToolResultContent.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "https://example.test/image.png"))]))
        @Expect(codexHttpBody(codec, codexRequest("model", [codexText("hi"), LlmWireMessage(LlmWireRole.Assistant, [call]), LlmWireMessage(LlmWireRole.User, [result])], tools: tools)).contains("function_call_output"), true)
    }

    @TestCase
    func webSocketEnvelopeLimitDoesNotStartAResponse() {
        let codec = codexTestCodec(); let ws = codec.newResponsesWebSocketSession()
        let overhead = codexHttpBody(codec, codexRequest("model", [codexText("hi")])).size - 2
        let text = String.fromUtf8(Array<Byte>(8388608 - overhead, repeat: 65u8))
        expectLlmError("llm.codex_request_too_large", { => let _ = ws.prepare(codexRequest("model", [codexText(text)])) })
        let _ = ws.prepare(codexRequest("model", [codexText("hello")]))
        let reply = succeededReply(codexUpdate(ws.push(("{\"type\":\"response.completed\",\"response\":" + codexFinalResponse() + "}").toArray())))
        let history = ArrayList<LlmWireMessage>(); history.add(codexText("hello")); for (message in reply.toContinuationInput()) { history.add(message) }
        let continued = codexJson(String.fromUtf8(ws.prepare(codexRequest("model", history.toArray())).body))
        @Expect(continued.field("previous_response_id").getOrThrow().stringValue(), Some("resp_1"))
        @Expect(continued.field("input").getOrThrow().values().size, 0)
        let _ = ws.cancel()
    }
}
