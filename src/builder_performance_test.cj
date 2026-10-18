package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

func builderTestValue<T>(value: LlmWireResult<T>): T {
    match (value) { case LlmWireResult.Ok(result) => result; case LlmWireResult.Err(error) => throw error }
}

func builderTestSnapshot(request: LlmWireRequest): String { builderTestValue(request.transcript.snapshot()) }

func builderTestEncoded(codec: LlmWireCodec, request: LlmWireRequest): String {
    String.fromUtf8(builderTestValue(codec.encodeRequest(request).materialize()).body)
}

func builderTestCodec(): LlmWireCodec {
    openAiResponsesCodec(openAiResponsesModelProfile("model",
        capabilities: LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))))
}

func builderTestText(value: String): LlmWireMessage {
    LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(value))])
}

@Test
class RequestBuilderSnapshotTests {
    @TestCase
    func appendFreezesNestedArraysAndEachBuildOwnsItsSnapshot() {
        let codec = builderTestCodec()
        let builder = codec.newRequestBuilder()
        let probability = builderTestValue(LlmWireJson.number("-0.5"))
        let citation = LlmWireCitation(LlmWireCitationKind.Url, url: "https://example.test/original")
        let candidate = LlmWireTokenLogprobCandidate("a", probability, bytes: [97])
        let logprob = LlmWireTokenLogprob("a", probability, bytes: [97], topLogprobs: [candidate])
        let text = LlmWireTextBlock("original", citations: [citation], annotations: [LlmWireAnnotation.UrlCitation(citation)], logprobs: [logprob])
        let blocks = [LlmWireBlock.Text(text)]
        builder.appendMessage(LlmWireMessage(LlmWireRole.User, blocks))
        let first = builderTestValue(builder.build())
        let before = builderTestSnapshot(first)
        let encoded = builderTestEncoded(codec, first)

        logprob.bytes[0] = 0
        candidate.bytes[0] = 0
        logprob.topLogprobs[0] = LlmWireTokenLogprobCandidate("changed", probability)
        text.logprobs[0] = LlmWireTokenLogprob("changed", probability)
        text.citations[0] = LlmWireCitation(LlmWireCitationKind.File, fileId: "changed")
        text.annotations[0] = LlmWireAnnotation.FileCitation(citation)
        blocks[0] = LlmWireBlock.Text(LlmWireTextBlock("changed"))
        @Expect(builderTestSnapshot(builderTestValue(builder.build())), before)

        let observed = first.transcript.items
        match (observed[0]) { case LlmWireInputItem.Message(message) =>
            match (message.blocks[0]) { case LlmWireBlock.Text(value) =>
                value.logprobs[0].bytes[0] = 1
                value.logprobs[0].topLogprobs[0].bytes[0] = 1
                value.citations[0] = LlmWireCitation(LlmWireCitationKind.File)
            case _ => @Fail("expected text") }
            message.blocks[0] = LlmWireBlock.Text(LlmWireTextBlock("observed mutation"))
        case _ => @Fail("expected message") }
        builder.appendMessage(builderTestText("later"))
        let second = builderTestValue(builder.build())
        @Expect(second.transcript.items.size, 2)
        @Expect(builderTestSnapshot(first), before)
        @Expect(builderTestEncoded(codec, first), encoded)
        builder.reset()
        builder.appendMessage(builderTestText("after reset"))
        @Expect(builderTestValue(builder.build()).transcript.items.size, 1)
        @Expect(second.transcript.items.size, 2)
        @Expect(builderTestSnapshot(first), before)
    }

    @TestCase
    func toolResultIngressAndObservedNestedContentStayIsolated() {
        let builder = builderTestCodec().newRequestBuilder()
        let schema = builderTestValue(LlmWireJson.parse("{}"))
        builder.setInitialContext(LlmWireInitialContext(tools: [LlmWireToolDeclaration(LlmWireTool("lookup", "", schema))]))
        builder.appendMessage(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(
            LlmWireToolCallBlock("call", "lookup", LlmWireToolArguments.Complete(schema)))]))
        let probability = builderTestValue(LlmWireJson.number("-1"))
        let logprob = LlmWireTokenLogprob("r", probability, bytes: [114],
            topLogprobs: [LlmWireTokenLogprobCandidate("r", probability, bytes: [114])])
        let text = LlmWireTextBlock("result", logprobs: [logprob])
        let content = [LlmWireToolResultContent.Text(text)]
        let result = LlmWireToolResultBlock("call", content)
        builder.appendMessage(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(result)]))
        let request = builderTestValue(builder.build())
        let before = builderTestSnapshot(request)
        content[0] = LlmWireToolResultContent.Text(LlmWireTextBlock("changed"))
        text.logprobs[0].bytes[0] = 0
        text.logprobs[0].topLogprobs[0].bytes[0] = 0
        match (request.transcript.items[1]) { case LlmWireInputItem.Message(message) =>
            match (message.blocks[0]) { case LlmWireBlock.ToolResult(value) =>
                match (value.content[0]) { case LlmWireToolResultContent.Text(observed) =>
                    observed.logprobs[0].bytes[0] = 1
                    observed.logprobs[0].topLogprobs[0].bytes[0] = 1
                case _ => @Fail("expected tool-result text") }
                value.content[0] = LlmWireToolResultContent.Text(LlmWireTextBlock("observed mutation"))
            case _ => @Fail("expected tool result") }
        case _ => @Fail("expected result message") }
        @Expect(builderTestSnapshot(request), before)
        @Expect(builderTestSnapshot(builderTestValue(builder.build())), before)
    }

    @TestCase
    func failedContextAndTranscriptAssignmentsKeepPreparedState() {
        let builder = builderTestCodec().newRequestBuilder()
        let originalInstructions = [LlmWireInstruction(LlmWireInstructionRole.System, "prepared")]
        builder.setInitialContext(LlmWireInitialContext(instructions: originalInstructions))
        let before = builderTestSnapshot(builderTestValue(builder.build()))
        originalInstructions[0] = LlmWireInstruction(LlmWireInstructionRole.System, "changed")
        try {
            builder.setInitialContext(LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, " ")]))
            @Fail("invalid context must fail")
        } catch (error: LlmWireError) { @Expect(error.code, "llm.instruction_empty") }
        @Expect(builderTestSnapshot(builderTestValue(builder.build())), before)
        try {
            builder.setTranscript(LlmWireTranscript(LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "candidate")]), items: [
                LlmWireInputItem.Message(builderTestText("valid candidate prefix")),
                LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, []))
            ]))
            @Fail("invalid transcript must fail")
        } catch (error: LlmWireError) {
            @Expect(error.code, "llm.message_empty"); @Expect(error.inputItemIndex, 1)
            @Expect(error.dialectId, "openai.responses.v1"); @Expect(error.phase, Some(LlmTransportPhase.Encode))
        }
        @Expect(builderTestSnapshot(builderTestValue(builder.build())), before)
        let source = LlmWireTranscript(items: [LlmWireInputItem.Message(builderTestText("replacement"))])
        builder.setTranscript(source)
        let replaced = builderTestSnapshot(builderTestValue(builder.build()))
        source.items[0] = LlmWireInputItem.Message(builderTestText("observed change"))
        @Expect(builderTestSnapshot(builderTestValue(builder.build())), replaced)
        try { builder.setInitialContext(LlmWireInitialContext()); @Fail("started context cannot change") }
        catch (error: LlmWireError) { @Expect(error.code, "llm.initial_context_already_started"); @Expect(error.inputItemIndex, 1) }
        try { builder.setTranscript(LlmWireTranscript()); @Fail("started transcript cannot change") }
        catch (error: LlmWireError) { @Expect(error.code, "llm.initial_context_already_started") }
        @Expect(builderTestSnapshot(builderTestValue(builder.build())), replaced)
    }

    @TestCase
    func failedAppendAndBuildLeaveUnresolvedCallCompletable() {
        let builder = builderTestCodec().newRequestBuilder()
        let object = builderTestValue(LlmWireJson.parse("{}"))
        builder.setInitialContext(LlmWireInitialContext(tools: [LlmWireToolDeclaration(LlmWireTool("lookup", "", object))]))
        builder.appendMessage(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(
            LlmWireToolCallBlock("call", "lookup", LlmWireToolArguments.Complete(object)))]))
        for (_ in 0..2) {
            match (builder.build()) { case LlmWireResult.Err(error) =>
                @Expect(error.code, "llm.tool_call_unresolved"); @Expect(error.inputItemIndex, 0)
            case _ => @Fail("unresolved call must fail aggregate validation") }
        }
        try { builder.appendMessage(LlmWireMessage(LlmWireRole.User, [])); @Fail("empty append must fail") }
        catch (error: LlmWireError) {
            @Expect(error.code, "llm.message_empty"); @Expect(error.inputItemIndex, 1)
            @Expect(error.dialectId, "openai.responses.v1"); @Expect(error.phase, Some(LlmTransportPhase.Encode))
        }
        builder.appendMessage(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(
            LlmWireToolResultBlock("call", [LlmWireToolResultContent.Text(LlmWireTextBlock("completed"))]))]))
        let request = builderTestValue(builder.build())
        @Expect(request.transcript.items.size, 2)
        @Expect(builderTestEncoded(builderTestCodec(), request).isEmpty(), false)
        let before = builderTestSnapshot(request)
        builder.appendMessage(builderTestText("next"))
        @Expect(builderTestValue(builder.build()).transcript.items.size, 3)
        @Expect(builderTestSnapshot(request), before)
    }
}
