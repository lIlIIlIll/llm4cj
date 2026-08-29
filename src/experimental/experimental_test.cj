package llm4cj.experimental

import llm4cj.*
import std.unittest.*
import std.unittest.testmacro.*

func prewarmCodec(): LlmWireCodec {
    anthropicMessagesCodec(anthropicMessagesModelProfile(
        "claude-test",
        capabilities: LlmWireCapabilities(cache: LlmWireCacheCapabilities(
            lifetimes: [LlmWirePromptCacheLifetime.ProviderDefault, LlmWirePromptCacheLifetime.OneHour]
        ))
    ))
}

func prewarmRequest(
    thinkingMode!: LlmWireThinkingMode = LlmWireThinkingMode.ProviderDefault,
    structuredOutput!: LlmWireStructuredOutput = LlmWireStructuredOutput.ProviderDefault,
    toolChoice!: LlmWireToolChoice = LlmWireToolChoice.ProviderDefault
): LlmWireRequest {
    LlmWireRequest(
        "claude-test",
        [LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("warm this prompt"))])],
        thinkingMode: thinkingMode,
        maxOutputTokens: Some(0),
        promptCache: LlmWirePromptCache.Automatic(LlmWirePromptCacheLifetime.ProviderDefault),
        toolChoice: toolChoice,
        structuredOutput: structuredOutput
    )
}

func expectExperimentalError(code: String, body: () -> Unit): Unit {
    try {
        body()
        @Fail("expected LlmWireError: " + code)
    } catch (error: LlmWireError) { @Expect(error.code, code) }
}

@Test
class Llm4CjExperimentalTests {
    @TestCase
    func customDialectIsExplicitlyExperimental() {
        let dialect = LlmWireStandardDialect(LlmWireDialectContract(
            "example.chat.v1",
            LlmWireProtocol.ChatCompletions,
            LlmWireRequestStyle.OpenAiChat,
            LlmWireOutputTokenField.MaxCompletionTokens
        ))
        let codec = customDialectCodec(LlmWireProtocol.ChatCompletions, dialect)
        @Expect(codec.dialect.compatibilityId, "example.chat.v1")

        expectExperimentalError("llm.dialect_identity_reserved", { =>
            let _ = LlmWireStandardDialect(LlmWireDialectContract(
                "openai.chat.v1",
                LlmWireProtocol.ChatCompletions,
                LlmWireRequestStyle.OpenAiChat,
                LlmWireOutputTokenField.MaxCompletionTokens
            ))
        })
    }

    @TestCase
    func cachePrewarmOwnsRequestAndResponseExpectation() {
        let exchange = match (prepareAnthropicCachePrewarm(prewarmCodec(), prewarmRequest())) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(error) => throw error
        }
        let materialized = match (exchange.request.materialize()) {
            case LlmWireResult.Ok(value) => value
            case LlmWireResult.Err(error) => throw error
        }
        let body = String.fromUtf8(materialized.body)
        @Expect(body.contains("\"max_tokens\":0"), true)
        @Expect(body.contains("\"cache_control\""), true)
        @Expect(body.contains("\"stream\""), false)

        let response = LlmWireHttpResponse(200, [], """
        {"id":"msg","type":"message","role":"assistant","model":"claude-test","content":[],"stop_reason":"max_tokens","stop_sequence":null,"usage":{"input_tokens":7,"output_tokens":0,"cache_creation_input_tokens":7}}
        """.toArray())
        match (exchange.decodeResponse(response)) {
            case LlmWireResult.Ok(usage) => @Expect(usage.outputTokens, Some(0)); @Expect(usage.cacheWriteTokens, Some(7))
            case LlmWireResult.Err(error) => throw error
        }
    }

    @TestCase
    func cachePrewarmRejectsGenerationFeatures() {
        match (prepareAnthropicCachePrewarm(prewarmCodec(), prewarmRequest(thinkingMode: LlmWireThinkingMode.Budget(1024)))) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.cache_prewarm_thinking_unsupported")
            case _ => @Fail("thinking pre-warm must fail")
        }
        match (prepareAnthropicCachePrewarm(prewarmCodec(), prewarmRequest(structuredOutput: LlmWireStructuredOutput.JsonObject))) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.cache_prewarm_structured_output_unsupported")
            case _ => @Fail("structured pre-warm must fail")
        }
        match (prepareAnthropicCachePrewarm(prewarmCodec(), prewarmRequest(toolChoice: LlmWireToolChoice.Required))) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.cache_prewarm_tool_choice_unsupported")
            case _ => @Fail("required-tool pre-warm must fail")
        }
    }

    @TestCase
    func grammarAndCustomToolValidateAtConstruction() {
        let grammar = LlmWireGrammar(LlmWireGrammarSyntax.Regex, "[a-z]+")
        let tool = LlmWireCustomTool("emit", format: LlmWireCustomToolFormat.Grammar(grammar))
        @Expect(tool.name, "emit")
        expectExperimentalError("llm.grammar_empty", { => let _ = LlmWireGrammar(LlmWireGrammarSyntax.Lark, " ") })
        expectExperimentalError("llm.custom_tool_name_invalid", { => let _ = LlmWireCustomTool(" ") })
    }
}
