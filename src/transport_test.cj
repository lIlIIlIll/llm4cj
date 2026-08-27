package llm4cj

import std.io.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

func allCapabilities(): LlmWireCapabilities {
    LlmWireCapabilities(
        thinkingDisabled: true, thinkingEnabled: true, thinkingEffort: true,
        thinkingBudget: true, thinkingAdaptive: true,
        thinkingLevels: [LlmWireThinkingLevel.Minimal, LlmWireThinkingLevel.Low, LlmWireThinkingLevel.Medium, LlmWireThinkingLevel.High, LlmWireThinkingLevel.XHigh, LlmWireThinkingLevel.Max],
        tools: true, structuredOutput: true, parallelToolCalls: true,
        serviceTier: true, stableCache: true
    )
}

func expectLlmError(code: String, body: () -> Unit): Unit {
    try {
        body()
        @Fail("expected LlmTransportError: " + code)
    } catch (error: LlmTransportError) { @Expect(error.code, code) }
}

func event(data: String): SseEvent { SseEvent("message", data, "", None) }

class AlternateChatReasoningDialect <: LlmWireDialect {
    private let standard = deepSeekChatDialect()
    public prop compatibilityId: String { get() { "test.chat.reasoning.v1" } }
    public prop protocol: LlmWireProtocol { get() { LlmWireProtocol.ChatCompletions } }
    public prop chatReasoningField: ?String { get() { Some("analysis") } }
    public func validateThinking(control: LlmWireThinkingControl, capabilities: LlmWireCapabilities): Unit { standard.validateThinking(control, capabilities) }
    public func encodeThinking(control: LlmWireThinkingControl): JsonNode { standard.encodeThinking(control) }
}

@Test
class Llm4CjV02Tests {
    @TestCase
    func t001DefaultRequestEncodesAllBuiltInDialects() {
        let codecs = [
            LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()),
            LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()),
            LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()),
            LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect()),
            LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect()),
            LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect())
        ]
        let request = LlmWireRequest("model", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello"))])])
        let expectedIds = ["openai.responses.v1", "openai.chat.v1", "anthropic.messages.v1", "deepseek.responses.v1", "deepseek.chat.v1", "deepseek.messages.v1"]
        for (index in 0..codecs.size) {
            let payload = codecs[index].encodeRequest(request)
            @Expect(codecs[index].dialect.compatibilityId, expectedIds[index])
            @Expect(payload.contains("thinking"), false)
            @Expect(payload.contains("reasoning_effort"), false)
            @Expect(payload.contains("parallel_tool_calls"), false)
            @Expect(payload.contains("tool_choice"), false)
        }
    }

    @TestCase
    func t002ThinkingUsesCapabilitiesAndDialectShape() {
        let capabilities = allCapabilities()
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities)
        let payload = responses.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Effort(LlmWireThinkingLevel.High)))
        @Expect(payload.contains("\"reasoning\":{\"effort\":\"high\"}"), true)

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: capabilities)
        let adaptive = messages.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Adaptive(Some(LlmWireThinkingLevel.High))))
        @Expect(adaptive.contains("\"thinking\":{\"type\":\"adaptive\"}"), true)
        @Expect(adaptive.contains("\"output_config\":{\"effort\":\"high\"}"), true)

        let deepSeek = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: capabilities)
        @Expect(deepSeek.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Enabled)).contains("\"type\":\"enabled\""), true)
        let unknown = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        expectLlmError("llm.thinking_unsupported", { => let _ = unknown.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Low))) })
        expectLlmError("llm.thinking_not_representable", { => let _ = responses.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Adaptive(None))) })
    }

    @TestCase
    func t003OpaqueBlocksRoundTripOnlyWithinDialect() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        let state = codec.decodeResponse("{\"id\":\"m\",\"model\":\"claude\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"sig\"},{\"type\":\"redacted_thinking\",\"data\":\"opaque\"},{\"type\":\"future_block\",\"x\":1}],\"stop_reason\":\"end_turn\"}")
        let blocks = match (state) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => reply.blocks; case _ => @Fail("expected success") }
        @Expect(blocks.size, 3)
        match (blocks[0]) { case LlmWireBlock.Opaque(value) => @Expect(value.payload()["signature"].string, "sig"); @Expect(value.displayReasoning, Some("why")); case _ => @Fail("thinking must be opaque") }
        match (blocks[1]) { case LlmWireBlock.Opaque(value) => @Expect(value.payload()["data"].string, "opaque"); case _ => @Fail("redacted thinking must be opaque") }
        let replay = codec.encodeRequest(LlmWireRequest("claude", [LlmWireMessage(LlmWireRole.Assistant, blocks)]))
        @Expect(replay.contains("\"signature\":\"sig\""), true)
        @Expect(replay.contains("\"data\":\"opaque\""), true)
        let foreignCodec = LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect())
        expectLlmError("llm.opaque_dialect_mismatch", { => let _ = foreignCodec.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, blocks)])) })
    }

    @TestCase
    func t004FixedResponsesMapTerminalStates() {
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        match (responses.decodeResponse("{\"status\":\"queued\"}")) { case LlmWireResponseState.Pending(LlmWirePendingReply.Queued(_)) => (); case _ => @Fail("queued must remain pending") }
        match (responses.decodeResponse("{\"status\":\"completed\",\"output\":[]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(_)) => (); case _ => @Fail("completed must succeed") }
        match (responses.decodeResponse("{\"status\":\"incomplete\",\"output\":[],\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(_, _)) => (); case _ => @Fail("incomplete must be distinct") }
        match (responses.decodeResponse("{\"status\":\"cancelled\"}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Failed(failure)) => match (failure.kind) { case LlmWireFailureKind.Cancelled => (); case _ => @Fail("wrong failure kind") }; case _ => @Fail("cancelled must fail") }

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        match (chat.decodeResponse("{\"choices\":[{\"message\":{\"content\":\"cut\"},\"finish_reason\":\"length\"}]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.Length)) => @Expect(reply.blocks.size, 1); case _ => @Fail("length must be incomplete") }
    }

    @TestCase
    func t005KnownFieldErrorsDoNotBecomeDefaults() {
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), provider: "p")
        match (responses.decodeResponse("{\"status\":\"completed\",\"error\":null,\"output\":[]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(_)) => (); case _ => @Fail("null error must not fail") }
        expectLlmError("llm.field_missing", { => let _ = responses.decodeResponse("{\"status\":\"completed\"}") })
        expectLlmError("llm.field_type_invalid", { => let _ = responses.decodeResponse("{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":\"many\"}}") })
        expectLlmError("llm.integer_invalid", { => let _ = responses.decodeResponse("{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":999999999999999999999}}") })
    }

    @TestCase
    func t006ToolArgumentsPreserveCompleteInvalidJsonAndShape() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        let objectState = codec.decodeResponse("{\"choices\":[{\"message\":{\"tool_calls\":[{\"id\":\"a\",\"function\":{\"name\":\"f\",\"arguments\":\"{\\\"x\\\":1}\"}}]},\"finish_reason\":\"tool_calls\"}]}")
        let shapeState = codec.decodeResponse("{\"choices\":[{\"message\":{\"tool_calls\":[{\"id\":\"b\",\"function\":{\"name\":\"f\",\"arguments\":\"[]\"}}]},\"finish_reason\":\"tool_calls\"}]}")
        let invalidState = codec.decodeResponse("{\"choices\":[{\"message\":{\"tool_calls\":[{\"id\":\"c\",\"function\":{\"name\":\"f\",\"arguments\":\"{\"}}]},\"finish_reason\":\"tool_calls\"}]}")
        match (objectState) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => match (reply.blocks[0]) { case LlmWireBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.Complete(_, raw) => @Expect(raw, "{\"x\":1}"); case _ => @Fail("expected complete") }; case _ => @Fail("expected tool") }; case _ => @Fail("expected success") }
        match (shapeState) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => match (reply.blocks[0]) { case LlmWireBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.InvalidShape(_, raw) => @Expect(raw, "[]"); case _ => @Fail("expected invalid shape") }; case _ => @Fail("expected tool") }; case _ => @Fail("expected success") }
        match (invalidState) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => match (reply.blocks[0]) { case LlmWireBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.InvalidJson(raw) => @Expect(raw, "{"); case _ => @Fail("expected invalid JSON") }; case _ => @Fail("expected tool") }; case _ => @Fail("expected success") }
    }

    @TestCase
    func t007StrictRejectsAndLenientPreservesToolHistory() {
        let blocks = [LlmWireBlock.ToolResult(LlmWireToolResultBlock("future", "result")), LlmWireBlock.Text(LlmWireTextBlock("after"))]
        let strict = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: allCapabilities())
        expectLlmError("llm.tool_result_unmatched", { => let _ = strict.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, blocks)])) })
        let lenient = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: allCapabilities(), validationPolicy: LlmWireValidationPolicy.Lenient)
        let payload = lenient.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, blocks)]))
        @Expect(payload.indexOf("future").getOrThrow() < payload.indexOf("after").getOrThrow(), true)
    }

    @TestCase
    func t008ChatStreamKeepsParallelToolIdentity() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        let decoder = codec.newStreamDecoder()
        let first = decoder.push(event("{\"id\":\"r\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c0\",\"function\":{\"name\":\"a\",\"arguments\":\"{\\\"x\\\":\"}},{\"index\":1,\"id\":\"c1\",\"function\":{\"name\":\"b\",\"arguments\":\"{\\\"y\\\":\"}}]}}]}"))
        @Expect(first.events.size, 2)
        @Expect(first.events[0].toolCallIndex, 0)
        @Expect(first.events[1].toolCallIndex, 1)
        let second = decoder.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"arguments\":\"2}\"}},{\"index\":0,\"function\":{\"arguments\":\"1}\"}}]}}]}"))
        @Expect(second.events[0].toolCallIndex, 1)
        @Expect(second.events[1].toolCallIndex, 0)
        let done = decoder.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}"))
        match (done.terminal) { case Some(LlmWireTerminal.Succeeded(reply)) => @Expect(reply.blocks.size, 2); case _ => @Fail("expected stream success") }
        let _ = decoder.push(event("[DONE]"))
        match (decoder.finishTransport()) { case LlmWireTerminal.Succeeded(reply) => @Expect(reply.blocks.size, 2); case _ => @Fail("expected success") }
    }

    @TestCase
    func t009ResponsesStreamSeparatesItemAndCallIds() {
        let decoder = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        let update = decoder.push(event("{\"type\":\"response.output_item.added\",\"output_index\":2,\"item\":{\"type\":\"function_call\",\"id\":\"item-1\",\"call_id\":\"call-9\",\"name\":\"lookup\"}}"))
        @Expect(update.events[0].itemId, "item-1")
        @Expect(update.events[0].callId, "call-9")
        let delta = decoder.push(event("{\"type\":\"response.function_call_arguments.delta\",\"output_index\":2,\"item_id\":\"item-1\",\"delta\":\"{}\"}"))
        @Expect(delta.events[0].itemId, "item-1")
        @Expect(delta.events[0].callId, "call-9")
        @Expect(delta.events[0].name, "lookup")
        let done = decoder.push(event("{\"type\":\"response.function_call_arguments.done\",\"output_index\":2,\"item_id\":\"item-1\",\"name\":\"lookup\",\"arguments\":\"{}\"}"))
        @Expect(done.events[0].callId, "call-9")
        expectLlmError("llm.responses_done_duplicate", { => let _ = decoder.push(event("{\"type\":\"response.function_call_arguments.done\",\"output_index\":2,\"item_id\":\"item-1\",\"name\":\"lookup\",\"arguments\":\"{}\"}")) })

        let late = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        let _ = late.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"item-2\",\"call_id\":\"call-2\",\"name\":\"lookup\"}}"))
        let _ = late.push(event("{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"item-2\",\"name\":\"lookup\",\"arguments\":\"\"}"))
        expectLlmError("llm.responses_delta_after_done", { => let _ = late.push(event("{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"item-2\",\"delta\":\"late\"}")) })
    }

    @TestCase
    func t010MessagesStreamPreservesOpaqueAndPartialBlocks() {
        let decoder = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        let _ = decoder.push(event("{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"claude\"}}"))
        let _ = decoder.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"why\"}}"))
        let _ = decoder.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig\"}}"))
        let _ = decoder.push(event("{\"type\":\"content_block_stop\",\"index\":0}"))
        let _ = decoder.push(event("{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"c\",\"name\":\"f\",\"input\":{}}}"))
        let _ = decoder.push(event("{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"x\\\":\"}}"))
        let _ = decoder.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":4}}"))
        let terminal = decoder.push(event("{\"type\":\"message_stop\"}"))
        match (terminal.terminal) {
            case Some(LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.MaxTokens)) =>
                match (reply.blocks[0]) { case LlmWireBlock.Opaque(value) => @Expect(value.snapshot().contains("sig"), true); case _ => @Fail("expected opaque") }
                match (reply.blocks[1]) { case LlmWireBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.Partial(raw) => @Expect(raw, "{\"x\":"); case _ => @Fail("expected partial") }; case _ => @Fail("expected tool") }
            case _ => @Fail("expected incomplete")
        }
    }

    @TestCase
    func t011StreamLifecycleRejectsMissingAndRepeatedTerminal() {
        let missing = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        expectLlmError("llm.stream_terminal_missing", { => let _ = missing.finishTransport() })
        expectLlmError("llm.stream_closed", { => let _ = missing.finishTransport() })

        let complete = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        let _ = complete.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"))
        expectLlmError("llm.stream_event_after_terminal", { => let _ = complete.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"late\"}}]}")) })
    }

    @TestCase
    func t012SseHandlesBytesBomLineEndingsAndPersistentFields() {
        let decoder = SseDecoder(maxEventBytes: 1024)
        match (decoder.push("\u{feff}id: a\rretry: 0\r\rdata: 你\r\n\r\ndata:\ndata: x\n\n".toArray())) {
            case LlmResult.Ok(events) =>
                @Expect(events.size, 2)
                @Expect(events[0].event, "message")
                @Expect(events[0].data, "你")
                @Expect(events[0].id, "a")
                @Expect(events[0].retryMillis, Some(0))
                @Expect(events[1].data, "\nx")
                @Expect(events[1].id, "a")
            case LlmResult.Err(error) => @Fail(error.message)
        }
        let tail = SseDecoder()
        match (tail.push("data: discarded")) { case LlmResult.Ok(values) => @Expect(values.size, 0); case LlmResult.Err(error) => @Fail(error.message) }
        match (tail.finish()) { case LlmResult.Ok(values) => @Expect(values.size, 0); case LlmResult.Err(error) => @Fail(error.message) }
    }

    @TestCase
    func t013SseLimitsWholeEventBlock() {
        let decoder = SseDecoder(maxEventBytes: 8)
        match (decoder.push(": 123456789\n\n")) { case LlmResult.Err(error) => @Expect(error.code, "llm.sse_event_too_large"); case _ => @Fail("large comment must count") }
    }

    @TestCase
    func t014RetryAfterSupportsSecondsAndHttpDates() {
        let epoch: Int64 = 784111777000
        @Expect(parseRetryAfterMillis("5", epoch), Some(5000))
        @Expect(parseRetryAfterMillis("Sun, 06 Nov 1994 08:49:37 GMT", epoch), Some(0))
        @Expect(parseRetryAfterMillis("Sunday, 06-Nov-94 08:49:38 GMT", epoch), Some(1000))
        @Expect(parseRetryAfterMillis("Sun Nov  6 08:49:39 1994", epoch), Some(2000))
        @Expect(parseRetryAfterMillis("invalid", epoch), None)
        @Expect(extractRetryAfterMillis("Retry-After: 1\nretry-after: 3\n", epoch), Some(3000))
    }

    @TestCase
    func t015ProviderErrorsAreWireFailures() {
        let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), provider: "openai")
        match (codec.decodeResponse("{\"error\":{\"type\":\"server_error\",\"code\":\"busy\",\"message\":\"try later\"}}")) {
            case LlmWireResponseState.Terminal(LlmWireTerminal.Failed(failure)) =>
                @Expect(failure.provider, "openai"); @Expect(failure.providerErrorType, "server_error"); @Expect(failure.providerErrorCode, "busy"); @Expect(failure.message, "try later")
            case _ => @Fail("provider error must be a failure outcome")
        }
        let stream = codec.newStreamDecoder()
        let update = stream.push(event("{\"type\":\"error\",\"error\":{\"type\":\"rate_limit\",\"message\":\"slow\"}}"))
        @Expect(update.events[0].text, "slow")
        match (update.terminal) { case Some(LlmWireTerminal.Failed(failure)) => @Expect(failure.providerErrorType, "rate_limit"); case _ => @Fail("stream error must fail") }
    }

    @TestCase
    func t016HttpBodyRemainsBounded() {
        let body = ByteBuffer(); body.write("hello".toArray())
        match (readLlmHttpBody(body, Some(5), 5)) { case LlmResult.Ok(value) => @Expect(String.fromUtf8(value), "hello"); case LlmResult.Err(error) => @Fail(error.message) }
        let large = ByteBuffer(); large.write("hello".toArray())
        match (readLlmHttpBody(large, Some(5), 4)) { case LlmResult.Err(error) => @Expect(error.code, "llm.body_too_large"); case _ => @Fail("body must be bounded") }
    }

    @TestCase
    func t017AllRequestShapesAreExplicitlyEncoded() {
        let schema = parseWireJson("{\"type\":\"object\"}")
        let tool = LlmWireTool("lookup", "find a value", schema)
        let format = LlmWireStructuredOutput("answer", schema, description: "answer schema", strict: false)
        let call = LlmWireBlock.ToolCall(LlmWireToolCallBlock("call-1", "lookup", LlmWireToolArguments.Complete(parseWireJson("{\"q\":1}"), "{\"q\":1}")))
        let result = LlmWireBlock.ToolResult(LlmWireToolResultBlock("call-1", "done", isError: true))
        let common = [
            LlmWireMessage(LlmWireRole.User, [
                LlmWireBlock.Text(LlmWireTextBlock("hello")),
                LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "https://example.invalid/image.png", detail: LlmWireImageDetail.Low)),
                LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Base64, "AAAA", mediaType: "image/png", detail: LlmWireImageDetail.High)),
                LlmWireBlock.Reasoning(LlmWireReasoningBlock("thought")),
                LlmWireBlock.Refusal(LlmWireRefusalBlock("no"))
            ]),
            LlmWireMessage(LlmWireRole.Assistant, [call]),
            LlmWireMessage(LlmWireRole.User, [result])
        ]
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: allCapabilities())
        let responsePayload = responses.encodeRequest(LlmWireRequest(
            "m", common, system: "system", tools: [tool],
            thinking: LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Max), maxOutputTokens: Some(99),
            streaming: Some(true), parallelToolCalls: Some(false), serviceTier: Some("priority"),
            cachePolicy: LlmWireCachePolicy.StablePrefix, cacheKey: Some("key"),
            toolChoice: LlmWireToolChoice.Auto, structuredOutput: Some(format)
        ))
        for (needle in ["instructions", "max_output_tokens", "prompt_cache_key", "function_call_output", "data:image/png;base64", "json_schema"]) { @Expect(responsePayload.contains(needle), true) }

        let chatMessages = [
            LlmWireMessage(LlmWireRole.Assistant, [call]),
            LlmWireMessage(LlmWireRole.User, [result]),
            LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Reasoning(LlmWireReasoningBlock("why", replayDialectId: "deepseek.chat.v1")), LlmWireBlock.Refusal(LlmWireRefusalBlock("no"))])
        ]
        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: allCapabilities())
        let chatPayload = chat.encodeRequest(LlmWireRequest("m", chatMessages, system: "system", tools: [tool], thinking: LlmWireThinkingControl.Disabled, maxOutputTokens: Some(9), streaming: Some(false), parallelToolCalls: Some(true), serviceTier: Some("default"), toolChoice: LlmWireToolChoice.Required, structuredOutput: Some(format)))
        for (needle in ["system", "tool_call_id", "tool_calls", "response_format", "thinking", "reasoning_content", "required"]) { @Expect(chatPayload.contains(needle), true) }

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: allCapabilities())
        let messagePayload = messages.encodeRequest(LlmWireRequest("m", common, system: "system", tools: [tool], thinking: LlmWireThinkingControl.Adaptive(Some(LlmWireThinkingLevel.XHigh)), maxOutputTokens: Some(8), streaming: Some(true), serviceTier: Some("fast"), toolChoice: LlmWireToolChoice.NoTools, structuredOutput: Some(format)))
        for (needle in ["output_config", "xhigh", "tool_use", "tool_result", "base64", "is_error", "input_schema"]) { @Expect(messagePayload.contains(needle), true) }

        let autoMessages = messages.encodeRequest(LlmWireRequest("m", [], toolChoice: LlmWireToolChoice.Auto))
        @Expect(autoMessages.contains("\"type\":\"auto\""), true)
        let anyMessages = messages.encodeRequest(LlmWireRequest("m", [], toolChoice: LlmWireToolChoice.Required))
        @Expect(anyMessages.contains("\"type\":\"any\""), true)
    }

    @TestCase
    func t018FixedDecodersCoverBlocksUsageAndTerminalVariants() {
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), provider: "openai")
        let response = responses.decodeResponse("{\"id\":\"r\",\"model\":\"m\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"},{\"type\":\"refusal\",\"refusal\":\"no\"},{\"type\":\"future\",\"x\":1}]},{\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{}\"},{\"type\":\"reasoning\",\"summary\":\"why\"},{\"type\":\"future_item\",\"x\":2}],\"usage\":{\"input_tokens\":5,\"output_tokens\":6,\"input_tokens_details\":{\"cached_tokens\":2,\"cache_write_tokens\":1},\"output_tokens_details\":{\"reasoning_tokens\":3}}}")
        match (response) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => @Expect(reply.blocks.size, 6); @Expect(reply.usage.reasoningTokens, 3); case _ => @Fail("expected response success") }
        match (responses.decodeResponse("{\"status\":\"in_progress\"}")) { case LlmWireResponseState.Pending(LlmWirePendingReply.InProgress(_)) => (); case _ => @Fail("expected progress") }
        match (responses.decodeResponse("{\"status\":\"failed\"}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("expected failed") }
        expectLlmError("llm.responses_status_unsupported", { => let _ = responses.decodeResponse("{\"status\":\"future\"}") })

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect())
        let chatState = chat.decodeResponse("{\"id\":\"c\",\"model\":\"m\",\"choices\":[{\"message\":{\"content\":\"ok\",\"reasoning_content\":\"why\",\"tool_calls\":[{\"id\":\"t\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"content_filter\"}],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":5,\"prompt_tokens_details\":{\"cached_tokens\":1},\"completion_tokens_details\":{\"reasoning_tokens\":2}}}")
        match (chatState) { case LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(reply, _)) => @Expect(reply.blocks.size, 3); @Expect(reply.usage.cacheReadTokens, 1); case _ => @Fail("expected filtered") }
        match (chat.decodeResponse("{\"choices\":[{\"message\":{},\"finish_reason\":\"insufficient_system_resource\"}]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("expected resource failure") }
        expectLlmError("llm.chat_choices_empty", { => let _ = chat.decodeResponse("{\"choices\":[]}") })
        expectLlmError("llm.chat_finish_reason_unsupported", { => let _ = chat.decodeResponse("{\"choices\":[{\"message\":{},\"finish_reason\":\"future\"}]}") })

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        let messageState = messages.decodeResponse("{\"id\":\"x\",\"model\":\"m\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"},{\"type\":\"tool_use\",\"id\":\"c\",\"name\":\"f\",\"input\":[]},{\"type\":\"future\",\"x\":1}],\"stop_reason\":\"model_context_window_exceeded\",\"usage\":{\"input_tokens\":4,\"output_tokens\":5,\"cache_read_input_tokens\":2,\"cache_creation_input_tokens\":1}}")
        match (messageState) { case LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.ModelContextWindowExceeded)) => @Expect(reply.blocks.size, 3); @Expect(reply.usage.cacheWriteTokens, 1); case _ => @Fail("expected context incomplete") }
        match (messages.decodeResponse("{\"content\":[],\"stop_reason\":\"pause_turn\"}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(_, LlmWireIncompleteReason.PauseTurn)) => (); case _ => @Fail("expected pause") }
        match (messages.decodeResponse("{\"type\":\"error\",\"error\":{\"message\":\"bad\"}}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("expected message error") }
        expectLlmError("llm.messages_stop_reason_unsupported", { => let _ = messages.decodeResponse("{\"content\":[],\"stop_reason\":\"future\"}") })
    }

    @TestCase
    func t019ValidationRejectsEveryUnsupportedRequestClass() {
        let base = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        expectLlmError("llm.model_missing", { => let _ = base.encodeRequest(LlmWireRequest("", [])) })
        expectLlmError("llm.max_output_tokens_invalid", { => let _ = base.encodeRequest(LlmWireRequest("m", [], maxOutputTokens: Some(0))) })
        expectLlmError("llm.tools_unsupported", { => let _ = base.encodeRequest(LlmWireRequest("m", [], tools: [LlmWireTool("f", "", parseWireJson("{}"))])) })
        expectLlmError("llm.structured_output_unsupported", { => let _ = base.encodeRequest(LlmWireRequest("m", [], structuredOutput: Some(LlmWireStructuredOutput("x", parseWireJson("{}"))))) })
        expectLlmError("llm.parallel_tools_unsupported", { => let _ = base.encodeRequest(LlmWireRequest("m", [], parallelToolCalls: Some(true))) })
        expectLlmError("llm.service_tier_unsupported", { => let _ = base.encodeRequest(LlmWireRequest("m", [], serviceTier: Some("x"))) })
        expectLlmError("llm.cache_unsupported", { => let _ = base.encodeRequest(LlmWireRequest("m", [], cachePolicy: LlmWireCachePolicy.StablePrefix)) })

        let capable = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: allCapabilities())
        let duplicate = [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Complete(parseWireJson("{}"), "{}"))), LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Complete(parseWireJson("{}"), "{}")))])]
        expectLlmError("llm.tool_call_duplicate", { => let _ = capable.encodeRequest(LlmWireRequest("m", duplicate)) })
        let partial = [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Partial("{")))])]
        expectLlmError("llm.tool_arguments_partial", { => let _ = capable.encodeRequest(LlmWireRequest("m", partial)) })
        let opaque = LlmWireOpaqueBlock.fromPayload(LlmWireProtocol.Responses, "openai.responses.v1", "future", parseWireJson("{}"), completion: LlmWireOpaqueCompletion.Partial)
        expectLlmError("llm.opaque_partial", { => let _ = capable.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Opaque(opaque)])])) })
        expectLlmError("llm.opaque_payload_invalid", { => let _ = LlmWireOpaqueBlock.restore(LlmWireProtocol.Responses, "openai.responses.v1", "x", "[]") })

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: allCapabilities(), validationPolicy: LlmWireValidationPolicy.Lenient)
        expectLlmError("llm.chat_image_unsupported", { => let _ = chat.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "x"))])])) })
        expectLlmError("llm.chat_opaque_unsupported", { => let _ = chat.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Opaque(LlmWireOpaqueBlock.fromPayload(LlmWireProtocol.ChatCompletions, "openai.chat.v1", "x", parseWireJson("{}")))])])) })
    }

    @TestCase
    func t020StreamDecodersCoverDeltasErrorsAndTerminalKinds() {
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        @Expect(responses.push(event("{\"type\":\"response.created\"}")).events[0].kind, LlmWireEventKind.StreamStarted)
        @Expect(responses.push(event("{\"type\":\"response.output_text.delta\",\"delta\":\"a\",\"output_index\":0,\"item_id\":\"i\"}")).events[0].text, "a")
        @Expect(responses.push(event("{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"b\",\"output_index\":0,\"item_id\":\"r\"}")).events[0].text, "b")
        @Expect(responses.push(event("{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\"}}")).events.size, 0)
        @Expect(responses.push(event("{\"type\":\"future\"}")).events.size, 0)
        match (responses.push(event("{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"output\":[]}}" )).terminal) { case Some(LlmWireTerminal.Incomplete(_, _)) => (); case _ => @Fail("expected incomplete") }

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect()).newStreamDecoder()
        let update = chat.push(event("{\"id\":\"c\",\"model\":\"m\",\"usage\":{\"prompt_tokens\":1},\"choices\":[{\"index\":2,\"delta\":{\"content\":\"a\",\"reasoning_content\":\"b\"}}]}"))
        @Expect(update.events.size, 2)
        match (chat.push(event("{\"choices\":[{\"index\":2,\"delta\":{},\"finish_reason\":\"content_filter\"}]}" )).terminal) { case Some(LlmWireTerminal.Incomplete(_, _)) => (); case _ => @Fail("expected filtered") }
        let chatError = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        match (chatError.push(event("{\"error\":{\"type\":\"busy\"}}" )).terminal) { case Some(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("expected chat failure") }
        let chatResource = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        match (chatResource.push(event("{\"choices\":[{\"delta\":{},\"finish_reason\":\"insufficient_system_resource\"}]}" )).terminal) { case Some(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("expected resource failure") }

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        let _ = messages.push(event("{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"x\",\"usage\":{\"input_tokens\":1}}}"))
        let _ = messages.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"a\"}}"))
        @Expect(messages.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"b\"}}" )).events[0].text, "b")
        let _ = messages.push(event("{\"type\":\"content_block_stop\",\"index\":0}"))
        let _ = messages.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}"))
        match (messages.push(event("{\"type\":\"message_stop\"}" )).terminal) { case Some(LlmWireTerminal.Succeeded(reply)) => @Expect(reply.blocks.size, 1); case _ => @Fail("expected messages success") }
        let messageError = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        match (messageError.push(event("{\"type\":\"error\",\"error\":{\"message\":\"bad\"}}" )).terminal) { case Some(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("expected messages failure") }
    }

    @TestCase
    func t021TransportParsersCoverLimitsFieldsAndCalendarEdges() {
        @Expect(LlmResult<Int64>.Ok(1).isOk(), true)
        @Expect(LlmResult<Int64>.Err(LlmTransportError(LlmTransportErrorKind.Transport, "x", "x")).isOk(), false)
        @Expect(sseDataLine("data: value"), Some("value"))
        @Expect(sseDataLine("event: value"), None)
        let fields = SseDecoder(maxEventBytes: 100)
        match (fields.push("event: custom\nid: a\u{0000}b\nretry: invalid\nunknown\ndata: x\n\n")) { case LlmResult.Ok(values) => @Expect(values[0].event, "custom"); @Expect(values[0].id, ""); case _ => @Fail("expected event") }
        match (fields.finish()) { case LlmResult.Ok(_) => (); case _ => @Fail("expected finish") }
        match (fields.push("data: x\n\n")) { case LlmResult.Err(error) => @Expect(error.code, "llm.sse_closed"); case _ => @Fail("closed push must fail") }
        match (fields.finish()) { case LlmResult.Err(error) => @Expect(error.code, "llm.sse_closed"); case _ => @Fail("closed finish must fail") }
        @Expect(parseSseRetryMillis(""), None)
        @Expect(parseSseRetryMillis("12x"), None)
        @Expect(parseSseRetryMillis("999999999999999999999999"), Some(Int64.Max))
        @Expect(parseRetryAfterMillis("999999999999999999999999", 0), Some(Int64.Max))
        for (date in ["Thu, 29 Feb 2024 00:00:00 GMT", "Thu, 29 Feb 2023 00:00:00 GMT", "Thu, 01 Jan 1969 00:00:00 GMT", "Thu, 01 Xxx 2024 00:00:00 GMT", "Thu, 01 Jan 2024 24:00:00 GMT", "Thu, 01 Jan 2024 bad GMT"]) { let _ = parseRetryAfterMillis(date, 0) }
        for (month in ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]) { @Expect(parseRetryAfterMillis("Mon, 01 " + month + " 2024 00:00:00 GMT", 0).isSome(), true) }
        let empty = ByteBuffer()
        match (readLlmHttpBody(empty, None, 0)) { case LlmResult.Err(error) => @Expect(error.code, "llm.body_limit_invalid"); case _ => @Fail("invalid limit") }
        match (readLlmHttpBody(empty, Some(-1), 10)) { case LlmResult.Err(error) => @Expect(error.code, "llm.body_too_large"); case _ => @Fail("invalid declared size") }
    }

    @TestCase
    func t022DerivedIdentityEnumsCompareEveryVariant() {
        let protocols = [LlmWireProtocol.Responses, LlmWireProtocol.ChatCompletions, LlmWireProtocol.Messages]
        for (index in 0..protocols.size) { @Expect(protocols[index] == protocols[index], true); @Expect(protocols[index] != protocols[(index + 1) % protocols.size], true) }
        let roles = [LlmWireRole.User, LlmWireRole.Assistant]
        for (index in 0..roles.size) { @Expect(roles[index] == roles[index], true); @Expect(roles[index] != roles[(index + 1) % roles.size], true) }
        let sources = [LlmWireImageSourceKind.Url, LlmWireImageSourceKind.Base64]
        for (index in 0..sources.size) { @Expect(sources[index] == sources[index], true); @Expect(sources[index] != sources[(index + 1) % sources.size], true) }
        let details = [LlmWireImageDetail.Auto, LlmWireImageDetail.Low, LlmWireImageDetail.High]
        for (index in 0..details.size) { @Expect(details[index] == details[index], true); @Expect(details[index] != details[(index + 1) % details.size], true) }
        let levels = [LlmWireThinkingLevel.Minimal, LlmWireThinkingLevel.Low, LlmWireThinkingLevel.Medium, LlmWireThinkingLevel.High, LlmWireThinkingLevel.XHigh, LlmWireThinkingLevel.Max]
        for (index in 0..levels.size) { @Expect(levels[index] == levels[index], true); @Expect(levels[index] != levels[(index + 1) % levels.size], true) }
        let caches = [LlmWireCachePolicy.ProviderDefault, LlmWireCachePolicy.StablePrefix]
        for (index in 0..caches.size) { @Expect(caches[index] == caches[index], true); @Expect(caches[index] != caches[(index + 1) % caches.size], true) }
        let choices = [LlmWireToolChoice.ProviderDefault, LlmWireToolChoice.Auto, LlmWireToolChoice.NoTools, LlmWireToolChoice.Required]
        for (index in 0..choices.size) { @Expect(choices[index] == choices[index], true); @Expect(choices[index] != choices[(index + 1) % choices.size], true) }
        let policies = [LlmWireValidationPolicy.Strict, LlmWireValidationPolicy.Lenient]
        for (index in 0..policies.size) { @Expect(policies[index] == policies[index], true); @Expect(policies[index] != policies[(index + 1) % policies.size], true) }
        let completions = [LlmWireOpaqueCompletion.Complete, LlmWireOpaqueCompletion.Partial]
        for (index in 0..completions.size) { @Expect(completions[index] == completions[index], true); @Expect(completions[index] != completions[(index + 1) % completions.size], true) }
        let dialects = [LlmWireBuiltinDialect.OpenAiResponses, LlmWireBuiltinDialect.OpenAiChat, LlmWireBuiltinDialect.AnthropicMessages, LlmWireBuiltinDialect.DeepSeekResponses, LlmWireBuiltinDialect.DeepSeekChat, LlmWireBuiltinDialect.DeepSeekMessages]
        for (index in 0..dialects.size) { @Expect(dialects[index] == dialects[index], true); @Expect(dialects[index] != dialects[(index + 1) % dialects.size], true) }
        let events = [
            LlmWireEventKind.StreamStarted, LlmWireEventKind.ContentBlockStarted, LlmWireEventKind.TextDelta,
            LlmWireEventKind.ReasoningDelta, LlmWireEventKind.ToolCallStarted, LlmWireEventKind.ToolArgumentsDelta,
            LlmWireEventKind.ContentBlockCompleted, LlmWireEventKind.UsageDelta, LlmWireEventKind.UsageCompleted,
            LlmWireEventKind.ProviderError, LlmWireEventKind.MessageTerminalObserved
        ]
        for (index in 0..events.size) { @Expect(events[index] == events[index], true); @Expect(events[index] != events[(index + 1) % events.size], true) }
    }

    @TestCase
    func t023EverySupportedThinkingDialectBranchIsEncoded() {
        let capabilities = allCapabilities()
        let controls = [
            LlmWireThinkingControl.Disabled,
            LlmWireThinkingControl.Enabled,
            LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Minimal)
        ]
        let deepSeekCodecs = [
            LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect(), capabilities: capabilities),
            LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: capabilities),
            LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect(), capabilities: capabilities)
        ]
        for (index in 0..deepSeekCodecs.size) {
            for (control in controls) {
                let payload = deepSeekCodecs[index].encodeRequest(LlmWireRequest("m", [], thinking: control))
                @Expect(payload.contains(if (index == 0) { "reasoning" } else { "thinking" }), true)
                if (index == 0) { @Expect(payload.contains("\"thinking\""), false) }
            }
        }
        let openAiChat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: capabilities)
        @Expect(openAiChat.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Enabled)).contains("medium"), true)
        @Expect(openAiChat.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Low))).contains("low"), true)
        let anthropic = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: capabilities)
        for (control in [LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Enabled, LlmWireThinkingControl.Budget(128), LlmWireThinkingControl.Adaptive(None)]) {
            @Expect(anthropic.encodeRequest(LlmWireRequest("m", [], thinking: control)).contains("thinking"), true)
        }
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities)
        for (level in [LlmWireThinkingLevel.Minimal, LlmWireThinkingLevel.Low, LlmWireThinkingLevel.Medium, LlmWireThinkingLevel.High, LlmWireThinkingLevel.XHigh, LlmWireThinkingLevel.Max]) {
            @Expect(responses.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Effort(level))).contains("reasoning"), true)
        }
    }

    @TestCase
    func t024StrictFieldReadersDistinguishMissingNullTypeAndValue() {
        let value = parseWireJson("{\"s\":\"x\",\"n\":null,\"o\":{},\"a\":[],\"i\":7,\"bad\":true,\"huge\":999999999999999999999}")
        @Expect(wireObject(value, "root").wireKind, WireJsonKind.Object)
        @Expect(wireRequiredField(value, "s").text, "x")
        @Expect(wireOptionalString(value, "missing"), None)
        @Expect(wireOptionalString(value, "n"), None)
        @Expect(wireOptionalString(value, "s"), Some("x"))
        @Expect(wireRequiredString(value, "s"), "x")
        @Expect(wireOptionalObject(value, "missing").isNone(), true)
        @Expect(wireOptionalObject(value, "n").isNone(), true)
        @Expect(wireOptionalObject(value, "o").isSome(), true)
        @Expect(wireOptionalArray(value, "missing").isNone(), true)
        @Expect(wireOptionalArray(value, "n").isNone(), true)
        @Expect(wireOptionalArray(value, "a").getOrThrow().size, 0)
        @Expect(wireOptionalInt(value, "missing"), None)
        @Expect(wireOptionalInt(value, "n"), None)
        @Expect(wireOptionalInt(value, "i"), Some(7))
        @Expect(wireIntOrZero(value, "missing"), 0)
        @Expect(wireIntOrZero(value, "i"), 7)
        expectLlmError("llm.object_expected", { => let _ = wireObject(parseWireJson("[]"), "root") })
        expectLlmError("llm.field_missing", { => let _ = wireRequiredField(value, "missing") })
        expectLlmError("llm.field_missing", { => let _ = wireRequiredString(value, "n") })
        expectLlmError("llm.field_type_invalid", { => let _ = wireOptionalString(value, "bad") })
        expectLlmError("llm.field_type_invalid", { => let _ = wireOptionalObject(value, "bad") })
        expectLlmError("llm.field_type_invalid", { => let _ = wireOptionalArray(value, "bad") })
        expectLlmError("llm.field_type_invalid", { => let _ = wireOptionalInt(value, "bad") })
        expectLlmError("llm.integer_invalid", { => let _ = wireOptionalInt(value, "huge") })
    }

    @TestCase
    func t025EveryUnrepresentableThinkingPairIsRejected() {
        let capabilities = allCapabilities()
        let pairs = [
            (LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities), LlmWireThinkingControl.Disabled),
            (LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities), LlmWireThinkingControl.Enabled),
            (LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities), LlmWireThinkingControl.Budget(1)),
            (LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities), LlmWireThinkingControl.Adaptive(None)),
            (LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: capabilities), LlmWireThinkingControl.Budget(1)),
            (LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: capabilities), LlmWireThinkingControl.Adaptive(None)),
            (LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: capabilities), LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Low)),
            (LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect(), capabilities: capabilities), LlmWireThinkingControl.Budget(1)),
            (LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect(), capabilities: capabilities), LlmWireThinkingControl.Adaptive(None)),
            (LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: capabilities), LlmWireThinkingControl.Budget(1)),
            (LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: capabilities), LlmWireThinkingControl.Adaptive(None)),
            (LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect(), capabilities: capabilities), LlmWireThinkingControl.Budget(1)),
            (LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect(), capabilities: capabilities), LlmWireThinkingControl.Adaptive(None))
        ]
        for ((codec, control) in pairs) {
            expectLlmError("llm.thinking_not_representable", { => let _ = codec.encodeRequest(LlmWireRequest("m", [], thinking: control)) })
        }
        let noLevels = LlmWireCapabilities(thinkingEffort: true)
        let levelCodec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: noLevels)
        expectLlmError("llm.thinking_unsupported", { => let _ = levelCodec.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Effort(LlmWireThinkingLevel.High))) })
        let budgetCodec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: capabilities)
        expectLlmError("llm.thinking_unsupported", { => let _ = budgetCodec.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Budget(0))) })
        expectLlmError("llm.dialect_protocol_mismatch", { => let _ = LlmWireCodec(LlmWireProtocol.Messages, openAiResponsesDialect()) })
    }

    @TestCase
    func t026TransportCoversSplitLinesInvalidLimitsAndOverflow() {
        try { let _ = SseDecoder(maxEventBytes: 0); @Fail("invalid limit") } catch (_: IllegalArgumentException) { () }
        try { let _ = SseDecoder(maxEventBytes: 10, maxBufferedBytes: 9); @Fail("invalid buffer") } catch (_: IllegalArgumentException) { () }
        let split = SseDecoder(maxEventBytes: 128)
        match (split.push("id: first\r")) { case LlmResult.Ok(values) => @Expect(values.size, 0); case _ => @Fail("split CR") }
        match (split.push("\ndata: one\r\n\r")) { case LlmResult.Ok(values) => @Expect(values.size, 1); @Expect(values[0].id, "first"); case _ => @Fail("split CRLF") }
        match (split.push("\nid:\ndata:\n\n")) { case LlmResult.Ok(values) => @Expect(values.size, 1); @Expect(values[0].id, ""); @Expect(values[0].data, ""); case _ => @Fail("empty data") }
        match (SseDecoder().push("retry: 999999999999999999999999\ndata: x\n\n")) { case LlmResult.Ok(values) => @Expect(values[0].retryMillis, Some(Int64.Max)); case _ => @Fail("retry overflow") }
        match (SseDecoder().push([255u8, 10u8, 10u8])) { case LlmResult.Err(error) => @Expect(error.code, "llm.sse_utf8_invalid"); case _ => @Fail("invalid UTF-8") }
        let actualLarge = ByteBuffer(); actualLarge.write("hello".toArray())
        match (readLlmHttpBody(actualLarge, None, 4)) { case LlmResult.Err(error) => @Expect(error.code, "llm.body_too_large"); case _ => @Fail("stream body must be bounded") }
        for (date in ["Sun, bad", "Sun, 06 Nov 1994 08:49:37 UTC", "Sunday, 06-Nov-94 08:49:37 UTC", "Sun Nov 6 08:49:37", "Sun Nov 6 08:49:37 1994 extra", "Sun, 31 Feb 1994 08:49:37 GMT"]) {
            @Expect(parseRetryAfterMillis(date, 0), None)
        }
    }

    @TestCase
    func t027ArgumentEncodersAndOptionalRequestFieldsCoverAllVariants() {
        let schema = parseWireJson("{}")
        let complete = LlmWireToolArguments.Complete(schema, "{}")
        let badJson = LlmWireToolArguments.InvalidJson("{")
        let badShape = LlmWireToolArguments.InvalidShape(parseWireJson("[]"), "[]")
        @Expect(toolArgumentsRaw(complete), "{}")
        @Expect(toolArgumentsRaw(badJson), "{")
        @Expect(toolArgumentsRaw(badShape), "[]")
        expectLlmError("llm.tool_arguments_json_invalid", { => let _ = toolArgumentsObject(badJson) })
        expectLlmError("llm.tool_arguments_shape_invalid", { => let _ = toolArgumentsObject(badShape) })
        expectLlmError("llm.tool_arguments_shape_invalid", { => let _ = toolArgumentsObject(LlmWireToolArguments.Complete(parseWireJson("[]"), "[]")) })
        let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: allCapabilities())
        let minimal = codec.encodeRequest(LlmWireRequest("m", [], tools: [LlmWireTool("f", "", schema)], cachePolicy: LlmWireCachePolicy.StablePrefix, toolChoice: LlmWireToolChoice.NoTools, structuredOutput: Some(LlmWireStructuredOutput("x", schema))))
        @Expect(minimal.contains("prompt_cache_key"), false)
        @Expect(minimal.contains("description"), true)
        @Expect(minimal.contains("\"tool_choice\":\"none\""), true)
        let autoImage = LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "u", detail: LlmWireImageDetail.Auto))
        @Expect(codec.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [autoImage])])).contains("\"detail\":\"auto\""), true)
    }

    @TestCase
    func t028StreamStateMachinesRejectMalformedOrderingAndMaterializeEdges() {
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        @Expect(responses.push(event("")).events.size, 0)
        expectLlmError("llm.responses_terminal_invalid", { => let _ = responses.push(event("{\"type\":\"response.completed\",\"response\":{\"status\":\"queued\"}}")) })
        let responseError = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        match (responseError.push(event("{\"type\":\"error\",\"message\":\"bad\"}")).terminal) { case Some(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("root error") }
        let responseDone = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        let _ = responseDone.push(event("{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}"))
        @Expect(responseDone.push(event("[DONE]")).events.size, 0)

        let chatEmpty = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        @Expect(chatEmpty.push(event("")).events.size, 0)
        @Expect(chatEmpty.push(event("[DONE]")).events.size, 0)
        @Expect(chatEmpty.push(event("{}")).events.size, 0)
        let chatCall = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        expectLlmError("llm.field_missing", { => let _ = chatCall.push(event("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{}}]}}]}")) })
        let chatNoFunction = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        @Expect(chatNoFunction.push(event("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0}]}}]}")).events.size, 0)
        let chatPartial = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        let _ = chatPartial.push(event("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\",\"function\":{\"name\":\"f\",\"arguments\":\"{\"}}]}}]}"))
        match (chatPartial.push(event("{\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}")).terminal) { case Some(LlmWireTerminal.Incomplete(reply, _)) => match (reply.blocks[0]) { case LlmWireBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.Partial(_) => (); case _ => @Fail("partial call") }; case _ => @Fail("tool call") }; case _ => @Fail("length") }
        let unsupportedChat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        expectLlmError("llm.chat_finish_reason_unsupported", { => let _ = unsupportedChat.push(event("{\"choices\":[{\"delta\":{},\"finish_reason\":\"future\"}]}")) })

        let emptyMessages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        @Expect(emptyMessages.push(event("")).events.size, 0)
        @Expect(emptyMessages.push(event("[DONE]")).events.size, 0)
        let duplicate = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        let startText = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"x\"}}"
        let _ = duplicate.push(event(startText))
        expectLlmError("llm.messages_block_duplicate", { => let _ = duplicate.push(event(startText)) })
        let unknown = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        expectLlmError("llm.messages_stream_block_unsupported", { => let _ = unknown.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"future\"}}")) })
        let noStart = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        expectLlmError("llm.messages_delta_without_start", { => let _ = noStart.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}")) })
        expectLlmError("llm.messages_block_stop_without_start", { => let _ = noStart.push(event("{\"type\":\"content_block_stop\",\"index\":0}")) })
        let stopped = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        let _ = stopped.push(event(startText)); let _ = stopped.push(event("{\"type\":\"content_block_stop\",\"index\":0}"))
        expectLlmError("llm.messages_delta_after_stop", { => let _ = stopped.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}")) })
        expectLlmError("llm.messages_block_stop_duplicate", { => let _ = stopped.push(event("{\"type\":\"content_block_stop\",\"index\":0}")) })
        let incompleteBlock = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        let _ = incompleteBlock.push(event(startText)); let _ = incompleteBlock.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}"))
        expectLlmError("llm.messages_content_block_incomplete", { => let _ = incompleteBlock.push(event("{\"type\":\"message_stop\"}")) })
        let redacted = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        let _ = redacted.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"x\"}}"))
        let _ = redacted.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}"))
        match (redacted.push(event("{\"type\":\"message_stop\"}")).terminal) { case Some(LlmWireTerminal.Incomplete(reply, _)) => match (reply.blocks[0]) { case LlmWireBlock.Opaque(value) => @Expect(value.completion, LlmWireOpaqueCompletion.Partial); case _ => @Fail("opaque") }; case _ => @Fail("redacted") }
    }

    @TestCase
    func t029FixedDecodersRejectMissingContainersAndCoverFailureFallbacks() {
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        match (responses.decodeResponse("{\"status\":\"failed\",\"error\":{\"message\":\"bad\"}}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Failed(failure)) => @Expect(failure.message, "bad"); case _ => @Fail("failed response") }
        expectLlmError("llm.field_missing", { => let _ = responses.decodeResponse("{\"status\":\"completed\",\"output\":[{\"type\":\"message\"}]}" ) })
        match (responses.decodeResponse("{\"status\":\"incomplete\",\"output\":[],\"incomplete_details\":{}}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(_, LlmWireIncompleteReason.Other(value))) => @Expect(value, "incomplete"); case _ => @Fail("fallback reason") }

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        match (chat.decodeResponse("{\"error\":{\"message\":\"bad\"}}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("chat error") }
        expectLlmError("llm.field_missing", { => let _ = chat.decodeResponse("{}") })
        expectLlmError("llm.field_missing", { => let _ = chat.decodeResponse("{\"choices\":[{}]}") })
        expectLlmError("llm.field_missing", { => let _ = chat.decodeResponse("{\"choices\":[{\"message\":{\"tool_calls\":[{\"id\":\"c\"}]},\"finish_reason\":\"tool_calls\"}]}" ) })
        match (chat.decodeResponse("{\"choices\":[{\"message\":{\"content\":\"\",\"reasoning_content\":\"\"},\"finish_reason\":\"function_call\"}]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => @Expect(reply.blocks.size, 0); case _ => @Fail("empty content") }

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        expectLlmError("llm.field_missing", { => let _ = messages.decodeResponse("{\"stop_reason\":\"end_turn\"}") })
        match (messages.decodeResponse("{\"type\":\"error\",\"message\":\"root bad\"}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Failed(failure)) => @Expect(failure.message, "root bad"); case _ => @Fail("root message error") }
        let completeTool = messages.decodeResponse("{\"content\":[{\"type\":\"tool_use\",\"id\":\"c\",\"name\":\"f\",\"input\":{\"x\":1}}],\"stop_reason\":\"tool_use\"}")
        match (completeTool) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => match (reply.blocks[0]) { case LlmWireBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.Complete(_, _) => (); case _ => @Fail("complete") }; case _ => @Fail("tool") }; case _ => @Fail("messages") }
    }

    @TestCase
    func t030DirectBranchContractsCoverReplayDefaultsAndStreamMaterialization() {
        let emptyFields = [
            encodeStandardThinking(LlmWireBuiltinDialect.OpenAiResponses, LlmWireThinkingControl.ProviderDefault),
            encodeStandardThinking(LlmWireBuiltinDialect.DeepSeekResponses, LlmWireThinkingControl.ProviderDefault),
            encodeStandardThinking(LlmWireBuiltinDialect.OpenAiChat, LlmWireThinkingControl.ProviderDefault),
            encodeStandardThinking(LlmWireBuiltinDialect.AnthropicMessages, LlmWireThinkingControl.ProviderDefault),
            encodeStandardThinking(LlmWireBuiltinDialect.DeepSeekChat, LlmWireThinkingControl.ProviderDefault),
            encodeStandardThinking(LlmWireBuiltinDialect.DeepSeekMessages, LlmWireThinkingControl.ProviderDefault)
        ]
        for (fields in emptyFields) { @Expect(fields.size, 0) }
        expectLlmError("llm.tool_arguments_partial", { => let _ = toolArgumentsRaw(LlmWireToolArguments.Partial("{")) })
        expectLlmError("llm.tool_arguments_partial", { => let _ = toolArgumentsObject(LlmWireToolArguments.Partial("{")) })
        let openAiChat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        let replay = LlmWireReasoningBlock("reasoning", replayDialectId: "deepseek.chat.v1")
        expectLlmError("llm.chat_reasoning_replay_unsupported", { => let _ = openAiChat.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Reasoning(replay)])])) })
        match (classifyToolArguments("null")) { case LlmWireToolArguments.InvalidShape(_, raw) => @Expect(raw, "null"); case _ => @Fail("null shape") }
        expectLlmError("llm.json_invalid", { => let _ = parseWireJson("{\"x\":1,\"x\":2}") })
        expectLlmError("llm.json_duplicate_key", { => let _ = wireJsonObject([WireJsonField("x", wireJsonString("a")), WireJsonField("x", wireJsonString("b"))]) })

        let completeOpaque = LlmWireOpaqueBlock.fromPayload(LlmWireProtocol.Responses, "openai.responses.v1", "future", parseWireJson("{\"type\":\"future\"}"))
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        @Expect(responses.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Opaque(completeOpaque)])])).contains("future"), true)
        let messageOpaque = LlmWireOpaqueBlock.fromPayload(LlmWireProtocol.Messages, "anthropic.messages.v1", "future", parseWireJson("{\"type\":\"future\"}"))
        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        @Expect(messages.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Opaque(messageOpaque)])])).contains("future"), true)

        let emptyId = [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("", "f", LlmWireToolArguments.Complete(parseWireJson("{}"), "{}")))])]
        let capable = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: allCapabilities())
        expectLlmError("llm.tool_call_duplicate", { => let _ = capable.encodeRequest(LlmWireRequest("m", emptyId)) })

        let chatStop = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        match (chatStop.decodeResponse("{\"choices\":[{\"message\":{},\"finish_reason\":\"stop\"}]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(_)) => (); case _ => @Fail("stop") }
        let chatNoFragment = chatStop.newStreamDecoder()
        @Expect(chatNoFragment.push(event("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\"}}]}}]}" )).events.size, 0)

        let messagesError = messages.newStreamDecoder()
        match (messagesError.push(event("{\"type\":\"error\",\"message\":\"bad\"}")).terminal) { case Some(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("messages root error") }
        let messagesDone = messages.newStreamDecoder()
        let _ = messagesDone.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}")); let _ = messagesDone.push(event("{\"type\":\"message_stop\"}"))
        @Expect(messagesDone.push(event("[DONE]")).events.size, 0)
        let completeToolStream = messages.newStreamDecoder()
        let _ = completeToolStream.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"c\",\"name\":\"f\"}}"))
        let _ = completeToolStream.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}")); let _ = completeToolStream.push(event("{\"type\":\"content_block_stop\",\"index\":0}")); let _ = completeToolStream.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}"))
        match (completeToolStream.push(event("{\"type\":\"message_stop\"}")).terminal) { case Some(LlmWireTerminal.Succeeded(reply)) => @Expect(reply.blocks.size, 1); case _ => @Fail("complete tool stream") }

        let rawRedacted = MessageStreamBlock(0, "redacted_thinking")
        match (materializeMessageBlock(messages, rawRedacted)) { case LlmWireBlock.Opaque(value) => @Expect(value.completion, LlmWireOpaqueCompletion.Partial); case _ => @Fail("raw redacted") }
        rawRedacted.completed = true
        match (materializeMessageBlock(messages, rawRedacted)) { case LlmWireBlock.Opaque(value) => @Expect(value.completion, LlmWireOpaqueCompletion.Complete); case _ => @Fail("complete redacted") }
        @Expect(extractRetryAfterMillis("Retry-After: invalid\n", 0), None)
    }

    @TestCase
    func t031SseFragmentationPropertyHoldsAtEveryByteBoundary() {
        let source = "\u{feff}id: stream-1\r\nevent: token\r\ndata: 你好\r\ndata: world\r\n\r\n"
        let bytes = source.toArray()
        for (split in 1..bytes.size) {
            let left = ArrayList<Byte>()
            let right = ArrayList<Byte>()
            for (index in 0..bytes.size) {
                if (index < split) { left.add(bytes[index]) } else { right.add(bytes[index]) }
            }
            let decoder = SseDecoder()
            var observed = Array<SseEvent>()
            match (decoder.push(left.toArray())) { case LlmResult.Ok(values) => observed = values; case _ => @Fail("left fragment failed") }
            match (decoder.push(right.toArray())) {
                case LlmResult.Ok(values) =>
                    if (observed.isEmpty()) { observed = values }
                    else if (!values.isEmpty()) { @Fail("event dispatched more than once") }
                case _ => @Fail("right fragment failed")
            }
            @Expect(observed.size, 1)
            @Expect(observed[0].event, "token")
            @Expect(observed[0].id, "stream-1")
            @Expect(observed[0].data, "你好\nworld")
        }
    }

    @TestCase
    func t032ResponsesTerminalEventsMatchStatusAndDeepSeekReasoningReplays() {
        for ((kind, status) in [("response.completed", "incomplete"), ("response.incomplete", "completed"), ("response.failed", "completed")]) {
            let decoder = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
            expectLlmError("llm.responses_terminal_mismatch", { =>
                let _ = decoder.push(event("{\"type\":\"" + kind + "\",\"response\":{\"status\":\"" + status + "\",\"output\":[]}}"))
            })
        }

        let deepSeek = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: allCapabilities())
        let state = deepSeek.decodeResponse("{\"choices\":[{\"message\":{\"content\":\"answer\",\"reasoning_content\":\"reason\",\"tool_calls\":[{\"id\":\"c\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}")
        let blocks = match (state) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => reply.blocks; case _ => @Fail("DeepSeek reply must succeed") }
        let replay = deepSeek.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, blocks)]))
        @Expect(replay.contains("\"reasoning_content\":\"reason\""), true)
        @Expect(replay.contains("\"content\":\"answer\""), true)
        @Expect(replay.contains("\"tool_calls\""), true)
        let openAi = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: allCapabilities())
        expectLlmError("llm.chat_reasoning_replay_unsupported", { => let _ = openAi.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, blocks)])) })
    }

    @TestCase
    func t033NewStrictBranchesRejectEveryIdentityAndReasoningMismatch() {
        let deepSeek = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: allCapabilities())
        let result = LlmWireBlock.ToolResult(LlmWireToolResultBlock("c", "ok"))
        expectLlmError("llm.tool_result_unmatched", { => let _ = deepSeek.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [result, LlmWireBlock.Text(LlmWireTextBlock("x"))])])) })
        let foreignReasoning = LlmWireBlock.Reasoning(LlmWireReasoningBlock("r", replayDialectId: "other.chat.v1"))
        expectLlmError("llm.reasoning_dialect_mismatch", { => let _ = deepSeek.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [foreignReasoning])])) })

        let responsesCodec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        let reasoning = responsesCodec.decodeResponse("{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"summary\":null,\"content\":[{\"text\":\"a\"},{}]}]}")
        match (reasoning) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => match (reply.blocks[0]) { case LlmWireBlock.Opaque(value) => @Expect(value.displayReasoning, Some("a")); case _ => @Fail("reasoning opaque") }; case _ => @Fail("reasoning response") }
        expectLlmError("llm.field_type_invalid", { => let _ = responsesCodec.decodeResponse("{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"summary\":1}]}" ) })
        match (responsesCodec.decodeResponse("{\"status\":\"incomplete\",\"output\":[],\"incomplete_details\":{\"reason\":\"content_filter\"}}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(_, LlmWireIncompleteReason.ContentFilter)) => (); case _ => @Fail("content filter") }
        match (responsesCodec.decodeResponse("{\"status\":\"incomplete\",\"output\":[],\"incomplete_details\":{\"reason\":\"future\"}}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(_, LlmWireIncompleteReason.Other("future"))) => (); case _ => @Fail("future reason") }

        func started(): LlmWireStreamDecoder {
            let decoder = responsesCodec.newStreamDecoder()
            let _ = decoder.push(event("{\"type\":\"response.output_item.added\",\"output_index\":2,\"item\":{\"type\":\"function_call\",\"id\":\"item\",\"call_id\":\"call\",\"name\":\"f\"}}"))
            decoder
        }
        let duplicate = started()
        expectLlmError("llm.responses_item_duplicate", { => let _ = duplicate.push(event("{\"type\":\"response.output_item.added\",\"output_index\":2,\"item\":{\"type\":\"function_call\",\"id\":\"item\",\"call_id\":\"call\",\"name\":\"f\"}}")) })
        expectLlmError("llm.responses_arguments_without_item", { => let _ = responsesCodec.newStreamDecoder().push(event("{\"type\":\"response.function_call_arguments.delta\",\"output_index\":2,\"item_id\":\"missing\",\"delta\":\"x\"}")) })
        expectLlmError("llm.responses_output_index_mismatch", { => let _ = started().push(event("{\"type\":\"response.function_call_arguments.delta\",\"output_index\":3,\"item_id\":\"item\",\"delta\":\"x\"}")) })
        let mismatch = started(); let _ = mismatch.push(event("{\"type\":\"response.function_call_arguments.delta\",\"output_index\":2,\"item_id\":\"item\",\"delta\":\"x\"}"))
        expectLlmError("llm.responses_arguments_mismatch", { => let _ = mismatch.push(event("{\"type\":\"response.function_call_arguments.done\",\"output_index\":2,\"item_id\":\"item\",\"name\":\"f\",\"arguments\":\"y\"}")) })
        expectLlmError("llm.responses_call_name_mismatch", { => let _ = started().push(event("{\"type\":\"response.function_call_arguments.done\",\"output_index\":2,\"item_id\":\"item\",\"name\":\"g\",\"arguments\":\"\"}")) })
        expectLlmError("llm.field_missing", { => let _ = responsesCodec.newStreamDecoder().push(event("{\"type\":\"response.reasoning_text.delta\",\"item_id\":\"r\",\"delta\":\"x\"}")) })
        match (responsesCodec.newStreamDecoder().push(event("{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\"}}" )).terminal) { case Some(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("failed terminal") }

        let kinds = [WireJsonKind.Null, WireJsonKind.Boolean, WireJsonKind.Number, WireJsonKind.Text, WireJsonKind.List, WireJsonKind.Object]
        for (i in 0..kinds.size) { for (j in 0..kinds.size) { @Expect(kinds[i] == kinds[j], i == j) } }
    }

    @TestCase
    func t034ChatReasoningFieldControlsFixedAndStreamingDecode() {
        let custom = LlmWireCodec(LlmWireProtocol.ChatCompletions, AlternateChatReasoningDialect())
        let fixed = custom.decodeResponse("{\"choices\":[{\"message\":{\"analysis\":\"custom\",\"reasoning_content\":\"stray\"},\"finish_reason\":\"stop\"}]}")
        let blocks = match (fixed) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => reply.blocks; case _ => @Fail("custom fixed response") }
        @Expect(blocks.size, 1)
        match (blocks[0]) { case LlmWireBlock.Reasoning(value) => @Expect(value.text, "custom"); case _ => @Fail("custom reasoning block") }
        let replay = custom.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, blocks)]))
        @Expect(replay.contains("\"analysis\":\"custom\""), true)
        @Expect(replay.contains("reasoning_content"), false)

        let streaming = custom.newStreamDecoder()
        let update = streaming.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"analysis\":\"stream\",\"reasoning_content\":\"stray\"}}]}"))
        @Expect(update.events.size, 1)
        @Expect(update.events[0].kind, LlmWireEventKind.ReasoningDelta)
        @Expect(update.events[0].text, "stream")
        let terminal = streaming.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"))
        match (terminal.terminal) { case Some(LlmWireTerminal.Succeeded(reply)) => match (reply.blocks[0]) { case LlmWireBlock.Reasoning(value) => @Expect(value.text, "stream"); case _ => @Fail("stream reasoning block") }; case _ => @Fail("custom stream terminal") }

        let openAi = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        match (openAi.decodeResponse("{\"choices\":[{\"message\":{\"reasoning_content\":\"stray\"},\"finish_reason\":\"stop\"}]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => @Expect(reply.blocks.size, 0); case _ => @Fail("OpenAI fixed response") }
        let openAiStream = openAi.newStreamDecoder()
        @Expect(openAiStream.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"stray\"}}]}" )).events.size, 0)
        match (openAiStream.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}" )).terminal) { case Some(LlmWireTerminal.Succeeded(reply)) => @Expect(reply.blocks.size, 0); case _ => @Fail("OpenAI stream terminal") }
    }
}
