package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

func responsesResult<T>(value: LlmWireResult<T>): T {
    match (value) { case LlmWireResult.Ok(result) => result; case LlmWireResult.Err(error) => throw error }
}

func responsesFixed(codec: LlmWireCodec, body: String): LlmWireReply {
    succeededReply(responsesResult(codec.decodeResponse(LlmWireHttpResponse(200, [], body.toArray()))))
}

func responsesEnvelope(item: String): String {
    "{\"id\":\"resp_protocol\",\"object\":\"response\",\"model\":\"model\",\"status\":\"completed\",\"output\":[" + item + "],\"usage\":{\"input_tokens\":3,\"output_tokens\":2,\"total_tokens\":5}}"
}

func responsesMessage(phase: String, refusal!: Bool = false): String {
    let part = if (refusal) { "{\"type\":\"refusal\",\"refusal\":\"no é\"}" } else { "{\"type\":\"output_text\",\"text\":\"ok é\",\"annotations\":[],\"logprobs\":[]}" }
    "{\"id\":\"msg_protocol\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\"" +
        (if (phase == "") { "" } else { ",\"phase\":\"" + phase + "\"" }) + ",\"content\":[" + part + "]}"
}

// These payloads follow the event schema independently of the codec's encoder.
func responsesMessageEvents(phase: String, refusal!: Bool = false, latePhase!: Bool = false): Array<String> {
    let kind = if (refusal) { "refusal" } else { "output_text" }
    let value = if (refusal) { "no é" } else { "ok é" }
    let field = if (refusal) { "refusal" } else { "text" }
    let prefix = "\"item_id\":\"msg_protocol\",\"output_index\":0,\"content_index\":0,"
    let phaseField = if (phase == "" || latePhase) { "" } else { ",\"phase\":\"" + phase + "\"" }
    [
        "{\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"resp_protocol\",\"model\":\"model\",\"status\":\"in_progress\",\"output\":[]}}",
        "{\"type\":\"response.output_item.added\",\"sequence_number\":1,\"output_index\":0,\"item\":{\"id\":\"msg_protocol\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]" + phaseField + "}}",
        "{\"type\":\"response.content_part.added\",\"sequence_number\":2," + prefix + "\"part\":{\"type\":\"" + kind + "\",\"" + field + "\":\"\"}}",
        "{\"type\":\"response." + kind + ".delta\",\"sequence_number\":3," + prefix + "\"delta\":\"" + value + "\"}",
        "{\"type\":\"response." + kind + ".done\",\"sequence_number\":4," + prefix + "\"" + field + "\":\"" + value + "\"}",
        "{\"type\":\"response.content_part.done\",\"sequence_number\":5," + prefix + "\"part\":{\"type\":\"" + kind + "\",\"" + field + "\":\"" + value + "\"}}",
        "{\"type\":\"response.output_item.done\",\"sequence_number\":6,\"output_index\":0,\"item\":" + responsesMessage(phase, refusal: refusal) + "}",
        "{\"type\":\"response.completed\",\"sequence_number\":7,\"response\":" + responsesEnvelope(responsesMessage(phase, refusal: refusal)) + "}"
    ]
}

func responsesByteReply(codec: LlmWireCodec, events: Array<String>, chunkSize: Int64): LlmWireReply {
    let source = StringBuilder()
    for (value in events) { source.append("data: "); source.append(value); source.append("\n\n") }
    let bytes = source.toString().toArray(); let stream = codec.newStreamDecoder()
    var offset: Int64 = 0; var terminal = LlmWireStreamUpdate()
    while (offset < bytes.size) {
        let end = if (chunkSize > bytes.size - offset) { bytes.size } else { offset + chunkSize }
        let update = responsesResult(stream.push(bytes[offset..end]))
        if (update.terminal.isSome()) { terminal = update }
        offset = end
    }
    let _ = responsesResult(stream.finish())
    succeededReply(terminal)
}

func expectResponsesEquivalent(expected: LlmWireReply, actual: LlmWireReply): Unit {
    @Expect(actual.responseId, expected.responseId); @Expect(actual.model, expected.model)
    @Expect(actual.rawStopReason, expected.rawStopReason)
    @Expect(actual.usage.inputTokens, expected.usage.inputTokens); @Expect(actual.usage.outputTokens, expected.usage.outputTokens)
    @Expect(actual.usage.totalTokens, expected.usage.totalTokens)
    @Expect(actual.choices.size, expected.choices.size); @Expect(actual.blocks.size, expected.blocks.size)
    let a = actual.choices[0]; let e = expected.choices[0]
    @Expect(a.index, e.index); @Expect(a.rawStopReason, e.rawStopReason)
    @Expect(a.messageSpans.size, e.messageSpans.size)
    for (index in 0..e.messageSpans.size) {
        @Expect(a.messageSpans[index].blockStart, e.messageSpans[index].blockStart)
        @Expect(a.messageSpans[index].blockCount, e.messageSpans[index].blockCount)
        @Expect(a.messageSpans[index].phase, e.messageSpans[index].phase)
    }
    for (index in 0..e.blocks.size) { match ((e.blocks[index], a.blocks[index])) {
        case (LlmWireOutputBlock.Text(left), LlmWireOutputBlock.Text(right)) =>
            @Expect(right.text, left.text); @Expect(right.phase, left.phase)
            @Expect(right.annotations.size, left.annotations.size); @Expect(right.logprobs.size, left.logprobs.size)
        case (LlmWireOutputBlock.Refusal(left), LlmWireOutputBlock.Refusal(right)) => @Expect(right.text, left.text)
        case (LlmWireOutputBlock.ToolCall(left), LlmWireOutputBlock.ToolCall(right)) =>
            @Expect(right.callId, left.callId); @Expect(right.name, left.name)
            match ((left.arguments, right.arguments)) {
                case (LlmWireToolArguments.Complete(l), LlmWireToolArguments.Complete(r)) => @Expect(r.stringify(), l.stringify())
                case _ => @Fail("expected executable function arguments")
            }
        case _ => @Fail("canonical Responses block type differs")
    } }
    match ((e.outcome, a.outcome)) {
        case (LlmWireChoiceOutcome.Completed, LlmWireChoiceOutcome.Completed) => ()
        case (LlmWireChoiceOutcome.Refused(left), LlmWireChoiceOutcome.Refused(right)) => @Expect(right.text, left.text)
        case _ => @Fail("canonical Responses outcome differs")
    }
}

func responsesReplayBody(codec: LlmWireCodec, reply: LlmWireReply): String {
    let continuation = responsesResult(reply.choices[0].toContinuationInput())
    let transcript = LlmWireTranscript(items: messageItems(continuation))
    let snapshot = responsesResult(transcript.snapshot())
    let restored = responsesResult(LlmWireTranscript.restore(snapshot))
    String.fromUtf8(responsesResult(codec.encodeRequest(LlmWireRequest("model", restored), streaming: true).materialize()).body)
}

@Test
class ResponsesProtocolTest {
    @TestCase
    func normativeMessageLifecyclesMatchAcrossPublicTransports() {
        for (codec in [openAiResponsesCodec(openAiResponsesModelProfile("model")), codexTestCodec()]) {
            for (phase in ["", "commentary", "final_answer"]) { for (refusal in [false, true]) {
                let fixed = responsesFixed(codec, responsesEnvelope(responsesMessage(phase, refusal: refusal)))
                @Expect(fixed.choices[0].messageSpans.size, 1)
                for (chunk in [Int64(100000), 1, 37]) {
                    expectResponsesEquivalent(fixed, responsesByteReply(codec, responsesMessageEvents(phase, refusal: refusal), chunk))
                }
                if (codec.dialect.compatibilityId == "openai.codex.responses.v1") {
                    let ws = codec.newResponsesWebSocketSession(); let _ = ws.prepare(codexRequest("model", [codexText("hello")]))
                    var terminal = LlmWireStreamUpdate()
                    for (value in responsesMessageEvents(phase, refusal: refusal)) { terminal = responsesResult(ws.push(value.toArray())) }
                    expectResponsesEquivalent(fixed, succeededReply(terminal))
                }
            } }
        }
    }

    @TestCase
    func normativeFunctionLifecycleMatchesFixedAndFragmentedBytes() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let item = "{\"id\":\"fc_protocol\",\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"call_protocol\",\"name\":\"echo\",\"arguments\":\"{\\\"value\\\":\\\"é\\\"}\"}"
        let events = [
            "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_protocol\",\"model\":\"model\"},\"sequence_number\":0}",
            "{\"type\":\"response.output_item.added\",\"output_index\":0,\"sequence_number\":1,\"item\":{\"id\":\"fc_protocol\",\"type\":\"function_call\",\"call_id\":\"call_protocol\",\"name\":\"echo\",\"arguments\":\"\",\"status\":\"in_progress\"}}",
            "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc_protocol\",\"sequence_number\":2,\"delta\":\"{\\\"value\\\":\\\"é\\\"}\"}",
            "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"fc_protocol\",\"sequence_number\":3,\"arguments\":\"{\\\"value\\\":\\\"é\\\"}\"}",
            "{\"type\":\"response.output_item.done\",\"output_index\":0,\"sequence_number\":4,\"item\":" + item + "}",
            "{\"type\":\"response.completed\",\"sequence_number\":5,\"response\":" + responsesEnvelope(item) + "}"
        ]
        for (chunk in [Int64(100000), 1, 29]) { expectResponsesEquivalent(responsesFixed(codec, responsesEnvelope(item)), responsesByteReply(codec, events, chunk)) }
        let codex = codexTestCodec(); let ws = codex.newResponsesWebSocketSession()
        let _ = ws.prepare(codexRequest("model", [codexText("hello")]))
        var terminal = LlmWireStreamUpdate()
        for (value in events) { terminal = responsesResult(ws.push(value.toArray())) }
        expectResponsesEquivalent(responsesFixed(codex, responsesEnvelope(item)), succeededReply(terminal))
    }

    @TestCase
    func phaseMayFirstAppearAtDoneWithoutBeingErased() {
        for (phase in ["commentary", "final_answer"]) {
            let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
            let expected = responsesFixed(codec, responsesEnvelope(responsesMessage(phase)))
            for (omitTerminalPhase in [false, true]) {
                let events = responsesMessageEvents(phase, latePhase: true)
                if (omitTerminalPhase) { events[7] = events[7].replace(",\"phase\":\"" + phase + "\"", "") }
                expectResponsesEquivalent(expected, responsesByteReply(codec, events, 1))
            }
        }
    }

    @TestCase
    func itemAndValueDoneRejectMalformedIdentityOrderAndDuplicates() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let base = responsesMessageEvents("commentary")
        let cases = [
            (6, base[6].replace("\"id\":\"msg_protocol\",", ""), "llm.field_missing"),
            (6, base[6].replace("\"output_index\":0,", ""), "llm.field_missing"),
            (6, base[6].replace("msg_protocol", "other"), "llm.responses_event_without_item"),
            (6, base[6].replace("\"output_index\":0", "\"output_index\":1"), "llm.responses_output_index_mismatch"),
            (6, base[6].replace("\"type\":\"message\"", "\"type\":\"reasoning\""), "llm.responses_output_item_mismatch"),
            (6, base[6].replace("commentary", "final_answer"), "llm.responses_phase_mismatch"),
            (4, base[4].replace("ok é", "different"), "llm.responses_text_mismatch"),
            (5, base[5].replace("ok é", "different"), "llm.responses_text_mismatch")
        ]
        for ((count, malformed, code) in cases) {
            let stream = codec.newStreamDecoder()
            for (index in 0..count) { let _ = responsesResult(stream.push(("data: " + base[index] + "\n\n").toArray())) }
            @Expect(codexError(stream.push(("data: " + malformed + "\n\n").toArray())), code)
        }
        let early = codec.newStreamDecoder()
        for (index in 0..4) { let _ = responsesResult(early.push(("data: " + base[index] + "\n\n").toArray())) }
        @Expect(codexError(early.push(("data: " + base[6] + "\n\n").toArray())), "llm.responses_content_part_incomplete")
        let duplicate = codec.newStreamDecoder()
        for (index in 0..7) { let _ = responsesResult(duplicate.push(("data: " + base[index] + "\n\n").toArray())) }
        @Expect(codexError(duplicate.push(("data: " + base[6] + "\n\n").toArray())), "llm.responses_output_item_done_duplicate")
    }

    @TestCase
    func officialPhasesAndMessageBoundariesSurviveReplayAndSnapshot() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let first = responsesMessage("commentary")
        let second = responsesMessage("commentary").replace("msg_protocol", "msg_second")
        let third = responsesMessage("final_answer").replace("msg_protocol", "msg_final")
        let reply = responsesFixed(codec, responsesEnvelope(first + "," + second + "," + third))
        @Expect(reply.choices[0].messageSpans.size, 3)
        let body = responsesResult(LlmWireJson.parse(responsesReplayBody(codec, reply)))
        let input = body.field("input").getOrThrow().values()
        @Expect(input.size, 3)
        @Expect(input[0].field("phase").getOrThrow().stringValue(), Some("commentary"))
        @Expect(input[1].field("phase").getOrThrow().stringValue(), Some("commentary"))
        @Expect(input[2].field("phase").getOrThrow().stringValue(), Some("final_answer"))
        let twoParts = first.replace("\"content\":[", "\"content\":[{\"type\":\"output_text\",\"text\":\"first\"},")
        let combined = responsesFixed(codec, responsesEnvelope(twoParts))
        @Expect(combined.choices[0].messageSpans[0].blockCount, 2)
        let combinedInput = responsesResult(LlmWireJson.parse(responsesReplayBody(codec, combined))).field("input").getOrThrow().values()
        @Expect(combinedInput.size, 1); @Expect(combinedInput[0].field("content").getOrThrow().values().size, 2)
        let reasoning = "{\"id\":\"reasoning_protocol\",\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"ciphertext\"}"
        let mixed = responsesFixed(codec, responsesEnvelope(first + "," + reasoning + "," + third))
        let mixedInput = responsesResult(LlmWireJson.parse(responsesReplayBody(codec, mixed))).field("input").getOrThrow().values()
        @Expect(mixedInput.size, 3)
        @Expect(mixedInput[1].field("type").getOrThrow().stringValue(), Some("reasoning"))
        @Expect(mixedInput[2].field("phase").getOrThrow().stringValue(), Some("final_answer"))
    }

    @TestCase
    func unsupportedPhaseValuesAndRolesFailClosed() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        for (phase in ["analysis", "final", "future"]) {
            match (codec.decodeResponse(LlmWireHttpResponse(200, [], responsesEnvelope(responsesMessage(phase)).toArray()))) {
                case LlmWireResult.Err(error) => @Expect(error.code, "llm.responses_semantic_unsupported")
                case _ => @Fail("unknown wire phase must fail")
            }
            let stream = codec.newStreamDecoder(); let events = responsesMessageEvents(phase)
            let _ = responsesResult(stream.push(("data: " + events[0] + "\n\n").toArray()))
            @Expect(codexError(stream.push(("data: " + events[1] + "\n\n").toArray())), "llm.responses_semantic_unsupported")
        }
        let user = LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello", phase: LlmWireOutputPhase.Final))])
        expectLlmError("llm.responses_phase_role_unsupported", { => let _ = codec.encodeRequest(LlmWireRequest("model", LlmWireTranscript(items: [LlmWireInputItem.Message(user)]))) })
        let analysis = LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(LlmWireTextBlock("hello", phase: LlmWireOutputPhase.Analysis))])
        expectLlmError("llm.responses_phase_unsupported", { => let _ = codec.encodeRequest(LlmWireRequest("model", LlmWireTranscript(items: [LlmWireInputItem.Message(analysis)]))) })
        let nullPhase = responsesEnvelope(responsesMessage("").replace("\"content\":", "\"phase\":null,\"content\":"))
        @Expect(responsesFixed(codec, nullPhase).choices[0].messageSpans[0].phase, LlmWireOutputPhase.Unspecified)
    }

    @TestCase
    func explicitSpanLayoutConflictsAndUnreplayableContentFailClosed() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let blocks = [LlmWireBlock.Text(LlmWireTextBlock("one")), LlmWireBlock.Text(LlmWireTextBlock("two"))]
        let layouts = [
            [LlmWireAssistantMessageSpan(0, -1)], [LlmWireAssistantMessageSpan(-1, 1)],
            [LlmWireAssistantMessageSpan(0, 3)], [LlmWireAssistantMessageSpan(1, 1)],
            [LlmWireAssistantMessageSpan(0, 1)],
            [LlmWireAssistantMessageSpan(0, 2), LlmWireAssistantMessageSpan(1, 1)]
        ]
        for (spans in layouts) {
            let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, blocks, messageSpans: spans))])
            expectLlmError("llm.responses_message_spans_invalid", { => let _ = codec.encodeRequest(LlmWireRequest("model", transcript)) })
            match (transcript.snapshot()) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.transcript_snapshot_invalid"); case _ => @Fail("invalid layout must not be persisted") }
        }
        let conflict = LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(LlmWireTextBlock("one", phase: LlmWireOutputPhase.Final))],
            messageSpans: [LlmWireAssistantMessageSpan(0, 1, phase: LlmWireOutputPhase.Commentary)])
        let conflictingTranscript = LlmWireTranscript(items: [LlmWireInputItem.Message(conflict)])
        expectLlmError("llm.responses_phase_mismatch", { => let _ = codec.encodeRequest(LlmWireRequest("model", conflictingTranscript)) })
        match (conflictingTranscript.snapshot()) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.transcript_snapshot_invalid"); case _ => @Fail("conflicting phase must not be persisted") }
        let empty = responsesFixed(codec, responsesEnvelope("{\"id\":\"empty\",\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[]}"))
        let continuation = responsesResult(empty.choices[0].toContinuationInput())
        @Expect(continuation.size, 1); @Expect(continuation[0].messageSpans[0].blockCount, 0)
        expectLlmError("llm.message_empty", { => let _ = codec.encodeRequest(LlmWireRequest("model", LlmWireTranscript(items: messageItems(continuation)))) })
        let refusal = responsesFixed(codec, responsesEnvelope(responsesMessage("final_answer", refusal: true)))
        match (refusal.choices[0].toContinuationInput()) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.continuation_projection_lossy"); case _ => @Fail("display refusal must not disappear from replay") }
    }

    @TestCase
    func codexTemporalToolsKeepTheirPositionAndProfileGate() {
        let endpoint = LlmWireEndpointProfile("codex.fixture", "model", "openai.codex.responses.v1", "https://example.test/responses", 1,
            LlmWireContextUpdateContract(style: LlmWireContextUpdateStyle.ResponsesAdditionalTools).capabilities, "offline-protocol-fixture", "2026-10-18")
        let codec = openAiCodexResponsesCodec(openAiCodexResponsesModelProfile("model", capabilities: allCapabilities(), endpoint: endpoint.endpoint, endpointProfile: Some(endpoint)))
        let call = LlmWireBlock.ToolCall(LlmWireToolCallBlock("call_temporal", "echo", LlmWireToolArguments.Complete(responsesResult(LlmWireJson.parse("{}")))))
        let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(codexText("first")),
            LlmWireInputItem.ToolDeclaration(LlmWireToolDeclaration(LlmWireTool("echo", "Echo", responsesResult(LlmWireJson.parse("{\"type\":\"object\"}"))))),
            LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.Developer, "then")),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [call])),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call_temporal", "done"))]))])
        let input = responsesResult(LlmWireJson.parse(codexHttpBody(codec, LlmWireRequest("model", transcript)))).field("input").getOrThrow().values()
        @Expect(input.size, 5)
        @Expect(input[0].field("content").getOrThrow().values()[0].field("text").getOrThrow().stringValue(), Some("first"))
        @Expect(input[1].field("type").getOrThrow().stringValue(), Some("additional_tools"))
        @Expect(input[2].field("role").getOrThrow().stringValue(), Some("developer"))
        @Expect(input[3].field("type").getOrThrow().stringValue(), Some("function_call"))
        expectLlmError("llm.context_update_unsupported", { => let _ = codexTestCodec().encodeRequest(LlmWireRequest("model", transcript), streaming: true) })
    }

    @TestCase
    func snapshotVersionOneMigratesAndVersionTwoRejectsInvalidSpans() {
        let v1 = "{\"format\":\"llm4cj.transcript\",\"version\":1,\"initial_context\":{\"instructions\":[],\"tools\":[]},\"items\":[{\"kind\":\"message\",\"value\":{\"role\":\"assistant\",\"blocks\":[{\"kind\":\"text\",\"value\":{\"text\":\"old\",\"citations\":[],\"annotations\":[],\"logprobs\":[],\"phase\":\"final\"}}]}}]}"
        let restored = responsesResult(LlmWireTranscript.restore(v1))
        let migrated = responsesResult(restored.snapshot())
        @Expect(migrated.contains("\"version\":2"), true)
        @Expect(migrated.contains("\"message_spans\":[]"), true)
        let source = [LlmWireAssistantMessageSpan(0, 1, phase: LlmWireOutputPhase.Final)]
        let message = LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(LlmWireTextBlock("hello"))], messageSpans: source)
        source[0] = LlmWireAssistantMessageSpan(0, 0)
        let exposed = message.messageSpans; exposed[0] = LlmWireAssistantMessageSpan(0, 0)
        @Expect(message.messageSpans[0].blockCount, 1)
        let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(message)])
        let valid = responsesResult(transcript.snapshot())
        let roundTrip = responsesResult(responsesResult(LlmWireTranscript.restore(valid)).snapshot())
        @Expect(roundTrip, valid)
        for (invalid in [valid.replace("\"block_count\":1", "\"block_count\":2"), valid.replace("\"block_start\":0", "\"block_start\":-1"), valid.replace("\"role\":\"assistant\"", "\"role\":\"user\""), valid.replace("\"phase\":\"final\"", "\"phase\":\"future\"")]) {
            match (LlmWireTranscript.restore(invalid)) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.transcript_snapshot_invalid"); case _ => @Fail("invalid span snapshot must fail") }
        }
    }
}
