package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

func customAcceptanceError(action: () -> Unit): LlmWireError {
    try { action(); @Fail("expected a public error") }
    catch (error: LlmWireError) { error }
}

func customAcceptanceBoundaryError(action: () -> Unit): ?LlmWireError {
    try { action(); None }
    catch (error: LlmWireError) { Some(error) }
    catch (_: Exception) { None }
}

func customAcceptanceRequestBody(codec: LlmWireCodec, text: String, tools!: Array<LlmWireToolDeclaration> = []): String {
    let transcript = LlmWireTranscript(LlmWireInitialContext(tools: tools), items: [
        LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(text))]))
    ])
    let request = LlmWireRequest("model", transcript, maxOutputTokens: Some(8))
    String.fromUtf8(customResult(codec.encodeRequest(request).materialize()).body)
}

func customAcceptanceOtherCodecs(): Array<LlmWireCodec> {
    let capabilities = LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))
    [openAiChatCodec(openAiChatModelProfile("model", capabilities: capabilities)),
        anthropicMessagesCodec(anthropicMessagesModelProfile("model", capabilities: capabilities))]
}

@Test
class CustomAcceptanceTest {
    @TestCase
    func declarationIdentityIncludesFormatSyntaxAndDescription() {
        let regex = LlmWireCustomToolFormat.Grammar(LlmWireGrammar(LlmWireGrammarSyntax.Regex, "[a-z]+"))
        let lark = LlmWireCustomToolFormat.Grammar(LlmWireGrammar(LlmWireGrammarSyntax.Lark, "start: \"hello\""))
        for ((left, right) in [(LlmWireCustomToolFormat.Text, regex), (regex, LlmWireCustomToolFormat.Text), (regex, lark), (lark, regex)]) {
            let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [customDeclaration(format: left)]), items: [
                customTranscript().items[0], LlmWireInputItem.ToolDeclaration(customDeclaration(format: right))
            ])
            let error = customAcceptanceError({ => let _ = customBody(customTemporalCodec(false), transcript) })
            @Expect(error.kind, LlmWireErrorKind.InvalidRequest)
            @Expect(error.code, "llm.tool_definition_conflict")
            @Expect(error.inputItemIndex, 1); @Expect(error.toolName, "run"); @Expect(error.toolVersion, "1")
        }
        let changedDescription = LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("run", description: "Changed")))
        let transcript = LlmWireTranscript(customTranscript().initialContext, items: [
            customTranscript().items[0], LlmWireInputItem.ToolDeclaration(changedDescription)
        ])
        customExpectError("llm.tool_definition_conflict", { => let _ = customBody(customTemporalCodec(false), transcript) })
    }

    @TestCase
    func historicalCallKindMustMatchThePriorDefinition() {
        let function = LlmWireToolDeclaration(LlmWireTool("run", "function", customResult(LlmWireJson.parse("{}"))))
        let functionArguments = LlmWireToolArguments.Complete(customResult(LlmWireJson.parse("{}")))
        for ((definition, arguments, kind) in [
            (customDeclaration(), functionArguments, LlmWireToolKind.Function),
            (function, LlmWireToolArguments.Text("run"), LlmWireToolKind.Custom)
        ]) {
            let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [definition]), items: [
                customTranscript().items[0],
                LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("call_1", "run", arguments))])),
                LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(LlmWireToolResultBlock("call_1", [LlmWireToolResultContent.Text(LlmWireTextBlock("done"))], kind: kind))]))
            ])
            let error = customAcceptanceError({ => let _ = customBody(customCodec(), transcript) })
            @Expect(error.kind, LlmWireErrorKind.InvalidRequest); @Expect(error.code, "llm.tool_kind_mismatch")
            @Expect(error.inputItemIndex, 1); @Expect(error.blockIndex, 0)
            @Expect(error.toolName, "run"); @Expect(error.toolCallId, "call_1")
        }
        let invalid = LlmWireToolDeclaration(LlmWireTool("invalid", "invalid schema", customResult(LlmWireJson.string("schema"))))
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [invalid]), items: customTranscript().items)
        let error = customAcceptanceError({ => let _ = customBody(customCodec(), transcript) })
        @Expect(error.code, "llm.tool_schema_invalid"); @Expect(error.inputItemIndex, -1)
        @Expect(error.toolName, "invalid")
    }

    @TestCase
    func doneOnlyInputCanFollowAnAddedItemWithoutPrefix() {
        for (codex in [false, true]) {
            let events = customEvents()
            let added = events[1].replace(",\"input\":\"\"", "")
            let reply = responsesByteReply(customCodec(codex: codex), [events[0], added, events[3], events[4], events[5]], 1)
            expectCustomInput(customCall(reply), "run é")
            @Expect(reply.usage.inputTokens, Some(3)); @Expect(reply.toContinuationInput(0).isOk(), true)
        }
    }

    @TestCase
    func itemDoneAndTerminalCannotChangeCallIdentityOrInput() {
        let events = customEvents(); let codec = customCodec()
        for ((oldValue, newValue) in [
            ("\"call_id\":\"call_1\"", "\"call_id\":\"other\""),
            ("\"name\":\"run\"", "\"name\":\"other\""),
            ("\"input\":\"run é\"", "\"input\":\"other\"")
        ]) {
            let itemDone = events[4].replace(oldValue, newValue)
            customExpectError("llm.responses_terminal_function_mismatch", { =>
                let _ = responsesByteReply(codec, [events[0], events[1], events[2], events[3], itemDone], 7)
            })
            let terminal = events[5].replace(oldValue, newValue)
            let error = customAcceptanceError({ =>
                let _ = responsesByteReply(codec, [events[0], events[1], events[2], events[3], events[4], terminal], 7)
            })
            @Expect(error.code, "llm.responses_terminal_function_mismatch")
            @Expect(error.usage.getOrThrow().inputTokens, Some(3))
            @Expect(error.usage.getOrThrow().outputTokens, Some(2))
        }
    }

    @TestCase
    func terminalOnlyPartialTextUsesTheSameExactInputBudget() {
        let codec = customCodec()
        let event = "data: {\"type\":\"response.incomplete\",\"response\":" + customEnvelope(customItem(input: "raw["), status: "incomplete") + "}\n\n"
        let decoder = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxToolArgumentsBytes: 4))
        let update = customResult(decoder.push(event.toArray()))
        match (update.terminal.getOrThrow()) {
            case LlmWireTerminal.Completed(reply) =>
                expectCustomInput(customCall(reply), "raw[", partial: true)
                @Expect(reply.toContinuationInput(0).isOk(), false)
            case _ => @Fail("incomplete terminal must retain diagnostic text")
        }
        let bounded = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxToolArgumentsBytes: 3))
        match (bounded.push(event.toArray())) {
            case LlmWireResult.Err(error) =>
                @Expect(error.code, "llm.stream_tool_arguments_too_large")
                @Expect(error.usage.getOrThrow().inputTokens, Some(3))
            case _ => @Fail("partial terminal input must be charged before terminal emission")
        }
    }

    @TestCase
    func legacySnapshotCannotReclassifyRawTextAsFunctionArguments() {
        let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [
            LlmWireBlock.ToolCall(LlmWireToolCallBlock("call_1", "run", LlmWireToolArguments.Text("{}")))
        ]))])
        let snapshot = customResult(transcript.snapshot())
        @Expect(snapshot.contains("\"version\":3"), true)
        let restored = customResult(LlmWireTranscript.restore(snapshot))
        @Expect(customResult(restored.snapshot()), snapshot)
        match (LlmWireTranscript.restore(snapshot.replace("\"version\":3", "\"version\":2"))) {
            case LlmWireResult.Err(error) =>
                @Expect(error.kind, LlmWireErrorKind.InvalidRequest)
                @Expect(error.code, "llm.transcript_snapshot_invalid")
            case _ => @Fail("version 2 cannot carry a raw-text argument tag")
        }
    }

    @TestCase
    func chatAndMessagesEscapedRequestsHonorExactBodyBudget() {
        for (codec in customAcceptanceOtherCodecs()) {
            let overhead = customAcceptanceRequestBody(codec, "a").size - 1
            let remaining = 8388608 - overhead
            let raw = String.fromUtf8(Array<Byte>(remaining / 2, repeat: 10u8)) + if (remaining % 2 == 0) { "" } else { "a" }
            @Expect(customAcceptanceRequestBody(codec, raw).size, 8388608)
            let failure = customAcceptanceBoundaryError({ => let _ = customAcceptanceRequestBody(codec, raw + "a") })
            @Expect(failure.isSome(), true)
            match (failure) {
                case Some(error) =>
                    @Expect(error.kind, LlmWireErrorKind.BodyLimit); @Expect(error.code, "llm.request_too_large")
                    @Expect(error.protocol, Some(codec.protocol)); @Expect(error.phase, Some(LlmTransportPhase.Encode))
                case None => ()
            }
            @Expect(customAcceptanceRequestBody(codec, "after rejection").contains("after rejection"), true)
        }
    }

    @TestCase
    func chatAndMessagesBoundTheDepthOfTheWrappedRequest() {
        for (codec in customAcceptanceOtherCodecs()) {
            // The function schema is valid JSON and within the standalone
            // depth bound. The protocol's request envelope adds 3 or 4 levels.
            let levels = if (codec.protocol == LlmWireProtocol.ChatCompletions) { 249 } else { 250 }
            for (overflow in [false, true]) {
                var schema = "{\"type\":\"string\"}"
                let count = levels + (if (overflow) { 1 } else { 0 })
                for (_ in 0..count) { schema = "{\"type\":\"array\",\"items\":" + schema + "}" }
                schema = "{\"type\":\"object\",\"properties\":{\"x\":" + schema + "}}"
                let declaration = LlmWireToolDeclaration(LlmWireTool("deep", "", customResult(LlmWireJson.parse(schema))))
                if (overflow) {
                    let failure = customAcceptanceBoundaryError({ => let _ = customAcceptanceRequestBody(codec, "depth", tools: [declaration]) })
                    @Expect(failure.isSome(), true)
                    match (failure) {
                        case Some(error) => @Expect(error.kind, LlmWireErrorKind.BodyLimit); @Expect(error.code, "llm.request_too_large")
                        case None => ()
                    }
                } else {
                    @Expect(customAcceptanceRequestBody(codec, "depth", tools: [declaration]).contains("\"name\":\"deep\""), true)
                }
            }
        }
    }
}
