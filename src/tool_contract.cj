package llm4cj

import std.collection.*
import std.deriving.Derive
import yjson.*

// Tool Input Contract Validation: a protocol-independent barrier between a
// wire-valid reply and tool execution. The validator never runs inside the
// decoders; callers opt in by invoking `validateReplyToolInputs` with the tool
// transcript from the originating request. Its end-state visibility is the
// authority for newly generated calls, independent of historical visibility.
@Derive[Equatable]
public enum LlmWireToolInputValidationMode {
    Disabled
    | ValidateSupportedSubset
    | Strict
}

// Annotation keywords never constrain instances and are ignored. Every other
// keyword outside the supported subset is reported as an unsupported feature —
// including unknown keywords — so a typo can never silently weaken the barrier.
internal func isToolSchemaAnnotationKeyword(name: String): Bool {
    name == "description" || name == "title" || name == "default" || name == "examples" ||
    name == "$schema" || name == "$id" || name == "$comment" || name == "$defs" || name == "definitions" ||
    name == "deprecated" || name == "readOnly" || name == "writeOnly"
}

internal func isToolSchemaSupportedKeyword(name: String): Bool {
    name == "type" || name == "properties" || name == "required" ||
    name == "additionalProperties" || name == "items" || name == "enum" || name == "const" ||
    schemaNumberKeyword(name) || schemaCountKeyword(name) || schemaCombinator(name)
}

internal enum ToolInputCheck { Valid | Violation(ToolInputViolation) | Unsupported(String) }

internal enum ToolInputViolationKind { TypeMismatch | MissingRequired | AdditionalProperty | EnumMismatch | Constraint(String) }

internal func toolInputViolationName(kind: ToolInputViolationKind): String {
    match (kind) {
        case ToolInputViolationKind.TypeMismatch => "type_mismatch"
        case ToolInputViolationKind.MissingRequired => "missing_required"
        case ToolInputViolationKind.AdditionalProperty => "additional_property"
        case ToolInputViolationKind.EnumMismatch => "enum_mismatch"
        case ToolInputViolationKind.Constraint(name) => name
    }
}

internal class ToolInputViolation {
    internal let kind: ToolInputViolationKind
    internal let schemaPath: String
    internal let instancePath: String
    internal let expected: String
    internal let actual: String
    internal init(kind: ToolInputViolationKind, schemaPath: String, instancePath: String, expected!: String = "", actual!: String = "") {
        this.kind = kind; this.schemaPath = schemaPath; this.instancePath = instancePath
        this.expected = expected; this.actual = actual
    }
}

internal func toolInputPath(base: String, component: String, prefix!: String = "/"): String {
    let marker = "<path exceeds 128 bytes>"
    if (base == marker || base.size + prefix.size + component.size > 128) { return marker }
    let escaped = ArrayList<Byte>()
    for (index in 0..component.size) {
        let byte = component[index]
        if (byte == b'~' || byte == b'/') { escaped.add(b'~'); escaped.add(if (byte == b'~') { b'0' } else { b'1' }) }
        else { escaped.add(byte) }
        if (base.size + prefix.size + escaped.size > 128) { return marker }
    }
    base + prefix + String.fromUtf8(escaped.toArray())
}

// Evidence strings are bounded by replacing oversized payloads with a length
// marker instead of slicing bytes, which keeps every diagnostic valid UTF-8.
internal func toolInputValueRepr(value: JsonNode): String {
    let output = WireJsonOutput(retainLimit: 64)
    value.writeJson(output, options: JsonWriteOptions(maxOutputBytes: LLM_JSON_MAX_BYTES, maxDepth: LLM_JSON_MAX_DEPTH))
    if (output.size > 64) { return "<" + output.size.toString() + " bytes>" }
    output.text()
}

internal func toolInputTextRepr(value: String): String {
    let size = value.size
    if (size > 64) { return "<" + size.toString() + " bytes>" }
    value
}

internal func toolInputJsonKindName(value: JsonNode): String {
    match (value.wireKind) {
        case WireJsonKind.Null => "null"
        case WireJsonKind.Boolean => "boolean"
        case WireJsonKind.Number => "number"
        case WireJsonKind.Text => "string"
        case WireJsonKind.List => "array"
        case WireJsonKind.Object => "object"
    }
}

internal func toolInputTypeKnown(name: String): Bool {
    name == "string" || name == "number" || name == "integer" || name == "boolean" ||
    name == "object" || name == "array" || name == "null"
}

internal func toolInputTypeFormValid(value: JsonNode): Bool {
    match (value.wireKind) {
        case WireJsonKind.Text => toolInputTypeKnown(value.text)
        case WireJsonKind.List =>
            for (entry in value.items) {
                match (entry.wireKind) {
                    case WireJsonKind.Text => if (!toolInputTypeKnown(entry.text)) { return false }
                    case _ => return false
                }
            }
            true
        case _ => false
    }
}

internal func toolInputNumberIsFractional(value: JsonNode): Bool {
    !wireJsonNumberIsInteger(value.numberText)
}

internal func toolInputTypeAccepts(name: String, value: JsonNode): Bool {
    match (name) {
        case "string" => value.wireKind == WireJsonKind.Text
        case "boolean" => value.wireKind == WireJsonKind.Boolean
        case "null" => value.wireKind == WireJsonKind.Null
        case "array" => value.wireKind == WireJsonKind.List
        case "object" => value.wireKind == WireJsonKind.Object
        case "number" => value.wireKind == WireJsonKind.Number
        case "integer" => value.wireKind == WireJsonKind.Number && !toolInputNumberIsFractional(value)
        case _ => false
    }
}

// Determinism without depending on hash-map iteration order: supported checks
// run in a fixed priority, and property/key scans walk a locally sorted copy.
internal func sortToolSchemaNames(values: ArrayList<String>, budget!: ?SchemaBudget = None): Unit {
    let temporary = Array<String>(values.size, repeat: "")
    var width: Int64 = 1
    while (width < values.size) {
        var start: Int64 = 0
        while (start < values.size) {
            let middle = min(start + width, values.size); let end = min(middle + width, values.size)
            var left = start; var right = middle
            for (out in start..end) {
                var useLeft = right == end
                if (left < middle && right < end) {
                    match (budget) { case Some(value) => value.charge(values[left].size + values[right].size + 1); case None => () }
                    useLeft = values[left] <= values[right]
                }
                if (left < middle && useLeft) { temporary[out] = values[left]; left++ }
                else { temporary[out] = values[right]; right++ }
            }
            start = end
        }
        for (index in 0..values.size) { values[index] = temporary[index] }
        width *= 2
    }
}

internal func toolSchemaObjectNames(schema: JsonNode, budget!: ?SchemaBudget = None): ArrayList<String> {
    let names = ArrayList<String>()
    let object = schema.asObject()
    match (budget) { case Some(value) => value.charge(object.size()); case None => () }
    for (index in 0..object.size()) { names.add(object.nameAt(index)) }
    sortToolSchemaNames(names, budget: budget)
    names
}

internal func schemaDiagnostic(value: JsonNode): String {
    try {
        let output = WireJsonOutput(retainLimit: 2048)
        value.writeJson(output, options: JsonWriteOptions(maxOutputBytes: 2048, maxDepth: 256))
        output.text()
    } catch (_: JsonException) {
        "{\"evidence\":\"diagnostic exceeds 2048 bytes\"}"
    }
}

internal func toolInputViolationError(call: LlmWireToolCallBlock, violation: ToolInputViolation): LlmWireError {
    let diagnostic = wireJsonObject([
        WireJsonField("tool_name", wireJsonString(boundedTranscriptEvidence(call.name))),
        WireJsonField("schema_path", wireJsonString(boundedTranscriptEvidence(violation.schemaPath))),
        WireJsonField("instance_path", wireJsonString(boundedTranscriptEvidence(violation.instancePath))),
        WireJsonField("violation", wireJsonString(toolInputViolationName(violation.kind)))
    ])
    if (violation.expected != "") { diagnostic.put("expected", wireJsonString(violation.expected)) }
    if (violation.actual != "") { diagnostic.put("actual", wireJsonString(violation.actual)) }
    LlmWireError(
        LlmWireErrorKind.InvalidWire, "llm.tool_arguments_schema_violation",
        "tool arguments do not satisfy the declared input schema at " + boundedTranscriptEvidence(violation.instancePath),
        phase: Some(LlmTransportPhase.SemanticAssembly), toolCallId: boundedTranscriptEvidence(call.callId), toolName: boundedTranscriptEvidence(call.name), diagnosticJson: Some(schemaDiagnostic(diagnostic))
    )
}

internal func toolInputUnsupportedError(call: LlmWireToolCallBlock, feature: String, schemaPath!: String = ""): LlmWireError {
    let diagnostic = wireJsonObject([
        WireJsonField("tool_name", wireJsonString(boundedTranscriptEvidence(call.name))),
        WireJsonField("feature", wireJsonString(toolInputTextRepr(feature))),
        WireJsonField("schema_path", wireJsonString(schemaPath))
    ])
    LlmWireError(
        LlmWireErrorKind.Unsupported, "llm.tool_schema_unsupported",
        "tool input schema uses features outside the supported validation subset: " + boundedTranscriptEvidence(feature),
        phase: Some(LlmTransportPhase.SemanticAssembly), toolCallId: boundedTranscriptEvidence(call.callId), toolName: boundedTranscriptEvidence(call.name), diagnosticJson: Some(schemaDiagnostic(diagnostic))
    )
}

// Validates tool call arguments in a wire-valid reply against the input schemas
// active tools at the end of the originating transcript. The temporal replay
// checks every historical call at its own item; this barrier checks newly
// generated calls against the final state. Unknown or inactive tools are always
// rejected, including when argument-schema validation is disabled. Calls whose
// arguments are not complete JSON objects are skipped by the schema barrier.
// Reports the first violation in
// deterministic order: block order, then fixed keyword priority, then sorted
// property names. Undeclared schema keywords and unsupported forms surface as
// `llm.tool_schema_unsupported` under Strict. ValidateSupportedSubset reports a
// provable violation first, otherwise unsupported rules also fail closed.
// Disabled performs no argument-schema checks.
public func validateReplyToolInputs(
    reply: LlmWireReply, transcript: LlmWireTranscript,
    mode!: LlmWireToolInputValidationMode = LlmWireToolInputValidationMode.ValidateSupportedSubset,
    limits!: LlmWireSchemaValidationLimits = LlmWireSchemaValidationLimits()
): LlmWireResult<Unit> {
    try {
        let view = replayTranscript(transcript)
        for (choice in reply.choices) {
            let callIds = HashSet<String>()
            for (block in choice.blocks) { match (block) {
            case LlmWireOutputBlock.ToolCall(call) =>
                if (!callIds.add(call.callId)) {
                    return LlmWireResult.Err(LlmWireError(
                        LlmWireErrorKind.InvalidWire, "llm.tool_call_id_duplicate",
                        "generated tool calls must have unique call IDs",
                        toolCallId: boundedTranscriptEvidence(call.callId), usage: observedWireUsage(reply.usage)
                    ))
                }
                if (call.kind == LlmWireToolKind.Custom) {
                    if (call.callId == "" || !validToolName(call.name)) {
                        return LlmWireResult.Err(LlmWireError(
                            LlmWireErrorKind.InvalidWire, "llm.tool_call_incomplete",
                            "custom tool call requires an id and a valid name", usage: observedWireUsage(reply.usage)
                        ))
                    }
                    match (call.arguments) {
                        case LlmWireToolArguments.PartialText(_) =>
                            return LlmWireResult.Err(LlmWireError(
                                LlmWireErrorKind.InvalidWire, "llm.tool_arguments_not_executable",
                                "partial custom input cannot be executed", toolName: call.name,
                                toolCallId: boundedTranscriptEvidence(call.callId), usage: observedWireUsage(reply.usage)
                            ))
                        case _ => ()
                    }
                }
                var active = false
                for (tool in view.activeTools where tool.name == call.name) {
                    if (tool.kind != call.kind) {
                        return LlmWireResult.Err(LlmWireError(
                            LlmWireErrorKind.InvalidWire, "llm.tool_kind_mismatch",
                            "generated tool kind does not match the active definition", toolName: call.name,
                            toolCallId: boundedTranscriptEvidence(call.callId), usage: observedWireUsage(reply.usage)
                        ))
                    }
                    active = true
                }
                if (!active) {
                    var declared: ?LlmWireToolDeclaration = None
                    for (value in view.declaredTools where value.tool.name == call.name) { declared = Some(value) }
                    let (code, version) = match (declared) {
                        case Some(value) => ("llm.tool_not_active", value.version)
                        case None => ("llm.tool_reference_unknown", "")
                    }
                    return LlmWireResult.Err(LlmWireError(LlmWireErrorKind.InvalidWire, code,
                        "generated tool calls must refer to a tool active at the request end",
                        phase: Some(LlmTransportPhase.SemanticAssembly), inputItemIndex: transcript.items.size,
                        toolName: call.name, toolVersion: version, toolCallId: boundedTranscriptEvidence(call.callId), usage: observedWireUsage(reply.usage)))
                }
            case _ => ()
        } } }
        match (validateReplyToolInputSchemas(reply, view.activeTools, mode, limits: limits)) {
            case LlmWireResult.Ok(_) => LlmWireResult.Ok(())
            case LlmWireResult.Err(error) => LlmWireResult.Err(withObservedUsage(error, observedWireUsage(reply.usage)))
        }
    } catch (error: LlmWireError) { LlmWireResult.Err(withObservedUsage(error, observedWireUsage(reply.usage))) }
}

internal func validateReplyToolInputSchemas(
    reply: LlmWireReply, tools: Array<LlmWireToolDefinition>, mode: LlmWireToolInputValidationMode,
    limits!: LlmWireSchemaValidationLimits = LlmWireSchemaValidationLimits()
): LlmWireResult<Unit> {
    match (mode) {
        case LlmWireToolInputValidationMode.Disabled => return LlmWireResult.Ok(())
        case _ => ()
    }
    let strict = mode == LlmWireToolInputValidationMode.Strict
    let budget = SchemaBudget(limits)
    for (choice in reply.choices) { for (block in choice.blocks) {
        match (block) {
            case LlmWireOutputBlock.ToolCall(call) =>
                match (call.arguments) {
                    case LlmWireToolArguments.Complete(value) =>
                        var declared: ?LlmWireJson = None
                        for (definition in tools where definition.name == call.name) { match (definition) {
                            case LlmWireToolDefinition.Function(tool) => declared = Some(tool.inputSchema)
                            case _ => ()
                        } }
                        match (declared) {
                            case Some(schema) =>
                                let evaluator = SchemaEvaluator(budget)
                                if (schema.kind != LlmWireJsonKind.Object) { return LlmWireResult.Err(toolInputUnsupportedError(call, "schema_not_object")) }
                                match (evaluator.check(budget.read(schema), budget.read(value), strict)) {
                                    case ToolInputCheck.Valid => ()
                                    case ToolInputCheck.Violation(violation) => return LlmWireResult.Err(toolInputViolationError(call, violation))
                                    case ToolInputCheck.Unsupported(feature) => return LlmWireResult.Err(toolInputUnsupportedError(call, feature, schemaPath: evaluator.unsupportedPath))
                                }
                            case None => ()
                        }
                    case LlmWireToolArguments.Text(_) =>
                        for (definition in tools where definition.name == call.name) { match (definition) {
                            case LlmWireToolDefinition.Custom(tool) => match (tool.format) {
                                case LlmWireCustomToolFormat.Grammar(_) => return LlmWireResult.Err(LlmWireError(LlmWireErrorKind.Unsupported, "llm.tool_grammar_validation_unsupported", "custom grammar validation requires a grammar engine not provided by this library", toolName: call.name, toolCallId: boundedTranscriptEvidence(call.callId)))
                                case _ => ()
                            }
                            case _ => ()
                        } }
                    case _ => ()
                }
            case _ => ()
        }
    } }
    LlmWireResult.Ok(())
}
