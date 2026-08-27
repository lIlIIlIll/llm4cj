package llm4cj

import std.io.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

func allCapabilities(): LlmWireCapabilities {
    LlmWireCapabilities(
        thinkingControls: [LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Enabled, LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium), LlmWireThinkingControl.Budget(1024), LlmWireThinkingControl.Adaptive(None)],
        thinkingLevels: [LlmWireThinkingLevel.Minimal, LlmWireThinkingLevel.Low, LlmWireThinkingLevel.Medium, LlmWireThinkingLevel.High, LlmWireThinkingLevel.XHigh, LlmWireThinkingLevel.Max],
        structuredOutputModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject, LlmWireStructuredOutputMode.JsonSchema],
        serviceTiers: [LlmWireServiceTier.Auto, LlmWireServiceTier.Default, LlmWireServiceTier.StandardOnly, LlmWireServiceTier.Flex, LlmWireServiceTier.Priority, LlmWireServiceTier.Fast, LlmWireServiceTier.Ultrafast],
        generationSpeeds: [LlmWireGenerationSpeed.Standard, LlmWireGenerationSpeed.Fast],
        promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.FiveMinutes, LlmWirePromptCacheLifetime.ThirtyMinutes, LlmWirePromptCacheLifetime.OneHour, LlmWirePromptCacheLifetime.TwentyFourHours],
        tools: true, parallelToolCalls: true
    )
}

func expectLlmError(code: String, body: () -> Unit): Unit {
    try {
        body()
        @Fail("expected LlmTransportError: " + code)
    } catch (error: LlmTransportError) { @Expect(error.code, code) }
}

func event(data: String): SseEvent { SseEvent("message", data, "", None) }

class SatisfiedRequirementResolver <: LlmWireRequirementResolver {
    public func resolve(requirement: LlmWireFeatureRequirement): LlmWireRequirementState { let _ = requirement; LlmWireRequirementState.Satisfied }
}

class UnknownRequirementResolver <: LlmWireRequirementResolver {
    public func resolve(requirement: LlmWireFeatureRequirement): LlmWireRequirementState { requirement.state }
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
        let request = LlmWireRequest("model", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello"))])], maxOutputTokens: Some(1024))
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
        let adaptive = messages.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Adaptive(Some(LlmWireThinkingLevel.High)), maxOutputTokens: Some(4096)))
        @Expect(adaptive.contains("\"thinking\":{\"type\":\"adaptive\"}"), true)
        @Expect(adaptive.contains("\"output_config\":{\"effort\":\"high\"}"), true)

        let deepSeek = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: capabilities)
        @Expect(deepSeek.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Enabled)).contains("\"type\":\"enabled\""), true)
        let unknown = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        expectLlmError("llm.thinking_unsupported", { => let _ = unknown.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Low))) })
        expectLlmError("llm.thinking_unsupported", { => let _ = responses.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Adaptive(None))) })
    }

    @TestCase
    func t003OpaqueBlocksRoundTripOnlyWithinDialect() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        let state = codec.decodeResponse("{\"id\":\"m\",\"model\":\"claude\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"sig\"},{\"type\":\"redacted_thinking\",\"data\":\"opaque\"},{\"type\":\"future_block\",\"x\":1}],\"stop_reason\":\"end_turn\"}")
        let reply = match (state) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(value)) => value; case _ => @Fail("expected success") }
        let blocks = reply.blocks
        @Expect(blocks.size, 3)
        match (blocks[0]) { case LlmWireBlock.NativeReplay(value) => @Expect(value.payload()["signature"].string, "sig"); @Expect(value.displayReasoning, Some("why")); case _ => @Fail("thinking must be native replay") }
        match (blocks[1]) { case LlmWireBlock.NativeReplay(value) => @Expect(value.payload()["data"].string, "opaque"); case _ => @Fail("redacted thinking must be native replay") }
        match (blocks[2]) { case LlmWireBlock.Opaque(_) => (); case _ => @Fail("unknown block must be diagnostic") }
        let continuation = reply.toContinuationInput()
        let replay = codec.encodeRequest(LlmWireRequest("claude", continuation, maxOutputTokens: Some(1024)))
        @Expect(replay.contains("\"signature\":\"sig\""), true)
        @Expect(replay.contains("\"data\":\"opaque\""), true)
        let foreignCodec = LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect())
        expectLlmError("llm.native_replay_dialect_mismatch", { => let _ = foreignCodec.encodeRequest(LlmWireRequest("m", continuation, maxOutputTokens: Some(1024))) })
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
        match (objectState) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => match (reply.blocks[0]) { case LlmWireBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.Complete(value) => @Expect(value.stringify(), "{\"x\":1}"); case _ => @Fail("expected complete") }; case _ => @Fail("expected tool") }; case _ => @Fail("expected success") }
        match (shapeState) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => match (reply.blocks[0]) { case LlmWireBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.InvalidShape(value) => @Expect(value.stringify(), "[]"); case _ => @Fail("expected invalid shape") }; case _ => @Fail("expected tool") }; case _ => @Fail("expected success") }
        match (invalidState) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => match (reply.blocks[0]) { case LlmWireBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.InvalidJson(raw) => @Expect(raw, "{"); case _ => @Fail("expected invalid JSON") }; case _ => @Fail("expected tool") }; case _ => @Fail("expected success") }
    }

    @TestCase
    func t007StrictRejectsInvalidToolHistory() {
        let blocks = [LlmWireBlock.ToolResult(LlmWireToolResultBlock("future", "result")), LlmWireBlock.Text(LlmWireTextBlock("after"))]
        let strict = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: allCapabilities())
        expectLlmError("llm.tool_result_unmatched", { => let _ = strict.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, blocks)], maxOutputTokens: Some(1024))) })
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
        @Expect(done.terminal.isNone(), true)
        let usage = decoder.push(event("{\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":5}}"))
        @Expect(usage.terminal.isNone(), true)
        match (decoder.push(event("[DONE]")).terminal) { case Some(LlmWireTerminal.Succeeded(reply)) => @Expect(reply.blocks.size, 2); @Expect(reply.usage.outputTokens, Some(5)); case _ => @Fail("expected stream success") }
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
                match (reply.blocks[0]) { case LlmWireBlock.NativeReplay(value) => @Expect(value.snapshot().contains("sig"), true); case _ => @Fail("expected native replay") }
                match (reply.blocks[1]) { case LlmWireBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.Partial(raw) => @Expect(raw, "{\"x\":"); case _ => @Fail("expected partial") }; case _ => @Fail("expected tool") }
            case _ => @Fail("expected incomplete")
        }
    }

    @TestCase
    func t011StreamLifecycleRejectsMissingAndRepeatedTerminal() {
        let missing = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        expectLlmError("llm.stream_terminal_missing", { => let _ = missing.finishTransport() })
        expectLlmError("llm.stream_failed", { => let _ = missing.finishTransport() })

        let complete = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        let _ = complete.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"))
        expectLlmError("llm.chat_event_after_choice_finished", { => let _ = complete.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"late\"}}]}")) })
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
        let format = LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("answer", schema, description: "answer schema", strict: false))
        let call = LlmWireBlock.ToolCall(LlmWireToolCallBlock("call-1", "lookup", LlmWireToolArguments.Complete(parseWireJson("{\"q\":1}"))))
        let result = LlmWireBlock.ToolResult(LlmWireToolResultBlock("call-1", "done", isError: true))
        let common = [
            LlmWireMessage(LlmWireRole.User, [
                LlmWireBlock.Text(LlmWireTextBlock("hello")),
                LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "https://example.invalid/image.png", detail: LlmWireImageDetail.Low)),
                LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Base64, "AAAA", mediaType: "image/png", detail: LlmWireImageDetail.High))
            ]),
            LlmWireMessage(LlmWireRole.Assistant, [call]),
            LlmWireMessage(LlmWireRole.User, [result])
        ]
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: allCapabilities())
        let responsePayload = responses.encodeRequest(LlmWireRequest(
            "m", common, system: "system", tools: [tool],
            thinking: LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Max), maxOutputTokens: Some(99),
            streaming: Some(true), parallelToolCalls: Some(false), serviceTier: LlmWireServiceTier.Priority,
            promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.TwentyFourHours), promptCacheRoutingKey: Some("key"),
            toolChoice: LlmWireToolChoice.Auto, structuredOutput: format
        ))
        for (needle in ["instructions", "max_output_tokens", "prompt_cache_key", "function_call_output", "data:image/png;base64", "json_schema"]) { @Expect(responsePayload.contains(needle), true) }

        let chatMessages = [LlmWireMessage(LlmWireRole.Assistant, [call]), LlmWireMessage(LlmWireRole.User, [result])]
        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: allCapabilities())
        let chatPayload = chat.encodeRequest(LlmWireRequest("m", chatMessages, system: "system", tools: [tool], thinking: LlmWireThinkingControl.Disabled, maxOutputTokens: Some(9), streaming: Some(false), parallelToolCalls: Some(true), serviceTier: LlmWireServiceTier.Default, toolChoice: LlmWireToolChoice.Required, structuredOutput: format))
        for (needle in ["system", "tool_call_id", "tool_calls", "response_format", "reasoning_effort", "required"]) { @Expect(chatPayload.contains(needle), true) }

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: allCapabilities())
        let messagePayload = messages.encodeRequest(LlmWireRequest("m", common, system: "system", tools: [tool], thinking: LlmWireThinkingControl.Adaptive(Some(LlmWireThinkingLevel.XHigh)), maxOutputTokens: Some(4096), streaming: Some(true), generationSpeed: LlmWireGenerationSpeed.Fast, toolChoice: LlmWireToolChoice.NoTools, structuredOutput: format))
        for (needle in ["output_config", "xhigh", "tool_use", "tool_result", "base64", "is_error", "input_schema"]) { @Expect(messagePayload.contains(needle), true) }

        expectLlmError("llm.tool_choice_without_tools", { => let _ = messages.encodeRequest(LlmWireRequest("m", [], maxOutputTokens: Some(1024), toolChoice: LlmWireToolChoice.Auto)) })
        expectLlmError("llm.tool_choice_without_tools", { => let _ = messages.encodeRequest(LlmWireRequest("m", [], maxOutputTokens: Some(1024), toolChoice: LlmWireToolChoice.Required)) })
    }

    @TestCase
    func t018FixedDecodersCoverBlocksUsageAndTerminalVariants() {
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), provider: "openai")
        let response = responses.decodeResponse("{\"id\":\"r\",\"model\":\"m\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"},{\"type\":\"refusal\",\"refusal\":\"no\"},{\"type\":\"future\",\"x\":1}]},{\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{}\"},{\"type\":\"reasoning\",\"summary\":\"why\"},{\"type\":\"future_item\",\"x\":2}],\"usage\":{\"input_tokens\":5,\"output_tokens\":6,\"input_tokens_details\":{\"cached_tokens\":2,\"cache_write_tokens\":1},\"output_tokens_details\":{\"reasoning_tokens\":3}}}")
        match (response) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => @Expect(reply.blocks.size, 6); @Expect(reply.usage.reasoningTokens, Some(3)); case _ => @Fail("expected response success") }
        match (responses.decodeResponse("{\"status\":\"in_progress\"}")) { case LlmWireResponseState.Pending(LlmWirePendingReply.InProgress(_)) => (); case _ => @Fail("expected progress") }
        match (responses.decodeResponse("{\"status\":\"failed\"}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("expected failed") }
        expectLlmError("llm.responses_status_unsupported", { => let _ = responses.decodeResponse("{\"status\":\"future\"}") })

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect())
        let chatState = chat.decodeResponse("{\"id\":\"c\",\"model\":\"m\",\"choices\":[{\"message\":{\"content\":\"ok\",\"reasoning_content\":\"why\",\"tool_calls\":[{\"id\":\"t\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"content_filter\"}],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":5,\"prompt_tokens_details\":{\"cached_tokens\":1},\"completion_tokens_details\":{\"reasoning_tokens\":2}}}")
        match (chatState) { case LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(reply, _)) => @Expect(reply.blocks.size, 3); @Expect(reply.usage.cacheReadTokens, Some(1)); case _ => @Fail("expected filtered") }
        match (chat.decodeResponse("{\"choices\":[{\"message\":{},\"finish_reason\":\"insufficient_system_resource\"}]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("expected resource failure") }
        expectLlmError("llm.chat_choices_empty", { => let _ = chat.decodeResponse("{\"choices\":[]}") })
        expectLlmError("llm.chat_finish_reason_unsupported", { => let _ = chat.decodeResponse("{\"choices\":[{\"message\":{},\"finish_reason\":\"future\"}]}") })

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        let messageState = messages.decodeResponse("{\"id\":\"x\",\"model\":\"m\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"},{\"type\":\"tool_use\",\"id\":\"c\",\"name\":\"f\",\"input\":[]},{\"type\":\"future\",\"x\":1}],\"stop_reason\":\"model_context_window_exceeded\",\"usage\":{\"input_tokens\":4,\"output_tokens\":5,\"cache_read_input_tokens\":2,\"cache_creation_input_tokens\":1}}")
        match (messageState) { case LlmWireResponseState.Terminal(LlmWireTerminal.Incomplete(reply, LlmWireIncompleteReason.ModelContextWindowExceeded)) => @Expect(reply.blocks.size, 3); @Expect(reply.usage.cacheWriteTokens, Some(1)); case _ => @Fail("expected context incomplete") }
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
        expectLlmError("llm.structured_output_unsupported", { => let _ = base.encodeRequest(LlmWireRequest("m", [], structuredOutput: LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("x", parseWireJson("{}"))))) })
        expectLlmError("llm.parallel_tools_without_tools", { => let _ = base.encodeRequest(LlmWireRequest("m", [], parallelToolCalls: Some(true))) })
        expectLlmError("llm.service_tier_unsupported", { => let _ = base.encodeRequest(LlmWireRequest("m", [], serviceTier: LlmWireServiceTier.Priority)) })
        expectLlmError("llm.cache_lifetime_unsupported", { => let _ = base.encodeRequest(LlmWireRequest("m", [], promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.TwentyFourHours))) })

        let capable = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: allCapabilities())
        let duplicate = [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Complete(parseWireJson("{}")))), LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Complete(parseWireJson("{}"))))])]
        expectLlmError("llm.tool_call_duplicate", { => let _ = capable.encodeRequest(LlmWireRequest("m", duplicate)) })
        let partial = [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Partial("{")))])]
        expectLlmError("llm.tool_arguments_partial", { => let _ = capable.encodeRequest(LlmWireRequest("m", partial)) })
        let opaque = LlmWireOpaqueBlock("future", parseWireJson("{\"type\":\"future\"}"), completion: LlmWireOpaqueCompletion.Partial)
        expectLlmError("llm.opaque_diagnostic_only", { => let _ = capable.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Opaque(opaque)])])) })
        expectLlmError("llm.object_expected", { => let _ = LlmWireNativeReplayBlock.restore("[]") })
        expectLlmError("llm.reasoning_display_only", { => let _ = capable.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Reasoning(LlmWireReasoningBlock("why"))])])) })
        expectLlmError("llm.refusal_display_only", { => let _ = capable.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Refusal(LlmWireRefusalBlock("no"))])])) })

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: allCapabilities())
        expectLlmError("llm.chat_image_unsupported", { => let _ = chat.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "x"))])])) })
        expectLlmError("llm.opaque_diagnostic_only", { => let _ = chat.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Opaque(LlmWireOpaqueBlock("x", parseWireJson("{\"type\":\"x\"}")))])])) })
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
        let update = chat.push(event("{\"id\":\"c\",\"model\":\"m\",\"usage\":{\"prompt_tokens\":1},\"choices\":[{\"index\":0,\"delta\":{\"content\":\"a\",\"reasoning_content\":\"b\"}}]}"))
        @Expect(update.events.size, 2)
        let _ = chat.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"content_filter\"}]}"))
        match (chat.push(event("[DONE]")).terminal) { case Some(LlmWireTerminal.Incomplete(_, _)) => (); case _ => @Fail("expected filtered") }
        let chatError = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        match (chatError.push(event("{\"error\":{\"type\":\"busy\"}}" )).terminal) { case Some(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("expected chat failure") }
        let chatResource = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        let _ = chatResource.push(event("{\"choices\":[{\"delta\":{},\"finish_reason\":\"insufficient_system_resource\"}]}"))
        match (chatResource.push(event("[DONE]")).terminal) { case Some(LlmWireTerminal.Failed(_)) => (); case _ => @Fail("expected resource failure") }

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
        let caches = [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.FiveMinutes, LlmWirePromptCacheLifetime.OneHour]
        for (index in 0..caches.size) { @Expect(caches[index] == caches[index], true); @Expect(caches[index] != caches[(index + 1) % caches.size], true) }
        let choices = [LlmWireToolChoice.ProviderDefault, LlmWireToolChoice.Auto, LlmWireToolChoice.NoTools, LlmWireToolChoice.Required]
        for (index in 0..choices.size) { @Expect(choices[index] == choices[index], true); @Expect(choices[index] != choices[(index + 1) % choices.size], true) }
        let speeds = [LlmWireGenerationSpeed.ProviderDefault, LlmWireGenerationSpeed.Standard, LlmWireGenerationSpeed.Fast]
        for (index in 0..speeds.size) { @Expect(speeds[index] == speeds[index], true); @Expect(speeds[index] != speeds[(index + 1) % speeds.size], true) }
        let completions = [LlmWireOpaqueCompletion.Complete, LlmWireOpaqueCompletion.Partial]
        for (index in 0..completions.size) { @Expect(completions[index] == completions[index], true); @Expect(completions[index] != completions[(index + 1) % completions.size], true) }
        let dialects = [LlmWireBuiltinDialect.OpenAiResponses, LlmWireBuiltinDialect.OpenAiChat, LlmWireBuiltinDialect.AnthropicMessages, LlmWireBuiltinDialect.DeepSeekResponses, LlmWireBuiltinDialect.DeepSeekChat, LlmWireBuiltinDialect.DeepSeekMessages]
        for (index in 0..dialects.size) { @Expect(dialects[index] == dialects[index], true); @Expect(dialects[index] != dialects[(index + 1) % dialects.size], true) }
        let requestStyles = [LlmWireRequestStyle.OpenAiResponses, LlmWireRequestStyle.OpenAiChat, LlmWireRequestStyle.AnthropicMessages, LlmWireRequestStyle.DeepSeekResponses, LlmWireRequestStyle.DeepSeekChat, LlmWireRequestStyle.DeepSeekMessages]
        for (index in 0..requestStyles.size) { @Expect(requestStyles[index] == requestStyles[index], true); @Expect(requestStyles[index] != requestStyles[(index + 1) % requestStyles.size], true) }
        let tokenFields = [LlmWireOutputTokenField.MaxOutputTokens, LlmWireOutputTokenField.MaxCompletionTokens, LlmWireOutputTokenField.MaxTokens]
        for (index in 0..tokenFields.size) { @Expect(tokenFields[index] == tokenFields[index], true); @Expect(tokenFields[index] != tokenFields[(index + 1) % tokenFields.size], true) }
        let structuredModes = [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject, LlmWireStructuredOutputMode.JsonSchema]
        for (index in 0..structuredModes.size) { @Expect(structuredModes[index] == structuredModes[index], true); @Expect(structuredModes[index] != structuredModes[(index + 1) % structuredModes.size], true) }
        let parallelStyles = [LlmWireParallelToolStyle.Unsupported, LlmWireParallelToolStyle.OpenAiTopLevel, LlmWireParallelToolStyle.AnthropicToolChoice]
        for (index in 0..parallelStyles.size) { @Expect(parallelStyles[index] == parallelStyles[index], true); @Expect(parallelStyles[index] != parallelStyles[(index + 1) % parallelStyles.size], true) }
        let cacheStyles = [LlmWirePromptCacheStyle.Unsupported, LlmWirePromptCacheStyle.OpenAi, LlmWirePromptCacheStyle.Anthropic, LlmWirePromptCacheStyle.ProviderAutomatic]
        for (index in 0..cacheStyles.size) { @Expect(cacheStyles[index] == cacheStyles[index], true); @Expect(cacheStyles[index] != cacheStyles[(index + 1) % cacheStyles.size], true) }
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
                let payload = deepSeekCodecs[index].encodeRequest(LlmWireRequest("m", [], thinking: control, maxOutputTokens: Some(2048)))
                @Expect(payload.contains(if (index == 0) { "reasoning" } else { "thinking" }), true)
                if (index == 0) { @Expect(payload.contains("\"thinking\""), false) }
            }
        }
        let openAiChat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: capabilities)
        @Expect(openAiChat.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Enabled)).contains("medium"), true)
        @Expect(openAiChat.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Low))).contains("low"), true)
        let anthropic = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: capabilities)
        for (control in [LlmWireThinkingControl.Disabled, LlmWireThinkingControl.Budget(1024), LlmWireThinkingControl.Adaptive(None)]) {
            @Expect(anthropic.encodeRequest(LlmWireRequest("m", [], thinking: control, maxOutputTokens: Some(2048))).contains("thinking"), true)
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
            expectLlmError("llm.thinking_unsupported", { => let _ = codec.encodeRequest(LlmWireRequest("m", [], thinking: control, maxOutputTokens: Some(2048))) })
        }
        let noLevels = LlmWireCapabilities(thinkingControls: [LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Medium)])
        let levelCodec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: noLevels)
        expectLlmError("llm.thinking_level_unsupported", { => let _ = levelCodec.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Effort(LlmWireThinkingLevel.High))) })
        let budgetCodec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: capabilities)
        expectLlmError("llm.thinking_budget_invalid", { => let _ = budgetCodec.encodeRequest(LlmWireRequest("m", [], thinking: LlmWireThinkingControl.Budget(0), maxOutputTokens: Some(2048))) })
        expectLlmError("llm.dialect_protocol_mismatch", { => let _ = LlmWireCodec(LlmWireProtocol.Messages, openAiResponsesDialect()) })
    }

    @TestCase
    func t026TransportCoversSplitLinesInvalidLimitsAndOverflow() {
        try { let _ = SseDecoder(maxEventBytes: 0); @Fail("invalid limit") } catch (_: IllegalArgumentException) { () }
        let independentBuffer = SseDecoder(maxEventBytes: 100, maxLineBytes: 100, maxBufferedBytes: 2)
        match (independentBuffer.push("abc")) { case LlmResult.Err(error) => @Expect(error.code, "llm.sse_buffer_too_large"); case _ => @Fail("independent buffer limit") }
        match (independentBuffer.push("x")) { case LlmResult.Err(error) => @Expect(error.code, "llm.sse_failed"); case _ => @Fail("poisoned SSE") }
        let lineLimit = SseDecoder(maxEventBytes: 100, maxLineBytes: 2, maxBufferedBytes: 100)
        match (lineLimit.push("abc")) { case LlmResult.Err(error) => @Expect(error.code, "llm.sse_line_too_large"); case _ => @Fail("line limit") }
        let outputLimit = SseDecoder(maxEventBytes: 100, maxLineBytes: 100, maxBufferedBytes: 100, maxEventsPerPush: 1)
        match (outputLimit.push("data: a\n\ndata: b\n\n")) { case LlmResult.Err(error) => @Expect(error.code, "llm.sse_output_too_large"); case _ => @Fail("output limit") }
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
        let complete = LlmWireToolArguments.Complete(schema)
        let badJson = LlmWireToolArguments.InvalidJson("{")
        let badShape = LlmWireToolArguments.InvalidShape(parseWireJson("[]"))
        @Expect(toolArgumentsRaw(complete), "{}")
        @Expect(toolArgumentsRaw(badJson), "{")
        @Expect(toolArgumentsRaw(badShape), "[]")
        expectLlmError("llm.tool_arguments_json_invalid", { => let _ = toolArgumentsObject(badJson) })
        expectLlmError("llm.tool_arguments_shape_invalid", { => let _ = toolArgumentsObject(badShape) })
        expectLlmError("llm.tool_arguments_shape_invalid", { => let _ = toolArgumentsObject(LlmWireToolArguments.Complete(parseWireJson("[]"))) })
        let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: allCapabilities())
        let minimal = codec.encodeRequest(LlmWireRequest("m", [], tools: [LlmWireTool("f", "", schema)], promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.TwentyFourHours), toolChoice: LlmWireToolChoice.NoTools, structuredOutput: LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("x", schema))))
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
        @Expect(chatEmpty.push(event("{}")).events.size, 0)
        expectLlmError("llm.chat_choice_terminal_missing", { => let _ = chatEmpty.push(event("[DONE]")) })
        let chatCall = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        expectLlmError("llm.field_missing", { => let _ = chatCall.push(event("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{}}]}}]}")) })
        let chatNoFunction = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        @Expect(chatNoFunction.push(event("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0}]}}]}")).events.size, 0)
        let chatPartial = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        let _ = chatPartial.push(event("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\",\"function\":{\"name\":\"f\",\"arguments\":\"{\"}}]}}]}"))
        let _ = chatPartial.push(event("{\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}"))
        match (chatPartial.finishTransport()) { case LlmWireTerminal.Incomplete(reply, _) => match (reply.blocks[0]) { case LlmWireBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.Partial(_) => (); case _ => @Fail("partial call") }; case _ => @Fail("tool call") }; case _ => @Fail("length") }
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
        try { let _ = unknown.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"future\"}}")); @Fail("unknown native") }
        catch (error: LlmTransportError) { @Expect(error.code, "llm.messages_stream_block_unsupported"); @Expect(error.diagnosticJson.getOrThrow().contains("start_event"), true) }
        let noStart = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        expectLlmError("llm.messages_delta_without_start", { => let _ = noStart.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}")) })
        expectLlmError("llm.stream_failed", { => let _ = noStart.push(event("{\"type\":\"content_block_stop\",\"index\":0}")) })
        let stopped = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        let _ = stopped.push(event(startText)); let _ = stopped.push(event("{\"type\":\"content_block_stop\",\"index\":0}"))
        expectLlmError("llm.messages_delta_after_stop", { => let _ = stopped.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}")) })
        expectLlmError("llm.stream_failed", { => let _ = stopped.push(event("{\"type\":\"content_block_stop\",\"index\":0}")) })
        let incompleteBlock = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        let _ = incompleteBlock.push(event(startText)); let _ = incompleteBlock.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}"))
        expectLlmError("llm.messages_content_block_incomplete", { => let _ = incompleteBlock.push(event("{\"type\":\"message_stop\"}")) })
        let redacted = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        let _ = redacted.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"x\"}}"))
        let _ = redacted.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}"))
        match (redacted.push(event("{\"type\":\"message_stop\"}")).terminal) { case Some(LlmWireTerminal.Incomplete(reply, _)) => match (reply.blocks[0]) { case LlmWireBlock.NativeReplay(value) => @Expect(value.completion, LlmWireOpaqueCompletion.Partial); case _ => @Fail("native replay") }; case _ => @Fail("redacted") }
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
        match (completeTool) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => match (reply.blocks[0]) { case LlmWireBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.Complete(_) => (); case _ => @Fail("complete") }; case _ => @Fail("tool") }; case _ => @Fail("messages") }
    }

    @TestCase
    func t030DirectBranchContractsCoverReplayDefaultsAndStreamMaterialization() {
        expectLlmError("llm.tool_arguments_partial", { => let _ = toolArgumentsRaw(LlmWireToolArguments.Partial("{")) })
        expectLlmError("llm.tool_arguments_partial", { => let _ = toolArgumentsObject(LlmWireToolArguments.Partial("{")) })
        expectLlmError("llm.chat_block_unsupported", { => let _ = blockText(LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Complete(parseWireJson("{}"))))) })
        match (classifyToolArguments("null")) { case LlmWireToolArguments.InvalidShape(value) => @Expect(value.stringify(), "null"); case _ => @Fail("null shape") }
        expectLlmError("llm.json_invalid", { => let _ = parseWireJson("{\"x\":1,\"x\":2}") })
        expectLlmError("llm.json_duplicate_key", { => let _ = wireJsonObject([WireJsonField("x", wireJsonString("a")), WireJsonField("x", wireJsonString("b"))]) })

        let completeOpaque = LlmWireOpaqueBlock("future", parseWireJson("{\"type\":\"future\"}"))
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        expectLlmError("llm.opaque_diagnostic_only", { => let _ = responses.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Opaque(completeOpaque)])])) })
        let messageOpaque = LlmWireOpaqueBlock("future", parseWireJson("{\"type\":\"future\"}"))
        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        expectLlmError("llm.opaque_diagnostic_only", { => let _ = messages.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Opaque(messageOpaque)])], maxOutputTokens: 1024)) })

        let emptyId = [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("", "f", LlmWireToolArguments.Complete(parseWireJson("{}"))))])]
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
        match (materializeMessageBlock(messages, rawRedacted)) { case LlmWireBlock.NativeReplay(value) => @Expect(value.completion, LlmWireOpaqueCompletion.Partial); case _ => @Fail("raw redacted") }
        rawRedacted.completed = true
        match (materializeMessageBlock(messages, rawRedacted)) { case LlmWireBlock.NativeReplay(value) => @Expect(value.completion, LlmWireOpaqueCompletion.Complete); case _ => @Fail("complete redacted") }
        @Expect(extractRetryAfterMillis("Retry-After: invalid\n", 0), None)
    }

    @TestCase
    func t031BuiltInDialectsMatchMinimalRequestGoldens() {
        let message = [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello"))])]
        let request = LlmWireRequest("fixture-model", message, maxOutputTokens: Some(256))
        let cases = [
            (LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()), "{\"model\":\"fixture-model\",\"max_output_tokens\":256,\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hello\"}]}]}"),
            (LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()), "{\"model\":\"fixture-model\",\"max_completion_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}"),
            (LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()), "{\"model\":\"fixture-model\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}]}"),
            (LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect()), "{\"model\":\"fixture-model\",\"max_output_tokens\":256,\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hello\"}]}]}"),
            (LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect()), "{\"model\":\"fixture-model\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}"),
            (LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect()), "{\"model\":\"fixture-model\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}]}")
        ]
        for ((codec, expected) in cases) { @Expect(codec.encodeRequest(request).body, expected) }
    }

    @TestCase
    func t032RemediationContractsStayFailClosed() {
        let capabilities = allCapabilities()
        let anthropic = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: capabilities)
        let plan = anthropic.encodeRequest(LlmWireRequest("claude", [], maxOutputTokens: Some(2048), generationSpeed: LlmWireGenerationSpeed.Fast))
        @Expect(plan.requiredHeaders.size, 1)
        @Expect(plan.featureRequirements.size, 1)
        plan.validateForSend(SatisfiedRequirementResolver())
        expectLlmError("llm.feature_requirement_unresolved", { => plan.validateForSend(UnknownRequirementResolver()) })
        let merged = plan.mergeHeaders([LlmWireHeader("Anthropic-Beta", "other-feature")])
        @Expect(merged[0].value, "fast-mode-2026-02-01,other-feature")
        expectLlmError("llm.required_header_conflict", { => let _ = LlmWireEncodedRequest("{}", requiredHeaders: [LlmWireHeader("x-mode", "required")]).mergeHeaders([LlmWireHeader("X-Mode", "different")]) })

        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        let grouped = responses.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("a")), LlmWireBlock.Text(LlmWireTextBlock("b"))])])).body
        @Expect(grouped, "{\"model\":\"m\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"a\"},{\"type\":\"input_text\",\"text\":\"b\"}]}]}")

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        match (chat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{\"refusal\":\"no\"},\"finish_reason\":\"stop\"}]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => match (reply.blocks[0]) { case LlmWireBlock.Refusal(value) => @Expect(value.text, "no"); case _ => @Fail("fixed refusal") }; case _ => @Fail("fixed chat") }
        expectLlmError("llm.chat_multiple_choices_unsupported", { => let _ = chat.decodeResponse("{\"choices\":[{\"message\":{},\"finish_reason\":\"stop\"},{\"message\":{},\"finish_reason\":\"stop\"}]}" ) })
        expectLlmError("llm.chat_choice_index_unsupported", { => let _ = chat.decodeResponse("{\"choices\":[{\"index\":1,\"message\":{},\"finish_reason\":\"stop\"}]}" ) })
        let refusal = chat.newStreamDecoder()
        @Expect(refusal.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"refusal\":\"no\"}}]}" )).events[0].kind, LlmWireEventKind.RefusalDelta)
        let _ = refusal.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"))
        match (refusal.push(event("[DONE]")).terminal) { case Some(LlmWireTerminal.Succeeded(reply)) => match (reply.blocks[0]) { case LlmWireBlock.Refusal(value) => @Expect(value.text, "no"); case _ => @Fail("stream refusal") }; case _ => @Fail("stream chat") }

        let badMessages = anthropic.newStreamDecoder()
        let _ = badMessages.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"))
        expectLlmError("llm.messages_delta_type_mismatch", { => let _ = badMessages.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"x\"}}")) })
        expectLlmError("llm.stream_failed", { => let _ = badMessages.push(event("{\"type\":\"content_block_stop\",\"index\":0}")) })

        let responseStream = responses.newStreamDecoder()
        let _ = responseStream.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"item\",\"call_id\":\"call\",\"name\":\"f\"}}"))
        let _ = responseStream.push(event("{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"item\",\"delta\":\"{}\"}"))
        let done = responseStream.push(event("{\"type\":\"response.function_call_arguments.done\",\"item_id\":\"item\",\"arguments\":\"{}\"}"))
        @Expect(done.events[0].callId, "call")

        let native = nativeReplayFromPayload(LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking", parseWireJson("{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"sig\"}"), modelConstraint: Some("claude"))
        let restored = LlmWireNativeReplayBlock.restore(native.snapshot())
        @Expect(restored.dialectId, "anthropic.messages.v1")
        @Expect(restored.payload()["signature"].string, "sig")
        expectLlmError("llm.native_replay_incomplete", { => let _ = LlmWireNativeReplayBlock.restore(native.snapshot().replace("\"complete\":true", "\"complete\":false")) })
        expectLlmError("llm.native_replay_model_mismatch", { => let _ = anthropic.encodeRequest(LlmWireRequest("other", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.NativeReplay(restored)])], maxOutputTokens: Some(2048))) })

        let tool = LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Complete(parseWireJson("{}"))))
        expectLlmError("llm.tool_call_role_invalid", { => let _ = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities).encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [tool])])) })
        match (chat.decodeResponse("{\"choices\":[{\"message\":{},\"finish_reason\":\"stop\"}]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) => @Expect(reply.usage.inputTokens, None); case _ => @Fail("optional usage") }
    }
}
