package llm4cj

import std.collection.*
import std.deriving.Derive
import yjson.*

@Derive[Equatable]
public enum LlmWireJsonKind {
    Null | Boolean | Number | String | Array | Object
}

public class LlmWireJsonField {
    public let name: String
    public let value: LlmWireJson

    public init(name: String, value: LlmWireJson) {
        this.name = name
        this.value = value
    }
}

// Immutable public JSON value. The provider JSON implementation remains private.
public class LlmWireJson {
    private let canonical: String
    private let cached: JsonNode
    private let depth: Int64

    private init(canonical: String, cached: JsonNode) {
        this.canonical = canonical
        this.cached = cached
        this.depth = wireJsonDepth(cached)
    }

    static func fromJsonNode(value: JsonNode): LlmWireJson {
        let canonical = writeBoundedWireJson(value)
        // Internal decoders own mutable nodes; do not retain their aliases.
        LlmWireJson(canonical, parseWireJson(canonical))
    }

    public static func parse(source: String): LlmWireResult<LlmWireJson> {
        try {
            let value = parseWireJson(source)
            LlmWireResult.Ok(LlmWireJson(writeBoundedWireJson(value), value))
        } catch (error: LlmWireError) {
            LlmWireResult.Err(error)
        }
    }

    public static func nullValue(): LlmWireJson {
        LlmWireJson("null", JsonNode.nullValue)
    }

    public static func boolean(value: Bool): LlmWireJson {
        LlmWireJson(if (value) { "true" } else { "false" }, wireJsonBool(value))
    }

    public static func string(value: String): LlmWireResult<LlmWireJson> {
        if (value.size > LLM_JSON_MAX_BYTES - 2) { return LlmWireResult.Err(jsonFactoryLimit()) }
        jsonFactory(wireJsonString(value))
    }

    public static func number(literal: String): LlmWireResult<LlmWireJson> {
        try {
            let value = parseWireJson(literal)
            if (value.wireKind != WireJsonKind.Number) {
                return LlmWireResult.Err(LlmWireError(
                    LlmWireErrorKind.InvalidRequest,
                    "llm.json_number_invalid",
                    "JSON number factory requires exactly one number literal"
                ))
            }
            LlmWireResult.Ok(LlmWireJson(writeBoundedWireJson(value), value))
        } catch (error: LlmWireError) {
            LlmWireResult.Err(LlmWireError(
                LlmWireErrorKind.InvalidRequest,
                "llm.json_number_invalid",
                error.message
            ))
        }
    }

    public static func array(values: Array<LlmWireJson>): LlmWireResult<LlmWireJson> {
        var size: Int64 = 2
        for (index in 0..values.size) {
            let value = values[index]
            let extra = value.canonical.size + (if (index > 0) { 1 } else { 0 })
            if (value.depth >= LLM_JSON_MAX_DEPTH || extra > LLM_JSON_MAX_BYTES - size) {
                return LlmWireResult.Err(jsonFactoryLimit())
            }
            size += extra
        }
        let nodes = ArrayList<JsonNode>()
        for (value in values) { nodes.add(value.cached) }
        jsonFactory(wireJsonArray(nodes.toArray()))
    }

    public static func object(fields: Array<LlmWireJsonField>): LlmWireResult<LlmWireJson> {
        var size: Int64 = 2
        let names = HashSet<String>()
        for (index in 0..fields.size) {
            let field = fields[index]
            if (!names.add(field.name)) {
                return LlmWireResult.Err(LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.json_duplicate_key", "duplicate JSON object key"))
            }
            if (field.value.depth >= LLM_JSON_MAX_DEPTH || field.name.size > LLM_JSON_MAX_BYTES - size) {
                return LlmWireResult.Err(jsonFactoryLimit())
            }
            size += field.name.size
            let extra = 3 + field.value.canonical.size + (if (index > 0) { 1 } else { 0 })
            if (extra > LLM_JSON_MAX_BYTES - size) { return LlmWireResult.Err(jsonFactoryLimit()) }
            size += extra
        }
        let nodes = ArrayList<WireJsonField>()
        for (field in fields) { nodes.add(WireJsonField(field.name, field.value.cached)) }
        jsonFactory(wireJsonObject(nodes.toArray()))
    }

    public prop kind: LlmWireJsonKind {
        get() {
            match (cached.wireKind) {
                case WireJsonKind.Null => LlmWireJsonKind.Null
                case WireJsonKind.Boolean => LlmWireJsonKind.Boolean
                case WireJsonKind.Number => LlmWireJsonKind.Number
                case WireJsonKind.Text => LlmWireJsonKind.String
                case WireJsonKind.List => LlmWireJsonKind.Array
                case WireJsonKind.Object => LlmWireJsonKind.Object
            }
        }
    }

    public func booleanValue(): ?Bool {
        let value = cached
        if (value.wireKind == WireJsonKind.Boolean) { Some(value.bool) } else { None }
    }

    public func stringValue(): ?String {
        let value = cached
        if (value.wireKind == WireJsonKind.Text) { Some(value.text) } else { None }
    }

    public func numberLiteral(): ?String {
        let value = cached
        if (value.wireKind == WireJsonKind.Number) { Some(value.numberText) } else { None }
    }

    public func values(): Array<LlmWireJson> {
        let value = cached
        if (value.wireKind != WireJsonKind.List) { return [] }
        let output = ArrayList<LlmWireJson>()
        for (item in value.items) {
            output.add(LlmWireJson.fromJsonNode(item))
        }
        output.toArray()
    }

    public func fields(): Array<LlmWireJsonField> {
        let value = cached
        if (value.wireKind != WireJsonKind.Object) { return [] }
        let output = ArrayList<LlmWireJsonField>()
        for (field in value.fields) {
            output.add(LlmWireJsonField(field.name, LlmWireJson.fromJsonNode(field.value)))
        }
        output.toArray()
    }

    public func field(name: String): ?LlmWireJson {
        let value = cached
        if (value.wireKind != WireJsonKind.Object) { return None }
        match (value.field(name)) {
            case Some(item) => Some(LlmWireJson.fromJsonNode(item))
            case None => None
        }
    }

    public func stringify(): String { canonical }

    func jsonNode(): JsonNode { parseWireJson(canonical) }
}

private func jsonFactoryLimit(): LlmWireError {
    LlmWireError(LlmWireErrorKind.InvalidRequest, "llm.json_invalid", "JSON construction exceeds the byte or depth limit")
}

private func jsonFactoryError(error: LlmWireError): LlmWireError {
    LlmWireError(LlmWireErrorKind.InvalidRequest, error.code, error.message)
}

private func jsonFactory(value: JsonNode): LlmWireResult<LlmWireJson> {
    try { LlmWireResult.Ok(LlmWireJson.fromJsonNode(value)) }
    catch (error: LlmWireError) { LlmWireResult.Err(jsonFactoryError(error)) }
}
