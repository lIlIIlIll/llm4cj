package llm4cj_provider_probe

import llm4cj.*
import std.collection.*

class CapabilityFixtureResolver <: LlmWireRequirementResolver {
    public func resolve(requirement: LlmWireFeatureRequirement): LlmWireRequirementState {
        let _ = requirement; LlmWireRequirementState.Satisfied
    }
}

func capabilityFixtureInput(scenario: String, dialect: String): (LlmWireCodec, LlmWireRequest, Bool) {
    let user = LlmWireInputItem.Message(userMessage("private-prompt"))
    match (scenario) {
        case "valid" => (codecFor(dialect, model: "fixture-model"), probeRequest(dialect, LlmWireTranscript(items: [user])), dialect == "openai-codex-responses")
        case "multiple" =>
            let tool = LlmWireToolDeclaration(LlmWireTool("lookup", "private-description", jp("{}")))
            (openAiResponsesCodec(openAiResponsesModelProfile("fixture-model"), provider: "Bearer private-token"),
                LlmWireRequest("fixture-model", LlmWireTranscript(items: [LlmWireInputItem.ToolDeclaration(tool), user]),
                    thinkingMode: LlmWireThinkingMode.Budget(512), reasoningEffort: LlmWireReasoningEffort.High,
                    maxOutputTokens: Some(256), parallelToolCalls: Some(true), serviceTier: LlmWireServiceTier.Priority,
                    generationSpeed: LlmWireGenerationSpeed.Fast, promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ThirtyMinutes),
                    structuredOutput: LlmWireStructuredOutput.JsonObject), false)
        case "malformed" =>
            let transcript = LlmWireTranscript(items: [LlmWireInputItem.ToolActivation(LlmWireToolDefinitionIdentity("private_tool")), user])
            (openAiResponsesCodec(openAiResponsesModelProfile("fixture-model")), LlmWireRequest("fixture-model", transcript,
                thinkingMode: LlmWireThinkingMode.Budget(1), reasoningEffort: LlmWireReasoningEffort.High,
                parallelToolCalls: Some(true), toolChoice: LlmWireToolChoice.Required,
                structuredOutput: LlmWireStructuredOutput.JsonObject, promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ThirtyMinutes)), false)
        case "unknown" =>
            let capabilities = LlmWireCapabilities(output: LlmWireOutputCapabilities(generationSpeeds: [LlmWireGenerationSpeed.Fast]))
            (anthropicMessagesCodec(anthropicMessagesModelProfile("fixture-model", capabilities: capabilities)),
                LlmWireRequest("fixture-model", LlmWireTranscript(items: [user]), maxOutputTokens: Some(32), generationSpeed: LlmWireGenerationSpeed.Fast), false)
        case "undeclared" => (openAiResponsesCodec(openAiResponsesModelProfile("fixture-model")),
            LlmWireRequest("fixture-model", LlmWireTranscript(items: [user]), thinkingMode: LlmWireThinkingMode.Enabled), false)
        case "cache" =>
            let capabilities = LlmWireCapabilities(cache: LlmWireCacheCapabilities(lifetimes: [LlmWirePromptCacheLifetime.FiveMinutes, LlmWirePromptCacheLifetime.OneHour], explicitBreakpoints: true))
            let codec = anthropicMessagesCodec(anthropicMessagesModelProfile("fixture-model", capabilities: capabilities))
            let message = LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("")), LlmWireBlock.Text(LlmWireTextBlock("one")),
                LlmWireBlock.Text(LlmWireTextBlock("two")), LlmWireBlock.Text(LlmWireTextBlock("three"))])
            let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(message)], cacheBreakpoints: [
                LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 0)), LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 1)),
                LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 2), lifetime: LlmWirePromptCacheLifetime.OneHour), LlmWireCacheBreakpoint(LlmWireCachePosition.MessageBlock(0, 3))])
            (codec, LlmWireRequest("fixture-model", transcript, maxOutputTokens: Some(32), promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.OneHour)), false)
        case "audio" =>
            let input = probeValue(LlmWireAudioInputBlock.fromBytes(LlmWireAudioFormat.Wav, [1u8]))
            (openAiResponsesCodec(openAiResponsesModelProfile("fixture-model")),
                LlmWireRequest("fixture-model", LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.Assistant, [LlmWireBlock.AudioInput(input)]))]),
                    structuredOutput: LlmWireStructuredOutput.JsonObject, audioOutput: Some(LlmWireAudioOutputOptions(LlmWireAudioFormat.Wav, LlmWireAudioVoice.Cedar))), false)
        case "audio-clock" =>
            let codec = audioProbeCodec(model: "fixture-model")
            let original = LlmWireRequest("fixture-model", LlmWireTranscript(items: [user]), audioOutput: Some(LlmWireAudioOutputOptions(LlmWireAudioFormat.Wav, LlmWireAudioVoice.Alloy)))
            let response = """
                {"id":"fixture","model":"fixture-model","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":null,"audio":{"id":"audio","data":"AQ==","transcript":"private-spoken","expires_at":100}}}]}
                """
            let reply = match (probeValue(codec.decodeResponse(LlmWireHttpResponse(200, [], response.toArray()), responseContext: Some(codec.encodeRequest(original).responseContext)))) {
                case LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply)) => reply
                case _ => throw IllegalStateException("audio clock fixture must decode a completed reply")
            }
            (codec, LlmWireRequest("fixture-model", LlmWireTranscript(items: messageItems(reply.toContinuationInput()))), false)
        case "custom" =>
            let endpoint = LlmWireEndpointProfile("fixture.capabilities", "fixture-model", "openai.responses.v1", "https://example.test/responses", 1,
                LlmWireContextUpdateCapabilities(toolDeclaration: true), "caller", "2026-10-18")
            let codec = openAiResponsesCodec(openAiResponsesModelProfile("fixture-model", capabilities: LlmWireCapabilities(tools: LlmWireToolCapabilities(enabled: true)),
                endpoint: endpoint.endpoint, endpointProfile: Some(endpoint)))
            let tool = LlmWireToolDeclaration(LlmWireToolDefinition.Custom(LlmWireCustomTool("emit", format: LlmWireCustomToolFormat.Grammar(LlmWireGrammar(LlmWireGrammarSyntax.Regex, "[a-z]+")))))
            (codec, LlmWireRequest("fixture-model", LlmWireTranscript(items: [LlmWireInputItem.ToolDeclaration(tool), user])), false)
        case _ => throw IllegalArgumentException("unknown capability fixture scenario")
    }
}

func capabilityReportJson(report: LlmWireRequestCapabilityReport): LlmWireJson {
    let diagnostics = ArrayList<LlmWireJson>()
    var bytes: Int64 = 0
    if (report.diagnostics.size > 128) { throw IllegalStateException("capability report exceeded its count bound") }
    for (value in report.diagnostics) {
        if (value.message.size > 256 || (value.message + value.code + value.featureId).contains("private")) { throw IllegalStateException("capability diagnostic is not bounded and redacted") }
        bytes += value.message.size + value.code.size + value.featureId.size
        let state = match (value.requirementState) {
            case Some(LlmWireRequirementState.Satisfied) => js("Satisfied")
            case Some(LlmWireRequirementState.Unknown(text)) =>
                if (text.contains("private")) { throw IllegalStateException("requirement leaked request content") }; bytes += text.size; js("Unknown")
            case Some(LlmWireRequirementState.Unsatisfied(text)) =>
                if (text.contains("private")) { throw IllegalStateException("requirement leaked request content") }; bytes += text.size; js("Unsatisfied")
            case None => jnull()
        }
        let kind = match (value.kind) { case LlmWireCapabilityDiagnosticKind.Requirement => "Requirement"; case LlmWireCapabilityDiagnosticKind.Unsupported => "Unsupported"; case LlmWireCapabilityDiagnosticKind.Invalid => "Invalid" }
        diagnostics.add(ja([js(kind), js(value.featureId), js(value.code), ji(value.inputItemIndex), ji(value.blockIndex), state]))
    }
    if (bytes > 65536) { throw IllegalStateException("capability report exceeded its text bound") }
    jo([jf("profile_id", js(report.profileId)), jf("contract_version", ji(report.contractVersion)), jf("complete", LlmWireJson.boolean(report.complete)),
        jf("truncated", LlmWireJson.boolean(report.truncated)), jf("diagnostics", ja(diagnostics.toArray()))])
}

func capabilityMaterializeCode(result: LlmWireResult<LlmWireMaterializedRequest>): String {
    match (result) { case LlmWireResult.Ok(_) => "ok"; case LlmWireResult.Err(error) => error.code }
}

func capabilityFixtureActual(scenario: String, dialect: String): LlmWireJson {
    let (codec, request, streaming) = capabilityFixtureInput(scenario, dialect)
    let report = capabilityReportJson(inspectRequestCapabilities(codec, request, streaming: streaming))
    if (report.stringify() != capabilityReportJson(inspectRequestCapabilities(codec, request, streaming: streaming)).stringify()) { throw IllegalStateException("capability report is not deterministic") }
    let (strict, resolved, clock) = try {
        let prepared = codec.encodeRequest(request, streaming: streaming)
        (capabilityMaterializeCode(prepared.materialize()), capabilityMaterializeCode(prepared.materialize(resolver: Some(CapabilityFixtureResolver()))),
            capabilityMaterializeCode(prepared.materialize(nowEpochSeconds: Some(1))))
    } catch (error: LlmWireError) { (error.code, error.code, error.code) }
    jo([jf("report", report), jf("strict_code", js(strict)), jf("resolved_code", js(resolved)), jf("clock_code", js(clock))])
}

// The oracle is hand-reviewed fixture data; this consumer only constructs typed requests.
func checkCapabilityFixture(path: String): Int64 {
    let fixture = jp(String.fromUtf8(readBytes(path)))
    var count: Int64 = 0
    for (test in fixture.field("cases").getOrThrow().values()) {
        let scenario = test.field("scenario").getOrThrow().stringValue().getOrThrow()
        let expected = test.field("expected").getOrThrow()
        for (dialect in test.field("dialects").getOrThrow().values()) {
            let actual = capabilityFixtureActual(scenario, dialect.stringValue().getOrThrow())
            if (actual.stringify() != expected.stringify()) {
                println("capability fixture mismatch: " + test.field("id").getOrThrow().stringValue().getOrThrow())
                println(actual.stringify()); return 1
            }
            count++
        }
    }
    println("capability fixture checks passed: " + count.toString())
    0
}
