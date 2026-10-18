package llm4cj

import std.collection.*
import yjson.*

// Limits may only tighten the library's hard resource bounds. Work units charge
// input bytes, node/keyword visits and comparison bytes, including each branch.
public class LlmWireSchemaValidationLimits {
    public let maxDepth: Int64
    public let maxWork: Int64
    public init(maxDepth!: Int64 = 256, maxWork!: Int64 = 67108864) {
        if (maxDepth < 1 || maxDepth > 256 || maxWork < 1 || maxWork > 67108864) {
            throw LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.schema_validation_limits_invalid", "schema limits must be positive and cannot exceed depth 256 or work 67108864")
        }
        this.maxDepth = maxDepth; this.maxWork = maxWork
    }
}

internal class SchemaBudget {
    private var remaining: Int64
    private let maxDepth: Int64
    internal init(limits: LlmWireSchemaValidationLimits) { remaining = limits.maxWork; maxDepth = limits.maxDepth }
    internal func charge(work: Int64): Unit {
        if (work < 0 || work > remaining) { fail() }
        remaining -= work
    }
    private func fail(): Nothing {
        throw LlmWireError(LlmWireErrorKind.LimitExceeded, "llm.schema_validation_limit", "schema validation exceeds the depth or work limit", phase: Some(LlmTransportPhase.SemanticAssembly))
    }
    internal func read(value: LlmWireJson): JsonNode {
        charge(value.stringify().size)
        try {
            let node = JsonNode.parse(value.stringify(), config: JsonReadOptions(
                duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject, maxDepth: maxDepth,
                maxStringBytes: LLM_JSON_MAX_STRING_BYTES, maxInputBytes: LLM_JSON_MAX_BYTES,
                maxBufferedValueBytes: LLM_JSON_MAX_BYTES))
            inspect(node)
            node
        } catch (error: JsonException) {
            // The immutable canonical source already passed every other parser
            // constraint. The only tightened constraint is this depth budget.
            if (error.code == "max_depth") { fail() }
            throw LlmWireError(LlmWireErrorKind.InvalidWire, "llm.json_invalid", "validated schema JSON could not be read")
        }
    }
    private func inspect(value: JsonNode): Unit {
        charge(1)
        match (value.wireKind) {
            case WireJsonKind.Object =>
                let object = value.asObject()
                for (index in 0..object.size()) { inspect(object.valueAt(index)) }
            case WireJsonKind.List =>
                let array = value.asArray()
                for (index in 0..array.size()) { inspect(array.get(index).getOrThrow()) }
            case _ => ()
        }
    }
}

internal func schemaNodeForm(value: JsonNode): Bool {
    value.wireKind == WireJsonKind.Object || value.wireKind == WireJsonKind.Boolean
}

internal func schemaCountKeyword(name: String): Bool {
    name == "minLength" || name == "maxLength" || name == "minItems" || name == "maxItems" || name == "minProperties" || name == "maxProperties"
}

internal func schemaNumberKeyword(name: String): Bool {
    name == "minimum" || name == "maximum" || name == "exclusiveMinimum" || name == "exclusiveMaximum"
}

internal func schemaCombinator(name: String): Bool { name == "allOf" || name == "anyOf" || name == "oneOf" }

internal class SchemaPlan {
    internal let schema: JsonNode
    internal var unsupported: Bool = false
    internal let properties = HashMap<String, SchemaPlan>()
    internal let direct = HashMap<String, SchemaPlan>()
    internal let groups = HashMap<String, Array<SchemaPlan>>()
    internal init(schema: JsonNode) { this.schema = schema }
}

internal class SchemaEvaluator {
    private let budget: SchemaBudget
    private var firstUnsupported: ?String = None
    internal var unsupportedPath: String = ""
    internal init(budget: SchemaBudget) { this.budget = budget }

    private func unsupported(feature: String, path: String): Unit {
        if (firstUnsupported.isNone()) { firstUnsupported = Some(feature); unsupportedPath = path }
    }

    private func form(name: String, value: JsonNode): Bool {
        budget.charge(1)
        if (name == "type") { budget.charge(8 * toolInputValueSize(value, budget)); return toolInputTypeFormValid(value) }
        if (name == "required") {
            if (value.wireKind != WireJsonKind.List) { return false }
            let array = value.asArray()
            for (index in 0..array.size()) { budget.charge(1); if (array.get(index).getOrThrow().wireKind != WireJsonKind.Text) { return false } }
            return true
        }
        if (name == "properties") { return value.wireKind == WireJsonKind.Object }
        if (name == "items" || name == "additionalProperties") { return schemaNodeForm(value) }
        if (name == "enum") { return value.wireKind == WireJsonKind.List }
        if (schemaNumberKeyword(name)) { return value.wireKind == WireJsonKind.Number }
        if (schemaCountKeyword(name)) {
            if (value.wireKind != WireJsonKind.Number) { return false }
            budget.charge(8 * value.numberText.size)
            return wireJsonNumberIsInteger(value.numberText) && wireJsonNumberCompare(value.numberText, "0", budget) >= 0
        }
        if (schemaCombinator(name)) {
            if (value.wireKind != WireJsonKind.List || value.asArray().size() == 0) { return false }
            let array = value.asArray()
            for (index in 0..array.size()) { budget.charge(1); if (!schemaNodeForm(array.get(index).getOrThrow())) { return false } }
        }
        true
    }

    // Traverse every schema-valued location, even when an instance omits it.
    // Ordinary annotation payloads and enum/const values are data, not schemas.
    private func preflight(schema: JsonNode, path: String): SchemaPlan {
        budget.charge(1)
        let plan = SchemaPlan(schema)
        if (schema.wireKind == WireJsonKind.Boolean) { return plan }
        if (schema.wireKind != WireJsonKind.Object) { unsupported("schema_not_object", path); plan.unsupported = true; return plan }
        // Preserve the existing unknown-keyword precedence and form priority.
        for (name in toolSchemaObjectNames(schema, budget: Some(budget))) {
            budget.charge(name.size + 1)
            if (!isToolSchemaSupportedKeyword(name) && !isToolSchemaAnnotationKeyword(name)) { unsupported(name, toolInputPath(path, name)); plan.unsupported = true }
        }
        for (name in ["type", "required", "properties", "additionalProperties", "items", "enum", "const", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties", "allOf", "anyOf", "oneOf"]) {
            match (schema.field(name)) {
                case Some(value) => if (!form(name, value)) { unsupported(name, toolInputPath(path, name)); plan.unsupported = true }
                case None => ()
            }
        }
        for (name in toolSchemaObjectNames(schema, budget: Some(budget))) {
            budget.charge(name.size + 1)
            let childPath = toolInputPath(path, name)
            let value = schema.field(name).getOrThrow()
            if (name == "$defs" || name == "definitions") {
                if (value.wireKind != WireJsonKind.Object) { unsupported(name, childPath); plan.unsupported = true; continue }
                for (key in toolSchemaObjectNames(value, budget: Some(budget))) {
                    budget.charge(key.size + 1)
                    let child = preflight(value.field(key).getOrThrow(), toolInputPath(childPath, key))
                    if (child.unsupported) { plan.unsupported = true }
                }
                continue
            }
            if (isToolSchemaAnnotationKeyword(name)) { continue }
            if (!isToolSchemaSupportedKeyword(name) || !form(name, value)) { unsupported(name, childPath); plan.unsupported = true; continue }
            if (name == "properties") {
                for (key in toolSchemaObjectNames(value, budget: Some(budget))) {
                    budget.charge(key.size + 1)
                    let child = preflight(value.field(key).getOrThrow(), toolInputPath(childPath, key))
                    plan.properties[key] = child
                    if (child.unsupported) { plan.unsupported = true }
                }
            } else if (name == "items" || name == "additionalProperties") {
                let child = preflight(value, childPath)
                plan.direct[name] = child
                if (child.unsupported) { plan.unsupported = true }
            } else if (schemaCombinator(name)) {
                let array = value.asArray()
                let branches = ArrayList<SchemaPlan>()
                for (index in 0..array.size()) {
                    let child = preflight(array.get(index).getOrThrow(), toolInputPath(childPath, index.toString()))
                    branches.add(child)
                    if (child.unsupported) { plan.unsupported = true }
                }
                plan.groups[name] = branches.toArray()
            }
        }
        plan
    }

    internal func check(schema: JsonNode, value: JsonNode, strict: Bool): ToolInputCheck {
        let plan = preflight(schema, "")
        if (strict) { match (firstUnsupported) { case Some(feature) => return ToolInputCheck.Unsupported(feature); case None => () } }
        let result = evaluate(plan, value, "", "")
        match (result) { case ToolInputCheck.Violation(_) => return result; case _ => () }
        match (firstUnsupported) { case Some(feature) => ToolInputCheck.Unsupported(feature); case None => result }
    }

    private func violation(name: String, path: String, at: String, expected!: String = "", actual!: String = ""): ToolInputCheck {
        ToolInputCheck.Violation(ToolInputViolation(ToolInputViolationKind.Constraint(name), path, at, expected: expected, actual: actual))
    }

    private func evidence(value: JsonNode): String {
        // A full byte-count marker remains compatible with existing diagnostics.
        // Charge the bounded writer's traversal before creating that evidence.
        budget.charge(toolInputValueSize(value, budget))
        toolInputValueRepr(value)
    }

    private func combine(name: String, branches: Array<SchemaPlan>, value: JsonNode, path: String, at: String): ToolInputCheck {
        var matches: Int64 = 0
        var unknown = false
        for (index in 0..branches.size) {
            budget.charge(1)
            let result = evaluate(branches[index], value, toolInputPath(path, index.toString()), at)
            match (result) {
                case ToolInputCheck.Valid => matches++
                case ToolInputCheck.Violation(_) => if (name == "allOf") { return result }
                case ToolInputCheck.Unsupported(_) => unknown = true
            }
            if (name == "anyOf" && matches > 0) { return ToolInputCheck.Valid }
            if (name == "oneOf" && matches > 1) { return violation("oneOf", path, at, expected: "exactly one matching branch", actual: "at least 2 matches") }
        }
        if (unknown) { return ToolInputCheck.Unsupported(name) }
        if (name == "allOf" || (name == "oneOf" && matches == 1)) { return ToolInputCheck.Valid }
        violation(name, path, at, expected: if (name == "oneOf") { "exactly one matching branch" } else { "at least one matching branch" }, actual: "0 matches")
    }

    private func evaluate(plan: SchemaPlan, value: JsonNode, path: String, at: String): ToolInputCheck {
        budget.charge(1)
        let schema = plan.schema
        if (schema.wireKind == WireJsonKind.Boolean) {
            return if (schema.bool) { ToolInputCheck.Valid } else { violation("false_schema", path, at) }
        }
        if (schema.wireKind != WireJsonKind.Object) { return ToolInputCheck.Unsupported("schema_not_object") }
        var unknown = plan.unsupported
        for (name in toolSchemaObjectNames(schema, budget: Some(budget))) {
            budget.charge(name.size + 1)
            if (!isToolSchemaAnnotationKeyword(name) && (!isToolSchemaSupportedKeyword(name) || !form(name, schema.field(name).getOrThrow()))) { unknown = true }
        }
        match (schema.field("type")) {
            case Some(typeValue) =>
                if (form("type", typeValue)) {
                    var accepted = false
                    var expected = ""
                    if (typeValue.wireKind == WireJsonKind.Text) { expected = typeValue.text; accepted = accepts(typeValue.text, value) }
                    else {
                        let array = typeValue.asArray()
                        for (index in 0..array.size()) {
                            budget.charge(1)
                            let entry = array.get(index).getOrThrow().text
                            if (expected == "") { expected = entry }
                            else if (expected.size + entry.size + 1 <= 64) { expected += "|" + entry }
                            else { expected = "<multiple allowed types>" }
                            if (accepts(entry, value)) { accepted = true }
                        }
                    }
                    if (!accepted) { return violation("type_mismatch", toolInputPath(path, "type"), at, expected: expected, actual: toolInputJsonKindName(value)) }
                }
            case None => ()
        }
        match (schema.field("const")) {
            case Some(expected) => if (!wireJsonEquivalent(expected, value, budget: Some(budget))) { return violation("const", toolInputPath(path, "const"), at, expected: evidence(expected), actual: evidence(value)) }
            case None => ()
        }
        match (schema.field("enum")) {
            case Some(values) =>
                if (form("enum", values)) {
                    let array = values.asArray()
                    var found = false
                    for (index in 0..array.size()) { if (wireJsonEquivalent(array.get(index).getOrThrow(), value, budget: Some(budget))) { found = true; break } }
                    if (!found) { return violation("enum_mismatch", toolInputPath(path, "enum"), at, expected: evidence(values), actual: evidence(value)) }
                }
            case None => ()
        }
        for (name in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"]) {
            match (schema.field(name)) {
                case Some(bound) =>
                    if (form(name, bound)) {
                        var actual: ?String = None
                        if (schemaNumberKeyword(name) && value.wireKind == WireJsonKind.Number) { actual = Some(value.numberText) }
                        if ((name == "minLength" || name == "maxLength") && value.wireKind == WireJsonKind.Text) {
                            budget.charge(value.text.size)
                            var count: Int64 = 0
                            for (index in 0..value.text.size) { if ((value.text[index] & 0xC0u8) != 0x80u8) { count++ } }
                            actual = Some(count.toString())
                        }
                        if ((name == "minItems" || name == "maxItems") && value.wireKind == WireJsonKind.List) { actual = Some(value.asArray().size().toString()) }
                        if ((name == "minProperties" || name == "maxProperties") && value.wireKind == WireJsonKind.Object) { actual = Some(value.asObject().size().toString()) }
                        match (actual) {
                            case Some(number) =>
                                let order = wireJsonNumberCompare(number, bound.numberText, budget)
                                let min = name == "minimum" || name == "exclusiveMinimum" || name == "minLength" || name == "minItems" || name == "minProperties"
                                let exclusive = name == "exclusiveMinimum" || name == "exclusiveMaximum"
                                if ((min && order < 0) || (!min && order > 0) || (exclusive && order == 0)) { return violation(name, toolInputPath(path, name), at, expected: toolInputTextRepr(bound.numberText), actual: toolInputTextRepr(number)) }
                            case None => ()
                        }
                    }
                case None => ()
            }
        }
        match (schema.field("required")) {
            case Some(required) =>
                if (form("required", required) && value.wireKind == WireJsonKind.Object) {
                    let array = required.asArray()
                    for (index in 0..array.size()) {
                        let name = array.get(index).getOrThrow().text; budget.charge(name.size + 1)
                        if (value.field(name).isNone()) { return violation("missing_required", toolInputPath(path, "required"), toolInputPath(at, name), expected: toolInputTextRepr(name)) }
                    }
                }
            case None => ()
        }
        if (value.wireKind == WireJsonKind.Object) {
            var properties: ?JsonNode = None
            match (schema.field("properties")) { case Some(node) => if (form("properties", node)) { properties = Some(node) }; case None => () }
            match (properties) {
                case Some(declared) =>
                    for (name in toolSchemaObjectNames(declared, budget: Some(budget))) {
                        budget.charge(name.size + 1)
                        match (value.field(name)) {
                            case Some(child) =>
                                match (evaluate(plan.properties[name], child, toolInputPath(toolInputPath(path, "properties"), name), toolInputPath(at, name))) {
                                    case ToolInputCheck.Violation(found) => return ToolInputCheck.Violation(found)
                                    case ToolInputCheck.Unsupported(_) => unknown = true
                                    case _ => ()
                                }
                            case None => ()
                        }
                    }
                case None => ()
            }
            match (schema.field("additionalProperties")) {
                case Some(policy) =>
                    if (schema.field("patternProperties").isNone() && form("additionalProperties", policy)) {
                        for (name in toolSchemaObjectNames(value, budget: Some(budget))) {
                            budget.charge(name.size + 1)
                            var declared = false
                            match (properties) { case Some(object) => declared = object.field(name).isSome(); case None => () }
                            if (declared) { continue }
                            if (policy.wireKind == WireJsonKind.Boolean && !policy.bool) { return violation("additional_property", toolInputPath(path, "additionalProperties"), toolInputPath(at, name), actual: toolInputTextRepr(name)) }
                            match (evaluate(plan.direct["additionalProperties"], value.field(name).getOrThrow(), toolInputPath(path, "additionalProperties"), toolInputPath(at, name))) {
                                case ToolInputCheck.Violation(found) => return ToolInputCheck.Violation(found)
                                case ToolInputCheck.Unsupported(_) => unknown = true
                                case _ => ()
                            }
                        }
                    }
                case None => ()
            }
        }
        match (schema.field("items")) {
            case Some(items) =>
                if (schema.field("prefixItems").isNone() && form("items", items) && value.wireKind == WireJsonKind.List) {
                    let array = value.asArray()
                    for (index in 0..array.size()) {
                        match (evaluate(plan.direct["items"], array.get(index).getOrThrow(), toolInputPath(path, "items"), toolInputPath(at, index.toString()))) {
                            case ToolInputCheck.Violation(found) => return ToolInputCheck.Violation(found)
                            case ToolInputCheck.Unsupported(_) => unknown = true
                            case _ => ()
                        }
                    }
                }
            case None => ()
        }
        for (name in ["allOf", "anyOf", "oneOf"]) {
            match (schema.field(name)) {
                case Some(branches) =>
                    if (form(name, branches)) {
                        match (combine(name, plan.groups[name], value, toolInputPath(path, name), at)) {
                            case ToolInputCheck.Violation(found) => return ToolInputCheck.Violation(found)
                            case ToolInputCheck.Unsupported(_) => unknown = true
                            case _ => ()
                        }
                    }
                case None => ()
            }
        }
        if (unknown) { ToolInputCheck.Unsupported("unknown_constraint") } else { ToolInputCheck.Valid }
    }

    private func accepts(name: String, value: JsonNode): Bool {
        if (name == "integer" && value.wireKind == WireJsonKind.Number) { budget.charge(8 * value.numberText.size) }
        toolInputTypeAccepts(name, value)
    }
}

// Upper bound on serialization work, without allocating another JSON string.
internal func toolInputValueSize(value: JsonNode, budget: SchemaBudget): Int64 {
    budget.charge(1)
    match (value.wireKind) {
        case WireJsonKind.Text => 6 * value.text.size + 2
        case WireJsonKind.Number => value.numberText.size
        case WireJsonKind.List =>
            let array = value.asArray(); var size: Int64 = 2
            for (index in 0..array.size()) { size += toolInputValueSize(array.get(index).getOrThrow(), budget) + 1 }
            size
        case WireJsonKind.Object =>
            let object = value.asObject(); var size: Int64 = 2
            for (index in 0..object.size()) { size += 6 * object.nameAt(index).size + 4 + toolInputValueSize(object.valueAt(index), budget) }
            size
        case _ => 5
    }
}
