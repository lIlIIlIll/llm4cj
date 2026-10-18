package llm4cj

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func customResult<T>(result: LlmWireResult<T>): T {
    match (result) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
}

func customCapabilities(): LlmWireCapabilities {
    LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true, parallelCalls: true,
        customFormats: [LlmWireCustomToolFormatKind.Text, LlmWireCustomToolFormatKind.Regex, LlmWireCustomToolFormatKind.Lark]))
}

func customCodec(codex!: Bool = false): LlmWireCodec {
    if (codex) { openAiCodexResponsesCodec(openAiCodexResponsesModelProfile("model", capabilities: customCapabilities())) }
    else { openAiResponsesCodec(openAiResponsesModelProfile("model", capabilities: customCapabilities())) }
}

func customDeclaration(format!: LlmWireCustomToolFormat = LlmWireCustomToolFormat.Text): LlmWireToolDeclaration {
    LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("run", description: "Run raw text", format: format)))
}

func customTranscript(format!: LlmWireCustomToolFormat = LlmWireCustomToolFormat.Text): LlmWireTranscript {
    LlmWireTranscript(LlmWireInitialContext(tools: [customDeclaration(format: format)]), items: [
        LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("run it"))]))
    ])
}

func customTemporalCodec(codex: Bool): LlmWireCodec {
    let dialectId = if (codex) { "openai.codex.responses.v1" } else { "openai.responses.v1" }
    let endpoint = "https://example.test/responses"
    let profile = LlmWireEndpointProfile("test.custom", "model", dialectId, endpoint, 1,
        LlmWireContextUpdateCapabilities(toolDeclaration: true), "offline schema-derived test", "2026-10-18")
    if (codex) { openAiCodexResponsesCodec(openAiCodexResponsesModelProfile("model", capabilities: customCapabilities(), endpoint: endpoint, endpointProfile: Some(profile))) }
    else { openAiResponsesCodec(openAiResponsesModelProfile("model", capabilities: customCapabilities(), endpoint: endpoint, endpointProfile: Some(profile))) }
}

func customBody(codec: LlmWireCodec, transcript: LlmWireTranscript): String {
    String.fromUtf8(customResult(codec.encodeRequest(LlmWireRequest("model", transcript), streaming: codec.dialect.compatibilityId == "openai.codex.responses.v1").materialize()).body)
}

func customItem(input!: String = "run é", status!: String = ""): String {
    "{\"id\":\"custom_1\",\"type\":\"custom_tool_call\",\"call_id\":\"call_1\",\"name\":\"run\",\"input\":\"" + input + "\"" + if (status == "") { "}" } else { ",\"status\":\"" + status + "\"}" }
}

func customEnvelope(item: String, status!: String = "completed"): String {
    "{\"id\":\"resp_custom\",\"model\":\"model\",\"status\":\"" + status + "\",\"output\":[" + item + "],\"usage\":{\"input_tokens\":3,\"output_tokens\":2}" + if (status == "incomplete") { ",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}" } else { "}" }
}

// Schema-derived payloads, independently written from the encoder.
func customEvents(prefix!: String = "", delta!: String = "run é", input!: String = "run é"): Array<String> {
    [
        "{\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"resp_custom\",\"model\":\"model\",\"status\":\"in_progress\",\"output\":[]}}",
        "{\"type\":\"response.output_item.added\",\"sequence_number\":1,\"output_index\":0,\"item\":" + customItem(input: prefix) + "}",
        "{\"type\":\"response.custom_tool_call_input.delta\",\"sequence_number\":2,\"item_id\":\"custom_1\",\"output_index\":0,\"delta\":\"" + delta + "\"}",
        "{\"type\":\"response.custom_tool_call_input.done\",\"sequence_number\":3,\"item_id\":\"custom_1\",\"output_index\":0,\"input\":\"" + input + "\"}",
        "{\"type\":\"response.output_item.done\",\"sequence_number\":4,\"output_index\":0,\"item\":" + customItem(input: input) + "}",
        "{\"type\":\"response.completed\",\"sequence_number\":5,\"response\":" + customEnvelope(customItem(input: input)) + "}"
    ]
}

func customFixed(codec: LlmWireCodec, body: String): LlmWireReply {
    match (customResult(codec.decodeResponse(LlmWireHttpResponse(200, [], body.toArray())))) {
        case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => reply
        case _ => @Fail("expected terminal reply")
    }
}

func customCall(reply: LlmWireReply, index!: Int64 = 0): LlmWireToolCallBlock {
    match (reply.blocks[index]) { case LlmWireOutputBlock.ToolCall(call) => call; case _ => @Fail("expected tool call") }
}

func expectCustomInput(call: LlmWireToolCallBlock, text: String, partial!: Bool = false): Unit {
    @Expect(call.kind, LlmWireToolKind.Custom); @Expect(call.callId, "call_1"); @Expect(call.name, "run")
    match (call.arguments) {
        case LlmWireToolArguments.Text(value) => @Expect(partial, false); @Expect(value, text)
        case LlmWireToolArguments.PartialText(value) => @Expect(partial, true); @Expect(value, text)
        case _ => @Fail("custom input must retain its raw text kind")
    }
}

func customExpectError(code: String, action: () -> Unit): Unit {
    try { action(); @Fail("expected error " + code) } catch (error: LlmWireError) { @Expect(error.code, code) }
}

func customHistory(reply: LlmWireReply, result: LlmWireToolResultBlock): LlmWireTranscript {
    let items = ArrayList<LlmWireInputItem>()
    for (item in customTranscript().items) { items.add(item) }
    for (message in customResult(reply.toContinuationInput(0))) { items.add(LlmWireInputItem.Message(message)) }
    items.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(result)])))
    LlmWireTranscript(customTranscript().initialContext, items: items.toArray())
}

@Test
class CustomToolsTest {
    @TestCase
    func stableTaggedModelAndConditionalSnapshotProbe() {
        let declaration = customDeclaration()
        @Expect(declaration.tool.name, "run"); @Expect(declaration.tool.kind, LlmWireToolKind.Custom)
        let body = customBody(customCodec(), customTranscript())
        @Expect(body.contains("\"type\":\"custom\""), true)
        @Expect(body.contains("\"format\":{\"type\":\"text\"}"), true)
        @Expect(body.contains("\"parameters\""), false)
        let snapshot = customResult(customTranscript().snapshot())
        @Expect(snapshot.contains("\"version\":3"), true)
        let restored = customResult(LlmWireTranscript.restore(snapshot))
        @Expect(restored.effectiveTools[0].kind, LlmWireToolKind.Custom)
        @Expect(customBody(customCodec(), restored), body)
        let legacy = LlmWireTranscript(LlmWireInitialContext(), items: [])
        @Expect(customResult(legacy.snapshot()), "{\"format\":\"llm4cj.transcript\",\"version\":2,\"initial_context\":{\"instructions\":[],\"tools\":[]},\"items\":[]}")
    }

    @TestCase
    func explicitFormatsAndCodexAdditionalTools() {
        for (codex in [false, true]) {
            let codec = customCodec(codex: codex)
            for (syntax in [LlmWireGrammarSyntax.Regex, LlmWireGrammarSyntax.Lark]) {
                let definition = if (syntax == LlmWireGrammarSyntax.Regex) { "[a-z]+" } else { "start: WORD\n%import common.WORD" }
                let format = LlmWireCustomToolFormat.Grammar(LlmWireGrammar(syntax, definition))
                let body = customBody(codec, customTranscript(format: format))
                @Expect(body.contains("\"type\":\"grammar\""), true)
                @Expect(body.contains(if (syntax == LlmWireGrammarSyntax.Regex) { "\"syntax\":\"regex\"" } else { "\"syntax\":\"lark\"" }), true)
                @Expect(body.contains("\"strict\""), false); @Expect(body.contains("\"parameters\""), false)
                @Expect(body.contains("\"type\":\"additional_tools\""), codex)
                let restored = customResult(LlmWireTranscript.restore(customResult(customTranscript(format: format).snapshot())))
                @Expect(customBody(codec, restored), body)
            }
        }
        let absent = openAiResponsesCodec(openAiResponsesModelProfile("model", capabilities: LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))))
        customExpectError("llm.custom_tool_format_unsupported", { => let _ = customBody(absent, customTranscript()) })
        let unsupported = deepSeekResponsesCodec(deepSeekResponsesModelProfile("model", capabilities: customCapabilities()))
        customExpectError("llm.custom_tool_format_unsupported", { => let _ = customBody(unsupported, customTranscript()) })
        customExpectError("llm.tools_unsupported", { => let _ = customBody(openAiResponsesCodec(openAiResponsesModelProfile("model")), customTranscript()) })
        let formats = [LlmWireCustomToolFormatKind.Text]
        let caps = LlmWireToolCapabilities(enabled: true, customFormats: formats)
        formats[0] = LlmWireCustomToolFormatKind.Lark
        let projected = caps.customFormats; projected[0] = LlmWireCustomToolFormatKind.Regex
        @Expect(caps.customFormats[0], LlmWireCustomToolFormatKind.Text)
        for (build in [
            { => let _ = LlmWireToolCapabilities(customFormats: [LlmWireCustomToolFormatKind.Text]) },
            { => let _ = LlmWireToolCapabilities(enabled: true, customFormats: [LlmWireCustomToolFormatKind.Text, LlmWireCustomToolFormatKind.Text]) },
            { => let _ = LlmWireDialectContract("test.custom.chat", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens, customToolFormats: [LlmWireCustomToolFormatKind.Text]) },
            { => let _ = LlmWireDialectContract("test.custom.disabled", LlmWireProtocol.Responses, LlmWireRequestStyle.OpenAiResponses, LlmWireOutputTokenField.MaxOutputTokens, tools: false, customToolFormats: [LlmWireCustomToolFormatKind.Text]) },
            { => let _ = LlmWireDialectContract("test.custom.duplicate", LlmWireProtocol.Responses, LlmWireRequestStyle.OpenAiResponses, LlmWireOutputTokenField.MaxOutputTokens, customToolFormats: [LlmWireCustomToolFormatKind.Text, LlmWireCustomToolFormatKind.Text]) }
        ]) { try { build(); @Fail("invalid capability declarations must be rejected") } catch (_: IllegalArgumentException) { () } }
    }

    @TestCase
    func fixedRawTextCompletionAndGrammarBarrier() {
        let codec = customCodec()
        for (input in ["run é", "{}", "", "not-json["]) {
            let reply = customFixed(codec, customEnvelope(customItem(input: input)))
            expectCustomInput(customCall(reply), input)
            @Expect(customResult(reply.toContinuationInput(0)).size, 1)
            for (mode in [LlmWireToolInputValidationMode.Strict, LlmWireToolInputValidationMode.ValidateSupportedSubset, LlmWireToolInputValidationMode.Disabled]) {
                @Expect(validateReplyToolInputs(reply, customTranscript(), mode: mode).isOk(), true)
                let grammar = customTranscript(format: LlmWireCustomToolFormat.Grammar(LlmWireGrammar(LlmWireGrammarSyntax.Regex, "[a-z]+")))
                let checked = validateReplyToolInputs(reply, grammar, mode: mode)
                if (mode == LlmWireToolInputValidationMode.Disabled) { @Expect(checked.isOk(), true) }
                else { match (checked) { case LlmWireResult.Err(error) => @Expect(error.kind, LlmWireErrorKind.Unsupported); @Expect(error.code, "llm.tool_grammar_validation_unsupported"); case _ => @Fail("grammar requires a local engine in both validation modes") } }
            }
        }
        let partial = customFixed(codec, customEnvelope(customItem(input: "run"), status: "incomplete"))
        expectCustomInput(customCall(partial), "run", partial: true)
        @Expect(partial.toContinuationInput(0).isOk(), false)
        @Expect(validateReplyToolInputs(partial, customTranscript(), mode: LlmWireToolInputValidationMode.Disabled).isOk(), false)
        for (status in ["incomplete", "in_progress"]) { expectCustomInput(customCall(customFixed(codec, customEnvelope(customItem(input: "run", status: status), status: "incomplete"))), "run", partial: true) }
        let completeInIncomplete = customFixed(codec, customEnvelope(customItem(status: "completed"), status: "incomplete"))
        expectCustomInput(customCall(completeInIncomplete), "run é")
        @Expect(completeInIncomplete.toContinuationInput(0).isOk(), true)
        let pending = customResult(codec.decodeResponse(LlmWireHttpResponse(200, [], customEnvelope(customItem(), status: "in_progress").toArray())))
        match (pending) { case LlmWireResponseState.Pending(LlmWirePendingReply.InProgress(reply)) => expectCustomInput(customCall(reply), "run é", partial: true); case _ => @Fail("expected pending custom input") }
    }

    @TestCase
    func sseAndWebSocketPreserveRawIdentityAndLifecycle() {
        for (codex in [false, true]) {
            let codec = customCodec(codex: codex)
            for (chunk in [1, 7, 65536]) {
                let reply = responsesByteReply(codec, customEvents(), chunk)
                expectCustomInput(customCall(reply), "run é")
                @Expect(reply.usage.inputTokens, Some(3)); @Expect(reply.usage.outputTokens, Some(2))
            }
            let stream = codec.newStreamDecoder(); let events = customEvents(prefix: "run ", delta: "é")
            let _ = customResult(stream.push(("data: " + events[0] + "\n\n").toArray()))
            let started = customResult(stream.push(("data: " + events[1] + "\n\n").toArray()))
            var sawKind = false
            for (event in started.events) { match (event) {
                case LlmWireEvent.ToolCallStarted(identity) => @Expect(identity.kind, LlmWireToolKind.Custom); @Expect(identity.callId, "call_1"); sawKind = true
                case LlmWireEvent.ToolArgumentsDelta(prefix, identity) => @Expect(prefix, "run "); @Expect(identity.kind, LlmWireToolKind.Custom)
                case _ => ()
            } }
            @Expect(sawKind, true)
            var final = LlmWireStreamUpdate()
            for (index in 2..events.size) { final = customResult(stream.push(("data: " + events[index] + "\n\n").toArray())) }
            match (final.terminal.getOrThrow()) { case LlmWireTerminal.Completed(reply) => expectCustomInput(customCall(reply), "run é"); case _ => @Fail("complete custom stream") }
            if (codex) {
                let ws = codec.newResponsesWebSocketSession(); let _ = ws.prepare(LlmWireRequest("model", customTranscript()))
                var update = LlmWireStreamUpdate()
                for (value in customEvents()) { update = customResult(ws.push(value.toArray())) }
                match (update.terminal.getOrThrow()) { case LlmWireTerminal.Completed(reply) => expectCustomInput(customCall(reply), "run é"); case _ => @Fail("custom WebSocket terminal") }
                let reply = customFixed(codec, customEnvelope(customItem()))
                let continued = String.fromUtf8(ws.prepare(LlmWireRequest("model", customHistory(reply, LlmWireToolResultBlock("call_1", [LlmWireToolResultContent.Text(LlmWireTextBlock("done"))], kind: LlmWireToolKind.Custom)))).body)
                @Expect(continued.contains("\"previous_response_id\":\"resp_custom\""), true)
                @Expect(continued.contains("\"custom_tool_call_output\""), true)
                @Expect(continued.contains("\"additional_tools\""), false)
            }
        }
    }

    @TestCase
    func customResultsRetainKindThroughContinuationAndSnapshot() {
        for (codex in [false, true]) {
            let codec = customCodec(codex: codex); let reply = customFixed(codec, customEnvelope(customItem(input: "{}")))
            let contents: Array<Array<LlmWireToolResultContent>> = [[], [LlmWireToolResultContent.Text(LlmWireTextBlock(""))], [LlmWireToolResultContent.Text(LlmWireTextBlock("done"))], [LlmWireToolResultContent.Text(LlmWireTextBlock("one")), LlmWireToolResultContent.Text(LlmWireTextBlock("two"))]]
            for (content in contents) {
                let result = LlmWireToolResultBlock("call_1", content, kind: LlmWireToolKind.Custom)
                let transcript = customHistory(reply, result)
                let body = customBody(codec, transcript)
                @Expect(body.contains("\"type\":\"custom_tool_call\""), true)
                @Expect(body.contains("\"input\":\"{}\""), true)
                @Expect(body.contains("\"type\":\"custom_tool_call_output\""), true)
                @Expect(body.contains(if (content.isEmpty()) { "\"output\":[]" } else if (content.size == 1) { "\"output\":\"" } else { "\"output\":[{\"type\":\"input_text\"" }), true)
                let snapshot = customResult(transcript.snapshot())
                @Expect(snapshot.contains("\"tool_kind\":\"custom\""), true)
                let restored = customResult(LlmWireTranscript.restore(snapshot))
                @Expect(customBody(codec, restored), body)
            }
            customExpectError("llm.tool_kind_mismatch", { => let _ = customBody(codec, customHistory(reply, LlmWireToolResultBlock("call_1", [LlmWireToolResultContent.Text(LlmWireTextBlock("done"))]))) })
            customExpectError("llm.tool_result_error_semantics_unsupported", { => let _ = customBody(codec, customHistory(reply, LlmWireToolResultBlock("call_1", [], kind: LlmWireToolKind.Custom, isError: true))) })
        }
        let partial = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("call_1", "run", LlmWireToolArguments.PartialText("raw[")))]))])
        let snapshot = customResult(partial.snapshot())
        @Expect(snapshot.contains("\"kind\":\"partial_text\""), true)
        let restored = customResult(LlmWireTranscript.restore(snapshot))
        customExpectError("llm.tool_arguments_partial", { => let _ = customBody(customCodec(), restored) })
        @Expect(LlmWireTranscript.restore(snapshot.replace("\"version\":3", "\"version\":2")).isOk(), false)
        @Expect(LlmWireTranscript.restore(snapshot.replace("\"version\":3", "\"version\":4")).isOk(), false)
    }

    @TestCase
    func lifecycleRejectsWrongCorrelationAndCompletion() {
        let codec = customCodec(); let valid = customEvents()
        for ((changed, code) in [
            (valid[2].replace("custom_1", "other"), "llm.responses_arguments_without_item"),
            (valid[2].replace("\"output_index\":0", "\"output_index\":1"), "llm.responses_output_index_mismatch"),
            (valid[2].replace("custom_tool_call_input", "function_call_arguments"), "llm.tool_kind_mismatch")
        ]) {
            customExpectError(code, { => let _ = responsesByteReply(codec, [valid[0], valid[1], changed], 65536) })
        }
        for ((events, code) in [
            ([valid[0], valid[1], valid[2], valid[3].replace("\"input\"", "\"arguments\"")], "llm.field_missing"),
            ([valid[0], valid[1], valid[2], valid[3].replace("run é", "other")], "llm.responses_function_arguments_mismatch"),
            ([valid[0], valid[1], valid[2], valid[4]], "llm.responses_function_call_incomplete"),
            ([valid[0], valid[1], valid[2], valid[3], valid[2]], "llm.responses_function_delta_after_done"),
            ([valid[0], valid[1], valid[2], valid[3], valid[3]], "llm.responses_function_done_duplicate"),
            ([valid[0], valid[1], valid[2], valid[3], valid[5]], "llm.responses_output_item_incomplete"),
            ([valid[0], valid[1], valid[2], valid[3], valid[4], valid[5].replace("run é", "other")], "llm.responses_terminal_function_mismatch"),
            ([valid[0], valid[1], valid[2], valid[3], valid[4].replace("custom_1", "other")], "llm.responses_event_without_item")
        ]) { customExpectError(code, { => let _ = responsesByteReply(codec, events, 65536) }) }
        let doneOnly = [valid[0], valid[1], valid[3], valid[4], valid[5]]
        expectCustomInput(customCall(responsesByteReply(codec, doneOnly, 1)), "run é")
        expectCustomInput(customCall(responsesByteReply(codec, [valid[5]], 1)), "run é")
        let incomplete = valid[5].replace("response.completed", "response.incomplete").replace(customEnvelope(customItem()), customEnvelope(customItem(), status: "incomplete"))
        let knownComplete = responsesByteReply(codec, [valid[0], valid[1], valid[2], valid[3], valid[4], incomplete], 1)
        expectCustomInput(customCall(knownComplete), "run é")
        for (added in [valid[1].replace("\"call_id\":\"call_1\"", "\"call_id\":\"\""), valid[1].replace("\"name\":\"run\"", "\"name\":\"bad name\"")]) {
            customExpectError("llm.tool_call_incomplete", { => let _ = responsesByteReply(codec, [valid[0], added], 1) })
        }
        let repeatedId = valid[1].replace("\"output_index\":0", "\"output_index\":1").replace("\"id\":\"custom_1\"", "\"id\":\"custom_2\"")
        customExpectError("llm.tool_call_id_duplicate", { => let _ = responsesByteReply(codec, [valid[0], valid[1], repeatedId], 1) })
    }

    @TestCase
    func malformedAndUnrepresentableCustomSemanticsFailClosed() {
        let codec = customCodec(); let item = customItem()
        for ((bad, code) in [
            (item.replace("\"input\":\"run é\"", "\"input\":7"), "llm.field_type_invalid"),
            (item.replace("\"call_id\":\"call_1\"", "\"call_id\":\"\""), "llm.tool_call_incomplete"),
            (item.replace("\"name\":\"run\"", "\"name\":\"bad name\""), "llm.tool_call_incomplete"),
            (item.replace("\"input\":\"run é\"", "\"input\":\"run é\",\"async\":true"), "llm.custom_tool_semantic_unsupported"),
            (item.replace("\"input\":\"run é\"", "\"input\":\"run é\",\"async\":\"true\""), "llm.field_type_invalid"),
            (item.replace("\"input\":\"run é\"", "\"input\":\"run é\",\"caller\":{\"type\":\"program\",\"tool_id\":\"p\"}"), "llm.custom_tool_semantic_unsupported"),
            (item.replace("\"input\":\"run é\"", "\"input\":\"run é\",\"namespace\":\"group\""), "llm.responses_semantic_unsupported"),
            (customItem(status: "in_progress"), "llm.responses_custom_status_mismatch"),
            (customItem(status: "unknown"), "llm.responses_custom_status_invalid"),
            (item.replace("custom_tool_call", "unknown_tool_call"), "llm.responses_block_unsupported")
        ]) { customExpectError(code, { => let _ = customFixed(codec, customEnvelope(bad)) }) }
        let direct = item.replace("\"input\":\"run é\"", "\"input\":\"run é\",\"async\":false,\"caller\":{\"type\":\"direct\"},\"namespace\":\"\"")
        expectCustomInput(customCall(customFixed(codec, customEnvelope(direct))), "run é")
        for (field in ["\"async\":null", "\"namespace\":null"]) {
            customExpectError("llm.field_type_invalid", { => let _ = customFixed(codec, customEnvelope(item.replace("\"input\":\"run é\"", "\"input\":\"run é\"," + field))) })
        }
        customExpectError("llm.custom_tool_unsupported", { => let _ = customFixed(deepSeekResponsesCodec(deepSeekResponsesModelProfile("model")), customEnvelope(item)) })
        customExpectError("llm.tool_call_id_duplicate", { => let _ = customFixed(codec, customEnvelope(item + "," + item)) })
        let customReply = customFixed(codec, customEnvelope(item))
        let function = LlmWireTranscript(LlmWireInitialContext(tools: [LlmWireToolDeclaration(LlmWireTool("run", "function", customResult(LlmWireJson.parse("{\"type\":\"object\"}"))))]), items: [])
        for (mode in [LlmWireToolInputValidationMode.Disabled, LlmWireToolInputValidationMode.Strict, LlmWireToolInputValidationMode.ValidateSupportedSubset]) {
            match (validateReplyToolInputs(customReply, function, mode: mode)) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.tool_kind_mismatch"); case _ => @Fail("kind barrier must not be disabled") }
        }
        let duplicate = LlmWireReply(blocks: [customReply.blocks[0], customReply.blocks[0]])
        match (validateReplyToolInputs(duplicate, customTranscript(), mode: LlmWireToolInputValidationMode.Disabled)) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.tool_call_id_duplicate"); case _ => @Fail("execution barrier rejects duplicate custom identities") }
        for ((id, name) in [("", "run"), ("call_1", "bad name")]) {
            let invalid = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock(id, name, LlmWireToolArguments.Text("raw")))])
            match (validateReplyToolInputs(invalid, customTranscript(), mode: LlmWireToolInputValidationMode.Disabled)) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.tool_call_incomplete"); case _ => @Fail("execution barrier must validate custom identities") }
        }
    }

    @TestCase
    func rawInputBudgetsApplyBeforeSemanticEmission() {
        let codec = customCodec(); let valid = customEvents()
        let limits = LlmWireStreamLimits(maxToolArgumentsBytes: 6)
        let stream = codec.newStreamDecoder(limits: limits)
        let _ = customResult(stream.push(("data: " + valid[0] + "\n\n").toArray()))
        let _ = customResult(stream.push(("data: " + valid[1] + "\n\n").toArray()))
        let _ = customResult(stream.push(("data: " + valid[2] + "\n\n").toArray()))
        match (stream.push(("data: " + valid[2] + "\n\n").toArray())) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.stream_tool_arguments_too_large"); case _ => @Fail("aggregate raw inputs exceed the configured bound") }
        let prefix = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxToolArgumentsBytes: 1))
        let _ = customResult(prefix.push(("data: " + valid[0] + "\n\n").toArray()))
        match (prefix.push(("data: " + customEvents(prefix: "xx")[1] + "\n\n").toArray())) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.stream_tool_arguments_too_large"); case _ => @Fail("initial input must be charged before events are emitted") }
        let terminalOnly = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxToolArgumentsBytes: 1))
        match (terminalOnly.push(("data: " + valid[5] + "\n\n").toArray())) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.stream_tool_arguments_too_large"); case _ => @Fail("terminal-only custom input uses the same budget") }
    }

    @TestCase
    func temporalDefinitionsKeepKindAndExactGrammarIdentity() {
        let initial = customTranscript().items[0]
        let call = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("call_1", "run", LlmWireToolArguments.Text("run")))]))
        let result = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(LlmWireToolResultBlock("call_1", [], kind: LlmWireToolKind.Custom))]))
        for (codex in [false, true]) {
            let codec = customTemporalCodec(codex)
            let temporal = LlmWireTranscript(items: [initial, LlmWireInputItem.ToolDeclaration(customDeclaration()), call, result])
            let body = customBody(codec, temporal)
            @Expect(body.contains("\"type\":\"additional_tools\""), true)
            @Expect(body.indexOf("run it").getOrThrow() < body.indexOf("additional_tools").getOrThrow(), true)
            @Expect(customBody(codec, customResult(LlmWireTranscript.restore(customResult(temporal.snapshot())))), body)
            customExpectError("llm.context_update_unsupported", { => let _ = customBody(customCodec(codex: codex), temporal) })
            customExpectError("llm.tool_reference_unknown", { => let _ = customBody(codec, LlmWireTranscript(items: [initial, call, result, LlmWireInputItem.ToolDeclaration(customDeclaration())])) })
            let function = LlmWireToolDeclaration(LlmWireTool("run", "Run raw text", customResult(LlmWireJson.parse("{}"))))
            customExpectError("llm.tool_definition_conflict", { => let _ = customBody(codec, LlmWireTranscript(LlmWireInitialContext(tools: [customDeclaration()]), items: [initial, LlmWireInputItem.ToolDeclaration(function)])) })
            let a = customDeclaration(format: LlmWireCustomToolFormat.Grammar(LlmWireGrammar(LlmWireGrammarSyntax.Lark, "start: \"x\"")))
            let b = customDeclaration(format: LlmWireCustomToolFormat.Grammar(LlmWireGrammar(LlmWireGrammarSyntax.Lark, "start:  \"x\"")))
            customExpectError("llm.tool_definition_conflict", { => let _ = customBody(codec, LlmWireTranscript(LlmWireInitialContext(tools: [a]), items: [initial, LlmWireInputItem.ToolDeclaration(b)])) })
            let version = LlmWireToolDeclaration(a.tool, version: "2")
            customExpectError("llm.tool_definition_conflict", { => let _ = customBody(codec, LlmWireTranscript(LlmWireInitialContext(tools: [a]), items: [initial, LlmWireInputItem.ToolDeclaration(version)])) })
            @Expect(customBody(codec, LlmWireTranscript(LlmWireInitialContext(tools: [a]), items: [initial, LlmWireInputItem.ToolDeclaration(a)])).contains("additional_tools"), codex)
        }
        let inactive = LlmWireTranscript(LlmWireInitialContext(tools: [LlmWireToolDeclaration(customDeclaration().tool, deferred: true)]))
        let reply = customFixed(customCodec(), customEnvelope(customItem()))
        match (validateReplyToolInputs(reply, inactive, mode: LlmWireToolInputValidationMode.Disabled)) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.tool_not_active"); case _ => @Fail("Disabled cannot activate a tool") }
    }

    @TestCase
    func mixedFunctionAndCustomCallsShareIdentityAndBudgets() {
        let function = "{\"id\":\"function_1\",\"type\":\"function_call\",\"call_id\":\"function_call_1\",\"name\":\"fn\",\"arguments\":\"{}\"}"
        let custom = customItem()
        let events = customEvents()
        let functionIdentity = "\"item_id\":\"function_1\",\"output_index\":0"
        let stream = [events[0],
            "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":" + function + "}",
            events[1].replace("\"output_index\":0", "\"output_index\":1"),
            "{\"type\":\"response.function_call_arguments.delta\"," + functionIdentity + ",\"delta\":\"{}\"}",
            "{\"type\":\"response.function_call_arguments.done\"," + functionIdentity + ",\"arguments\":\"{}\"}",
            events[2].replace("\"output_index\":0", "\"output_index\":1"), events[3].replace("\"output_index\":0", "\"output_index\":1"),
            "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" + function + "}",
            events[4].replace("\"output_index\":0", "\"output_index\":1"),
            "{\"type\":\"response.completed\",\"response\":" + customEnvelope(function + "," + custom) + "}"]
        let codec = customCodec(); let reply = responsesByteReply(codec, stream, 1)
        @Expect(reply.blocks.size, 2); @Expect(customCall(reply).kind, LlmWireToolKind.Function)
        expectCustomInput(customCall(reply, index: 1), "run é")
        let declarations = [customDeclaration(), LlmWireToolDeclaration(LlmWireTool("fn", "function", customResult(LlmWireJson.parse("{}"))))]
        let items = ArrayList<LlmWireInputItem>(); for (item in customTranscript().items) { items.add(item) }
        for (message in customResult(reply.toContinuationInput(0))) { items.add(LlmWireInputItem.Message(message)) }
        items.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [
            LlmWireBlock.ToolResult(LlmWireToolResultBlock("call_1", [], kind: LlmWireToolKind.Custom)),
            LlmWireBlock.ToolResult(LlmWireToolResultBlock("function_call_1", [LlmWireToolResultContent.Text(LlmWireTextBlock("ok"))]))
        ])))
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: declarations), items: items.toArray())
        let body = customBody(codec, transcript)
        @Expect(body.contains("custom_tool_call_output"), true); @Expect(body.contains("function_call_output"), true)
        @Expect(customBody(codec, customResult(LlmWireTranscript.restore(customResult(transcript.snapshot())))), body)
        let bounded = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxToolArgumentsBytes: 7))
        for (index in 0..5) { let _ = customResult(bounded.push(("data: " + stream[index] + "\n\n").toArray())) }
        match (bounded.push(("data: " + stream[5] + "\n\n").toArray())) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.stream_tool_arguments_too_large"); case _ => @Fail("function and custom input share the aggregate bound") }
    }

    @TestCase
    func responsesEscapedRequestBudgetIsPreappendAndExact() {
        let codec = customCodec()
        let transcript = { description: String => LlmWireTranscript(LlmWireInitialContext(tools: [LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("run", description: description)))]), items: customTranscript().items) }
        let overhead = customBody(codec, transcript("")).size
        let available = 8388608 - overhead
        let raw = String.fromUtf8(Array<Byte>(available / 2, repeat: 10u8)) + if (available % 2 == 0) { "" } else { "a" }
        @Expect(customBody(codec, transcript(raw)).size, 8388608)
        customExpectError("llm.request_too_large", { => let _ = customBody(codec, transcript(raw + "a")) })
        customExpectError("llm.request_too_large", { => let _ = customBody(codec, transcript(String.fromUtf8(Array<Byte>(8388609, repeat: 97u8)))) })
    }

    @TestCase
    func customSnapshotGrammarTagsAndImageResultsRemainExplicit() {
        let codec = customCodec(); let reply = customFixed(codec, customEnvelope(customItem()))
        let citation = LlmWireCitation(LlmWireCitationKind.Url, url: "https://example.test/source")
        for (text in [LlmWireTextBlock("done", phase: LlmWireOutputPhase.Final), LlmWireTextBlock("done", citations: [citation]), LlmWireTextBlock("done", annotations: [LlmWireAnnotation.UrlCitation(citation)]), LlmWireTextBlock("done", logprobs: [LlmWireTokenLogprob("done", customResult(LlmWireJson.number("0")))])]) {
            customExpectError("llm.custom_tool_result_metadata_unsupported", { => let _ = customBody(codec, customHistory(reply, LlmWireToolResultBlock("call_1", [LlmWireToolResultContent.Text(text)], kind: LlmWireToolKind.Custom))) })
        }
        let image = LlmWireToolResultContent.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "https://example.test/image.png"))
        let transcript = customHistory(reply, LlmWireToolResultBlock("call_1", [image], kind: LlmWireToolKind.Custom))
        customExpectError("llm.image_input_unsupported", { => let _ = customBody(codec, transcript) })
        let images = openAiResponsesCodec(openAiResponsesModelProfile("model", capabilities: LlmWireCapabilities(
            input: LlmWireInputCapabilities(modalities: [LlmWireInputModality.Text, LlmWireInputModality.Image]),
            tools: LlmWireToolCapabilities(enabled: true, customFormats: [LlmWireCustomToolFormatKind.Text]))))
        let body = customBody(images, transcript)
        @Expect(body.contains("\"type\":\"input_image\""), true)
        @Expect(customBody(images, customResult(LlmWireTranscript.restore(customResult(transcript.snapshot())))), body)
        let snapshot = customResult(customTranscript(format: LlmWireCustomToolFormat.Grammar(LlmWireGrammar(LlmWireGrammarSyntax.Regex, "[a-z]+"))).snapshot())
        for (source in [snapshot.replace("\"type\":\"grammar\"", "\"type\":\"future\""), snapshot.replace("\"syntax\":\"regex\"", "\"syntax\":\"future\"")]) {
            match (LlmWireTranscript.restore(source)) { case LlmWireResult.Err(error) => @Expect(error.kind, LlmWireErrorKind.Unsupported); @Expect(error.code, "llm.custom_tool_format_unsupported"); case _ => @Fail("unknown persisted format must not degrade to text") }
        }
        @Expect(LlmWireTranscript.restore(snapshot.replace("\"tool_kind\":\"custom\"", "\"tool_kind\":\"future\"")).isOk(), false)
        @Expect(LlmWireTranscript.restore(snapshot.replace("\"format\":{\"type\":\"grammar\"", "\"format\":{\"unknown\":true,\"type\":\"grammar\"")).isOk(), false)
        let resultOnly = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(LlmWireToolResultBlock("diagnostic", [], kind: LlmWireToolKind.Custom))]))])
        let diagnostic = customResult(resultOnly.snapshot())
        @Expect(diagnostic.contains("\"version\":3"), true)
        @Expect(customResult(customResult(LlmWireTranscript.restore(diagnostic)).snapshot()), diagnostic)
    }
}
