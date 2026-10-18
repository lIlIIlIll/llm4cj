package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

func requirementReviewTranscript(noisy!: Bool = false): LlmWireTranscript {
    let text = LlmWireTextBlock("private-prompt", phase: if (noisy) { LlmWireOutputPhase.Final } else { LlmWireOutputPhase.Unspecified })
    let message = LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(text)]))
    LlmWireTranscript(items: Array<LlmWireInputItem>(if (noisy) { 201 } else { 1 }, repeat: message))
}

func requirementReviewState(report: LlmWireRequestCapabilityReport, feature: String): String {
    for (value in report.diagnostics where value.kind == LlmWireCapabilityDiagnosticKind.Requirement && value.featureId == feature) {
        return match (value.requirementState) {
            case Some(LlmWireRequirementState.Unknown(_)) => "unknown"
            case Some(LlmWireRequirementState.Satisfied) => "satisfied"
            case _ => "invalid"
        }
    }
    "absent"
}

func requirementReviewHas(report: LlmWireRequestCapabilityReport, code: String): Bool {
    for (value in report.diagnostics where value.code == code) { return true }
    false
}

class RequirementReviewResolver <: LlmWireRequirementResolver {
    public func resolve(requirement: LlmWireFeatureRequirement): LlmWireRequirementState {
        let _ = requirement
        LlmWireRequirementState.Satisfied
    }
}

func requirementReviewCode(codec: LlmWireCodec, request: LlmWireRequest): String {
    try {
        match (codec.encodeRequest(request).materialize(resolver: Some(RequirementReviewResolver()))) {
            case LlmWireResult.Ok(_) => "ok"
            case LlmWireResult.Err(error) => error.code
        }
    } catch (error: LlmWireError) { error.code }
}

@Test
class CapabilityRequirementReviewTests {
    @TestCase
    func undeclaredFastNeverBecomesAnExternalRequirement() {
        let codec = anthropicMessagesCodec(anthropicMessagesModelProfile("model"))
        for (noisy in [false, true]) {
            let request = LlmWireRequest("model", requirementReviewTranscript(noisy: noisy), maxOutputTokens: Some(32), generationSpeed: LlmWireGenerationSpeed.Fast)
            let report = inspectRequestCapabilities(codec, request)
            @Expect(requirementReviewHas(report, "llm.generation_speed_unsupported"), true)
            @Expect(requirementReviewState(report, "anthropic.fast_mode"), "absent")
            @Expect(report.truncated, noisy)
            if (noisy) { @Expect(report.diagnostics.size, 128) }
            else { @Expect(requirementReviewCode(codec, request), "llm.generation_speed_unsupported") }
        }
    }

    @TestCase
    func undeclaredAutomaticCacheNeverBecomesSatisfied() {
        let codec = openAiChatCodec(openAiChatModelProfile("model"))
        for (noisy in [false, true]) {
            let request = LlmWireRequest("model", requirementReviewTranscript(noisy: noisy), promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault))
            let report = inspectRequestCapabilities(codec, request)
            @Expect(requirementReviewHas(report, "llm.cache_lifetime_unsupported"), true)
            @Expect(requirementReviewState(report, "openai.prompt_cache_automatic"), "absent")
            @Expect(report.truncated, noisy)
            if (noisy) { @Expect(report.diagnostics.size, 128) }
            else { @Expect(requirementReviewCode(codec, request), "llm.cache_lifetime_unsupported") }
        }
    }

    @TestCase
    func cacheRoutingFailureCannotContributeASatisfiedRequirement() {
        let capabilities = LlmWireCapabilities(cache: LlmWireCacheCapabilities(lifetimes: [LlmWirePromptCacheLifetime.ProviderDefault]))
        let codecs = [openAiResponsesCodec(openAiResponsesModelProfile("model", capabilities: capabilities)),
            deepSeekMessagesCodec(deepSeekMessagesModelProfile("model", capabilities: capabilities))]
        for (index in 0..codecs.size) {
            let key = if (index == 0) { "" } else { "private-routing-key" }
            let code = if (index == 0) { "llm.prompt_cache_routing_key_invalid" } else { "llm.prompt_cache_routing_unsupported" }
            let feature = if (index == 0) { "openai.prompt_cache_automatic" } else { "provider.prompt_cache_automatic" }
            let request = LlmWireRequest("model", requirementReviewTranscript(), maxOutputTokens: Some(32),
                promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault), promptCacheRoutingKey: Some(key))
            let report = inspectRequestCapabilities(codecs[index], request)
            @Expect(requirementReviewHas(report, code), true)
            @Expect(requirementReviewState(report, feature), "absent")
            @Expect(requirementReviewCode(codecs[index], request), code)
        }
    }

    @TestCase
    func acceptedFastKeepsUnknownDespiteIndependentErrorsAndRetention() {
        let capabilities = LlmWireCapabilities(thinking: LlmWireThinkingCapabilities(modes: [LlmWireThinkingMode.Budget(1024)]),
            output: LlmWireOutputCapabilities(generationSpeeds: [LlmWireGenerationSpeed.Fast]))
        let codec = anthropicMessagesCodec(anthropicMessagesModelProfile("model", capabilities: capabilities))
        for (noisy in [false, true]) {
            let request = LlmWireRequest("model", requirementReviewTranscript(noisy: noisy), maxOutputTokens: Some(32),
                thinkingMode: LlmWireThinkingMode.Budget(1), generationSpeed: LlmWireGenerationSpeed.Fast)
            let report = inspectRequestCapabilities(codec, request)
            @Expect(requirementReviewHas(report, "llm.thinking_budget_invalid"), true)
            @Expect(requirementReviewState(report, "anthropic.fast_mode"), "unknown")
            @Expect(report.truncated, noisy)
            if (!noisy) { @Expect(requirementReviewCode(codec, request), "llm.thinking_budget_invalid") }
        }
    }

    @TestCase
    func acceptedFastStillRequiresResolution() {
        let capabilities = LlmWireCapabilities(output: LlmWireOutputCapabilities(generationSpeeds: [LlmWireGenerationSpeed.Fast]))
        let codec = anthropicMessagesCodec(anthropicMessagesModelProfile("model", capabilities: capabilities))
        let request = LlmWireRequest("model", requirementReviewTranscript(), maxOutputTokens: Some(32), generationSpeed: LlmWireGenerationSpeed.Fast)
        @Expect(requirementReviewState(inspectRequestCapabilities(codec, request), "anthropic.fast_mode"), "unknown")
        let prepared = codec.encodeRequest(request)
        match (prepared.materialize()) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.feature_requirement_unresolved")
            case _ => @Fail("Fast requires an external decision")
        }
        @Expect(prepared.materialize(resolver: Some(RequirementReviewResolver())).isOk(), true)
    }

    @TestCase
    func acceptedCacheIsIndependentOfServiceTierAndRetention() {
        let capabilities = LlmWireCapabilities(cache: LlmWireCacheCapabilities(lifetimes: [LlmWirePromptCacheLifetime.ProviderDefault]))
        let codec = openAiChatCodec(openAiChatModelProfile("model", capabilities: capabilities))
        for (noisy in [false, true]) {
            let request = LlmWireRequest("model", requirementReviewTranscript(noisy: noisy), serviceTier: LlmWireServiceTier.Priority,
                promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault))
            let report = inspectRequestCapabilities(codec, request)
            @Expect(requirementReviewHas(report, "llm.service_tier_unsupported"), true)
            @Expect(requirementReviewState(report, "openai.prompt_cache_automatic"), "satisfied")
            @Expect(report.truncated, noisy)
        }
    }

    @TestCase
    func acceptedProviderAutomaticCacheStaysSatisfied() {
        let capabilities = LlmWireCapabilities(cache: LlmWireCacheCapabilities(lifetimes: [LlmWirePromptCacheLifetime.ProviderDefault]))
        let codec = deepSeekMessagesCodec(deepSeekMessagesModelProfile("model", capabilities: capabilities))
        let request = LlmWireRequest("model", requirementReviewTranscript(), maxOutputTokens: Some(32),
            promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault))
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, true)
        @Expect(report.diagnostics.size, 1)
        @Expect(requirementReviewState(report, "provider.prompt_cache_automatic"), "satisfied")
        @Expect(codec.encodeRequest(request).materialize().isOk(), true)
    }
}
