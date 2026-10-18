package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

private func structuredAcceptanceJson(source: String): LlmWireJson {
    match (LlmWireJson.parse(source)) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(error) => throw error
    }
}

private func structuredAcceptanceRequest(schema!: ?String = None): LlmWireRequest {
    let format = match (schema) {
        case Some(source) => LlmWireStructuredOutput.JsonSchemaDocument(structuredAcceptanceJson(source))
        case None => LlmWireStructuredOutput.JsonObject
    }
    LlmWireRequest("fixture-model", LlmWireTranscript(items: [
        LlmWireInputItem.Message(LlmWireMessage(LlmWireRole.User, [LlmWireBlock.Text(LlmWireTextBlock("answer"))]))
    ]), structuredOutput: format)
}

private func structuredAcceptanceResult(value: LlmWireResult<LlmWireStructuredOutputResult>): LlmWireStructuredOutputResult {
    match (value) {
        case LlmWireResult.Ok(result) => result
        case LlmWireResult.Err(error) => throw error
    }
}

private func structuredAcceptanceError(value: LlmWireResult<LlmWireStructuredOutputResult>): LlmWireError {
    match (value) {
        case LlmWireResult.Err(error) => error
        case LlmWireResult.Ok(_) => throw Exception("expected an outer extraction error")
    }
}

private func structuredAcceptanceReply(text: String): LlmWireReply {
    LlmWireReply(choices: [LlmWireChoice(23, [LlmWireOutputBlock.Text(LlmWireTextBlock(text))], LlmWireChoiceOutcome.Completed)],
        usage: LlmWireUsage(inputTokens: Some(5), outputTokens: Some(7)))
}

@Test
class StructuredAcceptanceTest {
    @TestCase
    func schemaDiagnosticsIncludeOnlyAvailableEvidence() {
        // Independent JSON Schema 2020-12 expectations: required, additional
        // properties and false schemas; specification checked 2026-10-18.
        let schemas = ["{\"required\":[\"missing\"]}", "{\"additionalProperties\":false}", "{\"allOf\":[false]}"]
        let instances = ["{}", "{\"extra\":1}", "{}"]
        let names = ["missing_required", "additional_property", "false_schema"]
        for (index in 0..schemas.size) {
            let result = structuredAcceptanceResult(extractStructuredOutput(structuredAcceptanceReply(instances[index]),
                structuredAcceptanceRequest(schema: Some(schemas[index]))))
            @Expect(result.choiceIndex, 23)
            @Expect(result.rawText, Some(instances[index]))
            match (result.outcome) {
                case LlmWireStructuredOutputOutcome.SchemaViolation(error) =>
                    @Expect(error.code, "llm.structured_output_schema_violation")
                    @Expect(error.kind, LlmWireErrorKind.InvalidWire)
                    @Expect(error.phase, Some(LlmTransportPhase.SemanticAssembly))
                    @Expect(error.usage.getOrThrow().outputTokens, Some(7))
                    let diagnostic = structuredAcceptanceJson(error.diagnosticJson.getOrThrow())
                    @Expect(diagnostic.field("choice_index").getOrThrow().numberLiteral(), Some("23"))
                    @Expect(diagnostic.field("violation").getOrThrow().stringValue(), Some(names[index]))
                    @Expect(diagnostic.field("expected").isSome(), index == 0)
                    @Expect(diagnostic.field("actual").isSome(), index == 1)
                case _ => @Fail("schema failure must remain distinct from a parse failure")
            }
        }
    }

    @TestCase
    func uniqueUnspecifiedMessageExcludesOtherMessagesAndKeepsExactUtf8Text() {
        let blocks = [
            LlmWireOutputBlock.Text(LlmWireTextBlock("commentary", phase: LlmWireOutputPhase.Commentary)),
            LlmWireOutputBlock.Reasoning(LlmWireReasoningBlock("reasoning")),
            LlmWireOutputBlock.Text(LlmWireTextBlock(" {\"v\":")),
            LlmWireOutputBlock.Text(LlmWireTextBlock("\"😀\"}\n")),
            LlmWireOutputBlock.Text(LlmWireTextBlock("analysis", phase: LlmWireOutputPhase.Analysis))
        ]
        let spans = [
            LlmWireAssistantMessageSpan(0, 1, phase: LlmWireOutputPhase.Commentary),
            LlmWireAssistantMessageSpan(2, 2),
            LlmWireAssistantMessageSpan(4, 1, phase: LlmWireOutputPhase.Analysis)
        ]
        let raw = " {\"v\":\"😀\"}\n"
        let reply = LlmWireReply(choices: [LlmWireChoice(31, blocks, LlmWireChoiceOutcome.Completed, messageSpans: spans)])
        let result = structuredAcceptanceResult(extractStructuredOutput(reply, structuredAcceptanceRequest(), maxTextBytes: raw.size))
        @Expect(result.choiceIndex, 31)
        @Expect(result.rawText, Some(raw))
        match (result.outcome) {
            case LlmWireStructuredOutputOutcome.Valid(value) =>
                @Expect(value.field("v").getOrThrow().stringValue(), Some("😀"))
            case _ => @Fail("the unique unspecified message is a complete candidate")
        }
        let error = structuredAcceptanceError(extractStructuredOutput(reply, structuredAcceptanceRequest(), maxTextBytes: raw.size - 1))
        @Expect(error.code, "llm.structured_output_text_limit")
        @Expect(error.kind, LlmWireErrorKind.LimitExceeded)
    }

    @TestCase
    func parseOffsetsCountUtf8BytesAndNeverRepeatProviderText() {
        let texts = ["{\"é\":]}", "{\n\"😀\":]}"]
        let offsets = ["6", "9"]
        for (index in 0..texts.size) {
            let result = structuredAcceptanceResult(extractStructuredOutput(structuredAcceptanceReply(texts[index]), structuredAcceptanceRequest()))
            @Expect(result.rawText, Some(texts[index]))
            match (result.outcome) {
                case LlmWireStructuredOutputOutcome.InvalidJson(error) =>
                    let diagnostic = structuredAcceptanceJson(error.diagnosticJson.getOrThrow())
                    @Expect(diagnostic.field("byte_offset").getOrThrow().numberLiteral(), Some(offsets[index]))
                    @Expect(diagnostic.field("choice_index").getOrThrow().numberLiteral(), Some("23"))
                    @Expect(error.diagnosticJson.getOrThrow().contains("é"), false)
                    @Expect(error.diagnosticJson.getOrThrow().contains("😀"), false)
                    @Expect(error.usage.getOrThrow().inputTokens, Some(5))
                case _ => @Fail("malformed JSON text must retain a safe UTF-8 byte offset")
            }
        }
    }

    @TestCase
    func resourceFailuresKeepUsageAndDistinguishUnselectedAndSelectedStages() {
        let choice = LlmWireChoice(47, [LlmWireOutputBlock.Text(LlmWireTextBlock("{}"))], LlmWireChoiceOutcome.Completed)
        let reply = LlmWireReply(choices: [LlmWireChoice(2, [], LlmWireChoiceOutcome.Completed), choice],
            usage: LlmWireUsage(outputTokens: Some(11)))
        for (work in [1, 3]) {
            let error = structuredAcceptanceError(extractStructuredOutput(reply, structuredAcceptanceRequest(), choiceIndex: Some(47),
                limits: LlmWireSchemaValidationLimits(maxWork: work)))
            @Expect(error.code, "llm.schema_validation_limit")
            @Expect(error.kind, LlmWireErrorKind.LimitExceeded)
            @Expect(error.phase, Some(LlmTransportPhase.SemanticAssembly))
            @Expect(error.usage.getOrThrow().outputTokens, Some(11))
            let diagnostic = structuredAcceptanceJson(error.diagnosticJson.getOrThrow())
            @Expect(diagnostic.field("choice_index").getOrThrow().numberLiteral(), Some(if (work == 1) { "-1" } else { "47" }))
        }
        let schema = "{\"properties\":{\"unused\":{\"type\":\"object\",\"properties\":{\"deep\":true}}}}"
        for (limits in [LlmWireSchemaValidationLimits(maxWork: 16), LlmWireSchemaValidationLimits(maxDepth: 1)]) {
            let error = structuredAcceptanceError(extractStructuredOutput(structuredAcceptanceReply("{}"),
                structuredAcceptanceRequest(schema: Some(schema)), limits: limits))
            @Expect(error.code, "llm.schema_validation_limit")
            @Expect(error.usage.getOrThrow().outputTokens, Some(7))
            let diagnostic = structuredAcceptanceJson(error.diagnosticJson.getOrThrow())
            @Expect(diagnostic.field("choice_index").getOrThrow().numberLiteral(), Some("23"))
        }
        // The same allowance covers extraction, schema and instance together.
        // A small answer that fits JsonObject cannot reset the budget when a
        // declared schema adds validation work.
        let allowance = LlmWireSchemaValidationLimits(maxWork: 11)
        let plain = structuredAcceptanceResult(extractStructuredOutput(structuredAcceptanceReply("{}"),
            structuredAcceptanceRequest(), limits: allowance))
        match (plain.outcome) {
            case LlmWireStructuredOutputOutcome.Valid(_) => ()
            case _ => @Fail("the small JsonObject answer fits the allowance")
        }
        let declared = structuredAcceptanceError(extractStructuredOutput(structuredAcceptanceReply("{}"),
            structuredAcceptanceRequest(schema: Some("{}")), limits: allowance))
        @Expect(declared.code, "llm.schema_validation_limit")
        @Expect(declared.usage.getOrThrow().outputTokens, Some(7))
    }

    @TestCase
    func scalarJsonObjectMismatchRemainsAValidationOutcome() {
        for (text in ["null", "false", "\"value\"", "42"]) {
            let result = structuredAcceptanceResult(extractStructuredOutput(structuredAcceptanceReply(text), structuredAcceptanceRequest()))
            @Expect(result.rawText, Some(text))
            match (result.outcome) {
                case LlmWireStructuredOutputOutcome.SchemaViolation(error) =>
                    let diagnostic = structuredAcceptanceJson(error.diagnosticJson.getOrThrow())
                    @Expect(diagnostic.field("expected").getOrThrow().stringValue(), Some("object"))
                    @Expect(diagnostic.field("actual").isSome(), true)
                case _ => @Fail("a valid scalar is not malformed JSON")
            }
            let allowed = structuredAcceptanceResult(extractStructuredOutput(structuredAcceptanceReply(text),
                structuredAcceptanceRequest(schema: Some("{}"))))
            match (allowed.outcome) {
                case LlmWireStructuredOutputOutcome.Valid(_) => ()
                case _ => @Fail("an empty declared schema permits every JSON value")
            }
        }
    }

    @TestCase
    func incompleteOutcomePrecedesMixedToolAndMalformedText() {
        let blocks = [LlmWireOutputBlock.Text(LlmWireTextBlock("{")),
            LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("call", "tool", LlmWireToolArguments.Partial("{")))]
        let choice = LlmWireChoice(19, blocks, LlmWireChoiceOutcome.Incomplete(LlmWireIncompleteReason.MaxTokens))
        let result = structuredAcceptanceResult(extractStructuredOutput(LlmWireReply(choices: [choice]), structuredAcceptanceRequest(), maxTextBytes: 1))
        @Expect(result.choiceIndex, 19)
        @Expect(result.rawText, None)
        match (result.outcome) {
            case LlmWireStructuredOutputOutcome.Incomplete(reason) => @Expect(reason, LlmWireIncompleteReason.MaxTokens)
            case _ => @Fail("truncated text and tool arguments cannot become an answer")
        }
    }
}
