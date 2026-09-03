package llm4cj

import std.collection.*
import std.deriving.Derive
import yjson.*

// Tool Input Contract Validation: a protocol-independent barrier between a
// wire-valid reply and tool execution. The validator never runs inside the
// decoders; callers opt in by invoking `validateReplyToolInputs` with the tool
// definitions from the originating request.
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
    name == "additionalProperties" || name == "items" || name == "enum"
}

internal enum ToolInputCheck { Valid | Violation(ToolInputViolation) | Unsupported(String) }

internal enum ToolInputViolationKind { TypeMismatch | MissingRequired | AdditionalProperty | EnumMismatch }

internal func toolInputViolationName(kind: ToolInputViolationKind): String {
    match (kind) {
        case ToolInputViolationKind.TypeMismatch => "type_mismatch"
        case ToolInputViolationKind.MissingRequired => "missing_required"
        case ToolInputViolationKind.AdditionalProperty => "additional_property"
        case ToolInputViolationKind.EnumMismatch => "enum_mismatch"
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

// Evidence strings are bounded by replacing oversized payloads with a length
// marker instead of slicing bytes, which keeps every diagnostic valid UTF-8.
internal func toolInputValueRepr(value: JsonNode): String {
    let text = value.stringify()
    let size = text.toArray().size
    if (size > 64) { return "<" + size.toString() + " bytes>" }
    text
}

internal func toolInputTextRepr(value: String): String {
    let size = value.toArray().size
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
    let literal = value.number
    literal.contains(".") || literal.contains("e") || literal.contains("E")
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
internal func sortToolSchemaNames(values: ArrayList<String>): Unit {
    for (left in 0..values.size) {
        var smallest = left
        for (right in left + 1..values.size) { if (values[right] < values[smallest]) { smallest = right } }
        if (smallest != left) { let swapped = values[left]; values[left] = values[smallest]; values[smallest] = swapped }
    }
}

internal func toolSchemaObjectNames(schema: JsonNode): ArrayList<String> {
    let names = ArrayList<String>()
    for (name in schema.asObject().entries().keys()) { names.add(name) }
    sortToolSchemaNames(names)
    names
}

// Returns the first unsupported feature of this schema level: an unrecognized
// keyword (lexicographically first) or a supported keyword in an unsupported form.
internal func toolSchemaUnsupportedFeature(schema: JsonNode): ?String {
    if (schema.wireKind != WireJsonKind.Object) { return Some("schema_not_object") }
    for (name in toolSchemaObjectNames(schema)) {
        if (!isToolSchemaSupportedKeyword(name) && !isToolSchemaAnnotationKeyword(name)) { return Some(name) }
    }
    match (schema.field("type")) {
        case Some(value) => if (!toolInputTypeFormValid(value)) { return Some("type") }
        case None => ()
    }
    match (schema.field("required")) {
        case Some(value) =>
            if (value.wireKind != WireJsonKind.List) { return Some("required") }
            for (entry in value.items) { if (entry.wireKind != WireJsonKind.Text) { return Some("required") } }
        case None => ()
    }
    match (schema.field("properties")) { case Some(value) => if (value.wireKind != WireJsonKind.Object) { return Some("properties") }; case None => () }
    match (schema.field("additionalProperties")) { case Some(value) => if (value.wireKind != WireJsonKind.Boolean) { return Some("additionalProperties") }; case None => () }
    match (schema.field("items")) { case Some(value) => if (value.wireKind != WireJsonKind.Object) { return Some("items") }; case None => () }
    match (schema.field("enum")) {
        case Some(value) =>
            if (value.wireKind != WireJsonKind.List) { return Some("enum") }
            for (entry in value.items) { if (entry.stringify().toArray().size > 256) { return Some("enum") } }
        case None => ()
    }
    None
}

// Strict mode fails on unsupported features and malformed forms before any
// instance check; subset mode skips exactly those keywords instead.
internal func checkToolInputValue(schema: JsonNode, value: JsonNode, schemaPath: String, instancePath: String, strict: Bool): ToolInputCheck {
    if (strict) {
        match (toolSchemaUnsupportedFeature(schema)) { case Some(feature) => return ToolInputCheck.Unsupported(feature); case None => () }
    }
    match (schema.field("type")) {
        case Some(typeValue) =>
            if (toolInputTypeFormValid(typeValue)) {
                if (typeValue.wireKind == WireJsonKind.Text) {
                    if (!toolInputTypeAccepts(typeValue.text, value)) {
                        return ToolInputCheck.Violation(ToolInputViolation(ToolInputViolationKind.TypeMismatch, schemaPath + "/type", instancePath, expected: typeValue.text, actual: toolInputJsonKindName(value)))
                    }
                } else {
                    var expected = ""
                    var matched = false
                    for (entry in typeValue.items) {
                        if (expected == "") { expected = entry.text } else { expected = expected + "|" + entry.text }
                        if (toolInputTypeAccepts(entry.text, value)) { matched = true }
                    }
                    if (!matched) {
                        return ToolInputCheck.Violation(ToolInputViolation(ToolInputViolationKind.TypeMismatch, schemaPath + "/type", instancePath, expected: expected, actual: toolInputJsonKindName(value)))
                    }
                }
            }
        case None => ()
    }
    match (schema.field("enum")) {
        case Some(values) =>
            if (values.wireKind == WireJsonKind.List) {
                let literal = value.stringify()
                var found = false
                for (entry in values.items where entry.stringify() == literal) { found = true }
                if (!found) {
                    return ToolInputCheck.Violation(ToolInputViolation(ToolInputViolationKind.EnumMismatch, schemaPath + "/enum", instancePath, expected: toolInputValueRepr(values), actual: toolInputValueRepr(value)))
                }
            }
        case None => ()
    }
    match (schema.field("required")) {
        case Some(values) =>
            if (values.wireKind == WireJsonKind.List && value.wireKind == WireJsonKind.Object) {
                for (entry in values.items) {
                    if (value.field(entry.text).isNone()) {
                        return ToolInputCheck.Violation(ToolInputViolation(ToolInputViolationKind.MissingRequired, schemaPath + "/required", instancePath + "/" + entry.text, expected: toolInputTextRepr(entry.text)))
                    }
                }
            }
        case None => ()
    }
    match (schema.field("properties")) {
        case Some(properties) =>
            if (properties.wireKind == WireJsonKind.Object && value.wireKind == WireJsonKind.Object) {
                for (name in toolSchemaObjectNames(properties)) {
                    match (value.field(name)) {
                        case Some(child) =>
                            match (checkToolInputValue(properties.field(name).getOrThrow(), child, schemaPath + "/properties/" + name, instancePath + "/" + name, strict)) {
                                case ToolInputCheck.Valid => ()
                                case found => return found
                            }
                        case None => ()
                    }
                }
            }
        case None => ()
    }
    match (schema.field("additionalProperties")) {
        case Some(policy) =>
            if (policy.wireKind == WireJsonKind.Boolean && !policy.bool && value.wireKind == WireJsonKind.Object) {
                var declared = ArrayList<String>()
                match (schema.field("properties")) { case Some(properties) => if (properties.wireKind == WireJsonKind.Object) { declared = toolSchemaObjectNames(properties) }; case None => () }
                for (name in toolSchemaObjectNames(value)) {
                    var known = false
                    for (candidate in declared where candidate == name) { known = true }
                    if (!known) {
                        return ToolInputCheck.Violation(ToolInputViolation(ToolInputViolationKind.AdditionalProperty, schemaPath + "/additionalProperties", instancePath + "/" + name, actual: toolInputTextRepr(name)))
                    }
                }
            }
        case None => ()
    }
    match (schema.field("items")) {
        case Some(itemSchema) =>
            if (itemSchema.wireKind == WireJsonKind.Object && value.wireKind == WireJsonKind.List) {
                for (index in 0..value.items.size) {
                    match (checkToolInputValue(itemSchema, value.items[index], schemaPath + "/items", instancePath + "/" + index.toString(), strict)) {
                        case ToolInputCheck.Valid => ()
                        case found => return found
                    }
                }
            }
        case None => ()
    }
    ToolInputCheck.Valid
}

internal func toolInputViolationError(call: LlmWireToolCallBlock, violation: ToolInputViolation): LlmWireError {
    let diagnostic = wireJsonObject([
        WireJsonField("tool_name", wireJsonString(call.name)),
        WireJsonField("schema_path", wireJsonString(violation.schemaPath)),
        WireJsonField("instance_path", wireJsonString(violation.instancePath)),
        WireJsonField("violation", wireJsonString(toolInputViolationName(violation.kind)))
    ])
    if (violation.expected != "") { diagnostic.put("expected", wireJsonString(violation.expected)) }
    if (violation.actual != "") { diagnostic.put("actual", wireJsonString(violation.actual)) }
    LlmWireError(
        LlmWireErrorKind.InvalidWire, "llm.tool_arguments_schema_violation",
        "tool arguments do not satisfy the declared input schema at " + violation.instancePath,
        phase: Some(LlmTransportPhase.SemanticAssembly), toolCallId: call.callId, diagnosticJson: Some(diagnostic.stringify())
    )
}

internal func toolInputUnsupportedError(call: LlmWireToolCallBlock, feature: String): LlmWireError {
    let diagnostic = wireJsonObject([
        WireJsonField("tool_name", wireJsonString(call.name)),
        WireJsonField("feature", wireJsonString(feature))
    ])
    LlmWireError(
        LlmWireErrorKind.Unsupported, "llm.tool_schema_unsupported",
        "tool input schema uses features outside the supported validation subset: " + feature,
        phase: Some(LlmTransportPhase.SemanticAssembly), toolCallId: call.callId, diagnosticJson: Some(diagnostic.stringify())
    )
}

// Validates tool call arguments in a wire-valid reply against the input schemas
// of the tools declared on the originating request. Calls for undeclared tools
// and calls whose arguments are not complete JSON objects are skipped; the
// latter are already rejected by wire assembly. Reports the first violation in
// deterministic order: block order, then fixed keyword priority, then sorted
// property names. Undeclared schema keywords and unsupported forms surface as
// `llm.tool_schema_unsupported` under Strict and are skipped under
// ValidateSupportedSubset; Disabled performs no checks at all.
public func validateReplyToolInputs(
    reply: LlmWireReply, tools: Array<LlmWireTool>,
    mode!: LlmWireToolInputValidationMode = LlmWireToolInputValidationMode.ValidateSupportedSubset
): LlmWireResult<Unit> {
    match (mode) {
        case LlmWireToolInputValidationMode.Disabled => return LlmWireResult.Ok(())
        case _ => ()
    }
    let strict = mode == LlmWireToolInputValidationMode.Strict
    for (block in reply.blocks) {
        match (block) {
            case LlmWireOutputBlock.ToolCall(call) =>
                match (call.arguments) {
                    case LlmWireToolArguments.Complete(value) =>
                        var declared: ?JsonNode = None
                        for (tool in tools where tool.name == call.name) { declared = Some(tool.inputSchema.jsonNode()) }
                        match (declared) {
                            case Some(schema) =>
                                match (checkToolInputValue(schema, value.jsonNode(), "", "", strict)) {
                                    case ToolInputCheck.Valid => ()
                                    case ToolInputCheck.Violation(violation) => return LlmWireResult.Err(toolInputViolationError(call, violation))
                                    case ToolInputCheck.Unsupported(feature) => return LlmWireResult.Err(toolInputUnsupportedError(call, feature))
                                }
                            case None => ()
                        }
                    case _ => ()
                }
            case _ => ()
        }
    }
    LlmWireResult.Ok(())
}
