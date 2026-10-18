package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

func capabilityNativeRequest(count: Int64): LlmWireRequest {
    let summary = StringBuilder()
    for (index in 0..count) {
        if (index > 0) { summary.append(",") }
        summary.append("{\"type\":\"summary_text\",\"text\":\"\"}")
    }
    let snapshot = "{\"protocol\":\"responses\",\"dialect_id\":\"openai.responses.v1\",\"native_type\":\"reasoning\",\"schema_version\":1,\"scope\":\"assistant_turn\",\"assistant_turn_index\":0,\"block_order\":0,\"complete\":true,\"payload\":{\"type\":\"reasoning\",\"id\":\"rs\",\"summary\":[" + summary.toString() + "]}}"
    let native = LlmWireNativeReplayBlock.restore(snapshot)
    LlmWireRequest("model", LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.NativeReplay(native)]))]))
}

@Test
class CapabilityInspectionCombinedTests {
    @TestCase
    func nativePayloadNodesAreChargedWithoutInspectionReparsing() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let small = inspectRequestCapabilities(codec, capabilityNativeRequest(2))
        @Expect(small.complete, true); @Expect(small.truncated, false)
        let request = capabilityNativeRequest(40000)
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, false); @Expect(report.truncated, true); @Expect(report.diagnostics.size, 0)
        @Expect(codec.encodeRequest(request).materialize().isOk(), true)
    }

    @TestCase
    func customFormatsKeepInitialAndTemporalDeclarationLocations() {
        let endpoint = LlmWireEndpointProfile("fixture.capabilities", "model", "openai.responses.v1", "https://example.test/responses", 1,
            LlmWireContextUpdateCapabilities(toolDeclaration: true), "caller", "2026-10-18")
        let capabilities = LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true))
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model", capabilities: capabilities, endpoint: endpoint.endpoint, endpointProfile: Some(endpoint)))
        let initial = LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("initial")))
        let temporal = LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("temporal",
            format: LlmWireCustomToolFormat.Grammar(LlmWireGrammar(LlmWireGrammarSyntax.Regex, "[a-z]+")))))
        let request = LlmWireRequest("model", LlmWireTranscript(LlmWireInitialContext(tools: [initial]), items: [
            LlmWireInputItem.ToolDeclaration(temporal), capabilityUser()]))
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, true); @Expect(report.diagnostics.size, 2)
        @Expect(report.diagnostics[0].featureId, "tools.custom_format"); @Expect(report.diagnostics[0].inputItemIndex, -1)
        @Expect(report.diagnostics[1].featureId, "tools.custom_format"); @Expect(report.diagnostics[1].inputItemIndex, 0)
        try { let _ = codec.encodeRequest(request); @Fail("undeclared custom formats must refuse") }
        catch (error: LlmWireError) { @Expect(error.code, "llm.custom_tool_format_unsupported") }
    }

    @TestCase
    func cacheChecksCollectSlotsTargetsOrderingAndCollisionIndependently() {
        let codec = cacheTestCodec()
        let message = LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("")),
            LlmWireBlock.Text(LlmWireTextBlock("one")), LlmWireBlock.Text(LlmWireTextBlock("two")), LlmWireBlock.Text(LlmWireTextBlock("three"))])
        let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(message)], cacheBreakpoints: [
            LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0)),
            LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 1)),
            LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 2), lifetime: LlmWirePromptCacheLifetime.OneHour),
            LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 3))])
        let request = LlmWireRequest(codec.modelProfile.getOrThrow().model, transcript, maxOutputTokens: Some(32),
            promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.OneHour))
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, true); @Expect(report.truncated, false); @Expect(report.diagnostics.size, 4)
        for (code in ["llm.cache_breakpoint_limit", "llm.cache_target_invalid", "llm.cache_ttl_order_invalid", "llm.cache_ttl_conflict"]) {
            @Expect(capabilityHas(report, code), true)
        }
        @Expect(report.diagnostics[1].blockIndex, 0); @Expect(report.diagnostics[2].blockIndex, 2); @Expect(report.diagnostics[3].blockIndex, 3)
        try { let _ = codec.encodeRequest(request); @Fail("cache slot limit must refuse") }
        catch (error: LlmWireError) { @Expect(error.code, "llm.cache_breakpoint_limit") }
        let invalidTarget = LlmWireTranscript(items: [LlmWireInputItem.Message(message)], cacheBreakpoints: [
            LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0)),
            LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 2), lifetime: LlmWirePromptCacheLifetime.OneHour)])
        let partial = inspectRequestCapabilities(codec, LlmWireRequest(codec.modelProfile.getOrThrow().model, invalidTarget, maxOutputTokens: Some(32)))
        @Expect(partial.diagnostics.size, 1); @Expect(partial.diagnostics[0].code, "llm.cache_target_invalid")
    }

    @TestCase
    func failedReplayKeepsIndependentCacheTtlChecksWithoutAPlan() {
        let codec = cacheTestCodec()
        let transcript = LlmWireTranscript(items: [LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity("unknown")), capabilityUser()],
            cacheBreakpoints: [LlmWireCacheBreakpoint(LlmWireCachePosition.Item(0), lifetime: LlmWirePromptCacheLifetime.ThirtyMinutes)])
        let request = LlmWireRequest(codec.modelProfile.getOrThrow().model, transcript, maxOutputTokens: Some(32), serviceTier: LlmWireServiceTier.Priority)
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, false); @Expect(report.truncated, false)
        for (code in ["llm.tool_reference_unknown", "llm.cache_lifetime_unsupported", "llm.service_tier_unsupported"]) { @Expect(capabilityHas(report, code), true) }
        @Expect(capabilityHas(report, "llm.cache_target_invalid"), false)
        @Expect(capabilityHas(report, "llm.cache_ttl_order_invalid"), false)
        try { let _ = codec.encodeRequest(request); @Fail("invalid replay must refuse") }
        catch (error: LlmWireError) { @Expect(error.code, "llm.tool_reference_unknown") }
    }

    @TestCase
    func audioOptionsAndInputsCollectIndependentStaticFailures() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let input = streamRegressionValue(LlmWireAudioInputBlock.fromBytes(LlmWireAudioFormat.Wav, [1u8]))
        let request = LlmWireRequest("model", LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.AudioInput(input)]))]),
            structuredOutput: LlmWireStructuredOutput.JsonObject, audioOutput: Some(LlmWireAudioOutputOptions(LlmWireAudioFormat.Wav, LlmWireAudioVoice.Cedar)))
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, true)
        for (code in ["llm.audio_dialect_unsupported", "llm.audio_input_role_invalid", "llm.audio_input_capability_missing",
            "llm.audio_output_format_unsupported", "llm.audio_voice_unsupported", "llm.audio_structured_output_unsupported", "llm.structured_output_unsupported"]) {
            @Expect(capabilityHas(report, code), true)
        }
        for (diagnostic in report.diagnostics) { @Expect(diagnostic.requirementState.isNone(), true) }
        let streaming = openAiChatCodec(openAiChatModelProfile("audio-model", capabilities: LlmWireCapabilities(audio: LlmWireAudioCapabilities(
            streamOutputFormats: [LlmWireAudioFormat.Wav], voices: [LlmWireAudioVoice.Alloy]))))
        let output = audioTestRequest(LlmWireAudioFormat.Wav)
        @Expect(capabilityHas(inspectRequestCapabilities(streaming, output), "llm.audio_output_format_unsupported"), true)
        @Expect(inspectRequestCapabilities(streaming, output, streaming: true).diagnostics.size, 0)
        @Expect(streaming.encodeRequest(output, streaming: true).materialize().isOk(), true)
    }

    @TestCase
    func audioReplayClockRemainsAnExplicitMaterializationInput() {
        let codec = audioTestCodec()
        let reply = audioTestFixed(codec, audioTestContext(codec, LlmWireAudioFormat.Wav), audioTestObject())
        let messages = reply.toContinuationInput()
        let request = LlmWireRequest("audio-model", LlmWireTranscript(items: messages.map({ value: LlmWireMessage => LlmWireInputItem.Message(value) })))
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, true); @Expect(report.truncated, false); @Expect(report.diagnostics.size, 0)
        let prepared = codec.encodeRequest(request)
        for (result in [prepared.materialize(), prepared.materialize(resolver: Some(CapabilitySatisfiedResolver()))]) {
            match (result) { case LlmWireResult.Err(error) => @Expect(error.code, "llm.audio_replay_clock_required"); case _ => @Fail("clock is mandatory") }
        }
        @Expect(prepared.materialize(nowEpochSeconds: Some(1)).isOk(), true)
        match (prepared.materialize(nowEpochSeconds: Some(100))) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.audio_replay_expired")
            case _ => @Fail("expired replay must refuse")
        }
    }

    @TestCase
    func newFeaturePayloadsAreChargedBeforeGrammarOrAudioObservation() {
        let codec = openAiResponsesCodec(openAiResponsesModelProfile("model"))
        let grammar = String.fromUtf8(Array<Byte>(16777217, repeat: b'x'))
        let declaration = LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("tool",
            format: LlmWireCustomToolFormat.Grammar(LlmWireGrammar(LlmWireGrammarSyntax.Regex, grammar)))))
        let custom = inspectRequestCapabilities(codec, LlmWireRequest("model", LlmWireTranscript(LlmWireInitialContext(tools: [declaration]), items: [capabilityUser()])))
        @Expect(custom.complete, false); @Expect(custom.truncated, true); @Expect(custom.diagnostics.size, 0)
        let input = streamRegressionValue(LlmWireAudioInputBlock.fromBytes(LlmWireAudioFormat.Wav, Array<Byte>(4194304, repeat: 1u8)))
        let audio = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, Array<LlmWireBlock>(5, repeat: LlmWireBlock.AudioInput(input))))])
        let report = inspectRequestCapabilities(audioTestCodec(), LlmWireRequest("audio-model", audio))
        @Expect(report.complete, false); @Expect(report.truncated, true); @Expect(report.diagnostics.size, 0)
    }
}
