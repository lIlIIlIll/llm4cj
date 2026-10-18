package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

private func outputRequest(format: LlmWireStructuredOutput): LlmWireRequest {
    LlmWireRequest("fixture-model", LlmWireTranscript(items: [LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("answer"))]))]), structuredOutput: format)
}
private func outputReply(text: String): LlmWireReply { LlmWireReply(blocks: [LlmWireOutputBlock.Text(LlmWireTextBlock(text))], usage: LlmWireUsage(outputTokens: Some(3))) }
private func outputResult(result: LlmWireResult<LlmWireStructuredOutputResult>): LlmWireStructuredOutputResult {
    match (result) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
}
private func outputKind(result: LlmWireResult<LlmWireStructuredOutputResult>): String {
    match (result) {
        case LlmWireResult.Err(error) => error.code
        case LlmWireResult.Ok(value) => match (value.outcome) {
            case LlmWireStructuredOutputOutcome.Valid(_) => "Valid"
            case LlmWireStructuredOutputOutcome.InvalidJson(_) => "InvalidJson"
            case LlmWireStructuredOutputOutcome.SchemaViolation(_) => "SchemaViolation"
            case LlmWireStructuredOutputOutcome.UnsupportedSchema(_) => "UnsupportedSchema"
            case LlmWireStructuredOutputOutcome.Incomplete(_) => "Incomplete"
            case LlmWireStructuredOutputOutcome.Refused(_) => "Refused"
        }
    }
}
private func outputSchema(schema: String): LlmWireStructuredOutput {
    LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("answer", jsonFactoryValue(LlmWireJson.parse(schema))))
}

@Test
class StructuredOutputTest {
    @TestCase
    func preservesRawTextAndAcceptsSchemaArraysAndScalars() {
        let raw = " \n{\"answer\": 2}\t"
        let result = outputResult(extractStructuredOutput(outputReply(raw), outputRequest(LlmWireStructuredOutput.JsonObject)))
        @Expect(result.rawText, Some(raw)); @Expect(result.choiceIndex, 0)
        match (result.outcome) { case LlmWireStructuredOutputOutcome.Valid(value) => @Expect(value.field("answer").getOrThrow().numberLiteral(), Some("2")); case _ => @Fail("valid object") }
        for (format in [outputSchema("{\"type\":\"array\",\"minItems\":2}"), LlmWireStructuredOutput.JsonSchemaDocument(jsonFactoryValue(LlmWireJson.parse("{\"type\":\"array\"}")))]) {
            @Expect(outputKind(extractStructuredOutput(outputReply("[1,2]"), outputRequest(format))), "Valid")
        }
        @Expect(outputKind(extractStructuredOutput(outputReply("9007199254740993"), outputRequest(outputSchema("{\"type\":\"integer\",\"minimum\":9007199254740993}")))), "Valid")
        @Expect(outputKind(extractStructuredOutput(outputReply("[1,2]"), outputRequest(LlmWireStructuredOutput.JsonObject))), "SchemaViolation")
    }

    @TestCase
    func invalidJsonIsNotRepairedAndDiagnosticsNeverContainRawOutput() {
        let request = outputRequest(LlmWireStructuredOutput.JsonObject)
        for (text in ["", "```json\n{}\n```", "{}{}", "{\"a\":", "{\"a\":1,\"a\":2}", "secret-output-marker " + String.fromUtf8(Array<Byte>(20000, repeat: b'x'))]) {
            let result = outputResult(extractStructuredOutput(outputReply(text), request))
            @Expect(result.rawText, Some(text))
            match (result.outcome) {
                case LlmWireStructuredOutputOutcome.InvalidJson(error) =>
                    @Expect(error.code, "llm.structured_output_invalid_json")
                    @Expect(error.message.size < 256, true)
                    @Expect(error.diagnosticJson.getOrThrow().size <= 2048, true)
                    @Expect(error.diagnosticJson.getOrThrow().contains("secret-output-marker"), false)
                    @Expect(error.diagnosticJson.getOrThrow().contains("\"byte_offset\""), true)
                    @Expect(error.usage.getOrThrow().outputTokens, Some(3))
                case _ => @Fail("invalid JSON must remain invalid")
            }
        }
    }

    @TestCase
    func selectedValidationModeDistinguishesUnsupportedAndProvableViolation() {
        let format = outputSchema("{\"type\":\"array\",\"future\":true}")
        @Expect(outputKind(extractStructuredOutput(outputReply("{}"), outputRequest(format))), "UnsupportedSchema")
        @Expect(outputKind(extractStructuredOutput(outputReply("{}"), outputRequest(format), mode: LlmWireToolInputValidationMode.ValidateSupportedSubset)), "SchemaViolation")
        @Expect(outputKind(extractStructuredOutput(outputReply("[]"), outputRequest(format), mode: LlmWireToolInputValidationMode.ValidateSupportedSubset)), "UnsupportedSchema")
        let providerRelaxed = LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("answer", jsonFactoryValue(LlmWireJson.parse("{\"pattern\":\"x\"}")), strict: false))
        @Expect(outputKind(extractStructuredOutput(outputReply("{}"), outputRequest(providerRelaxed))), "UnsupportedSchema")
        let result = outputResult(extractStructuredOutput(outputReply("{\"a/~b\":1}"), outputRequest(outputSchema("{\"properties\":{\"a/~b\":{\"minimum\":2}}}"))))
        match (result.outcome) {
            case LlmWireStructuredOutputOutcome.SchemaViolation(error) =>
                @Expect(error.diagnosticJson.getOrThrow().contains("/properties/a~1~0b/minimum"), true)
                @Expect(error.usage.getOrThrow().outputTokens, Some(3))
            case _ => @Fail("schema minimum must reject")
        }
    }

    @TestCase
    func refusalAndIncompleteOutcomesPrecedeParsingAndTextBudgets() {
        let request = outputRequest(LlmWireStructuredOutput.JsonObject)
        for (reason in [LlmWireIncompleteReason.Length, LlmWireIncompleteReason.MaxTokens, LlmWireIncompleteReason.ContentFilter]) {
            let reply = LlmWireReply(choices: [LlmWireChoice(8, [LlmWireOutputBlock.Text(LlmWireTextBlock("{}"))], LlmWireChoiceOutcome.Incomplete(reason))])
            let result = outputResult(extractStructuredOutput(reply, request, maxTextBytes: 1))
            @Expect(result.rawText, None); @Expect(result.choiceIndex, 8)
            match (result.outcome) { case LlmWireStructuredOutputOutcome.Incomplete(actual) => @Expect(actual, reason); case _ => @Fail("complete JSON cannot override incomplete") }
        }
        let denied = LlmWireRefusalBlock("no", category: Some("policy"))
        for (reply in [
            LlmWireReply(choices: [LlmWireChoice(9, [], LlmWireChoiceOutcome.Refused(denied))]),
            LlmWireReply(choices: [LlmWireChoice(9, [LlmWireOutputBlock.Text(LlmWireTextBlock("not JSON")), LlmWireOutputBlock.Refusal(denied)], LlmWireChoiceOutcome.Incomplete(LlmWireIncompleteReason.Length))])
        ]) {
            let result = outputResult(extractStructuredOutput(reply, request, maxTextBytes: 1))
            @Expect(result.rawText, None)
            match (result.outcome) { case LlmWireStructuredOutputOutcome.Refused(actual) => @Expect(actual.category, Some("policy")); case _ => @Fail("refusal must win") }
        }
    }

    @TestCase
    func choiceSelectionUsesIndicesAndIgnoresUnselectedSemanticFailures() {
        let request = outputRequest(LlmWireStructuredOutput.JsonObject)
        let good = LlmWireChoice(17, [LlmWireOutputBlock.Text(LlmWireTextBlock("{}"))], LlmWireChoiceOutcome.Completed)
        let bad = LlmWireChoice(3, [LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("c", "bad", LlmWireToolArguments.Partial("{")))], LlmWireChoiceOutcome.Completed)
        let reply = LlmWireReply(choices: [bad, good])
        @Expect(outputKind(extractStructuredOutput(reply, request)), "llm.structured_output_choice_required")
        @Expect(outputResult(extractStructuredOutput(reply, request, choiceIndex: Some(17))).choiceIndex, 17)
        @Expect(outputKind(extractStructuredOutput(reply, request, choiceIndex: Some(1))), "llm.structured_output_choice_missing")
        @Expect(outputKind(extractStructuredOutput(reply, request, choiceIndex: Some(-1))), "llm.structured_output_choice_missing")
        @Expect(outputKind(extractStructuredOutput(LlmWireReply(choices: [good, good]), request, choiceIndex: Some(17))), "llm.structured_output_choice_ambiguous")
        @Expect(outputKind(extractStructuredOutput(LlmWireReply(choices: [bad]), request)), "llm.structured_output_tool_calls_present")
    }

    @TestCase
    func explicitMessageBoundariesSelectUniqueFinalWithoutJoiningAnswers() {
        let request = outputRequest(LlmWireStructuredOutput.JsonObject)
        let blocks = [LlmWireOutputBlock.Text(LlmWireTextBlock("commentary", phase: LlmWireOutputPhase.Commentary)),
            LlmWireOutputBlock.Reasoning(LlmWireReasoningBlock("reasoning")),
            LlmWireOutputBlock.Text(LlmWireTextBlock("{\"a\":")), LlmWireOutputBlock.Text(LlmWireTextBlock("1}", phase: LlmWireOutputPhase.Final))]
        let choice = LlmWireChoice(0, blocks, LlmWireChoiceOutcome.Completed, messageSpans: [LlmWireAssistantMessageSpan(0,1,phase: LlmWireOutputPhase.Commentary), LlmWireAssistantMessageSpan(2,2,phase: LlmWireOutputPhase.Final)])
        @Expect(outputResult(extractStructuredOutput(LlmWireReply(choices: [choice]), request)).rawText, Some("{\"a\":1}"))
        let unphased = [LlmWireOutputBlock.Text(LlmWireTextBlock("{}")), LlmWireOutputBlock.Text(LlmWireTextBlock("{}"))]
        for (phase in [LlmWireOutputPhase.Final, LlmWireOutputPhase.Unspecified]) {
            let multiple = LlmWireChoice(0, unphased, LlmWireChoiceOutcome.Completed, messageSpans: [LlmWireAssistantMessageSpan(0,1,phase: phase), LlmWireAssistantMessageSpan(1,1,phase: phase)])
            @Expect(outputKind(extractStructuredOutput(LlmWireReply(choices: [multiple]), request)), "llm.structured_output_message_ambiguous")
        }
        let emptyFinal = LlmWireChoice(0, [], LlmWireChoiceOutcome.Completed, messageSpans: [LlmWireAssistantMessageSpan(0,0,phase: LlmWireOutputPhase.Final)])
        @Expect(outputKind(extractStructuredOutput(LlmWireReply(choices: [emptyFinal]), request)), "InvalidJson")
        let other = LlmWireChoice(0, [unphased[0]], LlmWireChoiceOutcome.Completed, messageSpans: [LlmWireAssistantMessageSpan(0,1,phase: LlmWireOutputPhase.Commentary)])
        @Expect(outputKind(extractStructuredOutput(LlmWireReply(choices: [other]), request)), "llm.structured_output_message_missing")
        let invalid = LlmWireChoice(0, [unphased[0]], LlmWireChoiceOutcome.Completed, messageSpans: [LlmWireAssistantMessageSpan(1,1)])
        @Expect(outputKind(extractStructuredOutput(LlmWireReply(choices: [invalid]), request)), "llm.responses_message_spans_invalid")
        let conflict = LlmWireChoice(0, [blocks[0]], LlmWireChoiceOutcome.Completed, messageSpans: [LlmWireAssistantMessageSpan(0,1,phase: LlmWireOutputPhase.Final)])
        @Expect(outputKind(extractStructuredOutput(LlmWireReply(choices: [conflict]), request)), "llm.structured_output_message_invalid")
    }

    @TestCase
    func legacyTextSplitsAndKnownNonAnswerPhasesHaveExplicitPolicy() {
        let request = outputRequest(LlmWireStructuredOutput.JsonObject)
        let native = LlmWireNativeReplayBlock.restore("{\"protocol\":\"responses\",\"dialect_id\":\"openai.responses.v1\",\"native_type\":\"reasoning\",\"schema_version\":1,\"scope\":\"assistant_turn\",\"assistant_turn_index\":0,\"block_order\":0,\"complete\":true,\"payload\":{\"type\":\"reasoning\",\"id\":\"rs\",\"summary\":[]}}")
        let reply = LlmWireReply(blocks: [LlmWireOutputBlock.NativeReplay(native), LlmWireOutputBlock.Reasoning(LlmWireReasoningBlock("ignore")), LlmWireOutputBlock.Text(LlmWireTextBlock("{")), LlmWireOutputBlock.Text(LlmWireTextBlock("}"))])
        @Expect(outputResult(extractStructuredOutput(reply, request)).rawText, Some("{}"))
        let phased = LlmWireReply(blocks: [LlmWireOutputBlock.Text(LlmWireTextBlock("ignore", phase: LlmWireOutputPhase.Analysis)), LlmWireOutputBlock.Text(LlmWireTextBlock("{}", phase: LlmWireOutputPhase.Final))])
        @Expect(outputKind(extractStructuredOutput(phased, request)), "Valid")
        @Expect(outputKind(extractStructuredOutput(LlmWireReply(blocks: [LlmWireOutputBlock.Text(LlmWireTextBlock("ignore", phase: LlmWireOutputPhase.Commentary))]), request)), "llm.structured_output_message_missing")
    }

    @TestCase
    func byteDepthAndWorkLimitsReturnOuterTypedErrors() {
        let request = outputRequest(LlmWireStructuredOutput.JsonObject)
        @Expect(outputKind(extractStructuredOutput(outputReply("{}"), request, maxTextBytes: 2)), "Valid")
        @Expect(outputKind(extractStructuredOutput(outputReply("{}"), request, maxTextBytes: 1)), "llm.structured_output_text_limit")
        let unicode = "{\"v\":\"😀\"}"
        @Expect(outputKind(extractStructuredOutput(outputReply(unicode), request, maxTextBytes: unicode.size)), "Valid")
        @Expect(outputKind(extractStructuredOutput(outputReply(unicode), request, maxTextBytes: unicode.size - 1)), "llm.structured_output_text_limit")
        for (depth in [256,257]) {
            let text = String.fromUtf8(Array<Byte>(depth, repeat: b'[')) + "0" + String.fromUtf8(Array<Byte>(depth, repeat: b']'))
            let result = extractStructuredOutput(outputReply(text), outputRequest(outputSchema("{}")))
            @Expect(outputKind(result), if (depth == 256) { "Valid" } else { "llm.structured_output_json_limit" })
            if (depth == 257) { match (result) { case LlmWireResult.Err(error) => @Expect(error.kind, LlmWireErrorKind.LimitExceeded); case _ => @Fail("outer resource error") } }
        }
        @Expect(outputKind(extractStructuredOutput(outputReply("{\"v\":[]}"), request, limits: LlmWireSchemaValidationLimits(maxDepth: 1))), "llm.structured_output_json_limit")
        @Expect(outputKind(extractStructuredOutput(outputReply("{}"), request, limits: LlmWireSchemaValidationLimits(maxWork: 1))), "llm.schema_validation_limit")
        let max = 8388608
        let text = "{\"v\":\"" + String.fromUtf8(Array<Byte>(max - 8, repeat: b'a')) + "\"}"
        @Expect(text.size, max)
        @Expect(outputKind(extractStructuredOutput(outputReply(text), request)), "Valid")
        @Expect(outputKind(extractStructuredOutput(outputReply(text + " "), request)), "llm.structured_output_text_limit")
    }

    @TestCase
    func requestFormatsAndOptionsAreValidatedWithoutGuessingCapabilities() {
        for (format in [LlmWireStructuredOutput.Text, LlmWireStructuredOutput.ProviderDefault]) {
            @Expect(outputKind(extractStructuredOutput(outputReply("{}"), outputRequest(format))), "llm.structured_output_format_required")
        }
        for (format in [LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("", jsonFactoryValue(LlmWireJson.parse("{}")))), outputSchema("[]"), LlmWireStructuredOutput.JsonSchemaDocument(LlmWireJson.boolean(true))]) {
            @Expect(outputKind(extractStructuredOutput(outputReply("{}"), outputRequest(format))), "llm.structured_schema_invalid")
        }
        let request = outputRequest(LlmWireStructuredOutput.JsonObject)
        @Expect(outputKind(extractStructuredOutput(outputReply("{}"), request, mode: LlmWireToolInputValidationMode.Disabled)), "llm.structured_output_options_invalid")
        for (limit in [0,8388609]) { @Expect(outputKind(extractStructuredOutput(outputReply("{}"), request, maxTextBytes: limit)), "llm.structured_output_options_invalid") }
    }
}
