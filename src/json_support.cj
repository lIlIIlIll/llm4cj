package llm4cj

import std.collection.*
import std.deriving.Derive
import std.io.*
import yjson.*

const LLM_JSON_MAX_BYTES: Int64 = 8388608
const LLM_JSON_MAX_DEPTH: Int64 = 256
const LLM_JSON_MAX_STRING_BYTES: Int64 = 8388608

// The streaming writer checks its budget before growing its internal buffer;
// this sink independently bounds retained bytes before appending a chunk.
class WireJsonOutput <: OutputStream {
    private let retained = ArrayList<Byte>()
    private let retainLimit: Int64
    var size: Int64 = 0

    init(retainLimit!: Int64 = LLM_JSON_MAX_BYTES) { this.retainLimit = retainLimit }

    public func write(bytes: Array<Byte>): Unit {
        if (bytes.size > LLM_JSON_MAX_BYTES - size) {
            throw LlmWireError(LlmWireErrorKind.InvalidWire, "llm.json_invalid", "JSON output exceeds the byte limit")
        }
        size += bytes.size
        if (size <= retainLimit) { retained.add(all: bytes) }
    }

    public func flush(): Unit {}
    func text(): String { String.fromUtf8(retained.toArray()) }
}

func writeBoundedWireJson(value: JsonNode): String {
    try {
        let output = WireJsonOutput()
        value.writeJson(output, options: JsonWriteOptions(maxOutputBytes: LLM_JSON_MAX_BYTES, maxDepth: LLM_JSON_MAX_DEPTH))
        output.text()
    } catch (_: JsonException) {
        throw LlmWireError(LlmWireErrorKind.InvalidWire, "llm.json_invalid", "JSON serialization exceeds the byte or depth limit")
    }
}

func wireJsonDepth(value: JsonNode): Int64 {
    var depth: Int64 = 0
    if (value.wireKind == WireJsonKind.List) {
        let array = value.asArray()
        for (index in 0..array.size()) { depth = max(depth, wireJsonDepth(array.get(index).getOrThrow())) }
        return depth + 1
    }
    if (value.wireKind == WireJsonKind.Object) {
        let object = value.asObject()
        for (index in 0..object.size()) { depth = max(depth, wireJsonDepth(object.valueAt(index))) }
        return depth + 1
    }
    depth
}

@Derive[Equatable]
enum WireJsonKind {
    Null | Boolean | Number | Text | List | Object
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
        JsonNode.parse(
            source,
            config: JsonReadOptions(
                unknownFieldPolicy: JsonUnknownFieldPolicy.Ignore,
                duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
                maxDepth: LLM_JSON_MAX_DEPTH,
                maxStringBytes: LLM_JSON_MAX_STRING_BYTES,
                maxInputBytes: LLM_JSON_MAX_BYTES,
                maxBufferedValueBytes: LLM_JSON_MAX_BYTES
            )
        )
    } catch (error: JsonException) {
        throw LlmWireError(
            LlmWireErrorKind.InvalidWire,
            "llm.json_invalid",
            error.message
        )
    }
}

func wireJsonBool(value: Bool): JsonNode { JsonNode.boolean(value) }
func wireJsonNumber(value: String): JsonNode { JsonNode.number(value) }
func wireJsonString(value: String): JsonNode { JsonNode.string(value) }
func wireJsonArray(items: Array<JsonNode>): JsonNode { JsonNode.array(items) }

func wireJsonObject(fields: Array<WireJsonField>): JsonNode {
    let value = JsonObject()
    for (field in fields) {
        if (value.contains(field.name)) {
            throw LlmWireError(
                LlmWireErrorKind.InvalidWire,
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
                case JsonKind.Null => WireJsonKind.Null
                case JsonKind.Boolean => WireJsonKind.Boolean
                case JsonKind.Number => WireJsonKind.Number
                case JsonKind.String => WireJsonKind.Text
                case JsonKind.Array => WireJsonKind.List
                case JsonKind.Object => WireJsonKind.Object
            }
        }
    }

    prop text: String { get() { asString() } }
    prop numberText: String { get() { asNumberText() } }
    prop bool: Bool { get() { asBool() } }
    prop items: Array<JsonNode> { get() {
        let array = asArray()
        let result = ArrayList<JsonNode>()
        for (index in 0..array.size()) {
            let node = array.get(index).getOrThrow()
            result.add(node)
        }
        result.toArray()
    } }

    prop fields: Array<WireJsonField> {
        get() {
            let object = asObject()
            let result = ArrayList<WireJsonField>()
            for (index in 0..object.size()) {
                result.add(WireJsonField(object.nameAt(index), object.valueAt(index)))
            }
            result.toArray()
        }
    }

    func field(name: String): ?JsonNode { asObject().get(name) }

    func put(name: String, value: JsonNode): Unit {
        this[name] = value
    }

    func add(value: JsonNode): JsonNode {
        let array = asArray()
        array.insert(array.size(), value)
        this
    }

    func stringify(): String { toJson() }
}
