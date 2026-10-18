package llm4cj

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func customReviewValue<T>(result: LlmWireResult<T>): T {
    match (result) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
}

private func customReviewCodec(codex: Bool): LlmWireCodec {
    let caps = LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true,
        customFormats: [LlmWireCustomToolFormatKind.Text]))
    if (codex) { openAiCodexResponsesCodec(openAiCodexResponsesModelProfile("model", capabilities: caps)) }
    else { openAiResponsesCodec(openAiResponsesModelProfile("model", capabilities: caps)) }
}

private func customReviewItem(callId!: String = "call_1", name!: String = "run", id!: String = "item_1", extra!: String = "", function!: Bool = false): String {
    let fields = if (function) { "\"type\":\"function_call\",\"arguments\":\"{}\"" }
        else { "\"type\":\"custom_tool_call\",\"input\":\"private-tool-input\"" }
    "{\"id\":\"" + id + "\",\"call_id\":\"" + callId + "\",\"name\":\"" + name + "\"," + fields + extra + "}"
}

private func customReviewEnvelope(items: Array<String>, status: String): String {
    var output = ""
    for (item in items) { if (output != "") { output += "," }; output += item }
    "{\"id\":\"review_resp\",\"model\":\"model\",\"status\":\"" + status + "\",\"output\":[" + output +
        "],\"usage\":{\"input_tokens\":17,\"output_tokens\":5,\"total_tokens\":22}" +
        if (status == "incomplete") { ",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}" } else { "}" }
}

private func customReviewReply(codec: LlmWireCodec, items: Array<String>, status: String, lane: Int64, added: Bool): LlmWireReply {
    let body = customReviewEnvelope(items, status)
    if (lane == 0) {
        return match (customReviewValue(codec.decodeResponse(LlmWireHttpResponse(200, [], body.toArray())))) {
            case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => reply
            case LlmWireResponseState.Pending(LlmWirePendingReply.Queued(reply)) => reply
            case LlmWireResponseState.Pending(LlmWirePendingReply.InProgress(reply)) => reply
            case _ => @Fail("expected a custom reply")
        }
    }
    // Hand-authored Responses wire; no candidate encoder produces these expectations.
    let events = ArrayList<String>()
    events.add("{\"type\":\"response.created\",\"sequence_number\":0,\"response\":" + customReviewEnvelope([], "in_progress") + "}")
    if (added) {
        for (index in 0..items.size) {
            events.add("{\"type\":\"response.output_item.added\",\"sequence_number\":" + events.size.toString() +
                ",\"output_index\":" + index.toString() + ",\"item\":" + items[index] + "}")
        }
        if (status == "completed" && items.size == 1) {
            events.add("{\"type\":\"response.custom_tool_call_input.done\",\"sequence_number\":" + events.size.toString() +
                ",\"item_id\":\"item_1\",\"output_index\":0,\"input\":\"private-tool-input\"}")
            events.add("{\"type\":\"response.output_item.done\",\"sequence_number\":" + events.size.toString() +
                ",\"output_index\":0,\"item\":" + items[0] + "}")
        }
    }
    events.add("{\"type\":\"response." + status + "\",\"sequence_number\":" + events.size.toString() + ",\"response\":" + body + "}")
    var update = LlmWireStreamUpdate()
    if (lane == 1) {
        let decoder = codec.newStreamDecoder()
        for (event in events) { update = customReviewValue(decoder.push("data: " + event + "\n\n")) }
        let _ = customReviewValue(decoder.finish())
    } else {
        let declaration = LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("run")))
        let session = codec.newResponsesWebSocketSession()
        let request = LlmWireRequest("model", LlmWireTranscript(LlmWireInitialContext(tools: [declaration]), items: [
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("run"))]))
        ]))
        let _ = session.prepare(request)
        for (event in events) { update = customReviewValue(session.push(event.toArray())) }
    }
    match (update.terminal.getOrThrow()) {
        case LlmWireTerminal.Completed(reply) => reply
        case _ => @Fail("expected a custom terminal reply")
    }
}

private func customReviewFailure(codec: LlmWireCodec, items: Array<String>, status: String, lane: Int64, added: Bool, code: String): Unit {
    let observed: ?LlmWireError = try { let _ = customReviewReply(codec, items, status, lane, added); None }
        catch (error: LlmWireError) { Some(error) }
    @Expect(observed.isSome(), true)
    match (observed) {
        case Some(error) =>
            @Expect(error.code, code)
            @Expect(error.protocol, Some(LlmWireProtocol.Responses))
            @Expect(error.dialectId, codec.dialect.compatibilityId)
            @Expect(error.usage.isSome(), true)
            match (error.usage) {
                case Some(usage) => @Expect(usage.inputTokens, Some(17)); @Expect(usage.outputTokens, Some(5)); @Expect(usage.totalTokens, Some(22))
                case None => ()
            }
            if (code == "llm.custom_tool_semantic_unsupported") {
                @Expect(error.kind, LlmWireErrorKind.Unsupported)
                let diagnostic = error.diagnosticJson.getOrThrow()
                @Expect(diagnostic.contains("created_by"), true)
                @Expect(diagnostic.contains("actor-secret"), false)
                @Expect(diagnostic.contains("private-tool-input"), false)
                @Expect(diagnostic.contains("raw_fragment"), false)
                @Expect(diagnostic.size < 2048, true)
            } else { @Expect(error.kind, LlmWireErrorKind.InvalidWire) }
        case None => ()
    }
}

@Test
class CustomReviewTest {
    @TestCase
    func everyFixedCompletionValidatesCustomIdentity() {
        for (codex in [false, true]) {
            let codec = customReviewCodec(codex)
            for (status in ["completed", "incomplete", "in_progress", "queued"]) {
                for (item in [customReviewItem(callId: ""), customReviewItem(name: ""), customReviewItem(name: "bad.name")]) {
                    customReviewFailure(codec, [item], status, 0, false, "llm.tool_call_incomplete")
                }
            }
        }
    }

    @TestCase
    func customIdentityAndMixedKindDuplicatesMatchAllStreamShapes() {
        for (codex in [false, true]) {
            let codec = customReviewCodec(codex)
            for (status in ["completed", "incomplete"]) {
                for (lane in 0..(if (codex) { 3 } else { 2 })) {
                    for (added in [false, true]) {
                        if (lane == 0 && added) { continue }
                        for (item in [customReviewItem(callId: ""), customReviewItem(name: "bad.name")]) {
                            customReviewFailure(codec, [item], status, lane, added, "llm.tool_call_incomplete")
                        }
                        for ((first, second) in [(false, false), (true, false), (false, true)]) {
                            customReviewFailure(codec, [customReviewItem(function: first), customReviewItem(id: "item_2", function: second)],
                                status, lane, added, "llm.tool_call_id_duplicate")
                        }
                    }
                }
            }
        }
    }

    @TestCase
    func everyPresentActorValueFailsWithoutRetainingProviderText() {
        let longActor = StringBuilder()
        for (_ in 0..5000) { longActor.append("x") }
        let values = ["\"actor-secret\"", "\"\"", "null", "{\"id\":\"actor-secret\"}", "42", "true", "[]", "\"actor-secret" + longActor.toString() + "\""]
        for (codex in [false, true]) {
            let codec = customReviewCodec(codex)
            for (status in ["completed", "incomplete"]) {
                for (lane in 0..(if (codex) { 3 } else { 2 })) {
                    for (added in [false, true]) {
                        if (lane == 0 && added) { continue }
                        for (value in values) {
                            customReviewFailure(codec, [customReviewItem(extra: ",\"created_by\":" + value)],
                                status, lane, added, "llm.custom_tool_semantic_unsupported")
                        }
                    }
                }
            }
        }
    }

    @TestCase
    func validCustomCompletionAndFunctionOnlyPartialDiagnosticsStayIntact() {
        for (codex in [false, true]) {
            let codec = customReviewCodec(codex)
            for (status in ["completed", "incomplete"]) {
                for (lane in 0..(if (codex) { 3 } else { 2 })) {
                    for (added in [false, true]) {
                        if (lane == 0 && added) { continue }
                        let reply = customReviewReply(codec, [customReviewItem()], status, lane, added)
                        @Expect(reply.usage.inputTokens, Some(17)); @Expect(reply.usage.outputTokens, Some(5)); @Expect(reply.usage.totalTokens, Some(22))
                        match (reply.blocks[0]) {
                            case LlmWireOutputBlock.ToolCall(call) =>
                                @Expect(call.callId, "call_1"); @Expect(call.name, "run"); @Expect(call.kind, LlmWireToolKind.Custom)
                                match (call.arguments) {
                                    case LlmWireToolArguments.Text(value) => @Expect(status, "completed"); @Expect(value, "private-tool-input")
                                    case LlmWireToolArguments.PartialText(value) => @Expect(status, "incomplete"); @Expect(value, "private-tool-input")
                                    case _ => @Fail("custom text must retain its completion")
                                }
                            case _ => @Fail("expected a custom call")
                        }
                        @Expect(reply.toContinuationInput(0).isOk(), status == "completed")
                    }
                }
            }
            let functionOnly = customReviewReply(codec, [customReviewItem(callId: "", name: "bad.name", function: true),
                customReviewItem(callId: "", name: "bad.name", id: "item_2", function: true)], "incomplete", 0, false)
            @Expect(functionOnly.blocks.size, 2)
        }
    }
}
