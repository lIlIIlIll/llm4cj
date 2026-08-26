package llm4cj

import std.collection.*
import yjson.*

let LLM_JSON_MAX_BYTES: Int64 = 8388608
let LLM_JSON_MAX_DEPTH: Int64 = 256
let LLM_JSON_MAX_STRING_BYTES: Int64 = 8388608

enum WireJsonKind <: Equatable<WireJsonKind> {
    Null | Boolean | Number | Text | List | Object

    public operator func ==(other: WireJsonKind): Bool {
        match ((this, other)) {
            case (Null, Null) | (Boolean, Boolean) | (Number, Number) |
                 (Text, Text) | (List, List) | (Object, Object) => true
            case _ => false
        }
    }
}

class WireJsonField {
    let name: String
    let value: JsonNode

    init(name: String, value: JsonNode) {
        this.name = name
        this.value = value
    }
}

func parseWireJson(source: String): JsonNode {
    try {
        YJson.parse(
            source,
            config: JsonReadConfig(
                duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
                numberPolicy: JsonNumberPolicy.PreserveLiteral,
                maxDepth: LLM_JSON_MAX_DEPTH,
                maxStringBytes: LLM_JSON_MAX_STRING_BYTES,
                maxBytes: LLM_JSON_MAX_BYTES
            )
        )
    } catch (error: JsonException) {
        throw LlmTransportError(
            LlmTransportErrorKind.InvalidWire,
            "llm.json_invalid",
            error.message
        )
    }
}

func wireJsonBool(value: Bool): JsonNode { YJson.value(value) }
func wireJsonNumber(value: String): JsonNode { JsonNumberLiteralValue(value) }
func wireJsonString(value: String): JsonNode { YJson.value(value) }
func wireJsonArray(items: Array<JsonNode>): JsonNode { JsonArrayValue(items) }

func wireJsonObject(fields: Array<WireJsonField>): JsonNode {
    let value = JsonObjectValue()
    for (field in fields) {
        if (value.contains(field.name)) {
            throw LlmTransportError(
                LlmTransportErrorKind.InvalidWire,
                "llm.json_duplicate_key",
                "duplicate JSON object key: " + field.name
            )
        }
        value[field.name] = field.value
    }
    value
}

extend JsonNode {
    prop wireKind: WireJsonKind {
        get() {
            match (kind()) {
                case JsonKind.JsNull => WireJsonKind.Null
                case JsonKind.JsBool => WireJsonKind.Boolean
                case JsonKind.JsInt | JsonKind.JsFloat | JsonKind.JsNumberLiteral => WireJsonKind.Number
                case JsonKind.JsString => WireJsonKind.Text
                case JsonKind.JsArray => WireJsonKind.List
                case JsonKind.JsObject => WireJsonKind.Object
            }
        }
    }

    prop text: String { get() { string } }
    prop number: String { get() { numberText } }
    prop items: Array<JsonNode> { get() { asArray().values().toArray() } }

    prop fields: Array<WireJsonField> {
        get() {
            let result = ArrayList<WireJsonField>()
            for ((name, value) in asObject().entries()) {
                result.add(WireJsonField(name, value))
            }
            result.toArray()
        }
    }

    func field(name: String): ?JsonNode { asObject().get(name) }

    func put(name: String, value: JsonNode): Unit {
        this[name] = value
    }

    func add(value: JsonNode): JsonNode {
        asArray().values().add(value)
        this
    }

    func stringify(): String { YJson.stringify(this) }
}
