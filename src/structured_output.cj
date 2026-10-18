package llm4cj

import yjson.*

public enum LlmWireStructuredOutputOutcome {
    Valid(LlmWireJson)
    | InvalidJson(LlmWireError)
    | SchemaViolation(LlmWireError)
    | UnsupportedSchema(LlmWireError)
    | Incomplete(LlmWireIncompleteReason)
    | Refused(LlmWireRefusalBlock)
}

public class LlmWireStructuredOutputResult {
    public let choiceIndex: Int64
    // Exact candidate text, never repaired or canonicalized. Terminal refusal
    // and incomplete outcomes do not allocate another copy of the reply text.
    public let rawText: ?String
    public let outcome: LlmWireStructuredOutputOutcome
    internal init(choiceIndex: Int64, rawText: ?String, outcome: LlmWireStructuredOutputOutcome) {
        this.choiceIndex = choiceIndex
        this.rawText = rawText
        this.outcome = outcome
    }
}

private func structuredError(kind: LlmWireErrorKind, code: String, message: String, choice: Int64, usage: ?LlmWireUsage,
    diagnostic!: ?String = None): LlmWireError {
    let details = wireJsonObject([WireJsonField("choice_index", wireJsonNumber(choice.toString()))])
    LlmWireError(kind, code, message, phase: Some(LlmTransportPhase.SemanticAssembly), usage: usage,
        diagnosticJson: if (diagnostic.isSome()) { diagnostic } else { Some(schemaDiagnostic(details)) })
}

private func structuredChoice(reply: LlmWireReply, selected: ?Int64, budget: SchemaBudget): LlmWireChoice {
    budget.charge(reply.choices.size)
    match (selected) {
        case None =>
            if (reply.choices.size != 1) {
                throw structuredError(LlmWireErrorKind.InvalidState, "llm.structured_output_choice_required", "multi-choice extraction requires an explicit choice index", -1, observedWireUsage(reply.usage))
            }
            reply.choices[0]
        case Some(index) =>
            var found: ?LlmWireChoice = None
            for (choice in reply.choices where choice.index == index) {
                if (found.isSome()) {
                    throw structuredError(LlmWireErrorKind.InvalidState, "llm.structured_output_choice_ambiguous", "reply contains duplicate selected choice indices", index, observedWireUsage(reply.usage))
                }
                found = Some(choice)
            }
            match (found) {
                case Some(value) => value
                case None =>
                    throw structuredError(LlmWireErrorKind.InvalidState, "llm.structured_output_choice_missing", "reply does not contain the selected choice index", index, observedWireUsage(reply.usage))
            }
    }
}

// With explicit spans, select one assistant message; without spans the legacy
// reply is one implicit message. No boundary lost in a legacy value is invented.
private func structuredText(choice: LlmWireChoice, budget: SchemaBudget, limit: Int64, usage: ?LlmWireUsage): String {
    let spans = choice.messageSpans
    budget.charge(spans.size + choice.blocks.size)
    validateMessageSpanLayout(spans, choice.blocks.size, {index =>
        match (choice.blocks[index]) {
            case LlmWireOutputBlock.Text(_) | LlmWireOutputBlock.Refusal(_) => true
            case _ => false
        }
    })
    var start: Int64 = 0
    var end = choice.blocks.size
    var phase = LlmWireOutputPhase.Unspecified
    if (!spans.isEmpty()) {
        var finals: Int64 = 0
        var unspecified: Int64 = 0
        var finalSpan: ?LlmWireAssistantMessageSpan = None
        var fallback: ?LlmWireAssistantMessageSpan = None
        for (span in spans) {
            if (span.phase == LlmWireOutputPhase.Final) {
                finals++
                finalSpan = Some(span)
            }
            if (span.phase == LlmWireOutputPhase.Unspecified) {
                unspecified++
                fallback = Some(span)
            }
        }
        if (finals > 1 || (finals == 0 && unspecified > 1)) {
            throw structuredError(LlmWireErrorKind.InvalidState, "llm.structured_output_message_ambiguous", "structured extraction requires one final or one unspecified assistant message", choice.index, usage)
        }
        let chosen = if (finals == 1) { finalSpan } else { fallback }
        match (chosen) {
            case Some(span) =>
                start = span.blockStart
                end = start + span.blockCount
                phase = span.phase
            case None =>
                throw structuredError(LlmWireErrorKind.InvalidState, "llm.structured_output_message_missing", "reply has no final or unspecified assistant message", choice.index, usage)
        }
    } else {
        var finalText = false
        var unspecifiedText = false
        var otherText = false
        for (block in choice.blocks) {
            match (block) {
                case LlmWireOutputBlock.Text(text) =>
                    if (text.phase == LlmWireOutputPhase.Final) {
                        finalText = true
                    } else if (text.phase == LlmWireOutputPhase.Unspecified) {
                        unspecifiedText = true
                    } else {
                        otherText = true
                    }
                case _ => ()
            }
        }
        if (finalText) {
            phase = LlmWireOutputPhase.Final
        } else if (!unspecifiedText && otherText) {
            throw structuredError(LlmWireErrorKind.InvalidState, "llm.structured_output_message_missing", "reply has no final or unspecified assistant text", choice.index, usage)
        }
    }
    var bytes: Int64 = 0
    for (index in start..end) {
        budget.charge(1)
        match (choice.blocks[index]) {
            case LlmWireOutputBlock.Text(text) =>
                if (!spans.isEmpty() && text.phase != LlmWireOutputPhase.Unspecified && text.phase != phase) {
                    throw structuredError(LlmWireErrorKind.InvalidState, "llm.structured_output_message_invalid", "assistant message and text phases conflict", choice.index, usage)
                }
                if (!spans.isEmpty() || text.phase == phase) {
                    if (text.text.size > limit - bytes) {
                        throw structuredError(LlmWireErrorKind.LimitExceeded, "llm.structured_output_text_limit", "structured output text exceeds the configured byte limit", choice.index, usage)
                    }
                    budget.charge(text.text.size)
                    bytes += text.text.size
                }
            case _ => ()
        }
    }
    let builder = StringBuilder()
    for (index in start..end) {
        budget.charge(1)
        match (choice.blocks[index]) {
            case LlmWireOutputBlock.Text(text) =>
                if (!spans.isEmpty() || text.phase == phase) {
                    builder.append(text.text)
                }
            case _ => ()
        }
    }
    builder.toString()
}

private func structuredSchemaError(choice: Int64, usage: ?LlmWireUsage, violation: ToolInputViolation): LlmWireError {
    let diagnostic = wireJsonObject([
        WireJsonField("choice_index", wireJsonNumber(choice.toString())),
        WireJsonField("schema_path", wireJsonString(violation.schemaPath)),
        WireJsonField("instance_path", wireJsonString(violation.instancePath)),
        WireJsonField("violation", wireJsonString(toolInputViolationName(violation.kind)))
    ])
    if (violation.expected != "") {
        diagnostic.put("expected", wireJsonString(violation.expected))
    }
    if (violation.actual != "") {
        diagnostic.put("actual", wireJsonString(violation.actual))
    }
    structuredError(LlmWireErrorKind.InvalidWire, "llm.structured_output_schema_violation", "structured output does not satisfy its declared schema", choice, usage, diagnostic: Some(schemaDiagnostic(diagnostic)))
}

// Extraction is an explicit post-decode barrier. Streaming callers must pass a
// finalized canonical reply, never provisional text deltas.
public func extractStructuredOutput(
    reply: LlmWireReply, request: LlmWireRequest, choiceIndex!: ?Int64 = None,
    mode!: LlmWireToolInputValidationMode = LlmWireToolInputValidationMode.Strict,
    limits!: LlmWireSchemaValidationLimits = LlmWireSchemaValidationLimits(), maxTextBytes!: Int64 = 8388608
): LlmWireResult<LlmWireStructuredOutputResult> {
    let usage = observedWireUsage(reply.usage)
    var selectedIndex: Int64 = -1
    try {
        if (mode == LlmWireToolInputValidationMode.Disabled || maxTextBytes < 1 || maxTextBytes > LLM_JSON_MAX_BYTES) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.structured_output_options_invalid", "structured extraction requires schema validation and a positive byte limit no greater than 8 MiB")
        }
        var schema: ?LlmWireJson = None
        var objectOnly = false
        match (request.structuredOutput) {
            case LlmWireStructuredOutput.JsonObject => objectOnly = true
            case LlmWireStructuredOutput.JsonSchema(spec) =>
                if (spec.name == "" || spec.schema.kind != LlmWireJsonKind.Object) {
                    throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.structured_schema_invalid", "structured output name and object schema are required")
                }
                schema = Some(spec.schema)
            case LlmWireStructuredOutput.JsonSchemaDocument(document) =>
                if (document.kind != LlmWireJsonKind.Object) {
                    throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.structured_schema_invalid", "structured output schema must be a JSON object")
                }
                schema = Some(document)
            case _ =>
                throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.structured_output_format_required", "structured extraction requires JsonObject or a declared JSON schema")
        }
        let budget = SchemaBudget(limits)
        let choice = structuredChoice(reply, choiceIndex, budget)
        selectedIndex = choice.index
        budget.charge(choice.blocks.size)
        for (block in choice.blocks) {
            match (block) {
                case LlmWireOutputBlock.Refusal(refusal) =>
                    return LlmWireResult.Ok(LlmWireStructuredOutputResult(choice.index, None, LlmWireStructuredOutputOutcome.Refused(refusal)))
                case _ => ()
            }
        }
        match (choice.outcome) {
            case LlmWireChoiceOutcome.Refused(refusal) =>
                return LlmWireResult.Ok(LlmWireStructuredOutputResult(choice.index, None, LlmWireStructuredOutputOutcome.Refused(refusal)))
            case LlmWireChoiceOutcome.Incomplete(reason) =>
                return LlmWireResult.Ok(LlmWireStructuredOutputResult(choice.index, None, LlmWireStructuredOutputOutcome.Incomplete(reason)))
            case _ => ()
        }
        for (block in choice.blocks) {
            match (block) {
                case LlmWireOutputBlock.ToolCall(_) =>
                    throw structuredError(LlmWireErrorKind.InvalidState, "llm.structured_output_tool_calls_present", "a mixed tool-call reply is not a complete structured answer", choice.index, usage)
                case LlmWireOutputBlock.Audio(_) =>
                    throw structuredError(LlmWireErrorKind.InvalidState, "llm.structured_output_audio_present", "a mixed audio reply is not a complete structured answer", choice.index, usage)
                case _ => ()
            }
        }
        let text = structuredText(choice, budget, maxTextBytes, usage)
        var parsed: JsonNode
        try {
            parsed = JsonNode.parse(text, config: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
                maxDepth: limits.maxDepth, maxStringBytes: LLM_JSON_MAX_STRING_BYTES,
                maxInputBytes: maxTextBytes, maxBufferedValueBytes: maxTextBytes))
            // Canonical escaping can grow output. Check before retaining it.
            let output = WireJsonOutput(retainLimit: 0)
            parsed.writeJson(output, options: JsonWriteOptions(maxOutputBytes: LLM_JSON_MAX_BYTES, maxDepth: limits.maxDepth))
        } catch (error: JsonException) {
            if (error.code == "max_depth" || error.code == "document_too_large" || error.code == "string_too_large" || error.code == "buffered_value_too_large" || error.code == "output_too_large") {
                throw structuredError(LlmWireErrorKind.LimitExceeded, "llm.structured_output_json_limit", "structured output JSON exceeds the byte or depth limit", choice.index, usage)
            }
            let diagnostic = wireJsonObject([WireJsonField("choice_index", wireJsonNumber(choice.index.toString()))])
            match (error.location) {
                case Some(location) =>
                    diagnostic.put("byte_offset", wireJsonNumber(location.byteOffset.toString()))
                case None => ()
            }
            let invalid = structuredError(LlmWireErrorKind.InvalidWire, "llm.structured_output_invalid_json", "structured output text is not exactly one valid JSON value", choice.index, usage, diagnostic: Some(schemaDiagnostic(diagnostic)))
            return LlmWireResult.Ok(LlmWireStructuredOutputResult(choice.index, Some(text), LlmWireStructuredOutputOutcome.InvalidJson(invalid)))
        }
        if (objectOnly && parsed.wireKind != WireJsonKind.Object) {
            let error = structuredSchemaError(choice.index, usage, ToolInputViolation(ToolInputViolationKind.Constraint("type_mismatch"), "", "", expected: "object", actual: toolInputJsonKindName(parsed)))
            return LlmWireResult.Ok(LlmWireStructuredOutputResult(choice.index, Some(text), LlmWireStructuredOutputOutcome.SchemaViolation(error)))
        }
        let value = LlmWireJson.fromJsonNode(parsed)
        match (schema) {
            case Some(declared) =>
                let evaluator = SchemaEvaluator(budget)
                match (evaluator.check(budget.read(declared), budget.read(value), mode == LlmWireToolInputValidationMode.Strict)) {
                    case ToolInputCheck.Valid => ()
                    case ToolInputCheck.Violation(violation) =>
                        return LlmWireResult.Ok(LlmWireStructuredOutputResult(choice.index, Some(text), LlmWireStructuredOutputOutcome.SchemaViolation(structuredSchemaError(choice.index, usage, violation))))
                    case ToolInputCheck.Unsupported(feature) =>
                        let diagnostic = wireJsonObject([WireJsonField("choice_index", wireJsonNumber(choice.index.toString())), WireJsonField("feature", wireJsonString(toolInputTextRepr(feature))), WireJsonField("schema_path", wireJsonString(evaluator.unsupportedPath))])
                        let error = structuredError(LlmWireErrorKind.Unsupported, "llm.structured_output_schema_unsupported", "structured output schema contains unsupported constraints", choice.index, usage, diagnostic: Some(schemaDiagnostic(diagnostic)))
                        return LlmWireResult.Ok(LlmWireStructuredOutputResult(choice.index, Some(text), LlmWireStructuredOutputOutcome.UnsupportedSchema(error)))
                }
            case None => ()
        }
        LlmWireResult.Ok(LlmWireStructuredOutputResult(choice.index, Some(text), LlmWireStructuredOutputOutcome.Valid(value)))
    } catch (error: LlmWireError) {
        if (error.code == "llm.schema_validation_limit") {
            return LlmWireResult.Err(structuredError(error.kind, error.code, error.message, selectedIndex, usage))
        }
        LlmWireResult.Err(withObservedUsage(error, usage))
    }
}
