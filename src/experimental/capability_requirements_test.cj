package llm4cj.experimental

import llm4cj.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ExperimentalCapabilityRequirementReviewTests {
    @TestCase
    func unsupportedContractCannotContributeAnExternalRequirement() {
        let contract = LlmWireDialectContract("example.no-speed.v1", LlmWireProtocol.Messages,
            LlmWireRequestStyle.AnthropicMessages, LlmWireOutputTokenField.MaxTokens, requireMaxOutputTokens: true)
        let capabilities = LlmWireCapabilities(output: LlmWireOutputCapabilities(generationSpeeds: [LlmWireGenerationSpeed.Fast]))
        let codec = customDialectCodec(LlmWireProtocol.Messages, LlmWireStandardDialect(contract), capabilities: capabilities)
        let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("prompt"))]))])
        let request = LlmWireRequest("model", transcript, maxOutputTokens: Some(32), generationSpeed: LlmWireGenerationSpeed.Fast)
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, true)
        @Expect(report.diagnostics.size, 1)
        @Expect(report.diagnostics[0].kind, LlmWireCapabilityDiagnosticKind.Unsupported)
        @Expect(report.diagnostics[0].code, "llm.generation_speed_unsupported")
        try { let _ = codec.encodeRequest(request); @Fail("the contract does not support Fast") }
        catch (error: LlmWireError) { @Expect(error.code, "llm.generation_speed_unsupported") }
    }

    @TestCase
    func unsupportedCacheLifetimeCannotContributeSatisfied() {
        let contract = LlmWireDialectContract("example.no-cache-lifetime.v1", LlmWireProtocol.ChatCompletions,
            LlmWireRequestStyle.OpenAiChat, LlmWireOutputTokenField.MaxCompletionTokens, promptCacheStyle: LlmWirePromptCacheStyle.OpenAi)
        let capabilities = LlmWireCapabilities(cache: LlmWireCacheCapabilities(lifetimes: [LlmWirePromptCacheLifetime.ProviderDefault]))
        let codec = customDialectCodec(LlmWireProtocol.ChatCompletions, LlmWireStandardDialect(contract), capabilities: capabilities)
        let transcript = LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("prompt"))]))])
        let request = LlmWireRequest("model", transcript, promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault))
        let report = inspectRequestCapabilities(codec, request)
        @Expect(report.complete, true)
        @Expect(report.diagnostics.size, 1)
        @Expect(report.diagnostics[0].kind, LlmWireCapabilityDiagnosticKind.Unsupported)
        @Expect(report.diagnostics[0].code, "llm.cache_lifetime_unsupported")
        try { let _ = codec.encodeRequest(request); @Fail("the contract does not support this lifetime") }
        catch (error: LlmWireError) { @Expect(error.code, "llm.cache_lifetime_unsupported") }
    }
}
