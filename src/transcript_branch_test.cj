package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

func branchValue<T>(value: LlmWireResult<T>): T {
    match (value) { case LlmWireResult.Ok(result) => result; case LlmWireResult.Err(error) => throw error }
}

func branchJson(value: String): LlmWireJson { branchValue(LlmWireJson.parse(value)) }
func branchSnapshot(value: LlmWireTranscript): String { branchValue(value.snapshot()) }
func branchText(value: String): LlmWireInputItem {
    LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(value))]))
}
func branchCall(id: String, name!: String = "lookup"): LlmWireToolCallBlock {
    LlmWireToolCallBlock(id, name, LlmWireToolArguments.Complete(branchJson("{}")))
}
func branchDefinition(name: String, deferred!: Bool = false): LlmWireToolDeclaration {
    LlmWireToolDeclaration(LlmWireTool(name, "", branchJson("{}")), deferred: deferred)
}
func branchResult(id: String): LlmWireBlock {
    LlmWireBlock.ToolResult(LlmWireToolResultBlock(id, [LlmWireToolResultContent.Text(LlmWireTextBlock("result"))]))
}
func branchError<T>(value: LlmWireResult<T>, code: String): LlmWireError {
    match (value) {
        case LlmWireResult.Err(error) => @Expect(error.code, code); error
        case _ => @Fail("expected branch error " + code)
    }
}
func branchNative(order: Int64): LlmWireNativeReplayBlock {
    LlmWireNativeReplayBlock.restore("{\"protocol\":\"responses\",\"dialect_id\":\"openai.responses.v1\",\"native_type\":\"reasoning\",\"schema_version\":1,\"scope\":\"assistant_turn\",\"assistant_turn_index\":0,\"block_order\":" + order.toString() + ",\"complete\":true,\"payload\":{\"type\":\"reasoning\",\"id\":\"reasoning-id\",\"summary\":[],\"encrypted_content\":\"signature\"}}")
}

@Test
class TranscriptBranchTests {
    @TestCase
    func forkBoundariesPreserveContextAndIgnoreDiscardedInvalidTail() {
        let context = LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "initial")])
        let source = LlmWireTranscript(context, items: [branchText("first"), LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(branchCall("unknown"))]))])
        let before = branchSnapshot(source)
        let empty = branchValue(source.forkAt(0))
        @Expect(empty.items.size, 0)
        @Expect(empty.initialContext.instructions[0].text, "initial")
        let prefix = branchValue(source.forkAt(1))
        @Expect(prefix.items.size, 1)
        @Expect(branchSnapshot(branchValue(prefix.forkAt(1))), branchSnapshot(prefix))
        @Expect(branchError(source.forkAt(-1), "llm.transcript_index_invalid").inputItemIndex, -1)
        @Expect(branchError(source.forkAt(3), "llm.transcript_index_invalid").inputItemIndex, 3)
        @Expect(branchError(source.forkAt(2), "llm.tool_reference_unknown").inputItemIndex, 1)
        @Expect(branchSnapshot(source), before)
    }

    @TestCase
    func forkCannotSplitParallelCallsAndTheirResults() {
        let context = LlmWireInitialContext(tools: [branchDefinition("lookup")])
        let calls = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(branchCall("one")), LlmWireBlock.ToolCall(branchCall("two"))]))
        let results = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [branchResult("one"), branchResult("two")]))
        let source = LlmWireTranscript(context, items: [calls, results])
        let before = branchSnapshot(source)
        let _ = branchError(source.forkAt(1), "llm.tool_call_unresolved")
        @Expect(branchSnapshot(branchValue(source.forkAt(2))), before)
        let split = LlmWireTranscript(context, items: [calls, LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [branchResult("one")]))])
        let _ = branchError(split.forkAt(2), "llm.tool_results_incomplete")
        @Expect(branchSnapshot(source), before)
    }

    @TestCase
    func forksKeepHistoricalDeclarationsAndVisibility() {
        let source = LlmWireTranscript(LlmWireInitialContext(tools: [branchDefinition("lookup"), branchDefinition("deferred", deferred: true)]), items: [
            branchText("history"),
            LlmWireInputItem.ToolDeactivation(LlmWireToolDefinitionIdentity("lookup")),
            LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity("deferred")),
            LlmWireInputItem.ToolDeclaration(branchDefinition("later")),
            LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.Developer, "later instruction"))
        ])
        let early = branchValue(source.forkAt(1))
        let removed = branchValue(source.forkAt(2))
        let activated = branchValue(source.forkAt(3))
        @Expect(early.effectiveTools[0].name, "lookup")
        @Expect(removed.effectiveTools.size, 0)
        @Expect(activated.effectiveTools[0].name, "deferred")
        @Expect(branchValue(source.forkAt(5)).effectiveTools.size, 2)
        let reply = LlmWireReply(usage: LlmWireUsage(inputTokens: Some(9)), blocks: [LlmWireOutputBlock.ToolCall(branchCall("new"))])
        @Expect(branchValue(early.appendContinuation(reply)).items.size, 2)
        @Expect(branchError(removed.appendContinuation(reply), "llm.tool_not_active").usage.getOrThrow().inputTokens, Some(9))
        let later = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(branchCall("later-call", name: "later"))])
        let _ = branchError(activated.appendContinuation(later), "llm.tool_reference_unknown")
        @Expect(branchValue(source.appendContinuation(later)).items.size, 6)
    }

    @TestCase
    func choiceSelectionPrecedesToolAdmissionAndPreservesUsage() {
        let source = LlmWireTranscript(items: [branchText("history")])
        let good = LlmWireChoice(2, [LlmWireOutputBlock.Text(LlmWireTextBlock("selected"))], LlmWireChoiceOutcome.Completed)
        let bad = LlmWireChoice(7, [LlmWireOutputBlock.ToolCall(branchCall("unknown"))], LlmWireChoiceOutcome.Completed)
        let reply = LlmWireReply(usage: LlmWireUsage(outputTokens: Some(4)), choices: [bad, good])
        @Expect(branchValue(source.appendContinuation(reply, 2)).items.size, 2)
        let _ = branchError(source.appendContinuation(reply, 7), "llm.tool_reference_unknown")
        @Expect(branchError(source.appendContinuation(reply), "llm.continuation_choice_required").usage.getOrThrow().outputTokens, Some(4))
        let _ = branchError(source.appendContinuation(reply, 0), "llm.continuation_choice_missing")
        let _ = branchError(source.appendContinuation(reply, -1), "llm.continuation_choice_missing")
        let _ = branchError(source.appendContinuation(LlmWireReply(choices: [good, good]), 2), "llm.continuation_choice_ambiguous")
        @Expect(branchValue(source.appendContinuation(LlmWireReply(choices: [good]))).items.size, 2)
    }

    @TestCase
    func continuationMayLeaveOnlyItsNewAssistantCallsPending() {
        let source = LlmWireTranscript(LlmWireInitialContext(tools: [branchDefinition("lookup")]), items: [branchText("history")])
        let reply = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(branchCall("one")), LlmWireOutputBlock.ToolCall(branchCall("two"))])
        let waiting = branchValue(source.appendContinuation(reply))
        @Expect(waiting.items.size, 2)
        let _ = branchError(waiting.forkAt(2), "llm.tool_call_unresolved")
        let _ = branchError(waiting.appendContinuation(LlmWireReply(blocks: [LlmWireOutputBlock.Text(LlmWireTextBlock("next"))])), "llm.tool_call_unresolved")
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model", capabilities: LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))))
        let builder = codec.newRequestBuilder()
        builder.setTranscript(waiting)
        let _ = branchError(builder.build(), "llm.tool_call_unresolved")
        builder.appendMessage(LlmWireMessage(LlmWireRole.User, [branchResult("one"), branchResult("two")]))
        let complete = branchValue(builder.build()).transcript
        @Expect(branchValue(complete.forkAt(3)).items.size, 3)
        let reused = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(branchCall("one"))])
        let _ = branchError(complete.appendContinuation(reused), "llm.tool_call_duplicate")
        @Expect(source.items.size, 1)
    }

    @TestCase
    func incompleteAndRefusedChoicesUseLosslessProjectionRules() {
        let source = LlmWireTranscript(LlmWireInitialContext(tools: [branchDefinition("lookup")]), items: [branchText("history")])
        let incomplete = LlmWireChoiceOutcome.Incomplete(LlmWireIncompleteReason.Length)
        @Expect(branchValue(source.appendContinuation(LlmWireReply(choices: [LlmWireChoice(0, [LlmWireOutputBlock.ToolCall(branchCall("complete"))], incomplete)]))).items.size, 2)
        let arguments = [LlmWireToolArguments.Partial("{"), LlmWireToolArguments.InvalidJson("{"), LlmWireToolArguments.InvalidShape(branchJson("[]"))]
        for (value in arguments) {
            let reply = LlmWireReply(choices: [LlmWireChoice(0, [LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("call", "lookup", value))], incomplete)])
            let _ = branchError(source.appendContinuation(reply), "llm.tool_arguments_not_executable")
        }
        let shaped = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("call", "lookup", LlmWireToolArguments.Complete(branchJson("[]"))))])
        let _ = branchError(source.appendContinuation(shaped), "llm.tool_arguments_shape_invalid")
        let refused = LlmWireReply(choices: [LlmWireChoice(0, [LlmWireOutputBlock.Text(LlmWireTextBlock("display"))], LlmWireChoiceOutcome.Refused(LlmWireRefusalBlock("refused")))])
        let _ = branchError(source.appendContinuation(refused), "llm.continuation_projection_lossy")
        let reasoning = LlmWireReply(blocks: [LlmWireOutputBlock.Reasoning(LlmWireReasoningBlock("display only"))])
        let _ = branchError(source.appendContinuation(reasoning), "llm.continuation_projection_lossy")
        @Expect(branchSnapshot(branchValue(source.appendContinuation(LlmWireReply()))), branchSnapshot(source))
    }

    @TestCase
    func continuationAndForkPreserveNativeGroupsSpansAndEncoding() {
        let source = LlmWireTranscript(items: [branchText("history")])
        let choice = LlmWireChoice(0, [
            LlmWireOutputBlock.Text(LlmWireTextBlock("before", phase: LlmWireOutputPhase.Commentary)),
            LlmWireOutputBlock.NativeReplay(branchNative(1)),
            LlmWireOutputBlock.Text(LlmWireTextBlock("after", phase: LlmWireOutputPhase.Final))
        ], LlmWireChoiceOutcome.Completed, messageSpans: [
            LlmWireAssistantMessageSpan(0, 1, phase: LlmWireOutputPhase.Commentary),
            LlmWireAssistantMessageSpan(2, 1, phase: LlmWireOutputPhase.Final)
        ])
        let result = branchValue(source.appendContinuation(LlmWireReply(choices: [choice])))
        let snapshot = branchSnapshot(result)
        @Expect(snapshot.contains("\"version\":2"), true)
        @Expect(snapshot.contains("signature"), true)
        let restored = branchValue(LlmWireTranscript.restore(snapshot))
        let fork = branchValue(restored.forkAt(2))
        @Expect(branchSnapshot(fork), snapshot)
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let encoded = String.fromUtf8(branchValue(codec.encodeRequest(LlmWireRequest("model", result)).materialize()).body)
        @Expect(String.fromUtf8(branchValue(codec.encodeRequest(LlmWireRequest("model", fork)).materialize()).body), encoded)
        let wrong = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.NativeReplay(branchNative(1))]))])
        let _ = branchError(wrong.forkAt(1), "llm.native_replay_order_mismatch")
        let _ = branchError(source.appendContinuation(LlmWireReply(blocks: [LlmWireOutputBlock.NativeReplay(branchNative(1))])), "llm.native_replay_projection_order_invalid")
        let nativeOnly = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.NativeReplay(branchNative(0))]))])
        let partial = branchValue(LlmWireTranscript.restore(branchSnapshot(nativeOnly).replace("\"complete\":true", "\"complete\":false")))
        @Expect(branchValue(partial.forkAt(0)).items.size, 0)
        let _ = branchError(partial.forkAt(1), "llm.native_replay_incomplete")
    }

    @TestCase
    func branchSnapshotsStayIndependentFromSourceAndObservedArrays() {
        let probability = branchJson("-1")
        let text = LlmWireTextBlock("original", logprobs: [LlmWireTokenLogprob("a", probability, bytes: [97], topLogprobs: [LlmWireTokenLogprobCandidate("a", probability, bytes: [97])])])
        let blocks = [LlmWireOutputBlock.Text(text)]
        let source = LlmWireTranscript(items: [branchText("history")])
        let result = branchValue(source.appendContinuation(LlmWireReply(blocks: blocks)))
        let fork = branchValue(result.forkAt(2))
        let before = branchSnapshot(result)
        text.logprobs[0].bytes[0] = 0
        text.logprobs[0].topLogprobs[0].bytes[0] = 0
        blocks[0] = LlmWireOutputBlock.Text(LlmWireTextBlock("changed"))
        match (fork.items[1]) { case LlmWireInputItem.Message(message) =>
            match (message.blocks[0]) { case LlmWireBlock.Text(observed) => observed.logprobs[0].bytes[0] = 1; case _ => @Fail("expected text") }
            message.blocks[0] = LlmWireBlock.Text(LlmWireTextBlock("observed mutation"))
        case _ => @Fail("expected continuation message") }
        @Expect(branchSnapshot(result), before)
        @Expect(branchSnapshot(fork), before)
        @Expect(source.items.size, 1)
    }

    @TestCase
    func retainedMalformedMessagesAndUpdatesFailWithoutChangingSource() {
        let bad = [
            (LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [])), "llm.message_empty"),
            (LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.System, " ")), "llm.instruction_empty"),
            (LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.NativeReplay(branchNative(0))])), "llm.native_replay_role_invalid"),
            (LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("phase", phase: LlmWireOutputPhase.Final))])), "llm.responses_phase_role_unsupported"),
            (LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("span"))], messageSpans: [LlmWireAssistantMessageSpan(0, 1)])), "llm.responses_phase_role_unsupported"),
            (LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(LlmWireTextBlock("span"))], messageSpans: [LlmWireAssistantMessageSpan(1, 1)])), "llm.responses_message_spans_invalid"),
            (LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.Text(LlmWireTextBlock("span", phase: LlmWireOutputPhase.Final))], messageSpans: [LlmWireAssistantMessageSpan(0, 1, phase: LlmWireOutputPhase.Commentary)])), "llm.responses_phase_mismatch")
        ]
        for ((item, code) in bad) {
            let source = LlmWireTranscript(items: [branchText("valid"), item])
            @Expect(branchValue(source.forkAt(1)).items.size, 1)
            @Expect(branchError(source.forkAt(2), code).inputItemIndex, 1)
            @Expect(source.items.size, 2)
        }
        let context = LlmWireTranscript(LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, " ")]))
        let _ = branchError(context.forkAt(0), "llm.instruction_empty")
    }
}
