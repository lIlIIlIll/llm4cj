package llm4cj

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func capabilityJson(source: String): LlmWireJson {
    match (LlmWireJson.parse(source)) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
}

func capabilityUser(text!: String = "hello"): LlmWireInputItem {
    LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock(text))]))
}

func capabilityHas(report: LlmWireRequestCapabilityReport, code: String, itemIndex!: Int64 = -2): Bool {
    for (value in report.diagnostics where value.code == code) {
        if (itemIndex == -2 || value.inputItemIndex == itemIndex) { return true }
    }
    false
}

class CapabilitySatisfiedResolver <: LlmWireRequirementResolver {
    public func resolve(requirement: LlmWireFeatureRequirement): LlmWireRequirementState {
        let _ = requirement; LlmWireRequirementState.Satisfied
    }
}

@Test
class CapabilityInspectionTests {
    @TestCase
    func multipleIndependentFailuresUseTheStrictCheckSource() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let tool = LlmWireToolDeclaration(LlmWireTool("lookup", "", capabilityJson("{}")))
        let request = LlmWireRequest("model", LlmWireTranscript(items: [LlmWireInputItem.ToolDeclaration(tool), capabilityUser()]),
            thinkingMode: LlmWireThinkingMode.Budget(512), reasoningEffort: LlmWireReasoningEffort.High,
            maxOutputTokens: Some(256), parallelToolCalls: Some(true),
            serviceTier: LlmWireServiceTier.Priority, generationSpeed: LlmWireGenerationSpeed.Fast,
            promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ThirtyMinutes),
            structuredOutput: LlmWireStructuredOutput.JsonObject)
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, true); @Expect(report.truncated, false)
        for (code in ["llm.context_update_unsupported", "llm.thinking_unsupported", "llm.reasoning_effort_unsupported",
            "llm.thinking_budget_invalid", "llm.thinking_budget_exceeds_output", "llm.tools_unsupported",
            "llm.structured_output_unsupported", "llm.parallel_tools_unsupported", "llm.service_tier_unsupported",
            "llm.generation_speed_unsupported", "llm.cache_lifetime_unsupported"]) { @Expect(capabilityHas(report, code), true) }
        try { let _ = codec.encodeRequest(request); @Fail("strict encoding must reject") }
        catch (error: LlmWireError) { @Expect(capabilityHas(report, error.code, itemIndex: error.inputItemIndex), true) }
    }

    @TestCase
    func invalidTranscriptKeepsItsErrorAndIndependentOptions() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let call = LlmWireToolCallBlock("call", "unknown", LlmWireToolArguments.Complete(capabilityJson("{}")))
        let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(call)]))])
        let report = inspectRequestCapabilities(codec, LlmWireRequest("model", transcript,
            thinkingMode: LlmWireThinkingMode.Budget(1), reasoningEffort: LlmWireReasoningEffort.High))
        @Expect(report.complete, false); @Expect(report.truncated, false)
        @Expect(capabilityHas(report, "llm.tool_reference_unknown", itemIndex: 0), true)
        @Expect(capabilityHas(report, "llm.thinking_budget_invalid"), true)
        @Expect(capabilityHas(report, "llm.reasoning_effort_unsupported"), true)
    }

    @TestCase
    func externalUnknownRemainsARequirementUntilMaterialization() {
        let capabilities = LlmWireCapabilities(output: LlmWireOutputCapabilities(generationSpeeds: [LlmWireGenerationSpeed.Fast]))
        let codec = anthropicMessagesCodec(anthropicMessagesModelProfile("model", capabilities: capabilities))
        let request = LlmWireRequest("model", LlmWireTranscript(items: [capabilityUser()]), maxOutputTokens: Some(32), generationSpeed: LlmWireGenerationSpeed.Fast)
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, true); @Expect(report.diagnostics.size, 1)
        let diagnostic = report.diagnostics[0]
        @Expect(diagnostic.kind, LlmWireCapabilityDiagnosticKind.Requirement)
        @Expect(diagnostic.featureId, "anthropic.fast_mode")
        @Expect(diagnostic.code, "llm.feature_requirement_unresolved")
        match (diagnostic.requirementState) { case Some(LlmWireRequirementState.Unknown(_)) => (); case _ => @Fail("retain Unknown") }
        let prepared = codec.encodeRequest(request)
        match (prepared.materialize()) { case LlmWireResult.Err(error) => @Expect(error.code, diagnostic.code); case _ => @Fail("unresolved requirement must refuse") }
        @Expect(prepared.materialize(resolver: Some(CapabilitySatisfiedResolver())).isOk(), true)
        let undeclared = anthropicMessagesCodec(anthropicMessagesModelProfile("model"))
        @Expect(capabilityHas(inspectRequestCapabilities(undeclared, request), "llm.generation_speed_unsupported"), true)
    }

    @TestCase
    func locallySatisfiedRequirementDoesNotBecomeUnknown() {
        let capabilities = LlmWireCapabilities(cache: LlmWireCacheCapabilities(lifetimes: [LlmWirePromptCacheLifetime.ProviderDefault]))
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model", capabilities: capabilities))
        let request = LlmWireRequest("model", LlmWireTranscript(items: [capabilityUser()]), promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault))
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, true); @Expect(report.diagnostics.size, 1)
        @Expect(report.diagnostics[0].featureId, "openai.prompt_cache_automatic")
        match (report.diagnostics[0].requirementState) { case Some(LlmWireRequirementState.Satisfied) => (); case _ => @Fail("retain Satisfied") }
        @Expect(codec.encodeRequest(request).materialize().isOk(), true)
    }

    @TestCase
    func boundProfileAndRedactedDefensiveReportsStayStable() {
        let endpoint = LlmWireEndpointProfile("fixture.report", "model", "openai.responses.v1", "https://example.test/responses", 1,
            LlmWireContextUpdateCapabilities(toolDeclaration: true), "caller", "2026-10-01")
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model", endpoint: endpoint.endpoint, endpointProfile: Some(endpoint)), provider: "Bearer private-provider")
        let request = LlmWireRequest("private-model", LlmWireTranscript(items: [capabilityUser(text: "private-prompt")]),
            promptCacheRoutingKey: Some("private-routing-key"), thinkingMode: LlmWireThinkingMode.Enabled)
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.profileId, "fixture.report"); @Expect(report.contractVersion, 1)
        @Expect(capabilityHas(report, "llm.model_profile_mismatch"), true)
        for (value in report.diagnostics) {
            @Expect(value.message.size <= 256, true)
            @Expect((value.message + value.code + value.featureId).contains("private"), false)
        }
        let original = report.diagnostics[0].code
        let values = report.diagnostics
        values[0] = report.diagnostics[report.diagnostics.size - 1]
        @Expect(report.diagnostics[0].code, original)
        @Expect(request.model, "private-model")
    }

    @TestCase
    func countBoundKeepsTheStructuralPrerequisiteAndInputOrder() {
        let items = ArrayList<LlmWireInputItem>()
        for (_ in 0..150) { items.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User,
            [LlmWireBlock.Image(LlmWireImageBlock(LlmWireImageSourceKind.Url, "https://example.test/image"))]))) }
        let call = LlmWireToolCallBlock("unknown-call", "unknown", LlmWireToolArguments.Complete(capabilityJson("{}")))
        items.add(LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(call)])))
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let report = inspectRequestCapabilities(codec, LlmWireRequest("model", LlmWireTranscript(items: items.toArray())))
        @Expect(report.complete, false); @Expect(report.truncated, true)
        @Expect(report.diagnostics.size, 128)
        @Expect(capabilityHas(report, "llm.tool_reference_unknown", itemIndex: 150), true)
        var last: Int64 = -1
        var bytes: Int64 = 0
        for (value in report.diagnostics) {
            @Expect(value.inputItemIndex >= last, true); last = value.inputItemIndex
            bytes += value.message.size + value.featureId.size + value.code.size
        }
        @Expect(bytes <= 65536, true)
    }

    @TestCase
    func workLimitsStopBeforeCopyingWideOrLongInput() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let block = LlmWireBlock.Text(LlmWireTextBlock("x"))
        let wide = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, Array<LlmWireBlock>(100001, repeat: block)))])
        let visits = inspectRequestCapabilities(codec, LlmWireRequest("model", wide))
        @Expect(visits.complete, false); @Expect(visits.truncated, true)
        let text = String.fromUtf8(Array<Byte>(16777217, repeat: b'x'))
        let bytes = inspectRequestCapabilities(codec, LlmWireRequest("model", LlmWireTranscript(items: [capabilityUser(text: text)])))
        @Expect(bytes.complete, false); @Expect(bytes.truncated, true)
        let nodes = Array<LlmWireJson>(100001, repeat: LlmWireJson.nullValue())
        let json = match (LlmWireJson.array(nodes)) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
        let schema = LlmWireToolDeclaration(LlmWireTool("tool", "", json))
        let tree = inspectRequestCapabilities(codec, LlmWireRequest("model", LlmWireTranscript(LlmWireInitialContext(tools: [schema]), items: [capabilityUser()])))
        @Expect(tree.complete, false); @Expect(tree.truncated, true)
    }

    @TestCase
    func encodingOnlyCodexChecksAreShared() {
        let codec = openAiCodexResponsesCodec(openAiCodexResponsesModelProfile("model"))
        let initial = LlmWireInitialContext(instructions: [LlmWireInstruction(LlmWireInstructionRole.Developer, "developer"), LlmWireInstruction(LlmWireInstructionRole.System, "system")])
        let request = LlmWireRequest("model", LlmWireTranscript(initial), maxOutputTokens: Some(32))
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, true)
        for (code in ["llm.codex_stream_required", "llm.codex_max_output_tokens_unsupported", "llm.codex_instruction_order_unsupported"]) { @Expect(capabilityHas(report, code), true) }
        try { let _ = codec.encodeRequest(request); @Fail("Codex requires streaming") }
        catch (error: LlmWireError) { @Expect(capabilityHas(report, error.code), true) }
    }

    @TestCase
    func repeatedSchemaComparisonIsChargedBeforeCanonicalSorting() {
        let fields = ArrayList<LlmWireJsonField>()
        for (index in 0..400) { fields.add(LlmWireJsonField("property_" + index.toString(), LlmWireJson.nullValue())) }
        let schema = match (LlmWireJson.object(fields.toArray())) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
        let declaration = LlmWireToolDeclaration(LlmWireTool("tool", "", schema))
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [declaration]), items: [LlmWireInputItem.ToolDeclaration(declaration), capabilityUser()])
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let report = inspectRequestCapabilities(codec, LlmWireRequest("model", transcript))
        @Expect(report.complete, false); @Expect(report.truncated, true)
    }

    @TestCase
    func supportedRequestsAcrossEveryDialectStillMaterialize() {
        let codecs = [openAiResponsesCodec(openAiResponsesModelProfile("model")), openAiChatCodec(openAiChatModelProfile("model")),
            anthropicMessagesCodec(anthropicMessagesModelProfile("model")), deepSeekResponsesCodec(deepSeekResponsesModelProfile("model")),
            deepSeekChatCodec(deepSeekChatModelProfile("model")), deepSeekMessagesCodec(deepSeekMessagesModelProfile("model")),
            kimiChatCodec(kimiChatModelProfile("model")), openAiCodexResponsesCodec(openAiCodexResponsesModelProfile("model"))]
        for (codec in codecs) {
            let codex = codec.dialect.compatibilityId == "openai.codex.responses.v1"
            let request = LlmWireRequest("model", LlmWireTranscript(items: [capabilityUser()]), maxOutputTokens: if (codex) { None } else { Some(32) })
            let report = inspectRequestCapabilities(codec, request, streaming: codex)
            @Expect(report.complete, true); @Expect(report.truncated, false); @Expect(report.diagnostics.size, 0)
            @Expect(codec.encodeRequest(request, streaming: codex).materialize().isOk(), true)
        }
    }

    @TestCase
    func phaseAndTextMetadataChecksPreserveBlockLocations() {
        let citation = LlmWireCitation(LlmWireCitationKind.Url, url: "https://example.test/private")
        let number = capabilityJson("-0.5")
        let candidate = LlmWireTokenLogprobCandidate("private-candidate", number, bytes: [1])
        let probability = LlmWireTokenLogprob("private-token", number, bytes: [1], topLogprobs: [candidate])
        let text = LlmWireTextBlock("private-text", citations: [citation], annotations: [LlmWireAnnotation.UrlCitation(citation), LlmWireAnnotation.FileCitation(citation)], logprobs: [probability], phase: LlmWireOutputPhase.Analysis)
        let message = LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(text), LlmWireBlock.Reasoning(LlmWireReasoningBlock("private-reasoning")),
            LlmWireBlock.Refusal(LlmWireRefusalBlock("private-refusal", category: Some("private-category"), explanation: Some("private-explanation"), logprobs: [probability]))])
        let codec = openAiCodexResponsesCodec(openAiCodexResponsesModelProfile("model"))
        let report = inspectRequestCapabilities(codec, LlmWireRequest("model", LlmWireTranscript(items: [LlmWireInputItem.Message(message)])), streaming: true)
        for (code in ["llm.codex_phase_role_unsupported", "llm.responses_phase_unsupported", "llm.codex_text_metadata_unsupported", "llm.reasoning_display_only", "llm.refusal_display_only"]) {
            @Expect(capabilityHas(report, code, itemIndex: 0), true)
        }
        for (diagnostic in report.diagnostics) { @Expect(diagnostic.blockIndex >= 0, true); @Expect(diagnostic.message.contains("private"), false) }
    }

    @TestCase
    func missingContextGrantsAreReportedPerOperation() {
        let initial = LlmWireToolDeclaration(LlmWireTool("initial", "", capabilityJson("{}")), deferred: true)
        let extension = LlmWireToolDeclaration(LlmWireTool("extension", "", capabilityJson("{}")), deferred: true)
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [initial]), items: [
            LlmWireInputItem.ToolActivation(initial.identity), LlmWireInputItem.ToolDeactivation(initial.identity),
            LlmWireInputItem.ToolDeclaration(extension), LlmWireInputItem.InstructionUpdate(LlmWireInstruction(LlmWireInstructionRole.Developer, "update"))])
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model", capabilities: LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))))
        let report = inspectRequestCapabilities(codec, LlmWireRequest("model", transcript))
        @Expect(report.complete, true)
        let features = ArrayList<String>()
        for (diagnostic in report.diagnostics) { features.add(diagnostic.featureId) }
        for (expected in ["context.deferred_tool_pool", "context.tool_activation", "context.tool_deactivation", "context.tool_declaration", "context.deferred_pool_extension", "context.append_developer_instruction"]) {
            var found = false; for (feature in features where feature == expected) { found = true }; @Expect(found, true)
        }
    }

    @TestCase
    func invalidProfileCannotGrantUnsupportedOperations() {
        let endpoint = LlmWireEndpointProfile("fixture.invalid", "model", "openai.responses.v1", "https://example.test/responses", 1,
            LlmWireContextUpdateCapabilities(toolActivation: true), "caller", "2026-10-01")
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model", endpoint: endpoint.endpoint, endpointProfile: Some(endpoint)))
        let report = inspectRequestCapabilities(codec, LlmWireRequest("model", LlmWireTranscript(items: [capabilityUser()])))
        @Expect(report.complete, false)
        @Expect(capabilityHas(report, "llm.endpoint_profile_capability_unsupported"), true)
    }

    @TestCase
    func kimiResultRepresentationAndArgumentShapesUseExistingErrors() {
        let capabilities = LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))
        let codec = kimiChatCodec(kimiChatModelProfile("model", capabilities: capabilities))
        let tool = LlmWireToolDeclaration(LlmWireTool("lookup", "", capabilityJson("{}")))
        let call = LlmWireToolCallBlock("call", "lookup", LlmWireToolArguments.Complete(capabilityJson("{}")))
        let result = LlmWireToolResultBlock("call", [LlmWireToolResultContent.Text(LlmWireTextBlock("one")), LlmWireToolResultContent.Text(LlmWireTextBlock("two"))])
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [tool]), items: [
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.ToolCall(call)])),
            LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.ToolResult(result)]))])
        let report = inspectRequestCapabilities(codec, LlmWireRequest("model", transcript))
        @Expect(report.complete, true)
        @Expect(capabilityHas(report, "llm.kimi_tool_result_content_unsupported", itemIndex: 1), true)
        let arguments = [LlmWireToolArguments.InvalidJson("private-json"), LlmWireToolArguments.InvalidShape(capabilityJson("[]")), LlmWireToolArguments.Partial("private-partial")]
        for (argument in arguments) {
            let invalid = LlmWireTranscript(LlmWireInitialContext(tools: [tool]), items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant,
                [LlmWireBlock.ToolCall(LlmWireToolCallBlock("call", "lookup", argument))]))])
            let value = inspectRequestCapabilities(codec, LlmWireRequest("model", invalid))
            @Expect(value.complete, false); @Expect(value.diagnostics.size > 0, true)
            for (diagnostic in value.diagnostics) { @Expect(diagnostic.message.contains("private"), false) }
        }
    }
}
