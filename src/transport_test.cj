package llm4cj

import std.io.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

func allCapabilities(): LlmWireCapabilities {
    LlmWireCapabilities(
        input: LlmWireInputCapabilities(modalities: [LlmWireInputModality.Text, LlmWireInputModality.Image]),
        thinking: LlmWireThinkingCapabilities(
            modes: [LlmWireThinkingMode.Disabled, LlmWireThinkingMode.Enabled, LlmWireThinkingMode.Budget(1024), LlmWireThinkingMode.Adaptive],
            efforts: [LlmWireReasoningEffort.Minimal, LlmWireReasoningEffort.Low, LlmWireReasoningEffort.Medium, LlmWireReasoningEffort.High, LlmWireReasoningEffort.XHigh, LlmWireReasoningEffort.Max]
        ),
        tools: LlmWireToolCapabilities(enabled: true, parallelCalls: true),
        output: LlmWireOutputCapabilities(
            structuredModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.JsonObject, LlmWireStructuredOutputMode.JsonSchema],
            serviceTiers: [LlmWireServiceTier.Auto, LlmWireServiceTier.Default, LlmWireServiceTier.StandardOnly, LlmWireServiceTier.Flex, LlmWireServiceTier.Priority, LlmWireServiceTier.Fast, LlmWireServiceTier.Ultrafast],
            generationSpeeds: [LlmWireGenerationSpeed.Standard, LlmWireGenerationSpeed.Fast]
        ),
        cache: LlmWireCacheCapabilities(lifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.FiveMinutes, LlmWirePromptCacheLifetime.ThirtyMinutes, LlmWirePromptCacheLifetime.OneHour, LlmWirePromptCacheLifetime.TwentyFourHours])
    )
}

func toolResultText(callId: String, text: String, isError!: Bool = false): LlmWireToolResultBlock {
    LlmWireToolResultBlock(callId, [LlmWireToolResultContent.Text(LlmWireTextBlock(text))], isError: isError)
}

func headerValue(headers: Array<LlmWireHeader>, name: String): String {
    for (header in headers where header.name == name) { return header.value }
    ""
}

func expectLlmError(code: String, body: () -> Unit): Unit {
    try {
        body()
        @Fail("expected LlmWireError: " + code)
    } catch (error: LlmWireError) { @Expect(error.code, code) }
}

func expectIllegalArgument(body: () -> Unit): Unit {
    try {
        body()
        @Fail("expected IllegalArgumentException")
    } catch (_: IllegalArgumentException) { () }
}

func event(data: String): SseEvent { SseEvent("message", data, "", None) }

func validMessages(): Array<LlmWireMessage> {
    [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello"))])]
}
func testJson(source: String): LlmWireJson { LlmWireJson.fromJsonNode(parseWireJson(source)) }
func beginMessages(decoder: LlmWireStreamDecoder): Unit { let _ = decoder.push(event("{\"type\":\"message_start\",\"message\":{}}")) }

func succeededReply(state: LlmWireResponseState): LlmWireReply {
    match (state) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(value)) => value; case _ => @Fail("expected succeeded reply") }
}

func succeededReply(update: LlmWireStreamUpdate): LlmWireReply {
    match (update.terminal) { case Some(LlmWireTerminal.Completed(value)) => value; case _ => @Fail("expected succeeded stream reply") }
}

func expectIncomplete(reply: LlmWireReply, expected: LlmWireIncompleteReason): Unit {
    @Expect(reply.choices.size > 0, true)
    match (reply.choices[0].outcome) {
        case LlmWireChoiceOutcome.Incomplete(actual) => @Expect(actual, expected)
        case _ => @Fail("expected incomplete choice")
    }
}

func eventText(value: LlmWireEvent): String {
    match (value) {
        case LlmWireEvent.TextDelta(text, _) => text
        case LlmWireEvent.ReasoningDelta(text, _) => text
        case LlmWireEvent.RefusalDelta(text, _) => text
        case LlmWireEvent.ToolArgumentsDelta(text, _) => text
        case _ => @Fail("expected text-bearing event")
    }
}

func eventLocation(value: LlmWireEvent): LlmWireEventIdentity {
    match (value) {
        case LlmWireEvent.ContentBlockStarted(_, location) => location
        case LlmWireEvent.TextDelta(_, location) => location
        case LlmWireEvent.ReasoningDelta(_, location) => location
        case LlmWireEvent.RefusalDelta(_, location) => location
        case LlmWireEvent.ContentBlockCompleted(_, location) => location
        case LlmWireEvent.ToolCallStarted(identity) => identity.location
        case LlmWireEvent.ToolArgumentsDelta(_, identity) => identity.location
        case _ => @Fail("expected located event")
    }
}

func eventToolIdentity(value: LlmWireEvent): LlmWireToolIdentity {
    match (value) {
        case LlmWireEvent.ToolCallStarted(identity) => identity
        case LlmWireEvent.ToolArgumentsDelta(_, identity) => identity
        case _ => @Fail("expected tool event")
    }
}

func expectTextReplyEquivalent(left: LlmWireReply, right: LlmWireReply): Unit {
    @Expect(left.responseId, right.responseId); @Expect(left.model, right.model); @Expect(left.rawStopReason, right.rawStopReason)
    @Expect(left.usage.inputTokens, right.usage.inputTokens); @Expect(left.usage.outputTokens, right.usage.outputTokens)
    @Expect(left.blocks.size, right.blocks.size)
    for (index in 0..left.blocks.size) {
        match ((left.blocks[index], right.blocks[index])) {
            case (LlmWireOutputBlock.Text(a), LlmWireOutputBlock.Text(b)) => @Expect(a.text, b.text)
            case _ => @Fail("canonical block mismatch")
        }
    }
}

class SatisfiedRequirementResolver <: LlmWireRequirementResolver {
    public func resolve(requirement: LlmWireFeatureRequirement): LlmWireRequirementState { let _ = requirement; LlmWireRequirementState.Satisfied }
}

class UnknownRequirementResolver <: LlmWireRequirementResolver {
    public func resolve(requirement: LlmWireFeatureRequirement): LlmWireRequirementState { requirement.state }
}

class MutableTestDialect <: LlmWireDialect {
    private var value: LlmWireDialectContract
    init(contract: LlmWireDialectContract) { this.value = contract }
    public prop contract: LlmWireDialectContract { get() { value } }
    public prop compatibilityId: String { get() { value.compatibilityId } }
    public prop protocol: LlmWireProtocol { get() { value.protocol } }
    func replace(contract: LlmWireDialectContract): Unit { value = contract }
}

// Test-only dialect keeps core contract validation covered without exposing custom
// dialect construction from the stable package.
class TestStandardDialect <: LlmWireDialect {
    private let value: LlmWireDialectContract
    init(contract: LlmWireDialectContract) {
        if (isBuiltinCompatibilityId(contract.compatibilityId)) {
            throw IllegalArgumentException("built-in dialect identity is reserved")
        }
        if (!customDialectThinkingIsReplaySafe(contract)) {
            throw IllegalArgumentException("custom dialect thinking is not replay-safe")
        }
        this.value = contract
    }
    public prop contract: LlmWireDialectContract { get() { value } }
    public prop compatibilityId: String { get() { value.compatibilityId } }
    public prop protocol: LlmWireProtocol { get() { value.protocol } }
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
        let payload = responses.encodeRequest(LlmWireRequest("m", validMessages(), reasoningEffort: LlmWireReasoningEffort.High))
        @Expect(payload.contains("\"reasoning\":{\"effort\":\"high\"}"), true)

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: capabilities)
        let adaptive = messages.encodeRequest(LlmWireRequest("m", validMessages(), thinkingMode: LlmWireThinkingMode.Adaptive, reasoningEffort: LlmWireReasoningEffort.High, maxOutputTokens: Some(4096)))
        @Expect(adaptive.contains("\"thinking\":{\"type\":\"adaptive\"}"), true)
        @Expect(adaptive.contains("\"output_config\":{\"effort\":\"high\"}"), true)

        let deepSeek = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: capabilities)
        @Expect(deepSeek.encodeRequest(LlmWireRequest("m", validMessages(), thinkingMode: LlmWireThinkingMode.Enabled)).contains("\"type\":\"enabled\""), true)
        let deepSeekEffort = deepSeek.encodeRequest(LlmWireRequest("m", validMessages(), thinkingMode: LlmWireThinkingMode.Enabled, reasoningEffort: LlmWireReasoningEffort.Low))
        @Expect(deepSeekEffort.contains("\"thinking\":{\"type\":\"enabled\"}"), true)
        @Expect(deepSeekEffort.contains("\"reasoning_effort\":\"low\""), true)
        let deepSeekResponses = LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect(), capabilities: capabilities)
        @Expect(deepSeekResponses.encodeRequest(LlmWireRequest("m", validMessages(), thinkingMode: LlmWireThinkingMode.Disabled)).contains("\"reasoning\":{\"effort\":\"none\"}"), true)
        @Expect(deepSeekResponses.encodeRequest(LlmWireRequest("m", validMessages(), thinkingMode: LlmWireThinkingMode.Enabled)).contains("\"reasoning\":{\"effort\":\"high\"}"), true)
        let unknown = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        expectLlmError("llm.reasoning_effort_unsupported", { => let _ = unknown.encodeRequest(LlmWireRequest("m", validMessages(), reasoningEffort: LlmWireReasoningEffort.Low)) })
        expectLlmError("llm.thinking_unsupported", { => let _ = responses.encodeRequest(LlmWireRequest("m", validMessages(), thinkingMode: LlmWireThinkingMode.Adaptive)) })
    }

    @TestCase
    func t003NativeReplayRoundTripsOnlyWithinDialectAndUnknownContentFailsClosed() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        let state = codec.decodeResponse("{\"id\":\"m\",\"model\":\"claude\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"sig\"},{\"type\":\"redacted_thinking\",\"data\":\"opaque\"}],\"stop_reason\":\"end_turn\"}")
        let reply = match (state) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(value)) => value; case _ => @Fail("expected success") }
        let blocks = reply.blocks
        @Expect(blocks.size, 2)
        match (blocks[0]) { case LlmWireOutputBlock.NativeReplay(value) => @Expect(value.payload()["signature"].string, "sig"); @Expect(value.displayReasoning, Some("why")); case _ => @Fail("thinking must be native replay") }
        match (blocks[1]) { case LlmWireOutputBlock.NativeReplay(value) => @Expect(value.payload()["data"].string, "opaque"); case _ => @Fail("redacted thinking must be native replay") }
        let continuation = reply.toContinuationInput()
        let replay = codec.encodeRequest(LlmWireRequest("claude", continuation, maxOutputTokens: Some(1024)))
        @Expect(replay.contains("\"signature\":\"sig\""), true)
        @Expect(replay.contains("\"data\":\"opaque\""), true)
        let foreignCodec = LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect())
        expectLlmError("llm.native_replay_dialect_mismatch", { => let _ = foreignCodec.encodeRequest(LlmWireRequest("m", continuation, maxOutputTokens: Some(1024))) })
        expectLlmError("llm.messages_block_unsupported", { =>
            let _ = codec.decodeResponse("{\"content\":[{\"type\":\"future_block\",\"x\":1}],\"stop_reason\":\"end_turn\"}")
        })
    }

    @TestCase
    func t004FixedResponsesMapTerminalStates() {
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        match (responses.decodeResponse("{\"status\":\"queued\"}")) { case LlmWireResponseState.Pending(LlmWirePendingReply.Queued(_)) => (); case _ => @Fail("queued must remain pending") }
        match (responses.decodeResponse("{\"status\":\"completed\",\"output\":[]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(_)) => (); case _ => @Fail("completed must succeed") }
        match (responses.decodeResponse("{\"status\":\"incomplete\",\"output\":[],\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => expectIncomplete(reply, LlmWireIncompleteReason.MaxTokens); case _ => @Fail("incomplete must be a choice outcome") }
        match (responses.decodeResponse("{\"status\":\"cancelled\"}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Cancelled(failure)) => match (failure.kind) { case LlmWireFailureKind.Cancelled => (); case _ => @Fail("wrong failure kind") }; case _ => @Fail("cancelled must remain distinct") }

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        match (chat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{\"content\":\"cut\"},\"finish_reason\":\"length\"}]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => @Expect(reply.blocks.size, 1); expectIncomplete(reply, LlmWireIncompleteReason.Length); case _ => @Fail("length must be a choice outcome") }
    }

    @TestCase
    func t005KnownFieldErrorsDoNotBecomeDefaults() {
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), provider: "p")
        match (responses.decodeResponse("{\"status\":\"completed\",\"error\":null,\"output\":[]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(_)) => (); case _ => @Fail("null error must not fail") }
        expectLlmError("llm.field_missing", { => let _ = responses.decodeResponse("{\"status\":\"completed\"}") })
        expectLlmError("llm.field_type_invalid", { => let _ = responses.decodeResponse("{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":\"many\"}}") })
        expectLlmError("llm.integer_invalid", { => let _ = responses.decodeResponse("{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":999999999999999999999}}") })
    }

    @TestCase
    func t006SuccessfulToolArgumentsMustBeExecutable() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        let objectState = codec.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{\"tool_calls\":[{\"id\":\"a\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{\\\"x\\\":1}\"}}]},\"finish_reason\":\"tool_calls\"}]}")
        match (objectState) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => match (reply.blocks[0]) { case LlmWireOutputBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.Complete(value) => @Expect(value.stringify(), "{\"x\":1}"); case _ => @Fail("expected complete") }; case _ => @Fail("expected tool") }; case _ => @Fail("expected success") }
        expectLlmError("llm.tool_arguments_not_executable", { => let _ = codec.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{\"tool_calls\":[{\"id\":\"b\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"[]\"}}]},\"finish_reason\":\"tool_calls\"}]}" ) })
        expectLlmError("llm.tool_arguments_not_executable", { => let _ = codec.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{\"tool_calls\":[{\"id\":\"c\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{\"}}]},\"finish_reason\":\"tool_calls\"}]}" ) })
    }

    @TestCase
    func t007StrictRejectsInvalidToolHistory() {
        let blocks = [LlmWireBlock.ToolResult(toolResultText("future", "result")), LlmWireBlock.Text(LlmWireTextBlock("after"))]
        let strict = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: allCapabilities())
        expectLlmError("llm.tool_result_unmatched", { => let _ = strict.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, blocks)], maxOutputTokens: Some(1024))) })
    }

    @TestCase
    func t008ChatStreamKeepsParallelToolIdentity() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        let decoder = codec.newStreamDecoder()
        let first = decoder.push(event("{\"id\":\"r\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c0\",\"type\":\"function\",\"function\":{\"name\":\"a\",\"arguments\":\"{\\\"x\\\":\"}},{\"index\":1,\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"b\",\"arguments\":\"{\\\"y\\\":\"}}]}}]}"))
        @Expect(first.events.size, 5)
        match (first.events[0]) { case LlmWireEvent.StreamStarted("r", _) => (); case _ => @Fail("stream start") }
        match (first.events[1]) { case LlmWireEvent.ToolCallStarted(identity) => @Expect(identity.location.toolCallIndex, Some(0)); case _ => @Fail("first tool start") }
        match (first.events[3]) { case LlmWireEvent.ToolCallStarted(identity) => @Expect(identity.location.toolCallIndex, Some(1)); case _ => @Fail("second tool start") }
        let second = decoder.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"arguments\":\"2}\"}},{\"index\":0,\"function\":{\"arguments\":\"1}\"}}]}}]}"))
        @Expect(eventLocation(second.events[0]).toolCallIndex, Some(1))
        @Expect(eventLocation(second.events[1]).toolCallIndex, Some(0))
        let done = decoder.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}"))
        @Expect(done.terminal.isNone(), true)
        let usage = decoder.push(event("{\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":5}}"))
        @Expect(usage.terminal.isNone(), true)
        match (decoder.push(event("[DONE]")).terminal) { case Some(LlmWireTerminal.Completed(reply)) => @Expect(reply.blocks.size, 2); @Expect(reply.usage.outputTokens, Some(5)); case _ => @Fail("expected stream success") }
        match (decoder.finishTransport()) { case LlmWireTerminal.Completed(reply) => @Expect(reply.blocks.size, 2); case _ => @Fail("expected success") }
    }

    @TestCase
    func t009ResponsesStreamSeparatesItemAndCallIds() {
        let decoder = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        let _ = decoder.push(event("{\"type\":\"response.created\",\"response\":{}}"))
        let update = decoder.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"item-1\",\"call_id\":\"call-9\",\"name\":\"lookup\"}}"))
        @Expect(eventToolIdentity(update.events[0]).location.itemId, "item-1")
        @Expect(eventToolIdentity(update.events[0]).callId, "call-9")
        let delta = decoder.push(event("{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"item-1\",\"delta\":\"{}\"}"))
        @Expect(eventToolIdentity(delta.events[0]).location.itemId, "item-1")
        @Expect(eventToolIdentity(delta.events[0]).callId, "call-9")
    }

    @TestCase
    func t010MessagesStreamPreservesNativeReplayAndPartialBlocks() {
        let decoder = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        let _ = decoder.push(event("{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"claude\"}}"))
        let _ = decoder.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"why\"}}"))
        let _ = decoder.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig\"}}"))
        let _ = decoder.push(event("{\"type\":\"content_block_stop\",\"index\":0}"))
        let _ = decoder.push(event("{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"c\",\"name\":\"f\",\"input\":{}}}"))
        let _ = decoder.push(event("{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"x\\\":\"}}"))
        let _ = decoder.push(event("{\"type\":\"content_block_stop\",\"index\":1}"))
        let _ = decoder.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":4}}"))
        let terminal = decoder.push(event("{\"type\":\"message_stop\"}"))
        match (terminal.terminal) {
            case Some(LlmWireTerminal.Completed(reply)) =>
                expectIncomplete(reply, LlmWireIncompleteReason.MaxTokens)
                match (reply.blocks[0]) { case LlmWireOutputBlock.NativeReplay(value) => @Expect(value.snapshot().contains("sig"), true); case _ => @Fail("expected native replay") }
                match (reply.blocks[1]) { case LlmWireOutputBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.InvalidJson(raw) => @Expect(raw, "{\"x\":"); case _ => @Fail("expected diagnostic arguments") }; case _ => @Fail("expected tool") }
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
            case LlmWireResult.Ok(events) =>
                @Expect(events.size, 2)
                @Expect(events[0].event, "message")
                @Expect(events[0].data, "你")
                @Expect(events[0].id, "a")
                @Expect(events[0].retryMillis, Some(0))
                @Expect(events[1].data, "\nx")
                @Expect(events[1].id, "a")
            case LlmWireResult.Err(error) => @Fail(error.message)
        }
        let tail = SseDecoder()
        match (tail.push("data: discarded")) { case LlmWireResult.Ok(values) => @Expect(values.size, 0); case LlmWireResult.Err(error) => @Fail(error.message) }
        match (tail.finish()) { case LlmWireResult.Ok(values) => @Expect(values.size, 0); case LlmWireResult.Err(error) => @Fail(error.message) }

        let trailingCarriageReturn = SseDecoder(maxOutputBytesPerPush: 8)
        match (trailingCarriageReturn.push("data:a\n\ndata:b\r\r")) { case LlmWireResult.Ok(values) => @Expect(values.size, 1); case LlmWireResult.Err(error) => @Fail(error.message) }
        match (trailingCarriageReturn.finish()) {
            case LlmWireResult.Ok(values) => @Expect(values.size, 1); @Expect(values[0].data, "b")
            case LlmWireResult.Err(error) => @Fail(error.message)
        }
    }

    @TestCase
    func t013SseLimitsWholeEventBlock() {
        let decoder = SseDecoder(maxEventBytes: 8)
        match (decoder.push(": 123456789\n\n")) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_event_too_large"); case _ => @Fail("large comment must count") }
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
            case LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(failure)) =>
                @Expect(failure.provider, "openai"); @Expect(failure.providerErrorType, "server_error"); @Expect(failure.providerErrorCode, "busy"); @Expect(failure.message, "try later")
            case _ => @Fail("provider error must be a failure outcome")
        }
        let stream = codec.newStreamDecoder()
        let update = stream.push(event("{\"type\":\"error\",\"error\":{\"type\":\"rate_limit\",\"message\":\"slow\"}}"))
        match (update.events[0]) { case LlmWireEvent.ProviderFailure(failure) => @Expect(failure.message, "slow"); case _ => @Fail("provider failure event") }
        match (update.terminal) { case Some(LlmWireTerminal.ProviderFailed(failure)) => @Expect(failure.providerErrorType, "rate_limit"); case _ => @Fail("stream error must fail") }
    }

    @TestCase
    func t016HttpBodyRemainsBounded() {
        let body = ByteBuffer(); body.write("hello".toArray())
        match (readLlmHttpBody(body, Some(5), 5)) { case LlmWireResult.Ok(value) => @Expect(String.fromUtf8(value), "hello"); case LlmWireResult.Err(error) => @Fail(error.message) }
        let large = ByteBuffer(); large.write("hello".toArray())
        match (readLlmHttpBody(large, Some(5), 4)) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.body_too_large"); case _ => @Fail("body must be bounded") }
    }

    @TestCase
    func t017AllRequestShapesAreExplicitlyEncoded() {
        let schema = testJson("{\"type\":\"object\"}")
        let tool = LlmWireTool("lookup", "find a value", schema)
        let format = LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("answer", schema, description: "answer schema", strict: false))
        let call = LlmWireBlock.ToolCall(LlmWireToolCallBlock("call-1", "lookup", LlmWireToolArguments.Complete(testJson("{\"q\":1}"))))
        let result = LlmWireBlock.ToolResult(toolResultText("call-1", "done", isError: true))
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
            "m", common, instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "system")], tools: [tool],
            reasoningEffort: LlmWireReasoningEffort.Max, maxOutputTokens: Some(99),
            parallelToolCalls: Some(false), serviceTier: LlmWireServiceTier.Priority,
            promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ThirtyMinutes), promptCacheRoutingKey: Some("key"),
            toolChoice: LlmWireToolChoice.Auto, structuredOutput: format
        ), streaming: true)
        for (needle in ["system", "max_output_tokens", "prompt_cache_key", "function_call_output", "data:image/png;base64", "json_schema"]) { @Expect(responsePayload.contains(needle), true) }

        let chatMessages = [LlmWireMessage(LlmWireRole.Assistant, [call]), LlmWireMessage(LlmWireRole.User, [result])]
        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: allCapabilities())
        let chatPayload = chat.encodeRequest(LlmWireRequest("m", chatMessages, instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "system")], tools: [tool], thinkingMode: LlmWireThinkingMode.Disabled, maxOutputTokens: Some(9), parallelToolCalls: Some(true), serviceTier: LlmWireServiceTier.Default, toolChoice: LlmWireToolChoice.Required, structuredOutput: format))
        for (needle in ["system", "tool_call_id", "tool_calls", "response_format", "reasoning_effort", "required"]) { @Expect(chatPayload.contains(needle), true) }

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: allCapabilities())
        let messagePayload = messages.encodeRequest(LlmWireRequest("m", common, instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "system")], tools: [tool], thinkingMode: LlmWireThinkingMode.Adaptive, reasoningEffort: LlmWireReasoningEffort.XHigh, maxOutputTokens: Some(4096), generationSpeed: LlmWireGenerationSpeed.Fast, toolChoice: LlmWireToolChoice.NoTools, structuredOutput: LlmWireStructuredOutput.JsonSchemaDocument(schema)), streaming: true)
        for (needle in ["output_config", "xhigh", "tool_use", "tool_result", "base64", "is_error", "input_schema"]) { @Expect(messagePayload.contains(needle), true) }

        expectLlmError("llm.tool_choice_without_tools", { => let _ = messages.encodeRequest(LlmWireRequest("m", validMessages(), maxOutputTokens: Some(1024), toolChoice: LlmWireToolChoice.Auto)) })
        expectLlmError("llm.tool_choice_without_tools", { => let _ = messages.encodeRequest(LlmWireRequest("m", validMessages(), maxOutputTokens: Some(1024), toolChoice: LlmWireToolChoice.Required)) })
    }

    @TestCase
    func t018FixedDecodersCoverBlocksUsageAndTerminalVariants() {
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), provider: "openai")
        let response = responses.decodeResponse("{\"id\":\"r\",\"model\":\"m\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"},{\"type\":\"refusal\",\"refusal\":\"no\"}]},{\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{}\"},{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"why\"}]}],\"usage\":{\"input_tokens\":5,\"output_tokens\":6,\"input_tokens_details\":{\"cached_tokens\":2,\"cache_write_tokens\":1},\"output_tokens_details\":{\"reasoning_tokens\":3}}}")
        match (response) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => @Expect(reply.blocks.size, 4); @Expect(reply.usage.reasoningTokens, Some(3)); case _ => @Fail("expected response success") }
        expectLlmError("llm.responses_block_unsupported", { => let _ = responses.decodeResponse("{\"status\":\"completed\",\"output\":[{\"type\":\"future_item\",\"x\":2}]}" ) })
        match (responses.decodeResponse("{\"status\":\"in_progress\"}")) { case LlmWireResponseState.Pending(LlmWirePendingReply.InProgress(_)) => (); case _ => @Fail("expected progress") }
        match (responses.decodeResponse("{\"status\":\"failed\"}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(_)) => (); case _ => @Fail("expected failed") }
        expectLlmError("llm.responses_status_unsupported", { => let _ = responses.decodeResponse("{\"status\":\"future\"}") })

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect())
        let chatState = chat.decodeResponse("{\"id\":\"c\",\"model\":\"m\",\"choices\":[{\"index\":0,\"message\":{\"content\":\"ok\",\"reasoning_content\":\"why\",\"tool_calls\":[{\"id\":\"t\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"content_filter\"}],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":5,\"prompt_tokens_details\":{\"cached_tokens\":1},\"completion_tokens_details\":{\"reasoning_tokens\":2}}}")
        match (chatState) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => @Expect(reply.blocks.size, 3); @Expect(reply.usage.cacheReadTokens, Some(1)); expectIncomplete(reply, LlmWireIncompleteReason.ContentFilter); case _ => @Fail("expected filtered") }
        match (chat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{},\"finish_reason\":\"insufficient_system_resource\"}]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(_)) => (); case _ => @Fail("expected resource failure") }
        expectLlmError("llm.chat_choices_empty", { => let _ = chat.decodeResponse("{\"choices\":[]}") })
        expectLlmError("llm.chat_finish_reason_unsupported", { => let _ = chat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{},\"finish_reason\":\"future\"}]}") })
        expectLlmError("llm.chat_semantic_unsupported", { => let _ = chat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{\"function_call\":{\"name\":\"f\",\"arguments\":\"{}\"}},\"finish_reason\":\"function_call\"}]}" ) })

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        let messageState = messages.decodeResponse("{\"id\":\"x\",\"model\":\"m\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"},{\"type\":\"tool_use\",\"id\":\"c\",\"name\":\"f\",\"input\":[]}],\"stop_reason\":\"model_context_window_exceeded\",\"usage\":{\"input_tokens\":4,\"output_tokens\":5,\"cache_read_input_tokens\":2,\"cache_creation_input_tokens\":1}}")
        match (messageState) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => @Expect(reply.blocks.size, 2); @Expect(reply.usage.cacheWriteTokens, Some(1)); expectIncomplete(reply, LlmWireIncompleteReason.ModelContextWindowExceeded); case _ => @Fail("expected context incomplete") }
        expectLlmError("llm.messages_block_unsupported", { => let _ = messages.decodeResponse("{\"content\":[{\"type\":\"future\",\"x\":1}],\"stop_reason\":\"end_turn\"}" ) })
        match (messages.decodeResponse("{\"content\":[],\"stop_reason\":\"pause_turn\"}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => expectIncomplete(reply, LlmWireIncompleteReason.PauseTurn); case _ => @Fail("expected pause") }
        match (messages.decodeResponse("{\"type\":\"error\",\"error\":{\"message\":\"bad\"}}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(_)) => (); case _ => @Fail("expected message error") }
        expectLlmError("llm.messages_stop_reason_unsupported", { => let _ = messages.decodeResponse("{\"content\":[],\"stop_reason\":\"future\"}") })
    }

    @TestCase
    func t019ValidationRejectsEveryUnsupportedRequestClass() {
        let base = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        expectLlmError("llm.model_missing", { => let _ = base.encodeRequest(LlmWireRequest("", [])) })
        expectLlmError("llm.max_output_tokens_invalid", { => let _ = base.encodeRequest(LlmWireRequest("m", validMessages(), maxOutputTokens: Some(0))) })
        expectLlmError("llm.tools_unsupported", { => let _ = base.encodeRequest(LlmWireRequest("m", validMessages(), tools: [LlmWireTool("f", "", testJson("{}"))])) })
        expectLlmError("llm.structured_output_unsupported", { => let _ = base.encodeRequest(LlmWireRequest("m", validMessages(), structuredOutput: LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("x", testJson("{}"))))) })
        expectLlmError("llm.parallel_tools_without_tools", { => let _ = base.encodeRequest(LlmWireRequest("m", validMessages(), parallelToolCalls: Some(true))) })
        expectLlmError("llm.service_tier_unsupported", { => let _ = base.encodeRequest(LlmWireRequest("m", validMessages(), serviceTier: LlmWireServiceTier.Priority)) })
        expectLlmError("llm.cache_lifetime_unsupported", { => let _ = base.encodeRequest(LlmWireRequest("m", validMessages(), promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.TwentyFourHours))) })

        let capable = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: allCapabilities())
        let duplicate = [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Complete(testJson("{}")))), LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Complete(testJson("{}"))))])]
        expectLlmError("llm.tool_call_duplicate", { => let _ = capable.encodeRequest(LlmWireRequest("m", duplicate)) })
        let partial = [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Partial("{")))])]
        expectLlmError("llm.tool_arguments_partial", { => let _ = capable.encodeRequest(LlmWireRequest("m", partial)) })
        let opaque = LlmWireOpaqueBlock("future", parseWireJson("{\"type\":\"future\"}"), completion: LlmWireOpaqueCompletion.Partial)
        expectLlmError("llm.opaque_diagnostic_only", { => let _ = capable.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Opaque(opaque)])])) })
        expectLlmError("llm.object_expected", { => let _ = LlmWireNativeReplayBlock.restore("[]") })
        expectLlmError("llm.reasoning_display_only", { => let _ = capable.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Reasoning(LlmWireReasoningBlock("why"))])])) })
        expectLlmError("llm.refusal_display_only", { => let _ = capable.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Refusal(LlmWireRefusalBlock("no"))])])) })

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: allCapabilities())
        @Expect(chat.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "x"))])])).contains("image_url"), true)
        expectLlmError("llm.opaque_diagnostic_only", { => let _ = chat.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Opaque(LlmWireOpaqueBlock("x", parseWireJson("{\"type\":\"x\"}")))])])) })
    }

    @TestCase
    func t020StreamDecodersCoverDeltasErrorsAndTerminalKinds() {
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        match (responses.push(event("{\"type\":\"response.created\",\"response\":{\"id\":\"r\",\"model\":\"m\"}}" )).events[0]) { case LlmWireEvent.StreamStarted("r", "m") => (); case _ => @Fail("response stream start") }
        @Expect(responses.push(event("{\"type\":\"response.in_progress\",\"response\":{\"id\":\"r\",\"model\":\"m\"}}" )).events.size, 0)
        let _ = responses.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"message\"}}"))
        let _ = responses.push(event("{\"type\":\"response.content_part.added\",\"item_id\":\"i\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\"}}"))
        @Expect(eventText(responses.push(event("{\"type\":\"response.output_text.delta\",\"delta\":\"a\",\"output_index\":0,\"content_index\":0,\"item_id\":\"i\"}")).events[0]), "a")
        let _ = responses.push(event("{\"type\":\"response.output_text.done\",\"text\":\"a\",\"output_index\":0,\"content_index\":0,\"item_id\":\"i\"}"))
        let _ = responses.push(event("{\"type\":\"response.content_part.done\",\"item_id\":\"i\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"a\"}}"))
        let _ = responses.push(event("{\"type\":\"response.output_item.done\",\"output_index\":0,\"item_id\":\"i\",\"item\":{\"id\":\"i\",\"type\":\"message\"}}"))
        let _ = responses.push(event("{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"id\":\"r1\",\"type\":\"reasoning\"}}"))
        let _ = responses.push(event("{\"type\":\"response.reasoning_summary_part.added\",\"item_id\":\"r1\",\"output_index\":1,\"summary_index\":0,\"part\":{\"type\":\"summary_text\",\"text\":\"\"}}"))
        @Expect(eventText(responses.push(event("{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"b\",\"output_index\":1,\"summary_index\":0,\"item_id\":\"r1\"}")).events[0]), "b")
        expectLlmError("llm.responses_stream_event_unsupported", { => let _ = responses.push(event("{\"type\":\"future\"}")) })
        let incompleteResponses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        match (incompleteResponses.push(event("{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"output\":[]}}" )).terminal) { case Some(LlmWireTerminal.Completed(reply)) => expectIncomplete(reply, LlmWireIncompleteReason.Other("incomplete")); case _ => @Fail("expected incomplete choice") }

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect()).newStreamDecoder()
        let update = chat.push(event("{\"id\":\"c\",\"model\":\"m\",\"usage\":{\"prompt_tokens\":1},\"choices\":[{\"index\":0,\"delta\":{\"content\":\"a\",\"reasoning_content\":\"b\"}}]}"))
        @Expect(update.events.size, 4)
        let _ = chat.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"content_filter\"}]}"))
        match (chat.push(event("[DONE]")).terminal) { case Some(LlmWireTerminal.Completed(reply)) => expectIncomplete(reply, LlmWireIncompleteReason.ContentFilter); case _ => @Fail("expected filtered") }
        let chatError = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        match (chatError.push(event("{\"error\":{\"type\":\"busy\"}}" )).terminal) { case Some(LlmWireTerminal.ProviderFailed(_)) => (); case _ => @Fail("expected chat failure") }
        let chatResource = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        let _ = chatResource.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"insufficient_system_resource\"}]}"))
        match (chatResource.push(event("[DONE]")).terminal) { case Some(LlmWireTerminal.ProviderFailed(_)) => (); case _ => @Fail("expected resource failure") }

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        let _ = messages.push(event("{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"x\",\"usage\":{\"input_tokens\":1}}}"))
        let _ = messages.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"a\"}}"))
        @Expect(eventText(messages.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"b\"}}" )).events[0]), "b")
        let _ = messages.push(event("{\"type\":\"content_block_stop\",\"index\":0}"))
        let _ = messages.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}"))
        match (messages.push(event("{\"type\":\"message_stop\"}" )).terminal) { case Some(LlmWireTerminal.Completed(reply)) => @Expect(reply.blocks.size, 1); case _ => @Fail("expected messages success") }
        let messageError = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        match (messageError.push(event("{\"type\":\"error\",\"error\":{\"message\":\"bad\"}}" )).terminal) { case Some(LlmWireTerminal.ProviderFailed(_)) => (); case _ => @Fail("expected messages failure") }
    }

    @TestCase
    func t021TransportParsersCoverLimitsFieldsAndCalendarEdges() {
        @Expect(LlmWireResult<Int64>.Ok(1).isOk(), true)
        @Expect(LlmWireResult<Int64>.Err(LlmWireError(LlmWireErrorKind.Transport, "x", "x")).isOk(), false)
        @Expect(sseDataLine("data: value"), Some("value"))
        @Expect(sseDataLine("event: value"), None)
        let fields = SseDecoder(maxEventBytes: 100)
        match (fields.push("event: custom\nid: a\u{0000}b\nretry: invalid\nunknown\ndata: x\n\n")) { case LlmWireResult.Ok(values) => @Expect(values[0].event, "custom"); @Expect(values[0].id, ""); case _ => @Fail("expected event") }
        match (fields.finish()) { case LlmWireResult.Ok(_) => (); case _ => @Fail("expected finish") }
        match (fields.push("data: x\n\n")) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_closed"); case _ => @Fail("closed push must fail") }
        match (fields.finish()) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_closed"); case _ => @Fail("closed finish must fail") }
        @Expect(parseSseRetryMillis(""), None)
        @Expect(parseSseRetryMillis("12x"), None)
        @Expect(parseSseRetryMillis("999999999999999999999999"), Some(Int64.Max))
        @Expect(parseRetryAfterMillis("999999999999999999999999", 0), Some(Int64.Max))
        for (date in ["Thu, 29 Feb 2024 00:00:00 GMT", "Thu, 29 Feb 2023 00:00:00 GMT", "Thu, 01 Jan 1969 00:00:00 GMT", "Thu, 01 Xxx 2024 00:00:00 GMT", "Thu, 01 Jan 2024 24:00:00 GMT", "Thu, 01 Jan 2024 bad GMT"]) { let _ = parseRetryAfterMillis(date, 0) }
        for (month in ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]) { @Expect(parseRetryAfterMillis("Mon, 01 " + month + " 2024 00:00:00 GMT", 0).isSome(), true) }
        let empty = ByteBuffer()
        match (readLlmHttpBody(empty, None, 0)) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.body_limit_invalid"); case _ => @Fail("invalid limit") }
        match (readLlmHttpBody(empty, Some(-1), 10)) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.body_too_large"); case _ => @Fail("invalid declared size") }
    }

    @TestCase
    func t022DerivedIdentityEnumsCompareEveryVariant() {
        let protocols = [LlmWireProtocol.Responses, LlmWireProtocol.ChatCompletions, LlmWireProtocol.Messages]
        for (index in 0..protocols.size) { @Expect(protocols[index] == protocols[index], true); @Expect(protocols[index] != protocols[(index + 1) % protocols.size], true) }
        let roles = [LlmWireRole.User, LlmWireRole.Assistant]
        for (index in 0..roles.size) { @Expect(roles[index] == roles[index], true); @Expect(roles[index] != roles[(index + 1) % roles.size], true) }
        let modalities = [LlmWireInputModality.Text, LlmWireInputModality.Image]
        for (index in 0..modalities.size) { @Expect(modalities[index] == modalities[index], true); @Expect(modalities[index] != modalities[(index + 1) % modalities.size], true) }
        let sources = [LlmWireImageSourceKind.Url, LlmWireImageSourceKind.Base64, LlmWireImageSourceKind.File]
        for (index in 0..sources.size) { @Expect(sources[index] == sources[index], true); @Expect(sources[index] != sources[(index + 1) % sources.size], true) }
        let details = [LlmWireImageDetail.Auto, LlmWireImageDetail.Low, LlmWireImageDetail.High]
        for (index in 0..details.size) { @Expect(details[index] == details[index], true); @Expect(details[index] != details[(index + 1) % details.size], true) }
        let levels = [LlmWireReasoningEffort.Minimal, LlmWireReasoningEffort.Low, LlmWireReasoningEffort.Medium, LlmWireReasoningEffort.High, LlmWireReasoningEffort.XHigh, LlmWireReasoningEffort.Max]
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
        let usageStyles = [LlmWireUsageMergeStyle.ReplacePresent, LlmWireUsageMergeStyle.Monotonic, LlmWireUsageMergeStyle.Delta]
        for (index in 0..usageStyles.size) { @Expect(usageStyles[index] == usageStyles[index], true); @Expect(usageStyles[index] != usageStyles[(index + 1) % usageStyles.size], true) }
        let errorKinds = [
            LlmWireErrorKind.InvalidWire, LlmWireErrorKind.InvalidRequest, LlmWireErrorKind.Unsupported,
            LlmWireErrorKind.InvalidState, LlmWireErrorKind.Http, LlmWireErrorKind.BodyLimit,
            LlmWireErrorKind.LimitExceeded, LlmWireErrorKind.Sse, LlmWireErrorKind.Cancelled,
            LlmWireErrorKind.Deadline, LlmWireErrorKind.Transport
        ]
        for (index in 0..errorKinds.size) { @Expect(errorKinds[index] == errorKinds[index], true); @Expect(errorKinds[index] != errorKinds[(index + 1) % errorKinds.size], true) }
        let phases = [
            LlmTransportPhase.Encode, LlmTransportPhase.Request, LlmTransportPhase.ResponseHeaders,
            LlmTransportPhase.StreamFraming, LlmTransportPhase.WireDecode,
            LlmTransportPhase.SemanticAssembly, LlmTransportPhase.Transport
        ]
        for (index in 0..phases.size) { @Expect(phases[index] == phases[index], true); @Expect(phases[index] != phases[(index + 1) % phases.size], true) }
        let blockKinds = [LlmWireStreamBlockKind.Text, LlmWireStreamBlockKind.Reasoning, LlmWireStreamBlockKind.Refusal, LlmWireStreamBlockKind.ToolCall]
        for (index in 0..blockKinds.size) { @Expect(blockKinds[index] == blockKinds[index], true); @Expect(blockKinds[index] != blockKinds[(index + 1) % blockKinds.size], true) }
    }

    @TestCase
    func t023EverySupportedThinkingDialectBranchIsEncoded() {
        let capabilities = allCapabilities()
        let modes = [
            LlmWireThinkingMode.Disabled,
            LlmWireThinkingMode.Enabled
        ]
        let deepSeekCodecs = [
            LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect(), capabilities: capabilities),
            LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: capabilities),
            LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect(), capabilities: capabilities)
        ]
        for (index in 0..deepSeekCodecs.size) {
            for (mode in modes) {
                let payload = deepSeekCodecs[index].encodeRequest(LlmWireRequest("m", validMessages(), thinkingMode: mode, maxOutputTokens: Some(2048)))
                @Expect(payload.contains(if (index == 0) { "reasoning" } else { "thinking" }), true)
                if (index == 0) { @Expect(payload.contains("\"thinking\""), false) }
            }
        }
        for (index in 0..deepSeekCodecs.size) {
            let mode = if (index == 0) { LlmWireThinkingMode.ProviderDefault } else { LlmWireThinkingMode.Enabled }
            let payload = deepSeekCodecs[index].encodeRequest(LlmWireRequest("m", validMessages(), thinkingMode: mode, reasoningEffort: LlmWireReasoningEffort.Low, maxOutputTokens: Some(2048)))
            @Expect(payload.contains("low"), true)
        }
        @Expect(deepSeekCodecs[0].encodeRequest(LlmWireRequest("m", validMessages(), reasoningEffort: LlmWireReasoningEffort.Minimal, maxOutputTokens: Some(2048))).contains("minimal"), true)
        let openAiChat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: capabilities)
        @Expect(openAiChat.encodeRequest(LlmWireRequest("m", validMessages(), thinkingMode: LlmWireThinkingMode.Enabled)).contains("medium"), true)
        @Expect(openAiChat.encodeRequest(LlmWireRequest("m", validMessages(), reasoningEffort: LlmWireReasoningEffort.Low)).contains("low"), true)
        let anthropic = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: capabilities)
        for (mode in [LlmWireThinkingMode.Disabled, LlmWireThinkingMode.Budget(1024), LlmWireThinkingMode.Adaptive]) {
            @Expect(anthropic.encodeRequest(LlmWireRequest("m", validMessages(), thinkingMode: mode, maxOutputTokens: Some(2048))).contains("thinking"), true)
        }
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities)
        for (level in [LlmWireReasoningEffort.Minimal, LlmWireReasoningEffort.Low, LlmWireReasoningEffort.Medium, LlmWireReasoningEffort.High, LlmWireReasoningEffort.XHigh, LlmWireReasoningEffort.Max]) {
            @Expect(responses.encodeRequest(LlmWireRequest("m", validMessages(), reasoningEffort: level)).contains("reasoning"), true)
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
            (LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities), LlmWireThinkingMode.Disabled),
            (LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities), LlmWireThinkingMode.Enabled),
            (LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities), LlmWireThinkingMode.Budget(1)),
            (LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities), LlmWireThinkingMode.Adaptive),
            (LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: capabilities), LlmWireThinkingMode.Budget(1)),
            (LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: capabilities), LlmWireThinkingMode.Adaptive),
            (LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect(), capabilities: capabilities), LlmWireThinkingMode.Budget(1)),
            (LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect(), capabilities: capabilities), LlmWireThinkingMode.Adaptive),
            (LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: capabilities), LlmWireThinkingMode.Budget(1)),
            (LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: capabilities), LlmWireThinkingMode.Adaptive),
            (LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect(), capabilities: capabilities), LlmWireThinkingMode.Budget(1)),
            (LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect(), capabilities: capabilities), LlmWireThinkingMode.Adaptive)
        ]
        for ((codec, control) in pairs) {
            expectLlmError("llm.thinking_unsupported", { => let _ = codec.encodeRequest(LlmWireRequest("m", validMessages(), thinkingMode: control, maxOutputTokens: Some(2048))) })
        }
        let noLevels = LlmWireCapabilities()
        let levelCodec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: noLevels)
        expectLlmError("llm.reasoning_effort_unsupported", { => let _ = levelCodec.encodeRequest(LlmWireRequest("m", validMessages(), reasoningEffort: LlmWireReasoningEffort.High)) })
        let budgetCodec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: capabilities)
        expectLlmError("llm.thinking_budget_invalid", { => let _ = budgetCodec.encodeRequest(LlmWireRequest("m", validMessages(), thinkingMode: LlmWireThinkingMode.Budget(0), maxOutputTokens: Some(2048))) })
        expectLlmError("llm.dialect_protocol_mismatch", { => let _ = LlmWireCodec(LlmWireProtocol.Messages, openAiResponsesDialect()) })
    }

    @TestCase
    func t026TransportCoversSplitLinesInvalidLimitsAndOverflow() {
        try { let _ = SseDecoder(maxEventBytes: 0); @Fail("invalid limit") } catch (_: IllegalArgumentException) { () }
        let independentBuffer = SseDecoder(maxEventBytes: 100, maxLineBytes: 100, maxBufferedBytes: 2)
        match (independentBuffer.push("abc")) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_buffer_too_large"); case _ => @Fail("independent buffer limit") }
        match (independentBuffer.push("x")) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_failed"); case _ => @Fail("poisoned SSE") }
        let lineLimit = SseDecoder(maxEventBytes: 100, maxLineBytes: 2, maxBufferedBytes: 100)
        match (lineLimit.push("abc")) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_line_too_large"); case _ => @Fail("line limit") }
        let outputLimit = SseDecoder(maxEventBytes: 100, maxLineBytes: 100, maxBufferedBytes: 100, maxEventsPerPush: 1)
        match (outputLimit.push("data: a\n\ndata: b\n\n")) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_output_too_large"); case _ => @Fail("output limit") }
        let split = SseDecoder(maxEventBytes: 128)
        match (split.push("id: first\r")) { case LlmWireResult.Ok(values) => @Expect(values.size, 0); case _ => @Fail("split CR") }
        match (split.push("\ndata: one\r\n\r\n")) { case LlmWireResult.Ok(values) => @Expect(values.size, 1); @Expect(values[0].id, "first"); case _ => @Fail("split CRLF") }
        match (split.push("\nid:\ndata:\n\n")) { case LlmWireResult.Ok(values) => @Expect(values.size, 1); @Expect(values[0].id, ""); @Expect(values[0].data, ""); case _ => @Fail("empty data") }
        match (SseDecoder().push("retry: 999999999999999999999999\ndata: x\n\n")) { case LlmWireResult.Ok(values) => @Expect(values[0].retryMillis, Some(Int64.Max)); case _ => @Fail("retry overflow") }
        match (SseDecoder().push([255u8, 10u8, 10u8])) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_utf8_invalid"); case _ => @Fail("invalid UTF-8") }
        let actualLarge = ByteBuffer(); actualLarge.write("hello".toArray())
        match (readLlmHttpBody(actualLarge, None, 4)) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.body_too_large"); case _ => @Fail("stream body must be bounded") }
        for (date in ["Sun, bad", "Sun, 06 Nov 1994 08:49:37 UTC", "Sunday, 06-Nov-94 08:49:37 UTC", "Sun Nov 6 08:49:37", "Sun Nov 6 08:49:37 1994 extra", "Sun, 31 Feb 1994 08:49:37 GMT"]) {
            @Expect(parseRetryAfterMillis(date, 0), None)
        }
    }

    @TestCase
    func t027ArgumentEncodersAndOptionalRequestFieldsCoverAllVariants() {
        let schema = testJson("{}")
        let complete = LlmWireToolArguments.Complete(schema)
        let badJson = LlmWireToolArguments.InvalidJson("{")
        let badShape = LlmWireToolArguments.InvalidShape(testJson("[]"))
        @Expect(toolArgumentsRaw(complete), "{}")
        @Expect(toolArgumentsRaw(badJson), "{")
        @Expect(toolArgumentsRaw(badShape), "[]")
        expectLlmError("llm.tool_arguments_json_invalid", { => let _ = toolArgumentsObject(badJson) })
        expectLlmError("llm.tool_arguments_shape_invalid", { => let _ = toolArgumentsObject(badShape) })
        expectLlmError("llm.tool_arguments_shape_invalid", { => let _ = toolArgumentsObject(LlmWireToolArguments.Complete(testJson("[]"))) })
        let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: allCapabilities())
        let minimal = codec.encodeRequest(LlmWireRequest("m", validMessages(), tools: [LlmWireTool("f", "", schema)], promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ThirtyMinutes), toolChoice: LlmWireToolChoice.NoTools, structuredOutput: LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("x", schema))))
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
        match (responseError.push(event("{\"type\":\"error\",\"message\":\"bad\"}")).terminal) { case Some(LlmWireTerminal.ProviderFailed(_)) => (); case _ => @Fail("root error") }
        let responseDone = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        let _ = responseDone.push(event("{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}"))
        @Expect(responseDone.push(event("[DONE]")).events.size, 0)

        let chatEmpty = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        @Expect(chatEmpty.push(event("")).events.size, 0)
        expectLlmError("llm.field_missing", { => let _ = chatEmpty.push(event("{}")) })
        let chatCall = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        expectLlmError("llm.field_missing", { => let _ = chatCall.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"function\":{}}]}}]}")) })
        let chatNoFunction = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        match (chatNoFunction.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0}]}}]}")).events[0]) {
            case LlmWireEvent.StreamStarted(_, _) => ()
            case _ => @Fail("expected stream start")
        }
        let legacyFunction = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        expectLlmError("llm.chat_semantic_unsupported", { => let _ = legacyFunction.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"function_call\":{\"name\":\"f\",\"arguments\":\"{}\"}}}]}")) })
        let chatPartial = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        let _ = chatPartial.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{\"}}]}}]}"))
        let _ = chatPartial.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}"))
        let _ = chatPartial.push(event("[DONE]"))
        match (chatPartial.finishTransport()) { case LlmWireTerminal.Completed(reply) => expectIncomplete(reply, LlmWireIncompleteReason.Length); match (reply.blocks[0]) { case LlmWireOutputBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.Partial(_) => (); case _ => @Fail("partial call") }; case _ => @Fail("tool call") }; case _ => @Fail("length") }
        let unsupportedChat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        expectLlmError("llm.chat_finish_reason_unsupported", { => let _ = unsupportedChat.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"future\"}]}")) })

        let emptyMessages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        @Expect(emptyMessages.push(event("")).events.size, 0)
        @Expect(emptyMessages.push(event("[DONE]")).events.size, 0)
        let duplicate = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        let startText = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"x\"}}"
        beginMessages(duplicate)
        let _ = duplicate.push(event(startText))
        expectLlmError("llm.messages_block_duplicate", { => let _ = duplicate.push(event(startText)) })
        let unknown = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        beginMessages(unknown)
        try { let _ = unknown.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"future\"}}")); @Fail("unknown native") }
        catch (error: LlmWireError) { @Expect(error.code, "llm.messages_stream_block_unsupported"); @Expect(error.diagnosticJson.getOrThrow().contains("raw_fragment"), true) }
        let noStart = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        expectLlmError("llm.messages_block_out_of_phase", { => let _ = noStart.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}")) })
        expectLlmError("llm.stream_failed", { => let _ = noStart.push(event("{\"type\":\"content_block_stop\",\"index\":0}")) })
        let stopped = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        beginMessages(stopped)
        let _ = stopped.push(event(startText)); let _ = stopped.push(event("{\"type\":\"content_block_stop\",\"index\":0}"))
        expectLlmError("llm.messages_delta_after_stop", { => let _ = stopped.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}")) })
        expectLlmError("llm.stream_failed", { => let _ = stopped.push(event("{\"type\":\"content_block_stop\",\"index\":0}")) })
        let incompleteBlock = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        beginMessages(incompleteBlock)
        let _ = incompleteBlock.push(event(startText))
        expectLlmError("llm.messages_content_block_incomplete", { => let _ = incompleteBlock.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}")) })
        let redacted = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        beginMessages(redacted)
        let _ = redacted.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"x\"}}"))
        let _ = redacted.push(event("{\"type\":\"content_block_stop\",\"index\":0}"))
        let _ = redacted.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}"))
        match (redacted.push(event("{\"type\":\"message_stop\"}")).terminal) { case Some(LlmWireTerminal.Completed(reply)) => expectIncomplete(reply, LlmWireIncompleteReason.MaxTokens); match (reply.blocks[0]) { case LlmWireOutputBlock.NativeReplay(value) => @Expect(value.completion, LlmWireOpaqueCompletion.Complete); case _ => @Fail("native replay") }; case _ => @Fail("redacted") }
    }

    @TestCase
    func t029FixedDecodersRejectMissingContainersAndCoverFailureFallbacks() {
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        match (responses.decodeResponse("{\"status\":\"failed\",\"error\":{\"message\":\"bad\"}}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(failure)) => @Expect(failure.message, "bad"); case _ => @Fail("failed response") }
        expectLlmError("llm.field_missing", { => let _ = responses.decodeResponse("{\"status\":\"completed\",\"output\":[{\"type\":\"message\"}]}" ) })
        match (responses.decodeResponse("{\"status\":\"incomplete\",\"output\":[],\"incomplete_details\":{}}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => expectIncomplete(reply, LlmWireIncompleteReason.Other("incomplete")); case _ => @Fail("fallback reason") }

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        match (chat.decodeResponse("{\"error\":{\"message\":\"bad\"}}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(_)) => (); case _ => @Fail("chat error") }
        expectLlmError("llm.field_missing", { => let _ = chat.decodeResponse("{}") })
        expectLlmError("llm.field_missing", { => let _ = chat.decodeResponse("{\"choices\":[{}]}") })
        expectLlmError("llm.field_missing", { => let _ = chat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{\"tool_calls\":[{\"id\":\"c\",\"type\":\"function\"}]},\"finish_reason\":\"tool_calls\"}]}" ) })
        expectLlmError("llm.chat_legacy_function_call_unsupported", { => let _ = chat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{\"content\":\"\",\"reasoning_content\":\"\"},\"finish_reason\":\"function_call\"}]}" ) })

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        expectLlmError("llm.field_missing", { => let _ = messages.decodeResponse("{\"stop_reason\":\"end_turn\"}") })
        match (messages.decodeResponse("{\"type\":\"error\",\"message\":\"root bad\"}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(failure)) => @Expect(failure.message, "root bad"); case _ => @Fail("root message error") }
        let completeTool = messages.decodeResponse("{\"content\":[{\"type\":\"tool_use\",\"id\":\"c\",\"name\":\"f\",\"input\":{\"x\":1}}],\"stop_reason\":\"tool_use\"}")
        match (completeTool) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => match (reply.blocks[0]) { case LlmWireOutputBlock.ToolCall(call) => match (call.arguments) { case LlmWireToolArguments.Complete(_) => (); case _ => @Fail("complete") }; case _ => @Fail("tool") }; case _ => @Fail("messages") }
    }

    @TestCase
    func t030DirectBranchContractsCoverReplayDefaultsAndStreamMaterialization() {
        expectLlmError("llm.tool_arguments_partial", { => let _ = toolArgumentsRaw(LlmWireToolArguments.Partial("{")) })
        expectLlmError("llm.tool_arguments_partial", { => let _ = toolArgumentsObject(LlmWireToolArguments.Partial("{")) })
        match (classifyToolArguments("null")) { case LlmWireToolArguments.InvalidShape(value) => @Expect(value.stringify(), "null"); case _ => @Fail("null shape") }
        expectLlmError("llm.json_invalid", { => let _ = parseWireJson("{\"x\":1,\"x\":2}") })
        expectLlmError("llm.json_duplicate_key", { => let _ = wireJsonObject([WireJsonField("x", wireJsonString("a")), WireJsonField("x", wireJsonString("b"))]) })

        let completeOpaque = LlmWireOpaqueBlock("future", parseWireJson("{\"type\":\"future\"}"))
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        expectLlmError("llm.opaque_diagnostic_only", { => let _ = responses.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Opaque(completeOpaque)])])) })
        let messageOpaque = LlmWireOpaqueBlock("future", parseWireJson("{\"type\":\"future\"}"))
        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        expectLlmError("llm.opaque_diagnostic_only", { => let _ = messages.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Opaque(messageOpaque)])], maxOutputTokens: 1024)) })

        let emptyId = [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("", "f", LlmWireToolArguments.Complete(testJson("{}"))))])]
        let capable = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: allCapabilities())
        expectLlmError("llm.tool_call_duplicate", { => let _ = capable.encodeRequest(LlmWireRequest("m", emptyId)) })

        let chatStop = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        match (chatStop.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{},\"finish_reason\":\"stop\"}]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(_)) => (); case _ => @Fail("stop") }
        let chatNoFragment = chatStop.newStreamDecoder()
        match (chatNoFragment.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\"}}]}}]}" )).events[0]) {
            case LlmWireEvent.StreamStarted(_, _) => ()
            case _ => @Fail("expected stream start")
        }

        let messagesError = messages.newStreamDecoder()
        match (messagesError.push(event("{\"type\":\"error\",\"message\":\"bad\"}")).terminal) { case Some(LlmWireTerminal.ProviderFailed(_)) => (); case _ => @Fail("messages root error") }
        let messagesDone = messages.newStreamDecoder()
        beginMessages(messagesDone)
        let _ = messagesDone.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}")); let _ = messagesDone.push(event("{\"type\":\"message_stop\"}"))
        @Expect(messagesDone.push(event("[DONE]")).events.size, 0)
        let completeToolStream = messages.newStreamDecoder()
        beginMessages(completeToolStream)
        let _ = completeToolStream.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"c\",\"name\":\"f\",\"input\":{}}}"))
        let _ = completeToolStream.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}")); let _ = completeToolStream.push(event("{\"type\":\"content_block_stop\",\"index\":0}")); let _ = completeToolStream.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}"))
        match (completeToolStream.push(event("{\"type\":\"message_stop\"}")).terminal) { case Some(LlmWireTerminal.Completed(reply)) => @Expect(reply.blocks.size, 1); case _ => @Fail("complete tool stream") }

        let rawRedacted = MessageStreamBlock(0, "redacted_thinking")
        rawRedacted.initialPayload = Some(parseWireJson("{\"type\":\"redacted_thinking\",\"data\":\"x\"}"))
        match (materializeMessageBlock(messages, rawRedacted)) { case LlmWireOutputBlock.NativeReplay(value) => @Expect(value.completion, LlmWireOpaqueCompletion.Partial); case _ => @Fail("raw redacted") }
        rawRedacted.completed = true
        match (materializeMessageBlock(messages, rawRedacted)) { case LlmWireOutputBlock.NativeReplay(value) => @Expect(value.completion, LlmWireOpaqueCompletion.Complete); case _ => @Fail("complete redacted") }
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
        for ((codec, expected) in cases) { @Expect(codec.encodeRequest(request).bodyText(), expected) }
    }

    @TestCase
    func t032RemediationContractsStayFailClosed() {
        let capabilities = allCapabilities()
        let anthropic = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: capabilities)
        let plan = anthropic.encodeRequest(LlmWireRequest("claude", validMessages(), maxOutputTokens: Some(2048), generationSpeed: LlmWireGenerationSpeed.Fast))
        @Expect(plan.requiredHeadersForTest().size, 1)
        @Expect(plan.featureRequirementsForTest().size, 1)
        plan.validateForSend(Some(SatisfiedRequirementResolver()))
        expectLlmError("llm.feature_requirement_unresolved", { => plan.validateForSend(Some(UnknownRequirementResolver())) })
        let merged = plan.mergeHeadersForTest([LlmWireHeader("Anthropic-Beta", "other-feature")])
        @Expect(merged[0].value, "fast-mode-2026-02-01,other-feature")
        expectLlmError("llm.required_header_conflict", { => let _ = LlmWirePreparedRequest("{}", requiredHeaders: [LlmWireHeader("x-mode", "required")]).mergeHeadersForTest([LlmWireHeader("X-Mode", "different")]) })

        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        let grouped = responses.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("a")), LlmWireBlock.Text(LlmWireTextBlock("b"))])])).bodyText()
        @Expect(grouped, "{\"model\":\"m\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"a\"},{\"type\":\"input_text\",\"text\":\"b\"}]}]}")

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        match (chat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{\"refusal\":\"no\"},\"finish_reason\":\"stop\"}]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => match (reply.blocks[0]) { case LlmWireOutputBlock.Refusal(value) => @Expect(value.text, "no"); case _ => @Fail("fixed refusal") }; case _ => @Fail("fixed chat") }
        let multi = succeededReply(chat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{},\"finish_reason\":\"stop\"},{\"index\":1,\"message\":{},\"finish_reason\":\"stop\"}]}"))
        @Expect(multi.choices.size, 2)
        expectLlmError("llm.chat_choice_index_invalid", { => let _ = chat.decodeResponse("{\"choices\":[{\"index\":1,\"message\":{},\"finish_reason\":\"stop\"}]}" ) })
        let refusal = chat.newStreamDecoder()
        let refusalDelta = refusal.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"refusal\":\"no\"}}]}" ))
        match (refusalDelta.events[1]) { case LlmWireEvent.RefusalDelta("no", _) => (); case _ => @Fail("refusal delta") }
        let _ = refusal.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"))
        match (refusal.push(event("[DONE]")).terminal) { case Some(LlmWireTerminal.Completed(reply)) => match (reply.blocks[0]) { case LlmWireOutputBlock.Refusal(value) => @Expect(value.text, "no"); case _ => @Fail("stream refusal") }; case _ => @Fail("stream chat") }

        let badMessages = anthropic.newStreamDecoder()
        beginMessages(badMessages)
        let _ = badMessages.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"))
        expectLlmError("llm.messages_delta_type_mismatch", { => let _ = badMessages.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"x\"}}")) })
        expectLlmError("llm.stream_failed", { => let _ = badMessages.push(event("{\"type\":\"content_block_stop\",\"index\":0}")) })

        let responseStream = responses.newStreamDecoder()
        let _ = responseStream.push(event("{\"type\":\"response.created\",\"response\":{}}"))
        let _ = responseStream.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"item\",\"call_id\":\"call\",\"name\":\"f\"}}"))
        let _ = responseStream.push(event("{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"item\",\"delta\":\"{}\"}"))
        let done = responseStream.push(event("{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"item\",\"arguments\":\"{}\"}"))
        match (done.events[0]) { case LlmWireEvent.ContentBlockCompleted(LlmWireStreamBlockKind.ToolCall, _) => (); case _ => @Fail("tool completion") }

        let native = nativeReplayFromPayload(LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking", parseWireJson("{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"sig\"}"), modelConstraint: Some("claude"))
        let restored = LlmWireNativeReplayBlock.restore(native.snapshot())
        @Expect(restored.dialectId, "anthropic.messages.v1")
        @Expect(restored.payload()["signature"].string, "sig")
        expectLlmError("llm.native_replay_incomplete", { => let _ = LlmWireNativeReplayBlock.restore(native.snapshot().replace("\"complete\":true", "\"complete\":false")) })
        expectLlmError("llm.native_replay_incomplete", { => let _ = LlmWireNativeReplayBlock.restore(native.snapshot().replace("\"complete\":true", "\"complete\":\"yes\"")) })
        expectLlmError("llm.native_replay_model_mismatch", { => let _ = anthropic.encodeRequest(LlmWireRequest("other", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.NativeReplay(restored)])], maxOutputTokens: Some(2048))) })

        let tool = LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Complete(testJson("{}"))))
        expectLlmError("llm.tool_call_role_invalid", { => let _ = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities).encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [tool])])) })
        match (chat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{},\"finish_reason\":\"stop\"}]}")) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => @Expect(reply.usage.inputTokens, None); case _ => @Fail("optional usage") }
    }

    @TestCase
    func t033ProviderSpecificRequestAndReplayShapesStayExact() {
        let capabilities = allCapabilities()
        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: capabilities)
        let schema = LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("answer", testJson("{\"type\":\"object\"}")))
        let encodedSchema = chat.encodeRequest(LlmWireRequest("m", validMessages(), structuredOutput: schema)).bodyText()
        @Expect(encodedSchema.contains("\"json_schema\":{\"name\":\"answer\""), true)
        @Expect(encodedSchema.contains("\"json_schema\":{\"type\":\"json_schema\""), false)

        let deepSeek = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: capabilities)
        let state = deepSeek.decodeResponse("{\"model\":\"m\",\"choices\":[{\"index\":0,\"message\":{\"content\":\"answer\",\"reasoning_content\":\"reason\",\"tool_calls\":[{\"id\":\"c\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}")
        let reply = match (state) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(value)) => value; case _ => @Fail("DeepSeek reply") }
        match (reply.blocks[1]) { case LlmWireOutputBlock.NativeReplay(value) => @Expect(value.nativeType, "reasoning_content"); case _ => @Fail("reasoning must be native replay") }
        let continuation = ArrayList<LlmWireMessage>()
        for (message in reply.toContinuationInput()) { continuation.add(message) }
        continuation.add(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("c", "ok"))]))
        let replay = deepSeek.encodeRequest(LlmWireRequest("m", continuation.toArray(), tools: [LlmWireTool("f", "", testJson("{}"))])).bodyText()
        @Expect(replay.contains("\"reasoning_content\":\"reason\""), true)

        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        let decoded = responses.decodeResponse("{\"model\":\"m\",\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"why\"}]},{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}]}")
        let responseReply = match (decoded) { case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(value)) => value; case _ => @Fail("Responses reply") }
        let ordered = responses.encodeRequest(LlmWireRequest("m", responseReply.toContinuationInput())).bodyText()
        let reasoningAt = match (ordered.indexOf("\"type\":\"reasoning\"")) { case Some(value) => value; case None => @Fail("missing reasoning") }
        let messageAt = match (ordered.indexOf("\"role\":\"assistant\"")) { case Some(value) => value; case None => @Fail("missing message") }
        @Expect(reasoningAt < messageAt, true)
    }

    @TestCase
    func t034LimitsPhasesAndPublicInvariantsFailClosed() {
        let limited = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder(
            limits: LlmWireStreamLimits(maxTotalSemanticBytes: 3, maxTextBytes: 3)
        )
        expectLlmError("llm.stream_semantic_too_large", { => let _ = limited.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"four\"}}]}")) })
        expectLlmError("llm.stream_failed", { => let _ = limited.push(event("{\"choices\":[]}")) })
        match (SseDecoder(maxOutputBytesPerPush: 1).push("data: xx\n\n")) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_output_bytes_too_large"); case _ => @Fail("SSE output byte limit") }

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: allCapabilities())
        let phase = messages.newStreamDecoder(); beginMessages(phase)
        expectLlmError("llm.messages_start_duplicate", { => beginMessages(phase) })
        let lateBlock = messages.newStreamDecoder(); beginMessages(lateBlock)
        let _ = lateBlock.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}"))
        expectLlmError("llm.messages_block_out_of_phase", { => let _ = lateBlock.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"x\"}}")) })

        expectLlmError("llm.header_invalid", { => let _ = LlmWireHeader("bad:name", "x") })
        expectLlmError("llm.tool_name_invalid", { => let _ = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: allCapabilities()).encodeRequest(LlmWireRequest("m", validMessages(), tools: [LlmWireTool("bad name", "", testJson("{}"))])) })
        expectLlmError("llm.tool_schema_invalid", { => let _ = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: allCapabilities()).encodeRequest(LlmWireRequest("m", validMessages(), tools: [LlmWireTool("f", "", testJson("[]"))])) })
        expectLlmError("llm.image_url_invalid", { => let _ = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, ""))])])) })
        expectLlmError("llm.usage_negative", { => let _ = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).decodeResponse("{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":-1}}") })

        let invalidReply = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.InvalidJson("{")))])
        expectLlmError("llm.tool_arguments_not_executable", { => let _ = invalidReply.toContinuationInput() })
        let named = LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("answer", testJson("{}")))
        expectLlmError("llm.structured_output_metadata_unsupported", { => let _ = messages.encodeRequest(LlmWireRequest("m", validMessages(), maxOutputTokens: Some(1024), structuredOutput: named)) })
        @Expect(messages.encodeRequest(LlmWireRequest("m", validMessages(), maxOutputTokens: Some(1024), structuredOutput: LlmWireStructuredOutput.JsonSchemaDocument(testJson("{}")))).contains("output_config"), true)

        try {
            let _ = LlmWireDialectContract("bad", LlmWireProtocol.Responses, LlmWireRequestStyle.DeepSeekChat, LlmWireOutputTokenField.MaxTokens)
            @Fail("invalid contract")
        } catch (_: IllegalArgumentException) { () }

        let responseStream = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        let _ = responseStream.push(event("{\"type\":\"response.created\",\"response\":{}}"))
        let _ = responseStream.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"message\"}}"))
        let _ = responseStream.push(event("{\"type\":\"response.content_part.added\",\"item_id\":\"i\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"refusal\",\"refusal\":\"\"}}"))
        let refusal = responseStream.push(event("{\"type\":\"response.refusal.delta\",\"item_id\":\"i\",\"output_index\":0,\"content_index\":0,\"delta\":\"no\"}"))
        match (refusal.events[0]) { case LlmWireEvent.RefusalDelta("no", location) => @Expect(location.contentIndex, Some(0)); case _ => @Fail("response refusal delta") }
    }

    @TestCase
    func t035ConversationCannotAdvancePastPendingToolCalls() {
        let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: allCapabilities())
        let tool = LlmWireTool("f", "", testJson("{}"))
        let call = LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Complete(testJson("{}"))))
        let assistant = LlmWireMessage(LlmWireRole.Assistant, [call])
        expectLlmError("llm.tool_conversation_out_of_phase", { =>
            let _ = codec.encodeRequest(LlmWireRequest("m", [assistant, LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("continue"))])], tools: [tool]))
        })

        let secondCall = LlmWireBlock.ToolCall(LlmWireToolCallBlock("d", "f", LlmWireToolArguments.Complete(testJson("{}"))))
        expectLlmError("llm.tool_results_incomplete", { =>
            let _ = codec.encodeRequest(LlmWireRequest(
                "m", [LlmWireMessage(LlmWireRole.Assistant, [call, secondCall]), LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("c", "ok"))])],
                tools: [tool]
            ))
        })
    }

    @TestCase
    func t036DialectUsageMergeStyleIsExplicit() {
        let replace = TestStandardDialect(LlmWireDialectContract(
            "test.chat.replace", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat,
            LlmWireOutputTokenField.MaxCompletionTokens, usageMergeStyle: LlmWireUsageMergeStyle.ReplacePresent
        ))
        let replaceDecoder = LlmWireCodec(LlmWireProtocol.ChatCompletions, replace).newStreamDecoder()
        let _ = replaceDecoder.push(event("{\"usage\":{\"prompt_tokens\":2},\"choices\":[]}"))
        let _ = replaceDecoder.push(event("{\"usage\":{\"prompt_tokens\":3},\"choices\":[]}"))
        let _ = replaceDecoder.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"))
        @Expect(succeededReply(replaceDecoder.push(event("[DONE]"))).usage.inputTokens, Some(3))

        let delta = TestStandardDialect(LlmWireDialectContract(
            "test.chat.delta", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat,
            LlmWireOutputTokenField.MaxCompletionTokens, usageMergeStyle: LlmWireUsageMergeStyle.Delta
        ))
        let deltaDecoder = LlmWireCodec(LlmWireProtocol.ChatCompletions, delta).newStreamDecoder()
        let _ = deltaDecoder.push(event("{\"usage\":{\"prompt_tokens\":2},\"choices\":[]}"))
        let _ = deltaDecoder.push(event("{\"usage\":{\"prompt_tokens\":3},\"choices\":[]}"))
        let _ = deltaDecoder.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"))
        @Expect(succeededReply(deltaDecoder.push(event("[DONE]"))).usage.inputTokens, Some(5))

        let monotonic = TestStandardDialect(LlmWireDialectContract(
            "test.chat.monotonic", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat,
            LlmWireOutputTokenField.MaxCompletionTokens, usageMergeStyle: LlmWireUsageMergeStyle.Monotonic
        ))
        let monotonicDecoder = LlmWireCodec(LlmWireProtocol.ChatCompletions, monotonic).newStreamDecoder()
        let _ = monotonicDecoder.push(event("{\"usage\":{\"prompt_tokens\":5},\"choices\":[]}"))
        expectLlmError("llm.usage_decreased", { => let _ = monotonicDecoder.push(event("{\"usage\":{\"prompt_tokens\":4},\"choices\":[]}")) })
    }

    @TestCase
    func t037OneShotAndStreamCanonicalRepliesMatchForEveryBuiltinDialect() {
        for (dialect in [openAiResponsesDialect(), deepSeekResponsesDialect()]) {
            let codec = LlmWireCodec(LlmWireProtocol.Responses, dialect)
            let body = "{\"id\":\"r\",\"model\":\"m\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}],\"usage\":{\"input_tokens\":2,\"output_tokens\":3}}"
            let decoder = codec.newStreamDecoder()
            let streamed = succeededReply(decoder.push(event("{\"type\":\"response.completed\",\"response\":" + body + "}")))
            expectTextReplyEquivalent(succeededReply(codec.decodeResponse(body)), streamed)
        }

        for (dialect in [openAiChatDialect(), deepSeekChatDialect()]) {
            let codec = LlmWireCodec(LlmWireProtocol.ChatCompletions, dialect)
            let body = "{\"id\":\"c\",\"model\":\"m\",\"choices\":[{\"index\":0,\"message\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}"
            let decoder = codec.newStreamDecoder()
            let _ = decoder.push(event("{\"id\":\"c\",\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"o\"}}]}"))
            let _ = decoder.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"k\"},\"finish_reason\":\"stop\"}]}"))
            let _ = decoder.push(event("{\"choices\":[],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}"))
            expectTextReplyEquivalent(succeededReply(codec.decodeResponse(body)), succeededReply(decoder.push(event("[DONE]"))))
        }

        for (dialect in [anthropicMessagesDialect(), deepSeekMessagesDialect()]) {
            let codec = LlmWireCodec(LlmWireProtocol.Messages, dialect)
            let body = "{\"id\":\"a\",\"model\":\"m\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":2,\"output_tokens\":3}}"
            let decoder = codec.newStreamDecoder()
            let _ = decoder.push(event("{\"type\":\"message_start\",\"message\":{\"id\":\"a\",\"model\":\"m\",\"usage\":{\"input_tokens\":2}}}"))
            let _ = decoder.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"))
            let _ = decoder.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}"))
            let _ = decoder.push(event("{\"type\":\"content_block_stop\",\"index\":0}"))
            let _ = decoder.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}"))
            expectTextReplyEquivalent(succeededReply(codec.decodeResponse(body)), succeededReply(decoder.push(event("{\"type\":\"message_stop\"}"))))
        }
    }

    @TestCase
    func t038UnsupportedDiagnosticsAndTruncationCarrySafeContext() {
        let payload = StringBuilder(); for (_ in 0..3000) { payload.append("x") }
        let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), provider: "openai")
        try {
            let _ = codec.decodeResponse("{\"status\":\"completed\",\"output\":[{\"type\":\"future\",\"secret\":\"" + payload.toString() + "\"}]}")
            @Fail("unknown semantic content must fail")
        } catch (error: LlmWireError) {
            @Expect(error.kind, LlmWireErrorKind.Unsupported)
            @Expect(error.phase, Some(LlmTransportPhase.SemanticAssembly))
            @Expect(error.protocol, Some(LlmWireProtocol.Responses))
            @Expect(error.dialectId, "openai.responses.v1")
            @Expect(error.diagnosticJson.getOrThrow().contains("\"truncated\":true"), true)
            @Expect(error.diagnosticJson.getOrThrow().contains("raw_fragment"), false)
        }

        let unknownStreamBlock = codec.newStreamDecoder()
        let _ = unknownStreamBlock.push(event("{\"type\":\"response.created\",\"response\":{}}"))
        expectLlmError("llm.responses_stream_block_unsupported", { =>
            let _ = unknownStreamBlock.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"future\",\"id\":\"i\"}}"))
        })

        let decoder = codec.newStreamDecoder()
        try { let _ = decoder.finishTransport(); @Fail("EOF without terminal must fail") }
        catch (error: LlmWireError) {
            @Expect(error.kind, LlmWireErrorKind.InvalidWire)
            @Expect(error.code, "llm.stream_terminal_missing")
            @Expect(error.phase, Some(LlmTransportPhase.SemanticAssembly))
            @Expect(error.protocol, Some(LlmWireProtocol.Responses))
        }
        expectLlmError("llm.stream_failed", { => let _ = decoder.finishTransport() })
    }

    @TestCase
    func t039RequestContractsRejectUnrepresentableAndForgedState() {
        try {
            let _ = LlmWireDialectContract(
                "custom.responses", LlmWireProtocol.Responses, LlmWireRequestStyle.OpenAiResponses,
                LlmWireOutputTokenField.MaxOutputTokens, generationSpeeds: [LlmWireGenerationSpeed.Fast]
            )
            @Fail("unmapped generation speed")
        } catch (_: IllegalArgumentException) { () }
        try {
            let _ = LlmWireDialectContract(
                "custom.messages", LlmWireProtocol.Messages, LlmWireRequestStyle.AnthropicMessages,
                LlmWireOutputTokenField.MaxTokens, structuredOutputModes: [LlmWireStructuredOutputMode.Text]
            )
            @Fail("unmapped Messages structured output")
        } catch (_: IllegalArgumentException) { () }
        try {
            let reserved = LlmWireDialectContract("openai.responses.v1", LlmWireProtocol.Responses, LlmWireRequestStyle.OpenAiResponses, LlmWireOutputTokenField.MaxOutputTokens)
            let _ = TestStandardDialect(reserved)
            @Fail("reserved compatibility ID")
        } catch (_: IllegalArgumentException) { () }

        let forged = "{\"protocol\":\"messages\",\"dialect_id\":\"anthropic.messages.v1\",\"native_type\":\"tool_use\",\"schema_version\":1,\"scope\":\"assistant_turn\",\"assistant_turn_index\":0,\"block_order\":0,\"complete\":true,\"payload\":{\"type\":\"tool_use\",\"id\":\"c\",\"name\":\"f\",\"input\":{}}}"
        expectLlmError("llm.native_replay_type_unsupported", { => let _ = LlmWireNativeReplayBlock.restore(forged) })
        let futureSchema = forged.replace("\"native_type\":\"tool_use\"", "\"native_type\":\"thinking\"").replace("\"schema_version\":1", "\"schema_version\":2")
        expectLlmError("llm.native_replay_payload_invalid", { => let _ = LlmWireNativeReplayBlock.restore(futureSchema) })
        let conversation = forged.replace("\"native_type\":\"tool_use\"", "\"native_type\":\"thinking\"").replace("\"scope\":\"assistant_turn\"", "\"scope\":\"conversation\"")
        expectLlmError("llm.native_replay_scope_unsupported", { => let _ = LlmWireNativeReplayBlock.restore(conversation) })

        let cachePlan = LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect(), capabilities: allCapabilities()).encodeRequest(
            LlmWireRequest("m", validMessages(), promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault))
        )
        @Expect(cachePlan.featureRequirementsForTest().size, 1)
        @Expect(cachePlan.featureRequirementsForTest()[0].featureId, "provider.prompt_cache_automatic")
        let openAiCachePlan = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: allCapabilities()).encodeRequest(
            LlmWireRequest("m", validMessages(), promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault))
        )
        @Expect(openAiCachePlan.featureRequirementsForTest()[0].featureId, "openai.prompt_cache_automatic")
    }

    @TestCase
    func t040CanonicalRequestsRejectInvalidMessagesAndArguments() {
        let tool = LlmWireTool("f", "", testJson("{}"))
        let bad = LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Complete(testJson("[]"))))
        for (codec in [
            LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: allCapabilities()),
            LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: allCapabilities()),
            LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: allCapabilities())
        ]) {
            expectLlmError("llm.tool_arguments_shape_invalid", { => let _ = codec.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [bad])], tools: [tool], maxOutputTokens: Some(2048))) })
        }
        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        expectLlmError("llm.message_empty", { => let _ = chat.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [])])) })
        expectLlmError("llm.message_empty", { => let _ = chat.encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(""))])])) })
        let illegalName = LlmWireBlock.ToolCall(LlmWireToolCallBlock("c", "bad name", LlmWireToolArguments.Complete(testJson("{}"))))
        expectLlmError("llm.tool_call_name_invalid", { => let _ = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: allCapabilities()).encodeRequest(LlmWireRequest("m", [LlmWireMessage(LlmWireRole.Assistant, [illegalName])], tools: [tool])) })
        expectLlmError("llm.chat_legacy_function_call_unsupported", { => let _ = chat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{},\"finish_reason\":\"function_call\"}]}" ) })
    }

    @TestCase
    func t041MessagesAcceptRepeatedDeltasAndEnforceOrdering() {
        let codec = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        let decoder = codec.newStreamDecoder()
        beginMessages(decoder)
        let _ = decoder.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":null},\"usage\":{\"output_tokens\":1}}"))
        let _ = decoder.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}"))
        match (decoder.push(event("{\"type\":\"message_stop\"}")).terminal) { case Some(LlmWireTerminal.Completed(reply)) => @Expect(reply.usage.outputTokens, Some(2)); case _ => @Fail("repeated message_delta") }

        let changed = codec.newStreamDecoder(); beginMessages(changed)
        let _ = changed.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}"))
        expectLlmError("llm.messages_stop_reason_mismatch", { => let _ = changed.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}")) })
        let gap = codec.newStreamDecoder(); beginMessages(gap)
        expectLlmError("llm.messages_block_index_gap", { => let _ = gap.push(event("{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")) })
    }

    @TestCase
    func t042ChatBuffersToolArgumentsUntilIdentityStarts() {
        let decoder = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        match (decoder.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\"}}]}}]}" )).events[0]) { case LlmWireEvent.StreamStarted(_, _) => (); case _ => @Fail("chat stream start") }
        @Expect(decoder.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"x\\\":1}\"}}]}}]}" )).events.size, 0)
        let identity = decoder.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\"}]}}]}"))
        @Expect(identity.events.size, 2)
        match (identity.events[0]) { case LlmWireEvent.ToolCallStarted(value) => @Expect(value.callId, "call-1"); case _ => @Fail("tool call start") }
        match (identity.events[1]) { case LlmWireEvent.ToolArgumentsDelta("{\"x\":1}", value) => @Expect(value.callId, "call-1"); case _ => @Fail("tool arguments") }
    }

    @TestCase
    func t043ResponsesLifecycleAndFinalLimitsFailClosed() {
        let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        let withoutItem = codec.newStreamDecoder()
        expectLlmError("llm.responses_event_before_start", { => let _ = withoutItem.push(event("{\"type\":\"response.output_text.delta\",\"item_id\":\"i\",\"output_index\":0,\"content_index\":0,\"delta\":\"x\"}")) })

        let doneOnly = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxToolArgumentsBytes: 1))
        let _ = doneOnly.push(event("{\"type\":\"response.created\",\"response\":{}}"))
        let _ = doneOnly.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"i\",\"call_id\":\"c\",\"name\":\"f\"}}"))
        expectLlmError("llm.stream_tool_arguments_too_large", { => let _ = doneOnly.push(event("{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"i\",\"arguments\":\"{}\"}")) })

        let terminalOnly = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxTextBytes: 1))
        expectLlmError("llm.stream_text_too_large", { => let _ = terminalOnly.push(event("{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"xx\"}]}]}}")) })

        let retained = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder(limits: LlmWireStreamLimits(maxRetainedStateBytes: 1))
        expectLlmError("llm.stream_retained_state_too_large", { => let _ = retained.push(event("{\"type\":\"message_start\",\"message\":{\"id\":\"long\"}}")) })
    }

    @TestCase
    func t044SseRetryAndRfc850FollowCurrentStandards() {
        @Expect(parseSseRetryMillis("1000 "), None)
        @Expect(parseSseRetryMillis(" 1000"), None)
        @Expect(parseSseRetryMillis("1000"), Some(1000))
        let now2060 = 2840140800000
        match (parseRetryAfterMillis("Sunday, 06-Nov-94 08:49:37 GMT", now2060)) { case Some(value) => @Expect(value > 0, true); case None => @Fail("RFC850 date") }
    }

    @TestCase
    func t045StreamLimitAndNativeReplayVariantsStayBounded() {
        expectIllegalArgument({ => let _ = LlmWireStreamLimits(maxTotalSemanticBytes: 0) })
        expectIllegalArgument({ => let _ = LlmWireStreamLimits(maxTextBytes: 0) })
        expectIllegalArgument({ => let _ = LlmWireStreamLimits(maxReasoningBytes: 0) })
        expectIllegalArgument({ => let _ = LlmWireStreamLimits(maxToolArgumentsBytes: 0) })
        expectIllegalArgument({ => let _ = LlmWireStreamLimits(maxRetainedStateBytes: 0) })
        expectIllegalArgument({ => let _ = LlmWireStreamLimits(maxBlocks: 0) })
        expectIllegalArgument({ => let _ = LlmWireStreamLimits(maxToolCalls: 0) })
        expectIllegalArgument({ => let _ = LlmWireStreamLimits(maxEvents: 0) })

        let thinking = "{\"protocol\":\"messages\",\"dialect_id\":\"anthropic.messages.v1\",\"native_type\":\"thinking\",\"schema_version\":1,\"scope\":\"assistant_turn\",\"assistant_turn_index\":0,\"block_order\":0,\"complete\":true,\"payload\":{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"sig\"}}"
        @Expect(LlmWireNativeReplayBlock.restore(thinking).nativeType, "thinking")
        let redacted = thinking.replace("\"native_type\":\"thinking\"", "\"native_type\":\"redacted_thinking\"").replace("{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"sig\"}", "{\"type\":\"redacted_thinking\",\"data\":\"opaque\"}")
        @Expect(LlmWireNativeReplayBlock.restore(redacted).nativeType, "redacted_thinking")
        let chat = thinking.replace("\"protocol\":\"messages\"", "\"protocol\":\"chat_completions\"").replace("\"dialect_id\":\"anthropic.messages.v1\"", "\"dialect_id\":\"deepseek.chat.v1\"").replace("\"native_type\":\"thinking\"", "\"native_type\":\"reasoning_content\"").replace("{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"sig\"}", "{\"type\":\"reasoning_content\",\"reasoning_content\":\"why\"}")
        @Expect(LlmWireNativeReplayBlock.restore(chat).nativeType, "reasoning_content")
        let reasoning = thinking.replace("\"protocol\":\"messages\"", "\"protocol\":\"responses\"").replace("\"dialect_id\":\"anthropic.messages.v1\"", "\"dialect_id\":\"openai.responses.v1\"").replace("\"native_type\":\"thinking\"", "\"native_type\":\"reasoning\"").replace("{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"sig\"}", "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[]}")
        @Expect(LlmWireNativeReplayBlock.restore(reasoning).nativeType, "reasoning")
        expectLlmError("llm.field_missing", { => let _ = LlmWireNativeReplayBlock.restore(thinking.replace(",\"signature\":\"sig\"", "")) })
        expectLlmError("llm.native_replay_payload_invalid", { => let _ = LlmWireNativeReplayBlock.restore(reasoning.replace(",\"summary\":[]", "")) })
    }

    @TestCase
    func t046EverySemanticStreamLimitCoversTerminalOnlyOutput() {
        let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        let complete = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"},{\"type\":\"refusal\",\"refusal\":\"no\"}]},{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[]},{\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{}\"}]}}"
        match (codec.newStreamDecoder().push(event(complete)).terminal) { case Some(LlmWireTerminal.Completed(reply)) => @Expect(reply.blocks.size, 4); case _ => @Fail("terminal-only output") }

        let blocks = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxBlocks: 1))
        expectLlmError("llm.stream_blocks_too_many", { => let _ = blocks.push(event(complete)) })
        let calls = codec.newStreamDecoder(limits: LlmWireStreamLimits(maxToolCalls: 1))
        let twoCalls = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"a\",\"name\":\"f\",\"arguments\":\"{}\"},{\"type\":\"function_call\",\"call_id\":\"b\",\"name\":\"g\",\"arguments\":\"{}\"}]}}"
        expectLlmError("llm.stream_tool_calls_too_many", { => let _ = calls.push(event(twoCalls)) })

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect())
        let reasoning = chat.newStreamDecoder(limits: LlmWireStreamLimits(maxReasoningBytes: 1))
        expectLlmError("llm.stream_reasoning_too_large", { => let _ = reasoning.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"xx\"}}]}")) })
        let events = chat.newStreamDecoder(limits: LlmWireStreamLimits(maxEvents: 1))
        let _ = events.push(event("{\"choices\":[]}"))
        expectLlmError("llm.stream_events_too_many", { => let _ = events.push(event("{\"choices\":[]}")) })
    }

    @TestCase
    func t047ReviewContractsClosePublicBypasses() {
        expectIllegalArgument({ => let _ = LlmWireDialectContract("test.messages.routing", LlmWireProtocol.Messages, LlmWireRequestStyle.AnthropicMessages, LlmWireOutputTokenField.MaxTokens, promptCacheRoutingKey: true) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract("test.messages.parallel", LlmWireProtocol.Messages, LlmWireRequestStyle.AnthropicMessages, LlmWireOutputTokenField.MaxTokens, parallelToolStyle: LlmWireParallelToolStyle.OpenAiTopLevel) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract("test.messages.cache", LlmWireProtocol.Messages, LlmWireRequestStyle.AnthropicMessages, LlmWireOutputTokenField.MaxTokens, promptCacheStyle: LlmWirePromptCacheStyle.OpenAi) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract("Bad ID", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract("test.cache.none", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault]) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract("test.deepseek.tier", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.DeepSeekChat, LlmWireOutputTokenField.MaxTokens, serviceTiers: [LlmWireServiceTier.Auto]) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract("test.duplicate.level", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens, reasoningEfforts: [LlmWireReasoningEffort.Low, LlmWireReasoningEffort.Low]) })
        @Expect(TestStandardDialect(LlmWireDialectContract("test_a-b", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens)).compatibilityId, "test_a-b")

        let declared = [LlmWireReasoningEffort.Low]
        let immutable = LlmWireDialectContract("test.chat.immutable", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens, reasoningEfforts: declared)
        declared[0] = LlmWireReasoningEffort.High
        let exposed = immutable.reasoningEfforts; exposed[0] = LlmWireReasoningEffort.Max
        @Expect(immutable.reasoningEfforts[0], LlmWireReasoningEffort.Low)

        let chat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        expectLlmError("llm.tool_call_id_missing", { => let _ = chat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{\"tool_calls\":[{\"id\":\"\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}" ) })
        expectLlmError("llm.tool_call_id_duplicate", { => let _ = chat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{\"tool_calls\":[{\"id\":\"c\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}},{\"id\":\"c\",\"type\":\"function\",\"function\":{\"name\":\"g\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}" ) })

        let blockLimited = chat.newStreamDecoder(limits: LlmWireStreamLimits(maxBlocks: 1))
        expectLlmError("llm.stream_blocks_too_many", { => let _ = blockLimited.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\",\"reasoning_content\":\"y\"}}]}")) })
        let terminalReasoning = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder(limits: LlmWireStreamLimits(maxReasoningBytes: 1))
        expectLlmError("llm.stream_reasoning_too_large", { => let _ = terminalReasoning.push(event("{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"xx\"}]}]}}")) })

        let usage = chat.newStreamDecoder()
        let usageUpdate = usage.push(event("{\"choices\":[],\"usage\":{\"prompt_tokens\":3}}"))
        match (usageUpdate.events[1]) { case LlmWireEvent.UsageUpdated(value) => @Expect(value.inputTokens, Some(3)); case _ => @Fail("usage update") }

        let custom = LlmWireCodec(LlmWireProtocol.ChatCompletions, TestStandardDialect(LlmWireDialectContract(
            "custom.deepseek.chat", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.DeepSeekChat,
            LlmWireOutputTokenField.MaxTokens
        )))
        expectLlmError("llm.native_replay_type_unsupported", { => let _ = custom.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{\"reasoning_content\":\"why\"},\"finish_reason\":\"stop\"}]}" ) })
    }

    @TestCase
    func t048AuditFindingsFailClosedAcrossDialectsAndStreams() {
        let initial = LlmWireDialectContract("test.mutable.chat", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens)
        let mutable = MutableTestDialect(initial)
        let frozen = LlmWireCodec(LlmWireProtocol.ChatCompletions, mutable)
        mutable.replace(LlmWireDialectContract("test.changed.chat", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.DeepSeekChat, LlmWireOutputTokenField.MaxTokens))
        let frozenBody = frozen.encodeRequest(LlmWireRequest("m", validMessages(), maxOutputTokens: Some(8)))
        @Expect(frozen.dialect.compatibilityId, "test.mutable.chat")
        @Expect(frozenBody.contains("max_completion_tokens"), true)
        @Expect(frozenBody.contains("\"max_tokens\""), false)

        let deepSeekMessages = LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect())
        let imageRequest = LlmWireRequest(
            "deepseek-v4-flash-vision-exp", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "https://example.invalid/x.png"))])],
            maxOutputTokens: Some(8)
        )
        expectLlmError("llm.image_input_unsupported", { => let _ = deepSeekMessages.encodeRequest(imageRequest) })
        let visionMessages = LlmWireCodec(LlmWireProtocol.Messages, deepSeekMessagesDialect(), capabilities: LlmWireCapabilities(input: LlmWireInputCapabilities(modalities: [LlmWireInputModality.Text, LlmWireInputModality.Image])))
        @Expect(visionMessages.encodeRequest(imageRequest).contains("\"type\":\"url\""), true)
        let filePlan = visionMessages.encodeRequest(LlmWireRequest(
            "deepseek-v4-flash-vision-exp", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.File, "file-api-test"))])],
            maxOutputTokens: Some(8)
        ))
        @Expect(filePlan.contains("\"file_id\":\"file-api-test\""), true)
        @Expect(filePlan.requiredHeadersForTest()[0].value, "files-api-2025-04-14")
        let visionCapabilities = LlmWireCapabilities(input: LlmWireInputCapabilities(modalities: [LlmWireInputModality.Text, LlmWireInputModality.Image]))
        let visionChat = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: visionCapabilities)
        @Expect(visionChat.encodeRequest(LlmWireRequest("deepseek-v4-flash-vision-exp", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.File, "file-api-chat"))])])).contains("\"type\":\"file\""), true)
        let visionResponses = LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect(), capabilities: visionCapabilities)
        @Expect(visionResponses.encodeRequest(LlmWireRequest("deepseek-v4-flash-vision-exp", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.File, "file-api-responses"))])])).contains("\"file_id\":\"file-api-responses\""), true)
        expectLlmError("llm.image_media_type_unsupported", { => let _ = visionMessages.encodeRequest(LlmWireRequest(
            "deepseek-v4-flash-vision-exp", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Base64, "AAAA", mediaType: "image/svg+xml"))])], maxOutputTokens: Some(8)
        )) })
        expectLlmError("llm.image_role_unsupported", { => let _ = visionResponses.encodeRequest(LlmWireRequest(
            "deepseek-v4-flash-vision-exp", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "https://example.invalid/x.png"))])]
        )) })

        let chatEof = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()).newStreamDecoder()
        let _ = chatEof.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"))
        expectLlmError("llm.stream_terminal_missing", { => let _ = chatEof.finishTransport() })

        let duplicateStart = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        let _ = duplicateStart.push(event("{\"type\":\"response.created\",\"response\":{}}"))
        expectLlmError("llm.responses_start_duplicate", { => let _ = duplicateStart.push(event("{\"type\":\"response.created\",\"response\":{}}")) })

        let duplicateValueDone = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        let _ = duplicateValueDone.push(event("{\"type\":\"response.created\",\"response\":{}}"))
        let _ = duplicateValueDone.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"message\"}}"))
        let _ = duplicateValueDone.push(event("{\"type\":\"response.content_part.added\",\"output_index\":0,\"item_id\":\"i\",\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\"}}"))
        let _ = duplicateValueDone.push(event("{\"type\":\"response.output_text.done\",\"output_index\":0,\"item_id\":\"i\",\"content_index\":0,\"text\":\"\"}"))
        expectLlmError("llm.responses_value_done_duplicate", { => let _ = duplicateValueDone.push(event("{\"type\":\"response.output_text.done\",\"output_index\":0,\"item_id\":\"i\",\"content_index\":0,\"text\":\"\"}")) })

        let partBeforeValue = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect()).newStreamDecoder()
        let _ = partBeforeValue.push(event("{\"type\":\"response.created\",\"response\":{}}"))
        let _ = partBeforeValue.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"message\"}}"))
        let _ = partBeforeValue.push(event("{\"type\":\"response.content_part.added\",\"output_index\":0,\"item_id\":\"i\",\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\"}}"))
        expectLlmError("llm.responses_content_value_incomplete", { => let _ = partBeforeValue.push(event("{\"type\":\"response.content_part.done\",\"output_index\":0,\"item_id\":\"i\",\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\"}}")) })

        let strictChat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect())
        expectLlmError("llm.envelope_identity_mismatch", { => let _ = strictChat.decodeResponse("{\"object\":\"response\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\"},\"finish_reason\":\"stop\"}]}" ) })
        expectLlmError("llm.tool_stop_without_call", { => let _ = strictChat.decodeResponse("{\"choices\":[{\"index\":0,\"message\":{},\"finish_reason\":\"tool_calls\"}]}" ) })

        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        let incomplete = responses.newStreamDecoder()
        let _ = incomplete.push(event("{\"type\":\"response.created\",\"response\":{\"id\":\"r\",\"model\":\"m\"}}"))
        let _ = incomplete.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\"}}"))
        let _ = incomplete.push(event("{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"i\",\"delta\":\"{\"}" ))
        match (incomplete.push(event("{\"type\":\"response.incomplete\",\"response\":{\"id\":\"r\",\"model\":\"m\",\"status\":\"incomplete\",\"output\":[{\"id\":\"i\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{\"}],\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}" )).terminal) {
            case Some(LlmWireTerminal.Completed(reply)) => expectIncomplete(reply, LlmWireIncompleteReason.MaxTokens)
            case _ => @Fail("incomplete Responses terminal")
        }

        let failed = responses.newStreamDecoder()
        let _ = failed.push(event("{\"type\":\"response.created\",\"response\":{\"id\":\"f\"}}"))
        let _ = failed.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\"}}"))
        match (failed.push(event("{\"type\":\"response.failed\",\"response\":{\"id\":\"f\",\"status\":\"failed\",\"error\":{\"type\":\"server_error\",\"message\":\"failed\"}}}" )).terminal) {
            case Some(LlmWireTerminal.ProviderFailed(_)) => ()
            case _ => @Fail("failed Responses terminal")
        }

        match (SseDecoder(maxEventBytes: 9).push("data:x\r\n\r\n")) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_event_too_large"); case _ => @Fail("CRLF bytes must count") }
        match (SseDecoder(maxEventBytes: 10).push("data:x\r\n\r\n")) { case LlmWireResult.Ok(values) => @Expect(values.size, 1); case _ => @Fail("exact CRLF event limit") }
        @Expect(parseRetryAfterMillis("Sunday, 06-Nov-94 08:49:37 GMT", Int64.Max), None)
    }

    @TestCase
    func t049ThinkingCombinationsAndContinuationProjectionFailClosed() {
        let tool = LlmWireTool("lookup", "lookup", testJson("{}"))
        let anthropic = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: allCapabilities())
        expectLlmError("llm.thinking_tool_choice_unsupported", { => let _ = anthropic.encodeRequest(LlmWireRequest(
            "claude", validMessages(), tools: [tool], thinkingMode: LlmWireThinkingMode.Budget(1024),
            maxOutputTokens: Some(2048), toolChoice: LlmWireToolChoice.Required
        )) })
        @Expect(anthropic.encodeRequest(LlmWireRequest(
            "claude", validMessages(), tools: [tool], thinkingMode: LlmWireThinkingMode.Adaptive,
            maxOutputTokens: Some(2048), toolChoice: LlmWireToolChoice.Required
        )).contains("\"type\":\"any\""), true)

        let deepSeek = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: allCapabilities())
        expectLlmError("llm.thinking_tool_choice_unsupported", { => let _ = deepSeek.encodeRequest(LlmWireRequest(
            "deepseek-v4-flash", validMessages(), tools: [tool], thinkingMode: LlmWireThinkingMode.Enabled,
            toolChoice: LlmWireToolChoice.Auto
        )) })
        @Expect(deepSeek.encodeRequest(LlmWireRequest(
            "deepseek-v4-flash", validMessages(), tools: [tool], thinkingMode: LlmWireThinkingMode.Disabled,
            toolChoice: LlmWireToolChoice.Required
        )).contains("\"tool_choice\":\"required\""), true)

        expectIllegalArgument({ => let _ = TestStandardDialect(LlmWireDialectContract(
            "custom.thinking.chat", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat,
            LlmWireOutputTokenField.MaxCompletionTokens,
            thinkingModes: [LlmWireThinkingMode.ProviderDefault],
            reasoningEfforts: [LlmWireReasoningEffort.High]
        )) })
        expectLlmError("llm.dialect_thinking_replay_unsupported", { => let _ = LlmWireCodec(
            LlmWireProtocol.ChatCompletions,
            MutableTestDialect(LlmWireDialectContract(
                "custom.direct.thinking", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat,
                LlmWireOutputTokenField.MaxCompletionTokens,
                thinkingModes: [LlmWireThinkingMode.ProviderDefault, LlmWireThinkingMode.Enabled]
            ))
        ) })
        expectLlmError("llm.dialect_identity_reserved", { => let _ = LlmWireCodec(
            LlmWireProtocol.ChatCompletions,
            MutableTestDialect(LlmWireDialectContract(
                "openai.chat.v1", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat,
                LlmWireOutputTokenField.MaxCompletionTokens
            ))
        ) })

        let replay = LlmWireNativeReplayBlock.restore(
            "{\"protocol\":\"messages\",\"dialect_id\":\"anthropic.messages.v1\",\"native_type\":\"thinking\",\"schema_version\":1,\"scope\":\"assistant_turn\",\"assistant_turn_index\":0,\"block_order\":1,\"complete\":true,\"payload\":{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"sig\"}}"
        )
        let reply = LlmWireReply(blocks: [
            LlmWireOutputBlock.Refusal(LlmWireRefusalBlock("no")),
            LlmWireOutputBlock.NativeReplay(replay)
        ])
        expectLlmError("llm.continuation_projection_lossy", { => let _ = reply.toContinuationInput() })
        expectLlmError("llm.native_replay_projection_order_invalid", { => let _ = LlmWireReply(blocks: [
            LlmWireOutputBlock.NativeReplay(replay)
        ]).toContinuationInput() })
        expectLlmError("llm.continuation_projection_lossy", { => let _ = LlmWireReply(blocks: [
            LlmWireOutputBlock.Refusal(LlmWireRefusalBlock("no"))
        ]).toContinuationInput() })
        expectLlmError("llm.continuation_projection_lossy", { => let _ = LlmWireReply(blocks: [
            LlmWireOutputBlock.Reasoning(LlmWireReasoningBlock("display only"))
        ]).toContinuationInput() })
    }

    @TestCase
    func t050ProviderFeatureShapesAndUnmodeledSemanticsFailClosed() {
        let imageCapabilities = LlmWireCapabilities(input: LlmWireInputCapabilities(modalities: [LlmWireInputModality.Text, LlmWireInputModality.Image]))
        let openAiChat = LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect(), capabilities: imageCapabilities)
        let deepSeekChat = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: imageCapabilities)
        let openAiFile = openAiChat.encodeRequest(LlmWireRequest(
            "gpt", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.File, "file-openai"))])]
        ))
        let deepSeekFile = deepSeekChat.encodeRequest(LlmWireRequest(
            "deepseek-v4-flash-vision-exp", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.File, "file-deepseek"))])]
        ))
        @Expect(openAiFile.contains("\"type\":\"file\",\"file\":{\"file_id\":\"file-openai\"}"), true)
        @Expect(openAiFile.contains("\"type\":\"file\",\"file_id\""), false)
        @Expect(deepSeekFile.contains("\"type\":\"file\",\"file_id\":\"file-deepseek\""), true)
        @Expect(deepSeekFile.contains("\"file\":{\"file_id\""), false)
        let url = openAiChat.encodeRequest(LlmWireRequest(
            "gpt", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "https://example.invalid/image.png"))])]
        ))
        let base64 = openAiChat.encodeRequest(LlmWireRequest(
            "gpt", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Base64, "AAAA", mediaType: "image/png"))])]
        ))
        @Expect(url.contains("\"image_url\":{\"url\":\"https://example.invalid/image.png\""), true)
        @Expect(base64.contains("data:image/png;base64,AAAA"), true)

        let cacheCapabilities = LlmWireCapabilities(cache: LlmWireCacheCapabilities(lifetimes: [
            LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.FiveMinutes, LlmWirePromptCacheLifetime.OneHour
        ]))
        let anthropic = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: cacheCapabilities)
        expectLlmError("llm.max_output_tokens_invalid", { => let _ = anthropic.encodeRequest(LlmWireRequest(
            "claude", validMessages(), maxOutputTokens: Some(0),
            promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.FiveMinutes)
        )) })
        let oneHour = anthropic.encodeRequest(LlmWireRequest(
            "claude", validMessages(), maxOutputTokens: Some(8),
            promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.OneHour)
        ))
        @Expect(oneHour.contains("\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"1h\"}"), true)
        expectLlmError("llm.max_output_tokens_invalid", { => let _ = anthropic.encodeRequest(LlmWireRequest("claude", validMessages(), maxOutputTokens: Some(0))) })
        expectLlmError("llm.cache_lifetime_unsupported", { => let _ = anthropic.encodeRequest(LlmWireRequest(
            "claude", validMessages(), maxOutputTokens: Some(8),
            promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ThirtyMinutes)
        )) })
        expectLlmError("llm.max_output_tokens_invalid", { => let _ = anthropic.encodeRequest(LlmWireRequest(
            "claude", validMessages(), maxOutputTokens: Some(-1),
            promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.FiveMinutes)
        )) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract(
            "test.anthropic.cache.invalid", LlmWireProtocol.Messages, LlmWireRequestStyle.AnthropicMessages,
            LlmWireOutputTokenField.MaxTokens, promptCacheStyle: LlmWirePromptCacheStyle.Anthropic,
            promptCacheLifetimes: [LlmWirePromptCacheLifetime.ThirtyMinutes]
        ) })

        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        let _ = responses.decodeResponse(
            "{\"object\":\"response\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[]}]}"
        )
        expectLlmError("llm.field_missing", { => let _ = responses.decodeResponse(
            "{\"object\":\"response\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\",\"annotations\":[{\"type\":\"file_citation\"}]}]}]}"
        ) })
        expectLlmError("llm.field_missing", { => let _ = responses.decodeResponse(
            "{\"object\":\"response\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\",\"logprobs\":[{\"token\":\"answer\"}]}]}]}"
        ) })
        let _ = responses.decodeResponse(
            "{\"object\":\"response\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\",\"annotations\":[],\"logprobs\":[]}]}]}"
        )

        let messages = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect())
        expectLlmError("llm.field_missing", { => let _ = messages.decodeResponse(
            "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"answer\",\"citations\":[{\"type\":\"page_location\"}]}],\"stop_reason\":\"end_turn\"}"
        ) })
        let _ = messages.decodeResponse(
            "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"stop_reason\":\"refusal\",\"stop_details\":{\"type\":\"refusal\",\"category\":\"cyber\"}}"
        )
        expectLlmError("llm.messages_refusal_details_missing", { => let _ = messages.decodeResponse(
            "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"stop_reason\":\"refusal\"}"
        ) })
        let _ = messages.decodeResponse(
            "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"answer\",\"citations\":[]}],\"stop_reason\":\"end_turn\",\"stop_details\":null}"
        )

        let citationStream = messages.newStreamDecoder(); beginMessages(citationStream)
        let _ = citationStream.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"))
        let citationUpdate = citationStream.push(event(
            "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"citations_delta\",\"citation\":{\"type\":\"page_location\",\"cited_text\":\"source\",\"document_index\":0,\"document_title\":\"Doc\",\"start_page_number\":1,\"end_page_number\":2}}}"
        ))
        match (citationUpdate.events[0]) { case LlmWireEvent.CitationAdded(value, _) => @Expect(value.endPage, Some(2)); case _ => @Fail("citation event") }
        let _ = citationStream.push(event("{\"type\":\"content_block_stop\",\"index\":0}"))
        let _ = citationStream.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}"))
        let citedTerminal = citationStream.push(event("{\"type\":\"message_stop\"}"))
        match (succeededReply(citedTerminal).blocks[0]) { case LlmWireOutputBlock.Text(value) => @Expect(value.citations.size, 1); case _ => @Fail("cited stream text") }
        let refusalStream = messages.newStreamDecoder(); beginMessages(refusalStream)
        let refusalUpdate = refusalStream.push(event(
            "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\",\"stop_details\":{\"type\":\"refusal\",\"category\":\"cyber\",\"explanation\":\"declined\"}}}"
        ))
        match (refusalUpdate.events[0]) { case LlmWireEvent.RefusalObserved(value) => @Expect(value.category, Some("cyber")); case _ => @Fail("refusal details event") }
        let refusalTerminal = refusalStream.push(event("{\"type\":\"message_stop\"}"))
        match (succeededReply(refusalTerminal).blocks[0]) { case LlmWireOutputBlock.Refusal(value) => @Expect(value.explanation, Some("declined")); case _ => @Fail("streamed refusal") }

        expectLlmError("llm.chat_tool_type_unsupported", { => let _ = openAiChat.decodeResponse(
            "{\"choices\":[{\"index\":0,\"message\":{\"tool_calls\":[{\"id\":\"c\",\"type\":\"custom\",\"custom\":{\"name\":\"shell\",\"input\":\"pwd\"}}]},\"finish_reason\":\"tool_calls\"}]}"
        ) })
        expectLlmError("llm.field_missing", { => let _ = openAiChat.decodeResponse(
            "{\"choices\":[{\"index\":0,\"message\":{\"tool_calls\":[{\"id\":\"c\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
        ) })
        let customStream = openAiChat.newStreamDecoder()
        expectLlmError("llm.chat_tool_type_unsupported", { => let _ = customStream.push(event(
            "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"type\":\"custom\"}]}}]}"
        )) })
        let missingTypeStream = openAiChat.newStreamDecoder()
        let _ = missingTypeStream.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]}}]}"))
        let _ = missingTypeStream.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}"))
        expectLlmError("llm.chat_tool_call_type_missing", { => let _ = missingTypeStream.push(event("[DONE]")) })

        let repeatedTypeStream = openAiChat.newStreamDecoder()
        let _ = repeatedTypeStream.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\",\"type\":\"function\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]}}]}"))
        let _ = repeatedTypeStream.push(event("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"type\":\"function\"}]}}]}"))
        let _ = repeatedTypeStream.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}"))
        let _ = repeatedTypeStream.push(event("[DONE]"))
    }

    @TestCase
    func t051PayloadEnumsHeadersAndRequirementsCoverEverySemanticBranch() {
        let requirementStates = [
            LlmWireRequirementState.Satisfied,
            LlmWireRequirementState.Unsatisfied("a"),
            LlmWireRequirementState.Unsatisfied("b"),
            LlmWireRequirementState.Unknown("a"),
            LlmWireRequirementState.Unknown("b")
        ]
        for (left in 0..requirementStates.size) {
            for (right in 0..requirementStates.size) {
                @Expect(requirementStates[left] == requirementStates[right], left == right)
            }
        }
        let thinkingModes = [
            LlmWireThinkingMode.ProviderDefault,
            LlmWireThinkingMode.Disabled,
            LlmWireThinkingMode.Enabled,
            LlmWireThinkingMode.Budget(1),
            LlmWireThinkingMode.Budget(2),
            LlmWireThinkingMode.Adaptive
        ]
        for (left in 0..thinkingModes.size) {
            for (right in 0..thinkingModes.size) {
                @Expect(thinkingModes[left] == thinkingModes[right], left == right)
            }
        }
        let tiers = [
            LlmWireServiceTier.ProviderDefault, LlmWireServiceTier.Auto, LlmWireServiceTier.Default,
            LlmWireServiceTier.StandardOnly, LlmWireServiceTier.Flex, LlmWireServiceTier.Priority,
            LlmWireServiceTier.Fast, LlmWireServiceTier.Ultrafast
        ]
        for (left in 0..tiers.size) { for (right in 0..tiers.size) { @Expect(tiers[left] == tiers[right], left == right) } }
        let scopes = [LlmWireNativeReplayScope.AssistantTurn, LlmWireNativeReplayScope.Conversation]
        for (left in 0..scopes.size) { for (right in 0..scopes.size) { @Expect(scopes[left] == scopes[right], left == right) } }
        let messagePhases = [MessagesStreamPhase.AwaitingMessageStart, MessagesStreamPhase.AcceptingBlocks, MessagesStreamPhase.AcceptingMessageDeltas]
        for (left in 0..messagePhases.size) { for (right in 0..messagePhases.size) { @Expect(messagePhases[left] == messagePhases[right], left == right) } }

        @Expect(LlmWireHeader("X-Test", " value ").name, "x-test")
        @Expect(LlmWireHeader("!#$%&'*+-.^_`|~", "\tvalue").value, "value")
        for (invalid in ["", "bad name", "bad:name", "bad\u{007f}", "bad\u{0001}"]) {
            expectLlmError("llm.header_invalid", { => let _ = LlmWireHeader(invalid, "x") })
        }
        for (invalidValue in ["bad\rvalue", "bad\nvalue", "bad\u{0001}value", "bad\u{007f}value"]) {
            expectLlmError("llm.header_invalid", { => let _ = LlmWireHeader("x-test", invalidValue) })
        }
        let merged = LlmWirePreparedRequest("{}", requiredHeaders: [
            LlmWireHeader("anthropic-beta", "one,, two"), LlmWireHeader("x-test", "same")
        ]).mergeHeadersForTest([
            LlmWireHeader("Anthropic-Beta", "two,three"), LlmWireHeader("X-Test", "same")
        ])
        @Expect(merged[0].value, "one,two,three")
        expectLlmError("llm.required_header_conflict", { => let _ = LlmWirePreparedRequest(
            "{}", requiredHeaders: [LlmWireHeader("x-test", "one")]
        ).mergeHeadersForTest([LlmWireHeader("x-test", "two")]) })

        LlmWirePreparedRequest("{}", featureRequirements: [
            LlmWireFeatureRequirement("ready", LlmWireRequirementState.Satisfied),
            LlmWireFeatureRequirement("resolve", LlmWireRequirementState.Unknown("resolve me"))
        ]).validateForSend(Some(SatisfiedRequirementResolver()))
        expectLlmError("llm.feature_requirement_unsatisfied", { => LlmWirePreparedRequest(
            "{}", featureRequirements: [LlmWireFeatureRequirement("blocked", LlmWireRequirementState.Unsatisfied("blocked"))]
        ).validateForSend(Some(SatisfiedRequirementResolver())) })
        expectLlmError("llm.feature_requirement_unresolved", { => LlmWirePreparedRequest(
            "{}", featureRequirements: [LlmWireFeatureRequirement("unknown", LlmWireRequirementState.Unknown("unknown"))]
        ).validateForSend(Some(UnknownRequirementResolver())) })
    }

    @TestCase
    func t052DialectContractMatrixRejectsEveryUnrepresentableDeclaration() {
        for (invalidId in ["", "UPPER", "bad/id", "bad id", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]) {
            expectIllegalArgument({ => let _ = LlmWireDialectContract(
                invalidId, LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens
            ) })
        }
        expectIllegalArgument({ => let _ = LlmWireDialectContract(
            "test.bad.protocol", LlmWireProtocol.Messages, LlmWireRequestStyle.OpenAiResponses, LlmWireOutputTokenField.MaxOutputTokens
        ) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract(
            "test.bad.token", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.DeepSeekChat, LlmWireOutputTokenField.MaxCompletionTokens
        ) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract(
            "test.bad.parallel", LlmWireProtocol.Messages, LlmWireRequestStyle.AnthropicMessages, LlmWireOutputTokenField.MaxTokens,
            parallelToolStyle: LlmWireParallelToolStyle.OpenAiTopLevel
        ) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract(
            "test.bad.cache", LlmWireProtocol.Messages, LlmWireRequestStyle.AnthropicMessages, LlmWireOutputTokenField.MaxTokens,
            promptCacheStyle: LlmWirePromptCacheStyle.OpenAi
        ) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract(
            "test.bad.cache.life", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens,
            promptCacheStyle: LlmWirePromptCacheStyle.Unsupported, promptCacheLifetimes: [LlmWirePromptCacheLifetime.ProviderDefault]
        ) })
        for (lifetime in [LlmWirePromptCacheLifetime.FiveMinutes, LlmWirePromptCacheLifetime.OneHour, LlmWirePromptCacheLifetime.TwentyFourHours]) {
            expectIllegalArgument({ => let _ = LlmWireDialectContract(
                "test.bad.openai.life", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens,
                promptCacheStyle: LlmWirePromptCacheStyle.OpenAi, promptCacheLifetimes: [lifetime]
            ) })
        }
        expectIllegalArgument({ => let _ = LlmWireDialectContract(
            "test.bad.routing", LlmWireProtocol.Messages, LlmWireRequestStyle.AnthropicMessages, LlmWireOutputTokenField.MaxTokens,
            promptCacheRoutingKey: true
        ) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract(
            "test.bad.tier", LlmWireProtocol.Messages, LlmWireRequestStyle.DeepSeekMessages, LlmWireOutputTokenField.MaxTokens,
            serviceTiers: [LlmWireServiceTier.Auto]
        ) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract(
            "test.bad.speed", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens,
            generationSpeeds: [LlmWireGenerationSpeed.Fast]
        ) })
        for (mode in [LlmWireStructuredOutputMode.JsonSchema, LlmWireStructuredOutputMode.JsonObject]) {
            expectIllegalArgument({ => let _ = LlmWireDialectContract(
                "test.bad.structured", LlmWireProtocol.Messages, LlmWireRequestStyle.DeepSeekMessages, LlmWireOutputTokenField.MaxTokens,
                structuredOutputModes: [mode]
            ) })
        }
        for (control in [LlmWireThinkingMode.Disabled, LlmWireThinkingMode.Enabled, LlmWireThinkingMode.Budget(1), LlmWireThinkingMode.Adaptive]) {
            expectIllegalArgument({ => let _ = LlmWireDialectContract(
                "test.bad.thinking", LlmWireProtocol.Responses, LlmWireRequestStyle.OpenAiResponses, LlmWireOutputTokenField.MaxOutputTokens,
                thinkingModes: [control]
            ) })
        }
        expectIllegalArgument({ => let _ = LlmWireInputCapabilities(modalities: [LlmWireInputModality.Text, LlmWireInputModality.Text]) })
        expectIllegalArgument({ => let _ = LlmWireThinkingCapabilities(modes: [LlmWireThinkingMode.Disabled, LlmWireThinkingMode.Disabled]) })
        expectIllegalArgument({ => let _ = LlmWireThinkingCapabilities(efforts: [LlmWireReasoningEffort.Low, LlmWireReasoningEffort.Low]) })
        expectIllegalArgument({ => let _ = LlmWireOutputCapabilities(structuredModes: [LlmWireStructuredOutputMode.Text, LlmWireStructuredOutputMode.Text]) })
        expectIllegalArgument({ => let _ = LlmWireOutputCapabilities(serviceTiers: [LlmWireServiceTier.Auto, LlmWireServiceTier.Auto]) })
        expectIllegalArgument({ => let _ = LlmWireOutputCapabilities(generationSpeeds: [LlmWireGenerationSpeed.Fast, LlmWireGenerationSpeed.Fast]) })
        expectIllegalArgument({ => let _ = LlmWireCacheCapabilities(lifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.ProviderDefault]) })
        expectIllegalArgument({ => let _ = LlmWireToolCapabilities(parallelCalls: true) })
    }

    @TestCase
    func t053RequestDescriptorHelpersAndOptionMappingsAreExhaustive() {
        @Expect(outputTokenName(LlmWireOutputTokenField.MaxOutputTokens), "max_output_tokens")
        @Expect(outputTokenName(LlmWireOutputTokenField.MaxCompletionTokens), "max_completion_tokens")
        @Expect(outputTokenName(LlmWireOutputTokenField.MaxTokens), "max_tokens")
        for ((tier, name) in [
            (LlmWireServiceTier.ProviderDefault, ""), (LlmWireServiceTier.Auto, "auto"),
            (LlmWireServiceTier.Default, "default"), (LlmWireServiceTier.StandardOnly, "standard_only"),
            (LlmWireServiceTier.Flex, "flex"), (LlmWireServiceTier.Priority, "priority"),
            (LlmWireServiceTier.Fast, "fast"), (LlmWireServiceTier.Ultrafast, "ultrafast")
        ]) { @Expect(serviceTierName(tier), name) }
        for ((speed, name) in [
            (LlmWireGenerationSpeed.ProviderDefault, ""), (LlmWireGenerationSpeed.Standard, "standard"), (LlmWireGenerationSpeed.Fast, "fast")
        ]) { @Expect(generationSpeedName(speed), name) }
        for ((lifetime, name) in [
            (LlmWirePromptCacheLifetime.ProviderDefault, ""), (LlmWirePromptCacheLifetime.FiveMinutes, "5m"),
            (LlmWirePromptCacheLifetime.ThirtyMinutes, "30m"), (LlmWirePromptCacheLifetime.OneHour, "1h"),
            (LlmWirePromptCacheLifetime.TwentyFourHours, "24h")
        ]) { @Expect(cacheLifetimeName(lifetime), name) }
        let capabilities = allCapabilities()
        let openAi = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: capabilities)
        for (tier in [LlmWireServiceTier.Auto, LlmWireServiceTier.Default, LlmWireServiceTier.Flex, LlmWireServiceTier.Priority, LlmWireServiceTier.Fast, LlmWireServiceTier.Ultrafast]) {
            @Expect(openAi.encodeRequest(LlmWireRequest("m", validMessages(), serviceTier: tier)).contains("service_tier"), true)
        }
        for (choice in [LlmWireToolChoice.Auto, LlmWireToolChoice.NoTools, LlmWireToolChoice.Required]) {
            @Expect(openAi.encodeRequest(LlmWireRequest(
                "m", validMessages(), tools: [LlmWireTool("lookup", "lookup", testJson("{}"))], toolChoice: choice
            )).contains("tool_choice"), true)
        }
        @Expect(openAi.encodeRequest(LlmWireRequest(
            "m", validMessages(), tools: [LlmWireTool("lookup", "lookup", testJson("{}"))],
            parallelToolCalls: Some(false), promptCacheRoutingKey: Some("route"),
            promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ThirtyMinutes)
        )).contains("prompt_cache_options"), true)
        let automatic = openAi.encodeRequest(LlmWireRequest(
            "m", validMessages(), promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault)
        ))
        automatic.validateForSend(Some(SatisfiedRequirementResolver()))
        let schema = LlmWireJsonSchema("answer", testJson("{}"), description: "desc", strict: false)
        for (format in [LlmWireStructuredOutput.Text, LlmWireStructuredOutput.JsonObject, LlmWireStructuredOutput.JsonSchema(schema)]) {
            @Expect(openAi.encodeRequest(LlmWireRequest("m", validMessages(), structuredOutput: format)).contains("format"), true)
        }
        let anthropic = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect(), capabilities: capabilities)
        for (speed in [LlmWireGenerationSpeed.Standard, LlmWireGenerationSpeed.Fast]) {
            let plan = anthropic.encodeRequest(LlmWireRequest("m", validMessages(), maxOutputTokens: Some(8), generationSpeed: speed))
            @Expect(plan.contains("speed"), true)
        }
        for (lifetime in [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.FiveMinutes, LlmWirePromptCacheLifetime.OneHour]) {
            @Expect(anthropic.encodeRequest(LlmWireRequest(
                "m", validMessages(), maxOutputTokens: Some(8), promptCache: LlmWirePromptCache.Automatic(lifetime)
            )).contains("cache_control"), true)
        }
        for (parallel in [true, false]) {
            @Expect(anthropic.encodeRequest(LlmWireRequest(
                "m", validMessages(), tools: [LlmWireTool("lookup", "lookup", testJson("{}"))],
                maxOutputTokens: Some(8), parallelToolCalls: Some(parallel)
            )).contains("disable_parallel_tool_use"), true)
        }
        let deepSeek = LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect(), capabilities: capabilities)
        deepSeek.encodeRequest(LlmWireRequest(
            "m", validMessages(), promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault)
        )).validateForSend(Some(SatisfiedRequirementResolver()))
        let unsupportedCache = LlmWireCodec(LlmWireProtocol.ChatCompletions, TestStandardDialect(LlmWireDialectContract(
            "test.no.cache", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens
        )))
        expectLlmError("llm.cache_unsupported", { => encodePromptCache(
            unsupportedCache, wireJsonObject([]), LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault), ArrayList<LlmWireFeatureRequirement>()
        ) })
    }

    @TestCase
    func t054AssemblerUsageAndNativeReplayInputDomainsAreClosed() {
        @Expect(mergeUsageValue(None, None, LlmWireUsageMergeStyle.ReplacePresent), None)
        @Expect(mergeUsageValue(Some(1), None, LlmWireUsageMergeStyle.Monotonic), Some(1))
        @Expect(mergeUsageValue(None, Some(2), LlmWireUsageMergeStyle.Monotonic), Some(2))
        @Expect(mergeUsageValue(Some(1), Some(2), LlmWireUsageMergeStyle.Monotonic), Some(2))
        @Expect(mergeUsageValue(None, Some(2), LlmWireUsageMergeStyle.Delta), Some(2))
        @Expect(mergeUsageValue(Some(1), Some(2), LlmWireUsageMergeStyle.Delta), Some(3))
        @Expect(mergeUsageValue(Some(1), Some(2), LlmWireUsageMergeStyle.ReplacePresent), Some(2))
        expectLlmError("llm.usage_decreased", { => let _ = mergeUsageValue(Some(2), Some(1), LlmWireUsageMergeStyle.Monotonic) })
        expectLlmError("llm.usage_overflow", { => let _ = mergeUsageValue(Some(Int64.Max), Some(1), LlmWireUsageMergeStyle.Delta) })
        let mergedUsage = mergeWireUsage(
            LlmWireUsage(inputTokens: Some(1), outputTokens: Some(1), reasoningTokens: Some(1), cacheReadTokens: Some(1), cacheWriteTokens: Some(1)),
            LlmWireUsage(inputTokens: Some(2), outputTokens: Some(2), reasoningTokens: Some(2), cacheReadTokens: Some(2), cacheWriteTokens: Some(2)),
            LlmWireUsageMergeStyle.ReplacePresent
        )
        @Expect(mergedUsage.cacheWriteTokens, Some(2))
        @Expect(mergeWireUsage(
            LlmWireUsage(serviceTier: Some("standard")), LlmWireUsage(), LlmWireUsageMergeStyle.ReplacePresent
        ).serviceTier, Some("standard"))
        @Expect(mergeWireUsage(
            LlmWireUsage(serviceTier: Some("standard")), LlmWireUsage(serviceTier: Some("priority")), LlmWireUsageMergeStyle.ReplacePresent
        ).serviceTier, Some("priority"))

        let diagnosticTool = LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("", "bad name", LlmWireToolArguments.Partial("{")))
        @Expect(assembleCanonicalReply("", "", [diagnosticTool], LlmWireUsage(), "length", requireExecutableToolCalls: false).blocks.size, 1)
        expectLlmError("llm.tool_arguments_shape_invalid", { => let _ = assembleCanonicalReply(
            "", "", [LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock(
                "call", "tool", LlmWireToolArguments.Complete(testJson("[]"))
            ))], LlmWireUsage(), "tool_calls"
        ) })
        expectLlmError("llm.tool_stop_without_call", { => validateReplyToolStop(LlmWireReply(), "tool_calls", "tool_calls", ["stop"]) })
        expectLlmError("llm.tool_call_stop_mismatch", { => validateReplyToolStop(
            LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Complete(testJson("{}"))))]),
            "stop", "tool_calls", ["stop"]
        ) })
        validateReplyToolStop(LlmWireReply(), "stop", "tool_calls", ["stop"])
        validateReplyToolStop(
            LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("c", "f", LlmWireToolArguments.Complete(testJson("{}"))))]),
            "tool_calls", "tool_calls", ["stop"]
        )

        let validThinking = parseWireJson("{\"type\":\"thinking\",\"thinking\":\"why\",\"signature\":\"sig\"}")
        let partialReplay = nativeReplayFromPayload(
            LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking", validThinking,
            completion: LlmWireOpaqueCompletion.Partial
        )
        expectLlmError("llm.native_replay_incomplete", { => let _ = assembleCanonicalReply(
            "", "", [LlmWireOutputBlock.NativeReplay(partialReplay)], LlmWireUsage(), "end_turn"
        ) })
        @Expect(assembleCanonicalReply(
            "", "", [LlmWireOutputBlock.NativeReplay(partialReplay)], LlmWireUsage(), "max_tokens",
            requireExecutableToolCalls: false
        ).blocks.size, 1)
        let opaque = LlmWireOpaqueBlock("future", parseWireJson("{}"))
        @Expect(opaque.payload().wireKind, WireJsonKind.Object)
        expectLlmError("llm.opaque_payload_invalid", { => let _ = LlmWireOpaqueBlock("", parseWireJson("{}")) })
        expectLlmError("llm.opaque_payload_invalid", { => let _ = LlmWireOpaqueBlock("future", parseWireJson("[]")) })

        expectLlmError("llm.native_replay_payload_invalid", { => let _ = nativeReplayFromPayload(LlmWireProtocol.Messages, "", "thinking", validThinking) })
        expectLlmError("llm.native_replay_payload_invalid", { => let _ = nativeReplayFromPayload(LlmWireProtocol.Messages, "anthropic.messages.v1", "", validThinking) })
        expectLlmError("llm.native_replay_payload_invalid", { => let _ = nativeReplayFromPayload(LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking", validThinking, schemaVersion: 2) })
        expectLlmError("llm.native_replay_payload_invalid", { => let _ = nativeReplayFromPayload(LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking", validThinking, assistantTurnIndex: 1) })
        expectLlmError("llm.native_replay_payload_invalid", { => let _ = nativeReplayFromPayload(LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking", validThinking, blockOrder: -1) })
        expectLlmError("llm.native_replay_payload_invalid", { => let _ = nativeReplayFromPayload(LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking", parseWireJson("[]")) })
        expectLlmError("llm.native_replay_scope_unsupported", { => let _ = nativeReplayFromPayload(
            LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking", validThinking, scope: LlmWireNativeReplayScope.Conversation
        ) })
        expectLlmError("llm.native_replay_type_missing", { => let _ = nativeReplayFromPayload(
            LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking", parseWireJson("{\"thinking\":\"why\",\"signature\":\"sig\"}")
        ) })
        expectLlmError("llm.native_replay_type_mismatch", { => let _ = nativeReplayFromPayload(
            LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking", parseWireJson("{\"type\":1,\"thinking\":\"why\",\"signature\":\"sig\"}")
        ) })
        expectLlmError("llm.native_replay_type_mismatch", { => let _ = nativeReplayFromPayload(
            LlmWireProtocol.Messages, "anthropic.messages.v1", "thinking", parseWireJson("{\"type\":\"other\",\"thinking\":\"why\",\"signature\":\"sig\"}")
        ) })
        expectLlmError("llm.native_replay_payload_invalid", { => let _ = nativeReplayFromPayload(
            LlmWireProtocol.Responses, "openai.responses.v1", "reasoning", parseWireJson("{\"type\":\"reasoning\",\"id\":\"r\"}")
        ) })
        expectLlmError("llm.field_type_invalid", { => let _ = nativeReplayFromPayload(
            LlmWireProtocol.Responses, "openai.responses.v1", "reasoning", parseWireJson("{\"type\":\"reasoning\",\"id\":\"r\",\"summary\":{}}")
        ) })
        expectLlmError("llm.field_type_invalid", { => let _ = nativeReplayFromPayload(
            LlmWireProtocol.Responses, "openai.responses.v1", "reasoning", parseWireJson("{\"type\":\"reasoning\",\"id\":\"r\",\"content\":{}}")
        ) })
    }

    @TestCase
    func t055TransportPrimitiveBranchesAreBoundedAndDeterministic() {
        for (limits in [
            (0, 1, 1, 1, 1), (1, 0, 1, 1, 1), (1, 1, 0, 1, 1),
            (1, 1, 1, 0, 1), (1, 1, 1, 1, 0)
        ]) {
            expectIllegalArgument({ => let _ = SseDecoder(
                maxEventBytes: limits[0], maxLineBytes: limits[1], maxBufferedBytes: limits[2],
                maxEventsPerPush: limits[3], maxOutputBytesPerPush: limits[4]
            ) })
        }
        let grammar = SseDecoder(maxEventBytes: 512)
        match (grammar.push(": heartbeat\rdata:first\rdata: second\nevent\nid: ok\nretry: 7\r\r")) {
            case LlmWireResult.Ok(values) => @Expect(values.size, 0)
            case _ => @Fail("mixed SSE grammar must decode")
        }
        match (grammar.finish()) {
            case LlmWireResult.Ok(values) => @Expect(values.size, 1); @Expect(values[0].data, "first\nsecond"); @Expect(values[0].retryMillis, Some(7))
            case _ => @Fail("SSE finish")
        }
        let finishEvent = SseDecoder(maxOutputBytesPerPush: 16)
        let _ = finishEvent.push("data: x\r\r")
        match (finishEvent.finish()) { case LlmWireResult.Ok(values) => @Expect(values.size, 1); case _ => @Fail("trailing CR must dispatch") }
        let outputBytes = SseDecoder(maxOutputBytesPerPush: 1)
        match (outputBytes.push("data: xx\n\n")) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_output_bytes_too_large"); case _ => @Fail("output bytes limit") }
        match (outputBytes.finish()) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_failed"); case _ => @Fail("failed finish") }

        @Expect(parseUnsignedDecimal("0"), Some(0)); @Expect(parseUnsignedDecimal("-1"), None)
        @Expect(parseUnsignedDecimal("a"), None); @Expect(parseUnsignedDecimal("١"), None)
        @Expect(extractRetryAfterMillis("x: 1\nRetry-After: bad", 0), None)
        @Expect(extractRetryAfterMillis("Retry-After: 1\r\nretry-after: 2", 0), Some(2000))
        @Expect(sseDataLine("data:"), Some("")); @Expect(sseDataLine("data:x"), Some("x"))

        @Expect(parseImfDate("01 Jan 2024 00:00:00 UTC"), None)
        @Expect(parseImfDate("01 Jan 2024"), None)
        @Expect(parseRfc850Date("06-Nov-94 08:49:37 UTC", 0), None)
        @Expect(parseRfc850Date("06/Nov/94 08:49:37 GMT", 0), None)
        @Expect(parseRfc850Date("06-Nov--1 08:49:37 GMT", 0), None)
        @Expect(parseRfc850Date("06-Nov-100 08:49:37 GMT", 0), None)
        @Expect(parseAsctimeDate("Sun Nov 6 08:49:37"), None)
        for ((year, month, day, clock) in [
            (1969, 1, 1, "00:00:00"), (10000, 1, 1, "00:00:00"),
            (2024, 0, 1, "00:00:00"), (2024, 13, 1, "00:00:00"),
            (2024, 1, 0, "00:00:00"), (2023, 2, 29, "00:00:00"),
            (2024, 1, 1, "00:00"), (2024, 1, 1, "-1:00:00"),
            (2024, 1, 1, "24:00:00"), (2024, 1, 1, "00:-1:00"),
            (2024, 1, 1, "00:60:00"), (2024, 1, 1, "00:00:-1"),
            (2024, 1, 1, "00:00:60")
        ]) { @Expect(dateEpochMillis(year, month, day, clock), None) }
        @Expect(dateEpochMillis(1970, 1, 1, "00:00:00"), Some(0))
        @Expect(dateEpochMillis(2000, 2, 29, "23:59:59").isSome(), true)
        @Expect(yearAtEpochMillis(-1), 1970); @Expect(yearAtEpochMillis(0), 1970)
        @Expect(yearAtEpochMillis(951782400000), 2000); @Expect(yearAtEpochMillis(978307200000), 2001)
        for ((year, leap) in [(1900, false), (2000, true), (2004, true), (2001, false)]) { @Expect(isLeapYear(year), leap) }
        @Expect(daysInMonth(2024, 2), 29); @Expect(daysInMonth(2023, 2), 28)
        for (month in [4, 6, 9, 11]) { @Expect(daysInMonth(2024, month), 30) }
        @Expect(daysInMonth(2024, 1), 31)
    }

    @TestCase
    func t056ValidationPredicatesCoverIndependentCapabilityAndShapeFailures() {
        let full = allCapabilities()
        let openAi = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: full)
        let noCapabilities = LlmWireCapabilities()
        let limited = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: noCapabilities)
        @Expect(supportedDeepSeekImageMediaType("image/jpeg"), true)
        @Expect(supportedDeepSeekImageMediaType("image/png"), true)
        @Expect(supportedDeepSeekImageMediaType("image/gif"), true)
        @Expect(supportedDeepSeekImageMediaType("image/webp"), true)
        @Expect(supportedDeepSeekImageMediaType("image/bmp"), false)
        for (name in ["A", "z", "0", "_", "-", "Az09_-"]) { @Expect(validToolName(name), true) }
        for (name in ["", "bad name", "bad.", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]) { @Expect(validToolName(name), false) }
        @Expect(messageHasContent(LlmWireMessage(LlmWireRole.User, [])), false)
        @Expect(messageHasContent(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(""))])), false)
        @Expect(messageHasContent(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("x"))])), true)

        for (control in [
            LlmWireThinkingMode.ProviderDefault, LlmWireThinkingMode.Disabled, LlmWireThinkingMode.Enabled,
            LlmWireThinkingMode.Budget(1024), LlmWireThinkingMode.Adaptive
        ]) { @Expect(supportsThinkingMode([control], control), true) }
        @Expect(supportsThinkingMode([LlmWireThinkingMode.Disabled], LlmWireThinkingMode.Enabled), false)
        @Expect(supportsThinkingMode([], LlmWireThinkingMode.Disabled), false)
        @Expect(supportsReasoningEffort([LlmWireReasoningEffort.Low], LlmWireReasoningEffort.Low), true)
        @Expect(supportsReasoningEffort([LlmWireReasoningEffort.Low], LlmWireReasoningEffort.High), false)
        @Expect(supportsStructuredMode([LlmWireStructuredOutputMode.Text], LlmWireStructuredOutputMode.Text), true)
        @Expect(supportsStructuredMode([], LlmWireStructuredOutputMode.Text), false)

        expectLlmError("llm.reasoning_effort_unsupported", { => limited.encodeRequest(LlmWireRequest("m", validMessages(), reasoningEffort: LlmWireReasoningEffort.Low)) })
        let effortOnly = LlmWireCapabilities(thinking: LlmWireThinkingCapabilities(efforts: [LlmWireReasoningEffort.High]))
        expectLlmError("llm.reasoning_effort_unsupported", { => LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect(), capabilities: effortOnly).encodeRequest(
            LlmWireRequest("m", validMessages(), reasoningEffort: LlmWireReasoningEffort.Low)
        ) })
        expectLlmError("llm.structured_output_unsupported", { => limited.encodeRequest(LlmWireRequest("m", validMessages(), structuredOutput: LlmWireStructuredOutput.Text)) })
        expectLlmError("llm.service_tier_unsupported", { => limited.encodeRequest(LlmWireRequest("m", validMessages(), serviceTier: LlmWireServiceTier.Auto)) })
        expectLlmError("llm.prompt_cache_routing_key_invalid", { => openAi.encodeRequest(LlmWireRequest("m", validMessages(), promptCacheRoutingKey: Some(""))) })
        expectLlmError("llm.cache_lifetime_unsupported", { => limited.encodeRequest(LlmWireRequest(
            "m", validMessages(), promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ThirtyMinutes)
        )) })
        for (block in [
            LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, " ")),
            LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Base64, "", mediaType: "image/png")),
            LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Base64, "x", mediaType: "")),
            LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Base64, "x", mediaType: "image")),
            LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.File, " "))
        ]) { try { validateBlockShape(block); @Fail("invalid image shape") } catch (_: LlmWireError) { () } }
        validateBlockShape(LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "https://example.invalid")))
        validateBlockShape(LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Base64, "x", mediaType: "image/png")))
        validateBlockShape(LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.File, "file-1")))
    }

    @TestCase
    func t057ResponsesContentLifecyclesReconcileWithoutSemanticLoss() {
        let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        let text = codec.newStreamDecoder()
        let _ = text.push(event("{\"type\":\"response.created\",\"response\":{\"id\":\"r\",\"model\":\"m\"}}"))
        let _ = text.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"message\"}}"))
        let _ = text.push(event("{\"type\":\"response.content_part.added\",\"item_id\":\"i\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\"}}"))
        let _ = text.push(event("{\"type\":\"response.output_text.delta\",\"item_id\":\"i\",\"output_index\":0,\"content_index\":0,\"delta\":\"ok\"}"))
        let _ = text.push(event("{\"type\":\"response.output_text.done\",\"item_id\":\"i\",\"output_index\":0,\"content_index\":0,\"text\":\"ok\"}"))
        let completed = text.push(event("{\"type\":\"response.content_part.done\",\"item_id\":\"i\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"ok\"}}"))
        match (completed.events[0]) { case LlmWireEvent.ContentBlockCompleted(LlmWireStreamBlockKind.Text, _) => (); case _ => @Fail("text block completion") }
        let _ = text.push(event("{\"type\":\"response.output_item.done\",\"item_id\":\"i\",\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"message\"}}"))
        let textTerminal = text.push(event("{\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"model\":\"m\",\"status\":\"completed\",\"output\":[{\"id\":\"i\",\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}}"))
        @Expect(succeededReply(textTerminal).blocks.size, 1)

        let refusal = codec.newStreamDecoder()
        let _ = refusal.push(event("{\"type\":\"response.created\",\"response\":{}}"))
        let _ = refusal.push(event("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"message\"}}"))
        let _ = refusal.push(event("{\"type\":\"response.content_part.added\",\"item_id\":\"i\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"refusal\",\"refusal\":\"\"}}"))
        let _ = refusal.push(event("{\"type\":\"response.refusal.delta\",\"item_id\":\"i\",\"output_index\":0,\"content_index\":0,\"delta\":\"no\"}"))
        let _ = refusal.push(event("{\"type\":\"response.refusal.done\",\"item_id\":\"i\",\"output_index\":0,\"content_index\":0,\"text\":\"no\"}"))
        let _ = refusal.push(event("{\"type\":\"response.content_part.done\",\"item_id\":\"i\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"refusal\",\"refusal\":\"no\"}}"))
        let _ = refusal.push(event("{\"type\":\"response.output_item.done\",\"item_id\":\"i\",\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"message\"}}"))
        let refusalTerminal = refusal.push(event("{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"id\":\"i\",\"type\":\"message\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"no\"}]}]}}"))
        @Expect(succeededReply(refusalTerminal).blocks.size, 1)

        @Expect(responsesEventMatchesTerminal("response.completed", LlmWireTerminal.Completed(LlmWireReply())), true)
        let incompleteReply = replyWithChoiceOutcome(LlmWireReply(), LlmWireChoiceOutcome.Incomplete(LlmWireIncompleteReason.Other("x")))
        @Expect(responsesEventMatchesTerminal("response.incomplete", LlmWireTerminal.Completed(incompleteReply)), true)
        @Expect(responsesEventMatchesTerminal("response.failed", LlmWireTerminal.ProviderFailed(LlmWireFailure(LlmWireFailureKind.ProviderError, "x"))), true)
        @Expect(responsesEventMatchesTerminal("response.completed", LlmWireTerminal.Completed(incompleteReply)), false)
    }

    @TestCase
    func t058PublicJsonAndNamedCodecFactoriesHideProviderInternals() {
        let parsed = match (LlmWireJson.parse("{\"n\":1.00,\"items\":[true,null]}")) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(error) => throw error
        }
        @Expect(parsed.kind, LlmWireJsonKind.Object)
        @Expect(parsed.field("n").getOrThrow().numberLiteral(), Some("1.00"))
        @Expect(parsed.field("items").getOrThrow().values().size, 2)
        @Expect(parsed.stringify(), "{\"n\":1.00,\"items\":[true,null]}")

        match (LlmWireJson.number("[]")) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.json_number_invalid")
            case _ => @Fail("non-number JSON must be rejected")
        }
        match (LlmWireJson.object([
            LlmWireJsonField("x", LlmWireJson.boolean(true)),
            LlmWireJsonField("x", LlmWireJson.nullValue())
        ])) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.json_duplicate_key")
            case _ => @Fail("duplicate object members must be rejected")
        }

        let profile = openAiResponsesModelProfile("model-a")
        let codec = openAiResponsesCodec(profile)
        @Expect(codec.protocol, LlmWireProtocol.Responses)
        @Expect(codec.dialect.compatibilityId, "openai.responses.v1")
        @Expect(codec.encodeRequest(LlmWireRequest("model-a", validMessages())).contains("model-a"), true)
        expectLlmError("llm.model_profile_mismatch", { =>
            codec.encodeRequest(LlmWireRequest("model-b", validMessages()))
        })
        expectLlmError("llm.model_profile_dialect_mismatch", { =>
            openAiChatCodec(profile)
        })
    }

    @TestCase
    func t059CodecBuilderKeepsInstructionsOrderedAndStreamingOperational() {
        let codec = openAiChatCodec(openAiChatModelProfile("model-a"))
        let builder = codec.newRequestBuilder()
        builder.addInstruction(LlmWireInstructionRole.System, "system-first")
        builder.addInstruction(LlmWireInstructionRole.Developer, "developer-second")
        builder.addMessage(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello-third"))]))
        let request = match (builder.build()) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(error) => throw error
        }
        let fixed = codec.encodeRequest(request)
        let streamed = codec.encodeRequest(request, streaming: true)
        @Expect(fixed.contains("\"stream\""), false)
        @Expect(streamed.contains("\"stream\":true"), true)
        let systemAt = fixed.indexOf("system-first").getOrThrow()
        let developerAt = fixed.indexOf("developer-second").getOrThrow()
        let userAt = fixed.indexOf("hello-third").getOrThrow()
        @Expect(systemAt < developerAt && developerAt < userAt, true)

        builder.reset()
        match (builder.build()) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.chat_messages_required")
            case _ => @Fail("reset builder must validate the empty aggregate")
        }

        let messages = anthropicMessagesCodec(anthropicMessagesModelProfile("claude"))
        let unsupported = messages.newRequestBuilder()
        unsupported.addInstruction(LlmWireInstructionRole.Developer, "developer")
        unsupported.addMessage(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello"))]))
        unsupported.setMaxOutputTokens(Some(32))
        match (unsupported.build()) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.developer_instruction_unsupported")
            case _ => @Fail("Messages must reject developer instructions")
        }
    }

    @TestCase
    func t060ToolResultsKeepTypedTextAndImageContentAcrossDialects() {
        let call = LlmWireBlock.ToolCall(LlmWireToolCallBlock(
            "call-1", "inspect", LlmWireToolArguments.Complete(testJson("{}"))
        ))
        let result = LlmWireBlock.ToolResult(LlmWireToolResultBlock("call-1", [
            LlmWireToolResultContent.Text(LlmWireTextBlock("visible result")),
            LlmWireToolResultContent.Image(LlmWireImageBlock(LlmWireImageSourceKind.File, "file-1"))
        ]))
        let history = [
            LlmWireMessage(LlmWireRole.Assistant, [call]),
            LlmWireMessage(LlmWireRole.User, [result])
        ]
        let tool = LlmWireTool("inspect", "inspect an image", testJson("{}"))

        let responses = openAiResponsesCodec(openAiResponsesModelProfile("model", capabilities: allCapabilities()))
        let responsesBody = responses.encodeRequest(LlmWireRequest("model", history, tools: [tool])).bodyText()
        for (needle in ["function_call_output", "visible result", "input_image", "file-1"]) {
            @Expect(responsesBody.contains(needle), true)
        }

        let openAiChat = openAiChatCodec(openAiChatModelProfile("model", capabilities: allCapabilities()))
        let openAiBody = openAiChat.encodeRequest(LlmWireRequest("model", history, tools: [tool])).bodyText()
        @Expect(openAiBody.contains("\"file\":{\"file_id\":\"file-1\"}"), true)

        let deepSeekChat = deepSeekChatCodec(deepSeekChatModelProfile("model", capabilities: allCapabilities()))
        let deepSeekBody = deepSeekChat.encodeRequest(LlmWireRequest("model", history, tools: [tool])).bodyText()
        @Expect(deepSeekBody.contains("\"type\":\"file\",\"file_id\":\"file-1\""), true)

        let messages = anthropicMessagesCodec(anthropicMessagesModelProfile("model", capabilities: allCapabilities()))
        let messagesPlan = messages.encodeRequest(LlmWireRequest("model", history, tools: [tool], maxOutputTokens: Some(128)))
        @Expect(messagesPlan.bodyText().contains("\"type\":\"tool_result\""), true)
        @Expect(messagesPlan.bodyText().contains("\"type\":\"file\",\"file_id\":\"file-1\""), true)
        @Expect(messagesPlan.requiredHeadersForTest()[0].value, "files-api-2025-04-14")
    }

    @TestCase
    func t061PreparedRequestsAndHttpResponsesCloseTheTransportBoundary() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let prepared = codec.encodeRequest(LlmWireRequest("model", validMessages()), streaming: true)
        let materialized = match (prepared.materialize(userHeaders: [LlmWireHeader("authorization", "Bearer token")])) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(error) => throw error
        }
        @Expect(String.fromUtf8(materialized.body).contains("\"stream\":true"), true)
        @Expect(headerValue(materialized.headers, "content-type"), "application/json")
        @Expect(headerValue(materialized.headers, "accept"), "text/event-stream")
        @Expect(headerValue(materialized.headers, "authorization"), "Bearer token")

        let requiring = anthropicMessagesCodec(anthropicMessagesModelProfile("claude", capabilities: allCapabilities()))
            .encodeRequest(LlmWireRequest("claude", validMessages(), maxOutputTokens: Some(32), generationSpeed: LlmWireGenerationSpeed.Fast))
        match (requiring.materialize()) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.feature_requirement_unresolved")
            case _ => @Fail("unknown feature requirements must fail closed")
        }
        @Expect(requiring.materialize(resolver: Some(SatisfiedRequirementResolver())).isOk(), true)

        let success = LlmWireHttpResponse(
            200, [LlmWireHeader("x-request-id", "req-ok")],
            "{\"status\":\"completed\",\"output\":[]}".toArray()
        )
        match (codec.decodeResponse(success)) {
            case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.Completed(_))) => ()
            case _ => @Fail("2xx response must decode through the protocol codec")
        }

        let throttled = LlmWireHttpResponse(
            429, [LlmWireHeader("retry-after", "3"), LlmWireHeader("x-request-id", "req-rate")],
            "{\"error\":{\"type\":\"rate_limit\",\"code\":\"slow_down\",\"message\":\"retry later\"}}".toArray()
        )
        match (codec.decodeResponse(throttled)) {
            case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.ProviderFailed(failure))) =>
                @Expect(failure.httpStatus, Some(429))
                @Expect(failure.retryAfterMillis, Some(3000))
                @Expect(failure.providerRequestId, "req-rate")
                @Expect(failure.retryable, true)
            case _ => @Fail("non-2xx provider errors must remain wire outcomes")
        }
        match (codec.decodeResponse(LlmWireHttpResponse(99, [], []))) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.http_status_invalid")
            case _ => @Fail("invalid HTTP status must be a local error")
        }
        match (codec.decodeResponse(LlmWireHttpResponse(200, [], [255u8]))) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.response_utf8_invalid")
            case _ => @Fail("invalid response UTF-8 must be a local error")
        }
    }

    @TestCase
    func t062FixedRepliesPreserveTypedProviderSemantics() {
        let responses = openAiResponsesCodec(openAiResponsesModelProfile("gpt"))
        let responseReply = succeededReply(responses.decodeResponse("""
        {"id":"resp","object":"response","model":"gpt","status":"completed","service_tier":"priority","output":[
          {"type":"message","role":"assistant","status":"completed","phase":"commentary","content":[
            {"type":"output_text","text":"source","annotations":[
              {"type":"url_citation","start_index":0,"end_index":6,"url":"https://example.invalid","title":"Example"},
              {"type":"file_citation","index":1,"file_id":"file-1","filename":"source.txt"}
            ],"logprobs":[{"token":"source","bytes":[115],"logprob":-0.25,"top_logprobs":[{"token":"Source","bytes":[83],"logprob":-1.5}]}]}
          ]}
        ],"usage":{"input_tokens":2,"output_tokens":1,"total_tokens":3}}
        """))
        match (responseReply.blocks[0]) {
            case LlmWireOutputBlock.Text(value) =>
                @Expect(value.phase, LlmWireOutputPhase.Commentary)
                @Expect(value.annotations.size, 2)
                match (value.annotations[0]) {
                    case LlmWireAnnotation.UrlCitation(citation) => @Expect(citation.url, "https://example.invalid"); @Expect(citation.startIndex, Some(0))
                    case _ => @Fail("expected URL citation")
                }
                match (value.annotations[1]) {
                    case LlmWireAnnotation.FileCitation(citation) => @Expect(citation.fileId, "file-1"); @Expect(citation.filename, "source.txt")
                    case _ => @Fail("expected file citation")
                }
                @Expect(value.logprobs.size, 1)
                @Expect(value.logprobs[0].bytes[0], 115)
                @Expect(value.logprobs[0].logprob.stringify(), "-0.25")
                @Expect(value.logprobs[0].topLogprobs[0].token, "Source")
            case _ => @Fail("expected typed Responses text")
        }
        @Expect(responseReply.usage.totalTokens, Some(3))
        @Expect(responseReply.usage.serviceTier, Some("priority"))

        let messages = anthropicMessagesCodec(anthropicMessagesModelProfile("claude"))
        let citationReply = succeededReply(messages.decodeResponse("""
        {"id":"msg","type":"message","role":"assistant","model":"claude","content":[
          {"type":"text","text":"grass","citations":[{"type":"char_location","cited_text":"grass","document_index":0,"document_title":"Doc","start_char_index":0,"end_char_index":5}]}
        ],"stop_reason":"end_turn","stop_details":null,"usage":{"input_tokens":4,"output_tokens":1,"server_tool_use":{"web_search_requests":2,"web_fetch_requests":1}},"service_tier":"standard"}
        """))
        match (citationReply.blocks[0]) {
            case LlmWireOutputBlock.Text(value) =>
                @Expect(value.citations.size, 1)
                @Expect(value.citations[0].kind, LlmWireCitationKind.CharacterRange)
                @Expect(value.citations[0].citedText, "grass")
                @Expect(value.citations[0].endIndex, Some(5))
            case _ => @Fail("expected cited Messages text")
        }
        @Expect(citationReply.usage.webSearchRequests, Some(2))
        @Expect(citationReply.usage.webFetchRequests, Some(1))

        let refusalReply = succeededReply(messages.decodeResponse("""
        {"id":"msg-refusal","type":"message","role":"assistant","model":"claude","content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"declined"},"usage":{"input_tokens":1,"output_tokens":0}}
        """))
        match (refusalReply.blocks[0]) {
            case LlmWireOutputBlock.Refusal(value) => @Expect(value.category, Some("cyber")); @Expect(value.explanation, Some("declined"))
            case _ => @Fail("expected structured refusal")
        }

        let chat = openAiChatCodec(openAiChatModelProfile("gpt"))
        let chatReply = succeededReply(chat.decodeResponse("""
        {"id":"chat","object":"chat.completion","model":"gpt","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop","logprobs":{"content":[{"token":"ok","bytes":[111,107],"logprob":-0.1,"top_logprobs":[]}]}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
        """))
        match (chatReply.blocks[0]) {
            case LlmWireOutputBlock.Text(value) => @Expect(value.logprobs[0].token, "ok")
            case _ => @Fail("expected Chat text logprobs")
        }
    }

    @TestCase
    func t063ChatChoicesKeepIndependentOutcomesAndContinuation() {
        let codec = openAiChatCodec(openAiChatModelProfile("gpt"))
        let reply = succeededReply(codec.decodeResponse("""
        {"id":"chat-multi","object":"chat.completion","model":"gpt","choices":[
          {"index":0,"message":{"role":"assistant","content":"first"},"finish_reason":"stop"},
          {"index":1,"message":{"role":"assistant","content":null,"refusal":"declined"},"finish_reason":"stop"}
        ]}
        """))
        @Expect(reply.choices.size, 2)
        @Expect(reply.choices[0].index, 0)
        match (reply.choices[0].outcome) { case LlmWireChoiceOutcome.Completed => (); case _ => @Fail("first choice must complete") }
        match (reply.choices[1].outcome) {
            case LlmWireChoiceOutcome.Refused(value) => @Expect(value.text, "declined")
            case _ => @Fail("second choice must preserve refusal")
        }
        expectLlmError("llm.continuation_choice_required", { => let _ = reply.toContinuationInput() })
        match (reply.toContinuationInput(0)) {
            case LlmWireResult.Ok(messages) =>
                @Expect(messages.size, 1)
                match (messages[0].blocks[0]) { case LlmWireBlock.Text(value) => @Expect(value.text, "first"); case _ => @Fail("expected selected text") }
            case LlmWireResult.Err(error) => throw error
        }
        match (reply.toContinuationInput(9)) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.continuation_choice_missing")
            case _ => @Fail("missing choice must fail")
        }
        expectLlmError("llm.chat_choice_index_invalid", { => let _ = codec.decodeResponse("""
        {"object":"chat.completion","choices":[
          {"index":1,"message":{"role":"assistant","content":"wrong"},"finish_reason":"stop"}
        ]}
        """) })
    }

    @TestCase
    func t064ByteStreamDecoderOwnsFramingHttpCancellationAndChoices() {
        let codec = openAiChatCodec(openAiChatModelProfile("gpt"))
        let decoder = codec.newStreamDecoder()
        let first = match (decoder.push("data: {\"id\":\"chat-stream\",\"model\":\"gpt\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"first\"}},{\"index\":1,\"delta\":{\"refusal\":\"declined\"}}]}\n\n")) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(error) => throw error
        }
        match (first.events[0]) { case LlmWireEvent.StreamStarted("chat-stream", "gpt") => (); case _ => @Fail("byte decoder must emit stream identity") }
        let _ = decoder.push("data: {\"id\":\"chat-stream\",\"model\":\"gpt\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"},{\"index\":1,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n")
        let tail = match (decoder.push("data: [DONE]\r\r")) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
        @Expect(tail.terminal.isNone(), true)
        let completed = match (decoder.finish()) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
        let streamed = succeededReply(completed)
        @Expect(streamed.choices.size, 2)
        match (streamed.choices[1].outcome) { case LlmWireChoiceOutcome.Refused(value) => @Expect(value.text, "declined"); case _ => @Fail("streamed refusal choice") }

        let fixed = succeededReply(codec.decodeResponse("""
        {"id":"chat-stream","object":"chat.completion","model":"gpt","choices":[
          {"index":0,"message":{"role":"assistant","content":"first"},"finish_reason":"stop"},
          {"index":1,"message":{"role":"assistant","content":null,"refusal":"declined"},"finish_reason":"stop"}
        ]}
        """))
        @Expect(streamed.choices.size, fixed.choices.size)
        match ((streamed.choices[0].blocks[0], fixed.choices[0].blocks[0])) {
            case (LlmWireOutputBlock.Text(left), LlmWireOutputBlock.Text(right)) => @Expect(left.text, right.text)
            case _ => @Fail("fixed and streamed choice block mismatch")
        }

        let http = match (codec.newHttpStreamDecoder(
            429, headers: [LlmWireHeader("retry-after", "7")], nowEpochMillis: 1000
        )) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
        match (http.push("{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow\"}}")) { case LlmWireResult.Ok(_) => (); case LlmWireResult.Err(error) => throw error }
        match (http.finish()) {
            case LlmWireResult.Ok(update) => match (update.terminal) {
                case Some(LlmWireTerminal.ProviderFailed(failure)) => @Expect(failure.retryAfterMillis, Some(7000))
                case _ => @Fail("HTTP error must become provider failure")
            }
            case LlmWireResult.Err(error) => throw error
        }

        let cancelled = codec.newStreamDecoder()
        match (cancelled.cancel()) { case LlmWireResult.Ok(LlmWireTerminal.Cancelled(_)) => (); case _ => @Fail("cancel terminal") }
        match (cancelled.cancel()) { case LlmWireResult.Ok(LlmWireTerminal.Cancelled(_)) => (); case _ => @Fail("cancel must be idempotent") }
        match (cancelled.push("data: [DONE]\n\n")) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.stream_closed"); case _ => @Fail("cancelled decoder accepted input") }

        let poisoned = codec.newStreamDecoder(sseLimits: LlmWireSseLimits(maxEventBytes: 8))
        match (poisoned.push("data: too-long\n\n")) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_event_too_large"); case _ => @Fail("SSE limit") }
        match (poisoned.push("data: x\n\n")) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.stream_failed"); case _ => @Fail("poisoned decoder accepted input") }
    }

    @TestCase
    func t065PublicJsonFactoriesAndAccessorsCoverEveryKind() {
        let nullValue = LlmWireJson.nullValue()
        @Expect(nullValue.kind, LlmWireJsonKind.Null)
        @Expect(nullValue.booleanValue(), None)
        @Expect(nullValue.stringValue(), None)
        @Expect(nullValue.numberLiteral(), None)
        @Expect(nullValue.values().size, 0)
        @Expect(nullValue.fields().size, 0)
        @Expect(nullValue.field("missing").isNone(), true)

        let boolean = LlmWireJson.boolean(false)
        @Expect(boolean.kind, LlmWireJsonKind.Boolean)
        @Expect(boolean.booleanValue(), Some(false))
        @Expect(boolean.stringValue(), None)

        let string = LlmWireJson.string("a\"b")
        @Expect(string.kind, LlmWireJsonKind.String)
        @Expect(string.stringValue(), Some("a\"b"))
        @Expect(string.booleanValue(), None)

        let number = match (LlmWireJson.number("-1.25e+2")) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(error) => throw error
        }
        @Expect(number.kind, LlmWireJsonKind.Number)
        @Expect(number.numberLiteral(), Some("-1.25e+2"))
        @Expect(number.stringValue(), None)
        match (LlmWireJson.number("not-json")) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.json_number_invalid")
            case _ => @Fail("invalid number syntax must fail")
        }
        match (LlmWireJson.parse("{")) {
            case LlmWireResult.Err(_) => ()
            case _ => @Fail("invalid public JSON must fail")
        }

        let emptyArray = LlmWireJson.array([])
        @Expect(emptyArray.kind, LlmWireJsonKind.Array)
        @Expect(emptyArray.values().size, 0)
        let array = LlmWireJson.array([boolean, string, number])
        @Expect(array.values().size, 3)
        @Expect(array.values()[1].stringValue(), Some("a\"b"))

        let emptyObject = match (LlmWireJson.object([])) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(error) => throw error
        }
        @Expect(emptyObject.kind, LlmWireJsonKind.Object)
        @Expect(emptyObject.fields().size, 0)
        @Expect(emptyObject.field("missing").isNone(), true)
        let object = match (LlmWireJson.object([
            LlmWireJsonField("boolean", boolean),
            LlmWireJsonField("array", array)
        ])) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(error) => throw error
        }
        @Expect(object.fields().size, 2)
        @Expect(object.field("boolean").getOrThrow().booleanValue(), Some(false))
        @Expect(object.field("missing").isNone(), true)
    }

    @TestCase
    func t066RequestBuilderValidatesImmediatelyAndResetsAllOptions() {
        let codec = openAiChatCodec(openAiChatModelProfile("model", capabilities: allCapabilities()))
        let builder = codec.newRequestBuilder()
        expectLlmError("llm.instruction_empty", { => builder.addInstruction(LlmWireInstructionRole.System, " ") })
        expectLlmError("llm.message_empty", { => builder.addMessage(LlmWireMessage(LlmWireRole.User, [])) })
        expectLlmError("llm.image_url_invalid", { =>
            builder.addMessage(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, ""))]))
        })
        expectLlmError("llm.tool_name_invalid", { => builder.addTool(LlmWireTool("bad name", "", testJson("{}"))) })
        expectLlmError("llm.tool_schema_invalid", { => builder.addTool(LlmWireTool("valid", "", testJson("[]"))) })
        expectLlmError("llm.thinking_budget_invalid", { => builder.setThinking(LlmWireThinkingMode.Budget(1)) })
        expectLlmError("llm.reasoning_effort_mode_unsupported", { => builder.setThinking(LlmWireThinkingMode.Disabled, effort: LlmWireReasoningEffort.Low) })
        expectLlmError("llm.max_output_tokens_invalid", { => builder.setMaxOutputTokens(Some(0)) })
        expectLlmError("llm.max_output_tokens_invalid", { => builder.setMaxOutputTokens(Some(-1)) })
        expectLlmError("llm.prompt_cache_routing_key_invalid", { => builder.setPromptCache(LlmWirePromptCache.ProviderDefault, routingKey: Some("")) })

        builder.setThinking(LlmWireThinkingMode.Budget(1024))
        builder.setThinking(LlmWireThinkingMode.ProviderDefault)
        builder.setPromptCache(LlmWirePromptCache.ProviderDefault)

        builder.addInstruction(LlmWireInstructionRole.System, "system")
        builder.addMessage(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("hello"))]))
        builder.addTool(LlmWireTool("lookup", "lookup", testJson("{}")))
        builder.setThinking(LlmWireThinkingMode.ProviderDefault, effort: LlmWireReasoningEffort.Low)
        builder.setMaxOutputTokens(Some(64))
        builder.setParallelToolCalls(Some(true))
        builder.setServiceTier(LlmWireServiceTier.Priority)
        builder.setGenerationSpeed(LlmWireGenerationSpeed.Fast)
        builder.setGenerationSpeed(LlmWireGenerationSpeed.ProviderDefault)
        builder.setPromptCache(LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ThirtyMinutes), routingKey: Some("route"))
        builder.setToolChoice(LlmWireToolChoice.Auto)
        builder.setStructuredOutput(LlmWireStructuredOutput.JsonObject)
        match (builder.build()) {
            case LlmWireResult.Ok(value) => @Expect(value.tools.size, 1)
            case LlmWireResult.Err(error) => throw error
        }

        builder.reset()
        builder.setMaxOutputTokens(None)
        builder.setParallelToolCalls(None)
        builder.addMessage(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("after reset"))]))
        match (builder.build()) {
            case LlmWireResult.Ok(value) => @Expect(value.tools.size, 0)
            case LlmWireResult.Err(error) => throw error
        }
    }

    @TestCase
    func t067FactoryLimitsAndChoiceBoundariesCoverAllPublicBranches() {
        let profiles = [
            openAiResponsesModelProfile("r"), openAiChatModelProfile("c"), anthropicMessagesModelProfile("a"),
            deepSeekResponsesModelProfile("dr"), deepSeekChatModelProfile("dc"), deepSeekMessagesModelProfile("dm")
        ]
        @Expect(openAiResponsesCodec(profiles[0]).protocol, LlmWireProtocol.Responses)
        @Expect(openAiChatCodec(profiles[1]).protocol, LlmWireProtocol.ChatCompletions)
        @Expect(anthropicMessagesCodec(profiles[2]).protocol, LlmWireProtocol.Messages)
        @Expect(deepSeekResponsesCodec(profiles[3]).protocol, LlmWireProtocol.Responses)
        @Expect(deepSeekChatCodec(profiles[4]).protocol, LlmWireProtocol.ChatCompletions)
        @Expect(deepSeekMessagesCodec(profiles[5]).protocol, LlmWireProtocol.Messages)
        expectLlmError("llm.model_missing", { => let _ = openAiResponsesModelProfile(" ") })
        expectLlmError("llm.choice_index_invalid", { => let _ = LlmWireChoice(-1, [], LlmWireChoiceOutcome.Completed) })

        @Expect(LlmWireResult<Int64>.Ok(1).isOk(), true)
        @Expect(LlmWireResult<Int64>.Err(LlmWireError(LlmWireErrorKind.InvalidState, "x", "x")).isOk(), false)
        expectIllegalArgument({ => let _ = LlmWireSseLimits(maxEventBytes: 0) })
        expectIllegalArgument({ => let _ = LlmWireSseLimits(maxLineBytes: 0) })
        expectIllegalArgument({ => let _ = LlmWireSseLimits(maxBufferedBytes: 0) })
        expectIllegalArgument({ => let _ = LlmWireSseLimits(maxEventsPerPush: 0) })
        expectIllegalArgument({ => let _ = LlmWireSseLimits(maxOutputBytesPerPush: 0) })
        expectIllegalArgument({ => let _ = LlmWireSseLimits(maxErrorBodyBytes: 0) })

        let unprofiled = LlmWireCodec(LlmWireProtocol.Responses, TestStandardDialect(LlmWireDialectContract(
            "example.responses.v1", LlmWireProtocol.Responses, LlmWireRequestStyle.OpenAiResponses,
            LlmWireOutputTokenField.MaxOutputTokens
        )))
        expectLlmError("llm.model_missing", { => let _ = unprofiled.newRequestBuilder() })
        @Expect(unprofiled.newRequestBuilder(model: "explicit").build().isOk(), false)
        match (openAiResponsesCodec(profiles[0]).newHttpStreamDecoder(99)) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.http_status_invalid")
            case _ => @Fail("invalid streaming HTTP status must fail")
        }
    }

    @TestCase
    func t068ValidationCombinationErrorsRemainDialectSpecific() {
        let anthropic = anthropicMessagesCodec(anthropicMessagesModelProfile("claude", capabilities: allCapabilities()))
        expectLlmError("llm.max_output_tokens_required", { => let _ = anthropic.encodeRequest(LlmWireRequest("claude", validMessages())) })
        expectLlmError("llm.reasoning_effort_mode_unsupported", { => let _ = anthropic.encodeRequest(LlmWireRequest(
            "claude", validMessages(), maxOutputTokens: Some(64), thinkingMode: LlmWireThinkingMode.ProviderDefault,
            reasoningEffort: LlmWireReasoningEffort.Low
        )) })

        let deepSeekChat = deepSeekChatCodec(deepSeekChatModelProfile("deepseek", capabilities: allCapabilities()))
        expectLlmError("llm.reasoning_effort_mode_unsupported", { => let _ = deepSeekChat.encodeRequest(LlmWireRequest(
            "deepseek", validMessages(), reasoningEffort: LlmWireReasoningEffort.Low
        )) })
        let deepSeekMessages = deepSeekMessagesCodec(deepSeekMessagesModelProfile("deepseek", capabilities: allCapabilities()))
        expectLlmError("llm.reasoning_effort_mode_unsupported", { => let _ = deepSeekMessages.encodeRequest(LlmWireRequest(
            "deepseek", validMessages(), maxOutputTokens: Some(64), reasoningEffort: LlmWireReasoningEffort.Low
        )) })

        let call = LlmWireBlock.ToolCall(LlmWireToolCallBlock("call", "tool", LlmWireToolArguments.Complete(testJson("{}"))))
        let failed = LlmWireBlock.ToolResult(toolResultText("call", "failed", isError: true))
        let errorConversation = [LlmWireMessage(LlmWireRole.Assistant, [call]), LlmWireMessage(LlmWireRole.User, [failed])]
        let marked = deepSeekMessages.encodeRequest(LlmWireRequest(
            "deepseek", errorConversation, maxOutputTokens: Some(64), tools: [LlmWireTool("tool", "", testJson("{}"))]
        ))
        @Expect(marked.contains("[tool_error]"), true)
        @Expect(marked.contains("is_error"), false)
        @Expect(marked.contains("failed"), true)
        let plainConversation = [LlmWireMessage(LlmWireRole.Assistant, [call]), LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(toolResultText("call", "done"))])]
        let plain = deepSeekMessages.encodeRequest(LlmWireRequest(
            "deepseek", plainConversation, maxOutputTokens: Some(64), tools: [LlmWireTool("tool", "", testJson("{}"))]
        ))
        @Expect(plain.contains("[tool_error]"), false)
        @Expect(plain.contains("is_error"), false)
        let anthropicPlain = anthropic.encodeRequest(LlmWireRequest(
            "claude", plainConversation, maxOutputTokens: Some(64), tools: [LlmWireTool("tool", "", testJson("{}"))]
        ))
        @Expect(anthropicPlain.contains("\"is_error\":false"), true)
        let strictMessages = LlmWireCodec(LlmWireProtocol.Messages, TestStandardDialect(LlmWireDialectContract(
            "test.messages.no.tool.error", LlmWireProtocol.Messages, LlmWireRequestStyle.AnthropicMessages,
            LlmWireOutputTokenField.MaxTokens
        )), capabilities: allCapabilities())
        expectLlmError("llm.tool_result_error_semantics_unsupported", { => let _ = strictMessages.encodeRequest(LlmWireRequest(
            "test", errorConversation, maxOutputTokens: Some(64), tools: [LlmWireTool("tool", "", testJson("{}"))]
        )) })
        expectIllegalArgument({ => let _ = LlmWireDialectContract(
            "test.chat.native.tool.error", LlmWireProtocol.ChatCompletions, LlmWireRequestStyle.OpenAiChat,
            LlmWireOutputTokenField.MaxCompletionTokens, toolErrorStyle: LlmWireToolErrorStyle.NativeField
        ) })
        @Expect(anthropic.dialect.contract.toolErrorStyle, LlmWireToolErrorStyle.NativeField)
        @Expect(deepSeekMessages.dialect.contract.toolErrorStyle, LlmWireToolErrorStyle.ContentMarker)
        expectLlmError("llm.test_unsupported_wire", { => unsupportedWire("llm.test_unsupported_wire", "test") })
    }

    @TestCase
    func t069NewSemanticEnumsAndChoiceProjectionCoverEveryVariant() {
        let jsonKinds = [
            LlmWireJsonKind.Null, LlmWireJsonKind.Boolean, LlmWireJsonKind.Number,
            LlmWireJsonKind.String, LlmWireJsonKind.Array, LlmWireJsonKind.Object
        ]
        for (left in 0..jsonKinds.size) {
            for (right in 0..jsonKinds.size) {
                @Expect(jsonKinds[left] == jsonKinds[right], left == right)
                @Expect(jsonKinds[left] != jsonKinds[right], left != right)
            }
        }

        let phases = [
            LlmWireOutputPhase.Unspecified, LlmWireOutputPhase.Analysis,
            LlmWireOutputPhase.Commentary, LlmWireOutputPhase.Final
        ]
        for (left in 0..phases.size) {
            for (right in 0..phases.size) {
                @Expect(phases[left] == phases[right], left == right)
                @Expect(phases[left] != phases[right], left != right)
            }
        }

        let citationKinds = [
            LlmWireCitationKind.Url, LlmWireCitationKind.File,
            LlmWireCitationKind.CharacterRange, LlmWireCitationKind.PageRange,
            LlmWireCitationKind.ContentBlockRange, LlmWireCitationKind.WebSearchResult,
            LlmWireCitationKind.SearchResult
        ]
        for (left in 0..citationKinds.size) {
            for (right in 0..citationKinds.size) {
                @Expect(citationKinds[left] == citationKinds[right], left == right)
                @Expect(citationKinds[left] != citationKinds[right], left != right)
            }
        }

        let reasons = [
            LlmWireIncompleteReason.MaxTokens, LlmWireIncompleteReason.Length,
            LlmWireIncompleteReason.ContentFilter, LlmWireIncompleteReason.ModelContextWindowExceeded,
            LlmWireIncompleteReason.PauseTurn, LlmWireIncompleteReason.Other("a"),
            LlmWireIncompleteReason.Other("b")
        ]
        for (left in 0..reasons.size) {
            for (right in 0..reasons.size) {
                @Expect(reasons[left] == reasons[right], left == right)
                @Expect(reasons[left] != reasons[right], left != right)
            }
        }

        let lossy = LlmWireChoice(
            0,
            [LlmWireOutputBlock.Reasoning(LlmWireReasoningBlock("private"))],
            LlmWireChoiceOutcome.Completed
        )
        match (lossy.toContinuationInput()) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.continuation_projection_lossy")
            case _ => @Fail("choice continuation must report lossy projection")
        }
        let budget = StreamBudget(LlmWireStreamLimits())
        budget.terminalReply(LlmWireReply(blocks: [LlmWireOutputBlock.Reasoning(LlmWireReasoningBlock("reason"))]))
    }

    @TestCase
    func t070ProviderMetadataDecodersCoverEveryTypedAndRejectedShape() {
        let responses = openAiResponsesCodec(openAiResponsesModelProfile("gpt"))
        @Expect(decodeResponsesPhase(responses, parseWireJson("{\"phase\":\"analysis\"}"), 0), LlmWireOutputPhase.Analysis)
        @Expect(decodeResponsesPhase(responses, parseWireJson("{\"phase\":\"commentary\"}"), 0), LlmWireOutputPhase.Commentary)
        @Expect(decodeResponsesPhase(responses, parseWireJson("{\"phase\":\"final\"}"), 0), LlmWireOutputPhase.Final)
        @Expect(decodeResponsesPhase(responses, parseWireJson("{}"), 0), LlmWireOutputPhase.Unspecified)
        expectLlmError("llm.responses_semantic_unsupported", { =>
            let _ = decodeResponsesPhase(responses, parseWireJson("{\"phase\":\"future\"}"), 0)
        })

        let annotations = decodeResponsesAnnotations(responses, parseWireJson("""
        {"annotations":[
          {"type":"url_citation","start_index":1,"end_index":2,"url":"https://example.test"},
          {"type":"file_citation","index":3,"file_id":"file-1"}
        ]}
        """), 0)
        @Expect(annotations.size, 2)
        expectLlmError("llm.responses_annotation_unsupported", { =>
            let _ = decodeResponsesAnnotations(responses, parseWireJson("{\"annotations\":[{\"type\":\"future\"}]}"), 0)
        })

        let logprobs = decodeTokenLogprobs(responses, parseWireJson("""
        {"content":[{"token":"a","logprob":-0.25,"bytes":[65],"top_logprobs":[{"token":"b","logprob":-1.0,"bytes":[66]}]}]}
        """), "content", 0, "test")
        @Expect(logprobs.size, 1)
        @Expect(logprobs[0].topLogprobs.size, 1)
        expectLlmError("llm.field_type_invalid", { => let _ = numericJsonField(parseWireJson("{\"n\":true}"), "n", "test") })
        expectLlmError("llm.field_type_invalid", { => let _ = decodeLogprobBytes(parseWireJson("{\"bytes\":[true]}"), "test") })
        expectLlmError("llm.integer_invalid", { => let _ = decodeLogprobBytes(parseWireJson("{\"bytes\":[1.5]}"), "test") })
        expectLlmError("llm.logprob_byte_invalid", { => let _ = decodeLogprobBytes(parseWireJson("{\"bytes\":[-1]}"), "test") })
        expectLlmError("llm.logprob_byte_invalid", { => let _ = decodeLogprobBytes(parseWireJson("{\"bytes\":[256]}"), "test") })

        let messages = anthropicMessagesCodec(anthropicMessagesModelProfile("claude"))
        let citations = [
            decodeMessagesCitation(messages, parseWireJson("{\"type\":\"char_location\",\"cited_text\":\"a\",\"document_index\":0,\"document_title\":\"d\",\"start_char_index\":1,\"end_char_index\":2}"), 0, "test"),
            decodeMessagesCitation(messages, parseWireJson("{\"type\":\"page_location\",\"cited_text\":\"b\",\"document_index\":0,\"document_title\":\"d\",\"start_page_number\":1,\"end_page_number\":2}"), 0, "test"),
            decodeMessagesCitation(messages, parseWireJson("{\"type\":\"content_block_location\",\"cited_text\":\"c\",\"document_index\":0,\"document_title\":\"d\",\"start_block_index\":1,\"end_block_index\":2}"), 0, "test"),
            decodeMessagesCitation(messages, parseWireJson("{\"type\":\"web_search_result_location\",\"cited_text\":\"d\",\"url\":\"https://example.test\",\"title\":\"t\"}"), 0, "test"),
            decodeMessagesCitation(messages, parseWireJson("{\"type\":\"search_result_location\",\"cited_text\":\"e\"}"), 0, "test")
        ]
        @Expect(citations.size, 5)
        expectLlmError("llm.messages_citation_unsupported", { =>
            let _ = decodeMessagesCitation(messages, parseWireJson("{\"type\":\"future\",\"cited_text\":\"x\"}"), 0, "test")
        })
        @Expect(decodeMessagesStopDetails(messages, parseWireJson("{\"stop_details\":null}"), "end_turn", "test").isNone(), true)
        expectLlmError("llm.messages_refusal_details_missing", { =>
            let _ = decodeMessagesStopDetails(messages, parseWireJson("{\"stop_details\":null}"), "refusal", "test")
        })
        expectLlmError("llm.messages_stop_details_unsupported", { =>
            let _ = decodeMessagesStopDetails(messages, parseWireJson("{\"stop_details\":{\"type\":\"pause\"}}"), "end_turn", "test")
        })
    }

    @TestCase
    func t071ByteStreamWrapperCoversHttpFramingAndTerminalFailureEdges() {
        let codec = openAiChatCodec(openAiChatModelProfile("gpt"))
        let limited = match (codec.newHttpStreamDecoder(429, sseLimits: LlmWireSseLimits(maxErrorBodyBytes: 2))) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(error) => throw error
        }
        match (limited.push("abc")) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.body_too_large")
            case _ => @Fail("error body limit must fail before buffering")
        }
        match (limited.finish()) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.stream_failed")
            case _ => @Fail("failed HTTP decoder must stay poisoned")
        }
        match (limited.cancel()) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.stream_failed")
            case _ => @Fail("failed HTTP decoder cannot be cancelled into success")
        }

        let invalidError = match (codec.newHttpStreamDecoder(500)) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(error) => throw error
        }
        let _ = invalidError.push("{")
        match (invalidError.finish()) {
            case LlmWireResult.Ok(update) => match (update.terminal) {
                case Some(LlmWireTerminal.ProviderFailed(failure)) => @Expect(failure.httpStatus, Some(500))
                case _ => @Fail("malformed non-success body must preserve the HTTP failure")
            }
            case LlmWireResult.Err(error) => throw error
        }

        let providerError = match (codec.newHttpStreamDecoder(429)) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(error) => throw error
        }
        let _ = providerError.push("{\"error\":{\"type\":\"rate_limit\",\"message\":\"slow\"}}")
        match (providerError.finish()) {
            case LlmWireResult.Ok(update) => match (update.terminal) {
                case Some(LlmWireTerminal.ProviderFailed(_)) => @Expect(update.events.size, 2)
                case _ => @Fail("HTTP provider error terminal")
            }
            case LlmWireResult.Err(error) => throw error
        }

        let incompleteUtf8 = codec.newStreamDecoder()
        match (incompleteUtf8.push([0xe2u8, 13u8])) {
            case LlmWireResult.Ok(_) => ()
            case LlmWireResult.Err(error) => throw error
        }
        match (incompleteUtf8.finish()) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_utf8_invalid")
            case _ => @Fail("incomplete UTF-8 at EOF must fail")
        }

        let malformedSemantic = codec.newStreamDecoder()
        match (malformedSemantic.push("data: {}\n\n")) {
            case LlmWireResult.Err(_) => ()
            case _ => @Fail("malformed semantic event must fail through byte framing")
        }
        match (malformedSemantic.push("data: [DONE]\n\n")) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.stream_failed")
            case _ => @Fail("semantic failure must poison byte stream")
        }

        let completed = LlmWireTerminal.Completed(LlmWireReply())
        @Expect(terminalEvents(completed).size, 2)
        let failure = LlmWireTerminal.ProviderFailed(LlmWireFailure(LlmWireFailureKind.ProviderError, "failed"))
        @Expect(terminalEvents(failure).size, 2)
        let cancelled = LlmWireTerminal.Cancelled(LlmWireFailure(LlmWireFailureKind.Cancelled, "cancelled"))
        @Expect(terminalEvents(cancelled).size, 1)

        let closed = codec.newStreamDecoder()
        let _ = closed.cancel()
        match (closed.finish()) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.stream_closed")
            case _ => @Fail("cancelled byte stream must be closed")
        }
    }

    @TestCase
    func t072RemainingValidationAndMappingBranchesFailClosed() {
        match (LlmWireJson.number("true")) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.json_number_invalid")
            case _ => @Fail("non-number JSON must not pass the number factory")
        }
        match (LlmWireJson.object([
            LlmWireJsonField("same", LlmWireJson.boolean(true)),
            LlmWireJsonField("same", LlmWireJson.boolean(false))
        ])) {
            case LlmWireResult.Err(_) => ()
            case _ => @Fail("duplicate public JSON object fields must fail")
        }
        @Expect(LlmWireJson.string("x").values().size, 0)
        @Expect(LlmWireJson.array([]).fields().size, 0)
        @Expect(LlmWireJson.array([]).field("x").isNone(), true)

        let full = allCapabilities()
        let responses = openAiResponsesCodec(openAiResponsesModelProfile("gpt", capabilities: full))
        expectLlmError("llm.model_profile_mismatch", { => let _ = responses.encodeRequest(LlmWireRequest("other", validMessages())) })
        expectLlmError("llm.responses_input_required", { => let _ = responses.encodeRequest(LlmWireRequest("gpt", [])) })
        expectLlmError("llm.tool_choice_without_tools", { => let _ = responses.encodeRequest(LlmWireRequest("gpt", validMessages(), toolChoice: LlmWireToolChoice.Auto)) })
        expectLlmError("llm.parallel_tools_without_tools", { => let _ = responses.encodeRequest(LlmWireRequest("gpt", validMessages(), parallelToolCalls: Some(true))) })
        expectLlmError("llm.structured_output_document_unsupported", { => let _ = responses.encodeRequest(LlmWireRequest(
            "gpt", validMessages(), structuredOutput: LlmWireStructuredOutput.JsonSchemaDocument(testJson("{}"))
        )) })
        expectLlmError("llm.tool_schema_invalid", { => let _ = responses.encodeRequest(LlmWireRequest(
            "gpt", validMessages(), tools: [LlmWireTool("lookup", "", testJson("[]"))]
        )) })

        let noFeatures = openAiResponsesCodec(openAiResponsesModelProfile("gpt"))
        expectLlmError("llm.tools_unsupported", { => let _ = noFeatures.encodeRequest(LlmWireRequest(
            "gpt", validMessages(), tools: [LlmWireTool("lookup", "", testJson("{}"))]
        )) })
        let toolsWithoutParallel = openAiResponsesCodec(openAiResponsesModelProfile(
            "gpt", capabilities: LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))
        ))
        expectLlmError("llm.parallel_tools_unsupported", { => let _ = toolsWithoutParallel.encodeRequest(LlmWireRequest(
            "gpt", validMessages(), tools: [LlmWireTool("lookup", "", testJson("{}"))], parallelToolCalls: Some(true)
        )) })
        expectLlmError("llm.service_tier_unsupported", { => let _ = noFeatures.encodeRequest(LlmWireRequest(
            "gpt", validMessages(), serviceTier: LlmWireServiceTier.Priority
        )) })
        expectLlmError("llm.generation_speed_unsupported", { => let _ = noFeatures.encodeRequest(LlmWireRequest(
            "gpt", validMessages(), generationSpeed: LlmWireGenerationSpeed.Fast
        )) })
        expectLlmError("llm.prompt_cache_routing_unsupported", { => let _ = anthropicMessagesCodec(anthropicMessagesModelProfile("claude", capabilities: full)).encodeRequest(LlmWireRequest(
            "claude", validMessages(), maxOutputTokens: Some(8), promptCacheRoutingKey: Some("route")
        )) })

        let anthropic = anthropicMessagesCodec(anthropicMessagesModelProfile("claude", capabilities: full))
        expectLlmError("llm.developer_instruction_unsupported", { => let _ = anthropic.encodeRequest(LlmWireRequest(
            "claude", validMessages(), instructions: [LlmWireInstruction(LlmWireInstructionRole.Developer, "developer")], maxOutputTokens: Some(8)
        )) })
        expectLlmError("llm.thinking_budget_exceeds_output", { => let _ = anthropic.encodeRequest(LlmWireRequest(
            "claude", validMessages(), thinkingMode: LlmWireThinkingMode.Budget(1024), maxOutputTokens: Some(1024)
        )) })
        expectLlmError("llm.thinking_unsupported", { => let _ = anthropic.encodeRequest(LlmWireRequest(
            "claude", validMessages(), thinkingMode: LlmWireThinkingMode.Enabled, maxOutputTokens: Some(2048)
        )) })
        expectLlmError("llm.structured_output_metadata_unsupported", { => let _ = anthropic.encodeRequest(LlmWireRequest(
            "claude", validMessages(), maxOutputTokens: Some(8), structuredOutput: LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("answer", testJson("{}")))
        )) })

        let noVision = deepSeekResponsesCodec(deepSeekResponsesModelProfile("deepseek"))
        expectLlmError("llm.image_input_unsupported", { => let _ = noVision.encodeRequest(LlmWireRequest(
            "deepseek", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "https://example.invalid/x"))])]
        )) })
        let vision = deepSeekResponsesCodec(deepSeekResponsesModelProfile(
            "deepseek", capabilities: LlmWireCapabilities(input: LlmWireInputCapabilities(modalities: [LlmWireInputModality.Text, LlmWireInputModality.Image]))
        ))
        expectLlmError("llm.image_role_unsupported", { => let _ = vision.encodeRequest(LlmWireRequest(
            "deepseek", [LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "https://example.invalid/x"))])]
        )) })
        expectLlmError("llm.image_media_type_unsupported", { => let _ = vision.encodeRequest(LlmWireRequest(
            "deepseek", [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Base64, "x", mediaType: "image/svg+xml"))])]
        )) })
    }

    @TestCase
    func t073TransportAndCodecHelpersCoverBothSidesOfEveryDecision() {
        @Expect(responseHeader([LlmWireHeader("x-request-id", "id")], ["request-id", "x-request-id"]), "id")
        @Expect(responseHeader([], ["x-request-id"]), "")
        @Expect(responseHeaderOption([LlmWireHeader("retry-after", "2")], "retry-after"), Some("2"))
        @Expect(responseHeaderOption([], "retry-after"), None)
        for ((status, expected) in [(408, true), (409, true), (429, true), (500, true), (499, false), (200, false)]) {
            @Expect(httpStatusRetryable(status), expected)
        }

        let root = wireJsonObject([])
        let requirements = ArrayList<LlmWireFeatureRequirement>()
        let responses = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
        encodeThinking(responses, root, LlmWireThinkingMode.ProviderDefault, LlmWireReasoningEffort.High)
        @Expect(root.field("reasoning").isSome(), true)
        let chatRoot = wireJsonObject([])
        encodeThinking(LlmWireCodec(LlmWireProtocol.ChatCompletions, openAiChatDialect()), chatRoot, LlmWireThinkingMode.Enabled, LlmWireReasoningEffort.ProviderDefault)
        @Expect(chatRoot.field("reasoning_effort").isSome(), true)
        let deepSeekRoot = wireJsonObject([])
        encodeThinking(LlmWireCodec(LlmWireProtocol.Responses, deepSeekResponsesDialect()), deepSeekRoot, LlmWireThinkingMode.Enabled, LlmWireReasoningEffort.Low)
        @Expect(deepSeekRoot.field("reasoning").isSome(), true)
        expectLlmError("llm.thinking_not_representable", { =>
            encodeThinking(responses, wireJsonObject([]), LlmWireThinkingMode.Budget(1024), LlmWireReasoningEffort.ProviderDefault)
        })
        encodePromptCache(
            LlmWireCodec(LlmWireProtocol.ChatCompletions, deepSeekChatDialect()), wireJsonObject([]),
            LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault), requirements
        )
        @Expect(requirements.size, 1)

        let emptyInput = wireJsonArray([])
        flushResponsesMessage(emptyInput, LlmWireRole.User, wireJsonArray([]))
        @Expect(emptyInput.items.size, 0)
        let nonEmpty = wireJsonArray([wireJsonObject([WireJsonField("type", wireJsonString("input_text")), WireJsonField("text", wireJsonString("x"))])])
        flushResponsesMessage(emptyInput, LlmWireRole.User, nonEmpty)
        @Expect(emptyInput.items.size, 1)

        let chat = openAiChatCodec(openAiChatModelProfile("gpt"))
        let duplicateDone = chat.newStreamDecoder()
        let _ = duplicateDone.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"))
        let _ = duplicateDone.push(event("[DONE]"))
        @Expect(duplicateDone.push(event("[DONE]")).events.size, 0)
        expectLlmError("llm.stream_event_after_terminal", { => let _ = duplicateDone.push(event("{\"choices\":[]}")) })

        let terminalThenCancel = chat.newStreamDecoder()
        let _ = terminalThenCancel.push(event("{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"))
        let terminal = terminalThenCancel.push(event("[DONE]")).terminal.getOrThrow()
        match (terminalThenCancel.cancel()) {
            case LlmWireResult.Ok(value) => match ((value, terminal)) {
                case (LlmWireTerminal.Completed(_), LlmWireTerminal.Completed(_)) => ()
                case _ => @Fail("cancelling a terminal stream must preserve its terminal")
            }
            case LlmWireResult.Err(error) => throw error
        }

        let sse = SseDecoder()
        match (sse.push("\u{feff}: comment\nid: bad\u{0000}id\nretry: nope\nunknown: x\n\n")) {
            case LlmWireResult.Ok(values) => @Expect(values.size, 0)
            case LlmWireResult.Err(error) => throw error
        }
        match (sse.finish()) { case LlmWireResult.Ok(_) => (); case LlmWireResult.Err(error) => throw error }
        match (sse.finish()) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_closed"); case _ => @Fail("closed SSE decoder must reject finish") }
        match (sse.push("data: x\n\n")) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.sse_closed"); case _ => @Fail("closed SSE decoder must reject input") }
    }
    @TestCase
    func t074TerminalEvidenceDistinguishesTruncatedStreams() {
        let truncated = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        let _ = truncated.push(event("{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"x\"}}"))
        let _ = truncated.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call-7\",\"name\":\"lookup\",\"input\":{}}}"))
        let _ = truncated.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"q\\\":\"}}"))
        try {
            let _ = truncated.finishTransport()
            @Fail("truncated Messages stream must fail")
        } catch (error: LlmWireError) {
            @Expect(error.code, "llm.stream_terminal_missing")
            let diagnostic = error.diagnosticJson.getOrThrow()
            @Expect(diagnostic.contains("transport_ended_before_terminal"), true)
            @Expect(diagnostic.contains("\"message_start_seen\":true"), true)
            @Expect(diagnostic.contains("\"native_type\":\"tool_use\""), true)
            @Expect(diagnostic.contains("\"tool_call_id\":\"call-7\""), true)
            @Expect(diagnostic.contains("\"name\":\"lookup\""), true)
            @Expect(diagnostic.contains("\"tool_input_fragment_bytes\":"), true)
        }

        let bare = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        try {
            let _ = bare.finishTransport()
            @Fail("bare transport EOF must fail")
        } catch (error: LlmWireError) {
            @Expect(error.code, "llm.stream_terminal_missing")
            let diagnostic = error.diagnosticJson.getOrThrow()
            @Expect(diagnostic.contains("\"message_start_seen\":false"), true)
            @Expect(diagnostic.contains("\"open_content_block_count\":0"), true)
        }

        let malformed = LlmWireCodec(LlmWireProtocol.Messages, anthropicMessagesDialect()).newStreamDecoder()
        beginMessages(malformed)
        let _ = malformed.push(event("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call-9\",\"name\":\"run\",\"input\":{}}}"))
        let _ = malformed.push(event("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"q\\\":1\"}}"))
        let _ = malformed.push(event("{\"type\":\"content_block_stop\",\"index\":0}"))
        let _ = malformed.push(event("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}"))
        try {
            let _ = malformed.push(event("{\"type\":\"message_stop\"}"))
            @Fail("malformed tool input must fail")
        } catch (error: LlmWireError) {
            @Expect(error.code, "llm.tool_arguments_not_executable")
            @Expect(error.toolCallId, "call-9")
        }
    }

}
