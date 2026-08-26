package llm4cj

import std.io.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

@Test
class Llm4CjTests {
    @TestCase
    func parsesFragmentedAndMultipleSseEvents() {
        let decoder = SseDecoder(maxEventBytes: 1024)
        match (decoder.push("event: delta\ndata: hel")) {
            case LlmResult.Ok(events) => @Expect(events.size, 0)
            case LlmResult.Err(error) => @Fail(error.message)
        }
        match (decoder.push("lo\n\ndata: one\ndata: two\n\n")) {
            case LlmResult.Ok(events) =>
                @Expect(events.size, 2)
                @Expect(events[0].event, "delta")
                @Expect(events[0].data, "hello")
                @Expect(events[1].data, "one\ntwo")
            case LlmResult.Err(error) => @Fail(error.message)
        }
        @Expect(decoder.finish().isOk(), true)
    }

    @TestCase
    func rejectsOversizedSseAndBodies() {
        let decoder = SseDecoder(maxEventBytes: 4)
        @Expect(decoder.push("data: hello\n\n").isOk(), false)

        let body = ByteBuffer()
        body.write("hello".toArray())
        @Expect(readLlmHttpBody(body, Some(5), 4).isOk(), false)
    }

    @TestCase
    func parsesRetryAfterWithoutOwningAgentBackoffPolicy() {
        @Expect(parseRetryAfterMillis("5"), 5000)
        @Expect(parseRetryAfterMillis("-1"), 0)
        @Expect(extractRetryAfterMillis("x: y\nRetry-After: 7\n"), 7000)
        @Expect(parseRetryAfterMillis("9223372036854775807"), Int64.Max)
    }

    @TestCase
    func ownsProviderRequestCodecs() {
        let request = LlmWireRequest(
            "model-x",
            [LlmWireMessage(LlmWireRole.User, [LlmWireBlock(LlmWireBlockKind.Text, text: "hello")])],
            tools: [LlmWireTool("lookup", "find", YJson.parse("{\"type\":\"object\"}"))],
            maxOutputTokens: 64,
            streaming: true,
            structuredOutput: Some(LlmWireStructuredOutput("answer", YJson.parse("{\"type\":\"object\"}")))
        )
        @Expect(encodeResponsesWireRequest(request).contains("\"max_output_tokens\":64"), true)
        @Expect(encodeChatCompletionsWireRequest(request).contains("\"response_format\""), true)
        let messagesRequest = LlmWireRequest(
            request.model,
            request.messages,
            tools: request.tools,
            thinking: LlmWireThinkingControl.Budget(8192),
            maxOutputTokens: request.maxOutputTokens,
            streaming: request.streaming,
            structuredOutput: request.structuredOutput
        )
        let messagesPayload = encodeMessagesWireRequest(messagesRequest)
        @Expect(messagesPayload.contains("\"input_schema\""), true)
        @Expect(messagesPayload.contains("\"budget_tokens\":8192"), true)
    }

    @TestCase
    func deepSeekMessagesUsesExplicitEffortDialect() {
        let request = LlmWireRequest(
            "deepseek-model",
            [LlmWireMessage(
                LlmWireRole.User,
                [LlmWireBlock(LlmWireBlockKind.Text, text: "hello")]
            )],
            thinking: LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Max),
            maxOutputTokens: 4096,
            structuredOutput: Some(LlmWireStructuredOutput(
                "answer",
                YJson.parse("{\"type\":\"object\"}")
            ))
        )
        let payload = encodeDeepSeekMessagesWireRequest(request)
        @Expect(payload.contains("\"thinking\":{\"type\":\"enabled\"}"), true)
        @Expect(payload.contains("\"output_config\":{\"format\":"), true)
        @Expect(payload.contains("\"effort\":\"max\""), true)
        @Expect(payload.contains("budget_tokens"), false)

        let disabled = encodeDeepSeekMessagesWireRequest(LlmWireRequest(
            request.model,
            request.messages,
            thinking: LlmWireThinkingControl.Toggle(false),
            maxOutputTokens: request.maxOutputTokens
        ))
        @Expect(disabled.contains("\"thinking\":{\"type\":\"disabled\"}"), true)

        try {
            let _ = encodeDeepSeekMessagesWireRequest(LlmWireRequest(
                request.model,
                request.messages,
                thinking: LlmWireThinkingControl.Budget(2048),
                maxOutputTokens: request.maxOutputTokens
            ))
            @Fail("DeepSeek Messages must reject numeric thinking budgets")
        } catch (error: LlmTransportError) {
            @Expect(error.code, "llm.deepseek_thinking_mode_invalid")
        }
    }

    @TestCase
    func decodesAllProviderRepliesAndPreservesUsage() {
        let messages = decodeMessagesWireReply("{\"id\":\"m1\",\"content\":[{\"type\":\"tool_use\",\"id\":\"c1\",\"name\":\"lookup\",\"input\":{\"q\":\"x\"}}],\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}")
        @Expect(messages.blocks[0].name, "lookup")
        @Expect(messages.usage.inputTokens, 3)

        let responses = decodeResponsesWireReply("{\"id\":\"r1\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}],\"usage\":{\"input_tokens\":4,\"output_tokens\":1}}")
        @Expect(responses.blocks[0].text, "ok")
        @Expect(responses.responseId, "r1")

        let chat = decodeChatCompletionsWireReply("{\"id\":\"c1\",\"choices\":[{\"message\":{\"content\":\"done\",\"tool_calls\":[]},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}")
        @Expect(chat.stopReason, "stop")
        @Expect(chat.usage.outputTokens, 2)
    }

    @TestCase
    func decodesProviderStreamsAndStructuredErrors() {
        let responses = decodeLlmWireEventStream(
            LlmWireProtocol.Responses,
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"o\"}\n\n" +
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n"
        )
        match (responses.events[0].kind) {
            case LlmWireEventKind.StreamStarted => ()
            case _ => @Fail("expected stream start")
        }
        match (responses.events[1].kind) {
            case LlmWireEventKind.TextDelta => ()
            case _ => @Fail("expected text delta")
        }
        @Expect(decodeResponsesWireReply(responses.terminalSource).blocks[0].text, "ok")

        try {
            let _ = decodeMessagesWireReply("{\"error\":{\"type\":\"invalid_request_error\",\"code\":\"bad\",\"message\":\"invalid\"}}", provider: "anthropic")
            @Fail("provider error should be structured")
        } catch (error: LlmTransportError) {
            @Expect(error.provider, "anthropic")
            @Expect(error.providerErrorCode, "bad")
            @Expect(error.providerErrorType, "invalid_request_error")
        }
    }

    @TestCase
    func requiresProviderTerminalEvidenceBeforeCompletingDecision() {
        let complete = decodeLlmWireEventStream(
            LlmWireProtocol.Messages,
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"usage\":{}}}\n\n" +
            "data: {\"type\":\"content_block_start\",\"index\":0," +
                "\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" +
            "data: {\"type\":\"content_block_delta\",\"index\":0," +
                "\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" +
            "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" +
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}," +
                "\"usage\":{\"output_tokens\":1}}\n\n" +
            "data: {\"type\":\"message_stop\"}\n\n"
        )
        var terminalObserved = false
        var blockCompleted = false
        var usageCompleted = false
        for (event in complete.events) {
            match (event.kind) {
                case LlmWireEventKind.MessageTerminalObserved => terminalObserved = true
                case LlmWireEventKind.ContentBlockCompleted => blockCompleted = true
                case LlmWireEventKind.UsageCompleted => usageCompleted = true
                case _ => ()
            }
        }
        @Expect(terminalObserved && blockCompleted && usageCompleted, true)

        try {
            let _ = decodeLlmWireEventStream(
                LlmWireProtocol.Messages,
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m2\",\"usage\":{}}}\n\n" +
                "data: {\"type\":\"content_block_start\",\"index\":0," +
                    "\"content_block\":{\"type\":\"text\",\"text\":\"partial\"}}\n\n"
            )
            @Fail("partial Messages stream must not become a decision")
        } catch (error: LlmTransportError) {
            @Expect(error.code, "llm.messages_terminal_missing")
        }
    }

    @TestCase
    func rejectsDuplicateKeysAndPreservesNumberLiterals() {
        try {
            let _ = decodeChatCompletionsWireReply(
                "{\"id\":\"one\",\"id\":\"two\",\"choices\":[]}"
            )
            @Fail("duplicate provider keys must be rejected")
        } catch (error: LlmTransportError) {
            @Expect(error.code, "llm.json_invalid")
        }

        let reply = decodeChatCompletionsWireReply(
            "{\"id\":\"c1\",\"choices\":[{\"message\":{\"content\":\"ok\"}," +
            "\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":9007199254740991," +
            "\"completion_tokens\":2}}"
        )
        @Expect(reply.usage.inputTokens, 9007199254740991)
    }

    @TestCase
    func coversSseFramingAndBodyBoundaries() {
        try {
            let _ = SseDecoder(maxEventBytes: 0)
            @Fail("zero event limit must fail")
        } catch (_: IllegalArgumentException) {}
        try {
            let _ = SseDecoder(maxEventBytes: 8, maxBufferedBytes: 7)
            @Fail("buffer limit smaller than event limit must fail")
        } catch (_: IllegalArgumentException) {}

        let buffered = SseDecoder(maxEventBytes: 4, maxBufferedBytes: 4)
        match (buffered.push("hello")) {
            case LlmResult.Err(error) => @Expect(error.code, "llm.sse_buffer_too_large")
            case _ => @Fail("oversized pending SSE data must fail")
        }

        let fields = SseDecoder(maxEventBytes: 64)
        match (fields.push(":comment\r\nevent: update\r\nid: abc\r\nretry: 12\r\ndata: one\r\ndata:two\r\nunknown\r\n\r\n")) {
            case LlmResult.Ok(events) =>
                @Expect(events.size, 1)
                @Expect(events[0].event, "update")
                @Expect(events[0].id, "abc")
                @Expect(events[0].retryMillis, 12)
                @Expect(events[0].data, "one\ntwo")
            case LlmResult.Err(error) => @Fail(error.message)
        }
        @Expect(fields.finish().isOk(), true)

        let tail = SseDecoder(maxEventBytes: 64)
        @Expect(tail.push("data: tail").isOk(), true)
        match (tail.finish()) {
            case LlmResult.Ok(events) => @Expect(events[0].data, "tail")
            case LlmResult.Err(error) => @Fail(error.message)
        }
        let ignored = SseDecoder(maxEventBytes: 64)
        @Expect(ignored.push(":comment\n\n").isOk(), true)
        match (ignored.finish()) {
            case LlmResult.Ok(events) => @Expect(events.size, 0)
            case LlmResult.Err(error) => @Fail(error.message)
        }

        match (sseDataLine("event: x")) {
            case None => ()
            case Some(_) => @Fail("non-data SSE line must be ignored")
        }
        @Expect(sseDataLine("data:value").getOrThrow(), "value")
        @Expect(sseDataLine("data: value").getOrThrow(), "value")
        @Expect(parseRetryAfterMillis(" bad "), 0)
        @Expect(extractRetryAfterMillis("retry-after: 2\nRetry-After: 7\n"), 7000)

        let valid = ByteBuffer()
        valid.write("hello".toArray())
        match (readLlmHttpBody(valid, None, 5)) {
            case LlmResult.Ok(bytes) => @Expect(bytes.size, 5)
            case LlmResult.Err(error) => @Fail(error.message)
        }
        let invalidLimit = ByteBuffer()
        match (readLlmHttpBody(invalidLimit, None, 0)) {
            case LlmResult.Err(error) => @Expect(error.code, "llm.body_limit_invalid")
            case _ => @Fail("zero body limit must fail")
        }
        let negativeSize = ByteBuffer()
        match (readLlmHttpBody(negativeSize, Some(-1), 5)) {
            case LlmResult.Err(error) => @Expect(error.code, "llm.body_too_large")
            case _ => @Fail("negative declared size must fail")
        }
        let streamed = ByteBuffer()
        streamed.write("hello".toArray())
        match (readLlmHttpBody(streamed, None, 4)) {
            case LlmResult.Err(error) => @Expect(error.code, "llm.body_too_large")
            case _ => @Fail("streamed body overflow must fail")
        }
    }

    @TestCase
    func coversWireJsonKindsAndValidationHelpers() {
        @Expect(YJson.parse("null").wireKind == WireJsonKind.Null, true)
        @Expect(YJson.parse("true").wireKind == WireJsonKind.Boolean, true)
        @Expect(YJson.parse("1.5").wireKind == WireJsonKind.Number, true)
        @Expect(YJson.parse("\"x\"").wireKind == WireJsonKind.Text, true)
        @Expect(YJson.parse("[]").wireKind == WireJsonKind.List, true)
        @Expect(YJson.parse("{}").wireKind == WireJsonKind.Object, true)
        @Expect(WireJsonKind.Null == WireJsonKind.Text, false)

        let array = wireJsonArray([])
        array.add(wireJsonString("x")).add(wireJsonNumber("2"))
        @Expect(array.items.size, 2)
        let object = wireJsonObject([WireJsonField("a", wireJsonBool(true))])
        object.put("b", array)
        @Expect(object.fields.size, 2)
        match (object.field("missing")) {
            case None => ()
            case Some(_) => @Fail("missing object field must return None")
        }
        @Expect(object.stringify().contains("\"a\":true"), true)

        try {
            let _ = wireJsonObject([
                WireJsonField("same", wireJsonString("a")),
                WireJsonField("same", wireJsonString("b"))
            ])
            @Fail("duplicate constructed keys must fail")
        } catch (error: LlmTransportError) {
            @Expect(error.code, "llm.json_duplicate_key")
        }
        try {
            let _ = wireObject(YJson.parse("[]"), "value")
            @Fail("object helper must reject arrays")
        } catch (error: LlmTransportError) { @Expect(error.code, "llm.object_expected") }
        try {
            let _ = wireArray(YJson.parse("{}"), "value")
            @Fail("array helper must reject objects")
        } catch (error: LlmTransportError) { @Expect(error.code, "llm.array_expected") }
        try {
            let _ = wireField(object, "missing")
            @Fail("required field must fail")
        } catch (error: LlmTransportError) { @Expect(error.code, "llm.field_missing") }

        let mixed = YJson.parse("{\"text\":\"ok\",\"wrong\":true,\"n\":7,\"huge\":999999999999999999999999}")
        @Expect(wireString(mixed, "text"), "ok")
        @Expect(wireString(mixed, "wrong"), "")
        @Expect(wireString(mixed, "none"), "")
        @Expect(wireObjectOrEmpty(mixed, "wrong").fields.size, 0)
        @Expect(wireObjectOrEmpty(mixed, "none").fields.size, 0)
        @Expect(wireInt(mixed, "n"), 7)
        @Expect(wireInt(mixed, "huge"), 0)
        @Expect(wireInt(mixed, "wrong"), 0)
        @Expect(wireInt(mixed, "none"), 0)
    }

    @TestCase
    func coversProviderRequestDialectsAndOptions() {
        let blocks = [
            LlmWireBlock(LlmWireBlockKind.Text, text: "hello"),
            LlmWireBlock(LlmWireBlockKind.Image, image: Some(LlmWireImage(
                LlmWireImageSourceKind.Url, "https://example.invalid/image.png",
                detail: LlmWireImageDetail.Low
            ))),
            LlmWireBlock(LlmWireBlockKind.Reasoning, text: "thought"),
            LlmWireBlock(LlmWireBlockKind.ToolCall, callId: "c1", name: "lookup", arguments: YJson.parse("{\"q\":1}")),
            LlmWireBlock(LlmWireBlockKind.ToolResult, callId: "c1", text: "result"),
            LlmWireBlock(LlmWireBlockKind.ToolResult, callId: "orphan", text: "hidden"),
            LlmWireBlock(LlmWireBlockKind.Refusal, text: "no"),
            LlmWireBlock(LlmWireBlockKind.Error),
            LlmWireBlock(LlmWireBlockKind.Unknown, text: "future")
        ]
        let tools = [LlmWireTool("lookup", "find", YJson.parse("{\"type\":\"object\"}"))]
        let common = LlmWireRequest(
            "model", [LlmWireMessage(LlmWireRole.Assistant, blocks)],
            system: "system", tools: tools,
            thinking: LlmWireThinkingControl.Toggle(true),
            maxOutputTokens: 32, streaming: true, parallelToolCalls: false,
            serviceTier: "priority", cachePolicy: LlmWireCachePolicy.StablePrefix,
            cacheKey: "cache", toolChoice: LlmWireToolChoice.Required,
            structuredOutput: Some(LlmWireStructuredOutput(
                "answer", YJson.parse("{\"type\":\"object\"}"),
                description: "schema", strict: false
            ))
        )
        let messages = encodeLlmWireRequest(LlmWireProtocol.Messages, common)
        @Expect(messages.contains("\"cache_control\""), true)
        @Expect(messages.contains("\"speed\":\"fast\""), true)
        @Expect(messages.contains("\"type\":\"any\""), true)
        @Expect(messages.contains("orphan"), false)
        let responses = encodeLlmWireRequest(LlmWireProtocol.Responses, common)
        @Expect(responses.contains("\"prompt_cache_key\":\"cache\""), true)
        @Expect(responses.contains("\"tool_choice\":\"required\""), true)
        @Expect(responses.contains("\"instructions\":\"system\""), true)
        let chat = encodeLlmWireRequest(LlmWireProtocol.ChatCompletions, common)
        @Expect(chat.contains("\"include_usage\":true"), true)
        @Expect(chat.contains("\"description\":\"schema\""), true)
        @Expect(chat.contains("\"role\":\"tool\""), true)

        let noTools = LlmWireRequest(
            "model", [], thinking: LlmWireThinkingControl.Disabled,
            toolChoice: LlmWireToolChoice.NoTools
        )
        @Expect(encodeMessagesWireRequest(noTools).contains("\"type\":\"none\""), true)
        @Expect(encodeResponsesWireRequest(noTools).contains("\"enabled\":false"), true)
        @Expect(encodeChatCompletionsWireRequest(noTools).contains("\"tool_choice\":\"none\""), true)

        for (thinking in [
            LlmWireThinkingControl.Disabled,
            LlmWireThinkingControl.Toggle(false),
            LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Low),
            LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Max)
        ]) {
            let payload = encodeDeepSeekChatWireRequest(LlmWireRequest("deepseek", [], thinking: thinking))
            @Expect(payload.contains("\"thinking\""), true)
        }
        for (invalid in [
            LlmWireThinkingControl.Budget(10),
            LlmWireThinkingControl.Adaptive(None)
        ]) {
            try {
                let _ = encodeDeepSeekChatWireRequest(LlmWireRequest("deepseek", [], thinking: invalid))
                @Fail("invalid DeepSeek Chat thinking mode must fail")
            } catch (error: LlmTransportError) {
                @Expect(error.code, "llm.deepseek_thinking_mode_invalid")
            }
        }
        try {
            let _ = encodeDeepSeekChatWireRequest(LlmWireRequest(
                "deepseek", [], thinking: LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Minimal)
            ))
            @Fail("minimal DeepSeek effort must fail")
        } catch (error: LlmTransportError) { @Expect(error.code, "llm.deepseek_effort_invalid") }
        try {
            let _ = encodeMessagesWireRequest(LlmWireRequest(
                "model", [], serviceTier: "standard",
                thinking: LlmWireThinkingControl.Toggle(true)
            ))
            @Fail("unsupported Messages service tier must fail")
        } catch (error: LlmTransportError) { @Expect(error.code, "llm.messages_service_tier_invalid") }
        try {
            let _ = encodeResponsesWireRequest(LlmWireRequest(
                "model", [], thinking: LlmWireThinkingControl.Budget(10)
            ))
            @Fail("numeric Responses thinking must fail")
        } catch (error: LlmTransportError) { @Expect(error.code, "llm.effort_thinking_mode_invalid") }
    }

    @TestCase
    func coversBlockEncodingImagesOpaqueStateAndToolResults() {
        let url = LlmWireImage(LlmWireImageSourceKind.Url, "https://example.invalid/a", detail: LlmWireImageDetail.Auto)
        let base64 = LlmWireImage(LlmWireImageSourceKind.Base64, "YWJj", mediaType: "image/png", detail: LlmWireImageDetail.High)
        @Expect(wireImageUrl(url), "https://example.invalid/a")
        @Expect(wireImageUrl(base64), "data:image/png;base64,YWJj")
        @Expect(wireImageDetail(LlmWireImageDetail.Auto), "auto")
        @Expect(wireImageDetail(LlmWireImageDetail.Low), "low")
        @Expect(wireImageDetail(LlmWireImageDetail.High), "high")
        @Expect(encodeMessagesWireBlock(LlmWireBlock(LlmWireBlockKind.Image, image: Some(url))).stringify().contains("\"url\""), true)
        @Expect(encodeMessagesWireBlock(LlmWireBlock(LlmWireBlockKind.Image, image: Some(base64))).stringify().contains("\"base64\""), true)
        @Expect(encodeResponsesWireBlock(LlmWireBlock(LlmWireBlockKind.Image, image: Some(base64))).stringify().contains("data:image/png"), true)
        try {
            let _ = encodeResponsesWireBlock(LlmWireBlock(LlmWireBlockKind.Image))
            @Fail("image payload is required")
        } catch (error: LlmTransportError) { @Expect(error.code, "llm.image_missing") }

        let preserved = LlmWireBlock(
            LlmWireBlockKind.Reasoning, text: "fallback",
            opaqueState: Some(LlmWireOpaqueState("messages", "{\"type\":\"thinking\",\"thinking\":\"saved\"}"))
        )
        @Expect(encodeMessagesWireBlock(preserved).stringify().contains("saved"), true)
        let foreignState = LlmWireBlock(
            LlmWireBlockKind.Reasoning, text: "fallback",
            opaqueState: Some(LlmWireOpaqueState("other", "{}"))
        )
        @Expect(encodeMessagesWireBlock(foreignState).stringify().contains("fallback"), true)
        @Expect(encodeMessagesWireBlock(LlmWireBlock(LlmWireBlockKind.Refusal, text: "no")).stringify().contains("no"), true)
        @Expect(encodeMessagesWireBlock(LlmWireBlock(LlmWireBlockKind.Unknown, text: "future")).stringify().contains("future"), true)
        @Expect(encodeMessagesWireBlock(LlmWireBlock(LlmWireBlockKind.Error)).stringify().contains("\"text\":\"\""), true)

        @Expect(wireVisibleToolResult(LlmWireBlock(LlmWireBlockKind.ToolResult, text: "visible")), "visible")
        @Expect(wireVisibleToolResult(LlmWireBlock(LlmWireBlockKind.ToolResult, arguments: YJson.parse("\"string\""))), "string")
        @Expect(wireVisibleToolResult(LlmWireBlock(LlmWireBlockKind.ToolResult, arguments: YJson.parse("{\"content\":\"nested\"}"))), "nested")
        @Expect(wireVisibleToolResult(LlmWireBlock(LlmWireBlockKind.ToolResult, arguments: YJson.parse("{\"value\":1}"))).contains("\"value\":1"), true)
    }

    @TestCase
    func projectsAllProviderEventFrameFamilies() {
        @Expect(decodeLlmWireEventFrame(LlmWireProtocol.Messages, "").size, 0)
        @Expect(decodeLlmWireEventFrame(LlmWireProtocol.Responses, "[DONE]").size, 0)

        let messageFrames = [
            "{\"type\":\"message_start\"}",
            "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"c1\",\"name\":\"lookup\"}}",
            "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"a\"}}",
            "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"b\"}}",
            "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}",
            "{\"type\":\"content_block_stop\",\"index\":1}",
            "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}",
            "{\"type\":\"message_stop\"}",
            "{\"type\":\"error\",\"error\":{\"message\":\"bad\"}}",
            "{\"type\":\"unknown\"}"
        ]
        var projected = 0
        for (frame in messageFrames) { projected += decodeLlmWireEventFrame(LlmWireProtocol.Messages, frame).size }
        @Expect(projected >= 10, true)

        let responseFrames = [
            "{\"type\":\"response.created\"}",
            "{\"type\":\"response.output_text.delta\",\"delta\":\"a\"}",
            "{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"b\"}",
            "{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"i\",\"delta\":\"{}\"}",
            "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\"}}",
            "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"call_id\":\"c\"}}",
            "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}}",
            "{\"type\":\"error\",\"message\":\"bad\"}"
        ]
        projected = 0
        for (frame in responseFrames) { projected += decodeLlmWireEventFrame(LlmWireProtocol.Responses, frame).size }
        @Expect(projected >= 10, true)

        let chat = decodeLlmWireEventFrame(
            LlmWireProtocol.ChatCompletions,
            "{\"choices\":[{\"finish_reason\":\"stop\",\"delta\":{\"content\":\"a\",\"reasoning_content\":\"b\",\"tool_calls\":[{\"id\":\"c\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]}}]}"
        )
        @Expect(chat.size, 5)
        @Expect(decodeLlmWireEventFrame(LlmWireProtocol.ChatCompletions, "{}").size, 0)
        @Expect(decodeLlmWireEventFrame(LlmWireProtocol.ChatCompletions, "{\"choices\":[]}").size, 0)
    }

    @TestCase
    func decodesRichRepliesAndRejectsInvalidShapes() {
        let messages = decodeLlmWireReply(
            LlmWireProtocol.Messages,
            "{\"id\":\"m\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"},{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"sig\"},{\"type\":\"tool_use\",\"id\":\"c\",\"name\":\"f\"},{\"type\":\"future\"}],\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1,\"cache_read_input_tokens\":3,\"cache_creation_input_tokens\":4}}"
        )
        @Expect(messages.blocks.size, 3)
        @Expect(messages.usage.inputTokens, 9)
        @Expect(messages.usage.cacheReadTokens, 3)

        let responses = decodeLlmWireReply(
            LlmWireProtocol.Responses,
            "{\"id\":\"r\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"},{\"type\":\"refusal\",\"refusal\":\"no\"},{\"type\":\"future\"}]},{\"type\":\"function_call\",\"id\":\"i\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{\\\"q\\\":1}\"},{\"type\":\"function_call\",\"call_id\":\"d\",\"name\":\"g\",\"arguments\":{\"x\":2}},{\"type\":\"reasoning\",\"id\":\"reason\"},{\"type\":\"future\"}],\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":2,\"cache_write_tokens\":1},\"output_tokens_details\":{\"reasoning_tokens\":2}}}"
        )
        @Expect(responses.blocks.size, 5)
        @Expect(responses.usage.reasoningTokens, 2)
        @Expect(responses.usage.cacheReadTokens, 2)

        let chat = decodeLlmWireReply(
            LlmWireProtocol.ChatCompletions,
            "{\"id\":\"c\",\"choices\":[{\"message\":{\"content\":\"ok\",\"reasoning_content\":\"why\",\"tool_calls\":[{\"id\":\"t\",\"function\":{\"name\":\"f\",\"arguments\":\"{\\\"x\\\":1}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2,\"prompt_tokens_details\":{\"cached_tokens\":1,\"cache_write_tokens\":2},\"completion_tokens_details\":{\"reasoning_tokens\":1}}}"
        )
        @Expect(chat.blocks.size, 3)
        @Expect(chat.usage.cacheWriteTokens, 2)

        let limited = decodeChatCompletionsWireReply(
            "{\"choices\":[{\"message\":{\"content\":\"\",\"tool_calls\":[{\"id\":\"ignored\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"length\"}]}"
        )
        @Expect(limited.blocks.size, 0)
        try {
            let _ = decodeChatCompletionsWireReply("{\"choices\":[]}")
            @Fail("empty choices must fail")
        } catch (error: LlmTransportError) { @Expect(error.code, "llm.chat_choices_empty") }
        try {
            let _ = decodeMessagesWireReply("{\"content\":{}}")
            @Fail("wrong content shape must fail")
        } catch (error: LlmTransportError) { @Expect(error.code, "llm.array_expected") }
        try {
            let _ = decodeResponsesWireReply("{\"output\":[] ,\"error\":\"bad\"}", provider: "p")
            @Fail("scalar provider error must fail")
        } catch (error: LlmTransportError) {
            @Expect(error.code, "llm.provider_error")
            @Expect(error.provider, "p")
        }
    }

    @TestCase
    func reconstructsChatAndMessagesStreamVariants() {
        let chatSource =
            "data: {\"id\":\"c\",\"model\":\"m\",\"choices\":[],\"usage\":null}\n\n" +
            "data: {\"id\":\"c\",\"model\":\"m\",\"choices\":[{\"delta\":{\"content\":\"hi\",\"reasoning_content\":\"why\",\"tool_calls\":[{\"index\":0,\"id\":\"call\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"q\\\":\"}}]}}]}\n\n" +
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"1}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3,\"prompt_tokens_details\":{\"cached_tokens\":1,\"cache_write_tokens\":2},\"completion_tokens_details\":{\"reasoning_tokens\":1}}}\n\n" +
            "data: [DONE]\n\n"
        let chat = decodeLlmWireEventStream(LlmWireProtocol.ChatCompletions, chatSource)
        let chatReply = decodeChatCompletionsWireReply(chat.terminalSource)
        @Expect(chatReply.blocks.size, 3)
        @Expect(chatReply.usage.outputTokens, 3)
        @Expect(chat.events.size >= 7, true)

        let messagesSource =
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"usage\":{\"input_tokens\":2,\"cache_read_input_tokens\":1,\"cache_creation_input_tokens\":1}}}\n\n" +
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"a\"}}\n\n" +
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"b\"}}\n\n" +
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig\"}}\n\n" +
            "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" +
            "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"c\",\"name\":\"f\",\"input\":{\"old\":1}}}\n\n" +
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"new\\\":\"}}\n\n" +
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"2}\"}}\n\n" +
            "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" +
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":3}}\n\n" +
            "data: {\"type\":\"message_stop\"}\n\n"
        let messages = decodeLlmWireEventStream(LlmWireProtocol.Messages, messagesSource)
        let messagesReply = decodeMessagesWireReply(messages.terminalSource)
        @Expect(messagesReply.blocks.size, 2)
        @Expect(messagesReply.blocks[0].text, "ab")
        @Expect(messagesReply.blocks[1].arguments["new"].int64, 2)
        @Expect(messagesReply.usage.inputTokens, 4)

        try {
            let _ = decodeLlmWireEventStream(
                LlmWireProtocol.Messages,
                "data: {\"type\":\"content_block_stop\",\"index\":9}\n\n"
            )
            @Fail("stop without start must fail")
        } catch (error: LlmTransportError) { @Expect(error.code, "llm.messages_block_stop_without_start") }
        try {
            let _ = decodeLlmWireEventStream(
                LlmWireProtocol.ChatCompletions,
                "data: {\"choices\":[{\"delta\":{}}]}\n\n"
            )
            @Fail("chat stream without terminal must fail")
        } catch (error: LlmTransportError) { @Expect(error.code, "llm.chat_terminal_missing") }
        try {
            let _ = decodeLlmWireEventStream(
                LlmWireProtocol.ChatCompletions,
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
            )
            @Fail("chat stream without accepted output must fail")
        } catch (error: LlmTransportError) { @Expect(error.code, "llm.chat_output_missing") }
        let limited = decodeLlmWireEventStream(
            LlmWireProtocol.ChatCompletions,
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n"
        )
        @Expect(decodeChatCompletionsWireReply(limited.terminalSource).stopReason, "length")
    }
}
