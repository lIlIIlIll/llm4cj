package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

@Test
class TranscriptBranchFeatureTests {
    @TestCase
    func spansRetainUnspecifiedTextAndNontextContentWithoutInventingPhase() {
        let source = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [
            LlmWireBlock.Text(LlmWireTextBlock("text")), LlmWireBlock.Refusal(LlmWireRefusalBlock("declined"))
        ], messageSpans: [LlmWireAssistantMessageSpan(0, 2, phase: LlmWireOutputPhase.Final)]))])
        let fork = branchValue(source.forkAt(1))
        @Expect(branchSnapshot(fork), branchSnapshot(source))
        let message = match (fork.items[0]) { case LlmWireInputItem.Message(value) => value; case _ => @Fail("expected message") }
        @Expect(message.messageSpans[0].phase, LlmWireOutputPhase.Final)
        match (message.blocks[0]) { case LlmWireBlock.Text(text) => @Expect(text.phase, LlmWireOutputPhase.Unspecified); case _ => @Fail("expected text") }
        match (message.blocks[1]) { case LlmWireBlock.Refusal(value) => @Expect(value.text, "declined"); case _ => @Fail("expected refusal") }
    }

    @TestCase
    func cachePositionsKeepOriginalCoordinatesAndDropDiscardedTail() {
        let initial = LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.System, "initial")], tools: [branchDefinition("lookup")])
        let markers = [
            LlmWireCacheBreakpoint(LlmWireCachePosition.InitialTool(0)),
            LlmWireCacheBreakpoint(LlmWireCachePosition.InitialInstruction(0)),
            LlmWireCacheBreakpoint(LlmWireCachePosition.Item(1)),
            LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(2, 0))
        ]
        let source = LlmWireTranscript(initial, items: [branchText("zero"), branchText("one"), branchText("two")], cacheBreakpoints: markers)
        let before = branchSnapshot(source)
        let empty = branchValue(source.forkAt(0)); let middle = branchValue(source.forkAt(2)); let full = branchValue(source.forkAt(3))
        @Expect(empty.cacheBreakpoints.size, 2); @Expect(middle.cacheBreakpoints.size, 3); @Expect(full.cacheBreakpoints.size, 4)
        @Expect(empty.cacheBreakpoints[0].position, LlmWireCachePosition.InitialTool(0))
        @Expect(empty.cacheBreakpoints[1].position, LlmWireCachePosition.InitialInstruction(0))
        @Expect(middle.cacheBreakpoints[2].position, LlmWireCachePosition.Item(1))
        @Expect(full.cacheBreakpoints[3].position, LlmWireCachePosition.MessageBlock(2, 0))
        let reply = LlmWireReply(blocks: [LlmWireOutputBlock.Text(LlmWireTextBlock("continuation"))])
        let appended = branchValue(middle.appendContinuation(reply))
        @Expect(appended.items.size, 3); @Expect(appended.cacheBreakpoints.size, 3)
        @Expect(appended.cacheBreakpoints[2].position, LlmWireCachePosition.Item(1))
        let observed = appended.cacheBreakpoints; observed[0] = markers[3]
        @Expect(appended.cacheBreakpoints[0].position, LlmWireCachePosition.InitialTool(0))
        @Expect(branchSnapshot(branchValue(LlmWireTranscript.restore(branchSnapshot(appended)))), branchSnapshot(appended))
        @Expect(branchSnapshot(source), before)
        let tailOnly = LlmWireTranscript(items: [branchText("tail")], cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.Item(0))])
        @Expect(branchSnapshot(tailOnly).contains("\"version\":3"), true)
        @Expect(branchSnapshot(branchValue(tailOnly.forkAt(0))), branchSnapshot(LlmWireTranscript()))
        @Expect(branchSnapshot(empty).contains("\"version\":3"), true)
    }

    @TestCase
    func customContinuationPreservesRawTextAndPendingKindIdentity() {
        let declaration = LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("run")))
        let source = LlmWireTranscript(items: [LlmWireInputItem.ToolDeclaration(declaration), branchText("history")])
        let call = LlmWireToolCallBlock("custom", "run", LlmWireToolArguments.Text("not-json[ é"))
        let reply = LlmWireReply(choices: [LlmWireChoice(9, [LlmWireOutputBlock.ToolCall(call)], LlmWireChoiceOutcome.Incomplete(LlmWireIncompleteReason.MaxTokens))])
        let waiting = branchValue(source.appendContinuation(reply, 9))
        let _ = branchError(waiting.forkAt(3), "llm.tool_call_unresolved")
        let wrongKind = waiting.append(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [branchResult("custom")])))
        let _ = branchError(wrongKind.forkAt(4), "llm.tool_kind_mismatch")
        let result = LlmWireToolResultBlock("custom", [LlmWireToolResultContent.Text(LlmWireTextBlock("done"))], kind: LlmWireToolKind.Custom)
        let closed = waiting.append(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(result)])))
        let fork = branchValue(closed.forkAt(4)); let snapshot = branchSnapshot(fork)
        @Expect(snapshot.contains("not-json[ é"), true); @Expect(snapshot.contains("\"tool_kind\":\"custom\""), true)
        @Expect(branchSnapshot(branchValue(LlmWireTranscript.restore(snapshot))), snapshot)
        @Expect(branchSnapshot(branchValue(closed.forkAt(0))), branchSnapshot(LlmWireTranscript()))
        let partial = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("partial", "run", LlmWireToolArguments.PartialText("raw")))])
        let _ = branchError(source.appendContinuation(partial), "llm.tool_arguments_not_executable")
        let _ = branchError(branchValue(source.forkAt(0)).appendContinuation(reply, 9), "llm.tool_reference_unknown")
        @Expect(source.items.size, 2); @Expect(waiting.items.size, 3)
    }

    @TestCase
    func audioContinuationPreservesEntireReplayGroupAndClockGate() {
        let codec = audioTestCodec(); let reply = audioTestFixed(codec, audioTestContext(codec, LlmWireAudioFormat.Mp3), audioTestObject())
        let source = LlmWireTranscript(items: [branchText("history")]); let before = branchSnapshot(source)
        let appended = branchValue(source.appendContinuation(reply)); let full = branchValue(appended.forkAt(2))
        let snapshot = branchSnapshot(full)
        @Expect(snapshot.contains("\"version\":3"), true)
        @Expect(snapshot.contains("\"block_order\":1"), true)
        @Expect(branchSnapshot(branchValue(LlmWireTranscript.restore(snapshot))), snapshot)
        let prepared = codec.encodeRequest(LlmWireRequest("audio-model", full))
        @Expect(prepared.materialize().isOk(), false); @Expect(prepared.materialize(nowEpochSeconds: Some(100)).isOk(), false)
        let body = String.fromUtf8(branchValue(prepared.materialize(nowEpochSeconds: Some(99))).body)
        @Expect(body.contains("\"audio\":{\"id\":\"a\"}"), true)
        @Expect(body.contains("spoken"), false)
        @Expect(branchSnapshot(branchValue(appended.forkAt(1))), before)
        let blocks = match (full.items[1]) { case LlmWireInputItem.Message(message) => message.blocks; case _ => @Fail("expected assistant") }
        let relocated = LlmWireTranscript(items: [branchText("history"), LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [blocks[1]]))])
        let _ = branchError(relocated.forkAt(2), "llm.transcript_snapshot_invalid")
        @Expect(branchSnapshot(branchValue(relocated.forkAt(1))), before)
        let extended = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [blocks[0], blocks[1], LlmWireBlock.Text(LlmWireTextBlock("after"))]))])
        let _ = branchError(extended.appendContinuation(LlmWireReply()), "llm.transcript_snapshot_invalid")
        let partial = audioTestFixed(codec, audioTestContext(codec, LlmWireAudioFormat.Mp3), audioTestObject(), reason: "length")
        @Expect(source.appendContinuation(partial).isOk(), false)
        @Expect(branchSnapshot(source), before)
    }

    @TestCase
    func mixedSnapshotVisitorsPreserveFeaturesAndRejectVersionConfusion() {
        let input = branchValue(LlmWireAudioInputBlock.fromBytes(LlmWireAudioFormat.Wav, [0u8, 1u8, 2u8]))
        let declaration = LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("run")))
        let history = LlmWireTranscript(items: [
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.AudioInput(input)])),
            LlmWireInputItem.ToolDeclaration(declaration),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(LlmWireToolCallBlock("mixed", "run", LlmWireToolArguments.Text("raw")))])),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(LlmWireToolResultBlock("mixed", [], kind: LlmWireToolKind.Custom))]))
        ])
        let codec = audioTestCodec(); let reply = audioTestFixed(codec, audioTestContext(codec, LlmWireAudioFormat.Wav), audioTestObject())
        let appended = branchValue(history.appendContinuation(reply))
        let source = LlmWireTranscript(items: appended.items, cacheBreakpoints: [
            LlmWireCacheBreakpoint(LlmWireCachePosition.Item(3)), LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(4, 1))
        ])
        let snapshot = branchSnapshot(branchValue(source.forkAt(5)))
        for (tag in ["\"audio_input\"", "\"audio_replay\"", "\"tool_kind\":\"custom\"", "\"cache_breakpoints\""]) { @Expect(snapshot.contains(tag), true) }
        @Expect(branchSnapshot(branchValue(LlmWireTranscript.restore(snapshot))), snapshot)
        @Expect(branchSnapshot(branchValue(source.forkAt(0))), branchSnapshot(LlmWireTranscript()))
        @Expect(branchValue(source.forkAt(1)).cacheBreakpoints.size, 0)
        @Expect(branchValue(source.forkAt(4)).cacheBreakpoints.size, 1)
        @Expect(LlmWireTranscript.restore(snapshot.replace("\"version\":3", "\"version\":2")).isOk(), false)
        @Expect(LlmWireTranscript.restore(snapshot.replace("\"tool_kind\":\"custom\"", "\"tool_kind\":\"function\"")).isOk(), false)
        @Expect(LlmWireTranscript.restore(snapshot.replace("\"cache_breakpoints\":[", "\"unknown_cache\":[")).isOk(), false)
        let empty = branchSnapshot(LlmWireTranscript())
        @Expect(branchSnapshot(branchValue(LlmWireTranscript.restore(empty.replace("\"version\":2", "\"version\":1")))), empty)
        @Expect(branchSnapshot(branchValue(LlmWireTranscript.restore(empty.replace("\"version\":2", "\"version\":3")))), empty)
        @Expect(LlmWireTranscript.restore(empty.replace("\"items\":[]", "\"items\":[],\"cache_breakpoints\":[]")).isOk(), false)
    }
}
