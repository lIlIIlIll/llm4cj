package llm4cj

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func acceptanceBudgetCodec(count: Int64): LlmWireCodec {
    let modes = ArrayList<LlmWireThinkingMode>()
    for (index in 0..count) { modes.add(LlmWireThinkingMode.Budget(index + 1)) }
    modes.add(LlmWireThinkingMode.Adaptive)
    let capabilities = LlmWireCapabilities(thinking: LlmWireThinkingCapabilities(modes: modes.toArray()))
    anthropicMessagesCodec(anthropicMessagesModelProfile("model", capabilities: capabilities))
}

func acceptanceBudgetRequest(count: Int64): LlmWireRequest {
    let instruction = LlmWireInstruction(LlmWireInstructionRole.System, "private-instruction")
    let initial = LlmWireInitialContext(instructions: Array<LlmWireInstruction>(count, repeat: instruction))
    LlmWireRequest("model", LlmWireTranscript(initial, items: [capabilityUser()]),
        thinkingMode: LlmWireThinkingMode.Adaptive, maxOutputTokens: Some(32))
}

@Test
class CapabilityInspectionAcceptanceTests {
    @TestCase
    func capabilityStorageParticipatesInTheWorkBudgetBeforeObservation() {
        let smallCodec = acceptanceBudgetCodec(0)
        // Locate the public work boundary without depending on internal check counts.
        var lower: Int64 = 0
        var upper: Int64 = 50001
        while (upper - lower > 1) {
            let middle = lower + (upper - lower) / 2
            let report = inspectRequestCapabilities(smallCodec, acceptanceBudgetRequest(middle))
            if (report.truncated) { upper = middle } else { @Expect(report.complete, true); lower = middle }
        }
        let request = acceptanceBudgetRequest(lower)
        let small = inspectRequestCapabilities(smallCodec, request)
        @Expect(small.complete, true); @Expect(small.truncated, false)
        let codec = acceptanceBudgetCodec(100)
        let large = inspectRequestCapabilities(codec, request)
        @Expect(large.complete, false); @Expect(large.truncated, true)
        for (diagnostic in large.diagnostics) {
            @Expect((diagnostic.message + diagnostic.code + diagnostic.featureId).contains("private"), false)
        }
        @Expect(codec.encodeRequest(request).materialize().isOk(), true)
    }

    @TestCase
    func malformedReplayDoesNotInventAnActiveToolView() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let transcript = LlmWireTranscript(items: [
            LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity("unknown")), capabilityUser()])
        let request = LlmWireRequest("model", transcript,
            thinkingMode: LlmWireThinkingMode.Budget(1), reasoningEffort: LlmWireReasoningEffort.High,
            parallelToolCalls: Some(true), toolChoice: LlmWireToolChoice.Required,
            structuredOutput: LlmWireStructuredOutput.JsonObject,
            promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ThirtyMinutes))
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, false); @Expect(report.truncated, false)
        @Expect(capabilityHas(report, "llm.tool_reference_unknown", itemIndex: 0), true)
        for (code in ["llm.tool_choice_without_tools", "llm.parallel_tools_without_tools", "llm.tools_unsupported"]) {
            @Expect(capabilityHas(report, code), false)
        }
        for (code in ["llm.thinking_budget_invalid", "llm.reasoning_effort_unsupported", "llm.parallel_tools_unsupported",
            "llm.structured_output_unsupported", "llm.cache_lifetime_unsupported"]) {
            @Expect(capabilityHas(report, code), true)
        }
        try { let _ = codec.encodeRequest(request); @Fail("malformed replay must refuse encoding") }
        catch (error: LlmWireError) { @Expect(error.code, "llm.tool_reference_unknown") }
    }

    @TestCase
    func retainedReportsHaveDeterministicOrderAndSafeTextBounds() {
        let items = ArrayList<LlmWireInputItem>()
        for (_ in 0..150) { items.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User,
            [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "https://example.test/private"))]))) }
        items.add(LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity("private-tool")))
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"), provider: "Bearer private-token")
        let request = LlmWireRequest("model", LlmWireTranscript(items: items.toArray()),
            thinkingMode: LlmWireThinkingMode.Enabled, serviceTier: LlmWireServiceTier.Priority)
        let first = inspectRequestCapabilities(codec, request)
        let second = inspectRequestCapabilities(codec, request)
        @Expect(first.complete, false); @Expect(first.truncated, true)
        @Expect(first.diagnostics.size, 128); @Expect(second.diagnostics.size, first.diagnostics.size)
        @Expect(capabilityHas(first, "llm.tool_reference_unknown", itemIndex: 150), true)
        var bytes: Int64 = 0
        for (index in 0..first.diagnostics.size) {
            let left = first.diagnostics[index]; let right = second.diagnostics[index]
            @Expect(left.kind, right.kind); @Expect(left.featureId, right.featureId); @Expect(left.code, right.code)
            @Expect(left.message, right.message); @Expect(left.inputItemIndex, right.inputItemIndex)
            @Expect(left.blockIndex, right.blockIndex); @Expect(left.requirementState, right.requirementState)
            @Expect(left.message.size <= 256, true)
            @Expect((left.message + left.code + left.featureId).contains("private"), false)
            bytes += left.message.size + left.code.size + left.featureId.size
            match (left.requirementState) {
                case Some(LlmWireRequirementState.Unknown(text)) => bytes += text.size
                case Some(LlmWireRequirementState.Unsatisfied(text)) => bytes += text.size
                case _ => ()
            }
        }
        @Expect(bytes <= 65536, true)
    }
}
