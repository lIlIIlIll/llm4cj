package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

private func mergedJson(text: String): LlmWireJson {
    match (LlmWireJson.parse(text)) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
}

private func mergedTools(schema: String, grammar!: Bool = false): LlmWireTranscript {
    let function = LlmWireToolDefinition.Function(LlmWireTool("lookup", "", mergedJson(schema)))
    let custom = LlmWireToolDefinition.Custom(LlmWireCustomTool("raw", format: if (grammar) {
        LlmWireCustomToolFormat.Grammar(LlmWireGrammar(LlmWireGrammarSyntax.Regex, "[a-z]+"))
    } else { LlmWireCustomToolFormat.Text }))
    LlmWireTranscript(LlmWireInitialContext(tools: [LlmWireToolDeclaration(function), LlmWireToolDeclaration(custom)]))
}

private func mergedCode(result: LlmWireResult<Unit>): String {
    match (result) { case LlmWireResult.Ok(_) => "ok"; case LlmWireResult.Err(error) => error.code }
}

@Test
class SchemaCustomIntegrationTest {
    @TestCase
    func taggedFunctionsValidateExactlyWhileCustomTextStaysRaw() {
        let transcript = mergedTools("{\"properties\":{\"n\":{\"type\":\"integer\",\"minimum\":9007199254740993}},\"required\":[\"n\"]}")
        let raw = LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("raw-id", "raw", LlmWireToolArguments.Text("not { JSON")))
        for ((arguments, expected) in [("{\"n\":9007199254740993.0}", "ok"), ("{\"n\":9007199254740992}", "llm.tool_arguments_schema_violation")]) {
            let reply = LlmWireReply(blocks: [raw, LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("function-id", "lookup", LlmWireToolArguments.Complete(mergedJson(arguments))))])
            for (mode in [LlmWireToolInputValidationMode.Strict, LlmWireToolInputValidationMode.ValidateSupportedSubset]) {
                @Expect(mergedCode(validateReplyToolInputs(reply, transcript, mode: mode)), expected)
                let restored = match (transcript.snapshot()) {
                    case LlmWireResult.Ok(snapshot) => match (LlmWireTranscript.restore(snapshot)) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
                    case LlmWireResult.Err(error) => throw error
                }
                @Expect(mergedCode(validateReplyToolInputs(reply, restored, mode: mode)), expected)
            }
            @Expect(mergedCode(validateReplyToolInputs(reply, transcript, mode: LlmWireToolInputValidationMode.Disabled)), "ok")
        }
        let grammar = mergedTools("{}", grammar: true)
        let reply = LlmWireReply(blocks: [raw])
        for (mode in [LlmWireToolInputValidationMode.Strict, LlmWireToolInputValidationMode.ValidateSupportedSubset]) {
            @Expect(mergedCode(validateReplyToolInputs(reply, grammar, mode: mode)), "llm.tool_grammar_validation_unsupported")
        }
        @Expect(mergedCode(validateReplyToolInputs(reply, grammar, mode: LlmWireToolInputValidationMode.Disabled)), "ok")
    }

    @TestCase
    func sharedSchemaBudgetDoesNotParseRawCustomInputOrResetPerChoice() {
        let transcript = mergedTools("{}")
        let function = LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("same", "lookup", LlmWireToolArguments.Complete(mergedJson("{}"))))
        let raw = LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("same", "raw", LlmWireToolArguments.Text("not JSON")))
        let independent = LlmWireReply(choices: [LlmWireChoice(0, [function], LlmWireChoiceOutcome.Completed), LlmWireChoice(9, [raw], LlmWireChoiceOutcome.Completed)])
        @Expect(validateReplyToolInputs(independent, transcript, mode: LlmWireToolInputValidationMode.Strict, limits: LlmWireSchemaValidationLimits(maxWork: 8)).isOk(), true)
        let twoFunctions = LlmWireReply(choices: [LlmWireChoice(0, [function], LlmWireChoiceOutcome.Completed), LlmWireChoice(9, [function], LlmWireChoiceOutcome.Completed)])
        @Expect(mergedCode(validateReplyToolInputs(twoFunctions, transcript, limits: LlmWireSchemaValidationLimits(maxWork: 15))), "llm.schema_validation_limit")
        @Expect(validateReplyToolInputs(twoFunctions, transcript, limits: LlmWireSchemaValidationLimits(maxWork: 16)).isOk(), true)
        for (mode in [LlmWireToolInputValidationMode.Strict, LlmWireToolInputValidationMode.ValidateSupportedSubset, LlmWireToolInputValidationMode.Disabled]) {
            @Expect(mergedCode(validateReplyToolInputs(LlmWireReply(blocks: [function,raw]), transcript, mode: mode)), "llm.tool_call_id_duplicate")
            let wrongKind = LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("wrong", "lookup", LlmWireToolArguments.Text("{}")))
            @Expect(mergedCode(validateReplyToolInputs(LlmWireReply(blocks: [wrongKind]), transcript, mode: mode)), "llm.tool_kind_mismatch")
            let partial = LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("partial", "raw", LlmWireToolArguments.PartialText("raw")))
            @Expect(mergedCode(validateReplyToolInputs(LlmWireReply(blocks: [partial]), transcript, mode: mode)), "llm.tool_arguments_not_executable")
        }
    }

    @TestCase
    func structuredExtractionNeverTreatsCustomInputAsJsonAnswer() {
        let request = LlmWireRequest("fixture-model", mergedTools("{}"), structuredOutput: LlmWireStructuredOutput.JsonObject)
        for (arguments in [LlmWireToolArguments.Text("{}"), LlmWireToolArguments.PartialText("{" )]) {
            let reply = LlmWireReply(blocks: [LlmWireOutputBlock.Text(LlmWireTextBlock("{}")), LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("raw-id", "raw", arguments))])
            match (extractStructuredOutput(reply, request)) {
                case LlmWireResult.Err(error) => @Expect(error.code, "llm.structured_output_tool_calls_present")
                case _ => @Fail("mixed custom call cannot become a structured answer")
            }
        }
    }
}
