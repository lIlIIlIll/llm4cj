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

    private init(canonical: String) {
        this.canonical = canonical
    }

    static func fromJsonNode(value: JsonNode): LlmWireJson {
        LlmWireJson(value.stringify())
    }

    public static func parse(source: String): LlmWireResult<LlmWireJson> {
        try {
            LlmWireResult.Ok(LlmWireJson(parseWireJson(source).stringify()))
        } catch (error: LlmWireError) {
            LlmWireResult.Err(error)
        }
    }

    public static func nullValue(): LlmWireJson {
        LlmWireJson("null")
    }

    public static func boolean(value: Bool): LlmWireJson {
        LlmWireJson(wireJsonBool(value).stringify())
    }

    public static func string(value: String): LlmWireJson {
        LlmWireJson(wireJsonString(value).stringify())
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
            LlmWireResult.Ok(LlmWireJson(value.stringify()))
        } catch (error: LlmWireError) {
            LlmWireResult.Err(LlmWireError(
                LlmWireErrorKind.InvalidRequest,
                "llm.json_number_invalid",
                error.message
            ))
        }
    }

    public static func array(values: Array<LlmWireJson>): LlmWireJson {
        let nodes = ArrayList<JsonNode>()
        for (value in values) {
            nodes.add(value.jsonNode())
        }
        LlmWireJson(wireJsonArray(nodes.toArray()).stringify())
    }

    public static func object(fields: Array<LlmWireJsonField>): LlmWireResult<LlmWireJson> {
        try {
            let nodes = ArrayList<WireJsonField>()
            for (field in fields) {
                nodes.add(WireJsonField(field.name, field.value.jsonNode()))
            }
            LlmWireResult.Ok(LlmWireJson(wireJsonObject(nodes.toArray()).stringify()))
        } catch (error: LlmWireError) {
            LlmWireResult.Err(LlmWireError(
                LlmWireErrorKind.InvalidRequest,
                error.code,
                error.message
            ))
        }
    }

    public prop kind: LlmWireJsonKind {
        get() {
            match (jsonNode().wireKind) {
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
        let value = jsonNode()
        if (value.wireKind == WireJsonKind.Boolean) { Some(value.bool) } else { None }
    }

    public func stringValue(): ?String {
        let value = jsonNode()
        if (value.wireKind == WireJsonKind.Text) { Some(value.text) } else { None }
    }

    public func numberLiteral(): ?String {
        let value = jsonNode()
        if (value.wireKind == WireJsonKind.Number) { Some(value.number) } else { None }
    }

    public func values(): Array<LlmWireJson> {
        let value = jsonNode()
        if (value.wireKind != WireJsonKind.List) { return [] }
        let output = ArrayList<LlmWireJson>()
        for (item in value.items) {
            output.add(LlmWireJson.fromJsonNode(item))
        }
        output.toArray()
    }

    public func fields(): Array<LlmWireJsonField> {
        let value = jsonNode()
        if (value.wireKind != WireJsonKind.Object) { return [] }
        let output = ArrayList<LlmWireJsonField>()
        for (field in value.fields) {
            output.add(LlmWireJsonField(field.name, LlmWireJson.fromJsonNode(field.value)))
        }
        output.toArray()
    }

    public func field(name: String): ?LlmWireJson {
        let value = jsonNode()
        if (value.wireKind != WireJsonKind.Object) { return None }
        match (value.field(name)) {
            case Some(item) => Some(LlmWireJson.fromJsonNode(item))
            case None => None
        }
    }

    public func stringify(): String { canonical }

    func jsonNode(): JsonNode { parseWireJson(canonical) }
}
