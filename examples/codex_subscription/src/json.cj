package codex_subscription

import llm4cj.*
import std.collection.*
import std.convert.*
import std.time.*

open class ExampleError <: Exception { init(message: String) { super(message) } }
func require(condition: Bool, message: String): Unit { if (!condition) { throw ExampleError(message) } }
func json(text: String): LlmWireJson {
    match (LlmWireJson.parse(text)) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(_) => throw ExampleError("Invalid or oversized JSON") }
}
func jsonString(value: String): LlmWireJson {
    match (LlmWireJson.string(value)) { case LlmWireResult.Ok(item) => item; case LlmWireResult.Err(error) => throw ExampleError(error.code) }
}
func jsonArray(values: Array<LlmWireJson>): LlmWireJson {
    match (LlmWireJson.array(values)) { case LlmWireResult.Ok(item) => item; case LlmWireResult.Err(error) => throw ExampleError(error.code) }
}
func object(fields: Array<(String, LlmWireJson)>): LlmWireJson {
    let result = ArrayList<LlmWireJsonField>(); for ((name, value) in fields) { result.add(LlmWireJsonField(name, value)) }
    match (LlmWireJson.object(result.toArray())) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(_) => throw ExampleError("Invalid JSON object") }
}
func field(value: LlmWireJson, name: String): LlmWireJson { value.field(name).getOrThrow({ => ExampleError("Missing field: " + name) }) }
func text(value: LlmWireJson, name: String): String { field(value, name).stringValue().getOrThrow({ => ExampleError("Invalid string field: " + name) }) }
func optionalText(value: LlmWireJson, name: String): String {
    match (value.field(name)) { case None => ""; case Some(item) => if (item.kind == LlmWireJsonKind.Null) { "" } else { item.stringValue().getOrThrow({ => ExampleError("Invalid string field: " + name) }) } }
}
func integer(value: LlmWireJson, name: String): Int64 { Int64.parse(field(value, name).numberLiteral().getOrThrow({ => ExampleError("Invalid integer field: " + name) })) }
func number(value: Int64): LlmWireJson { match (LlmWireJson.number(value.toString())) { case LlmWireResult.Ok(item) => item; case LlmWireResult.Err(_) => throw ExampleError("Invalid number") } }
func nowSeconds(): Int64 { DateTime.nowUTC().toUnixTimeStamp().toSeconds() }
func hasScope(scopes: String, scope: String): Bool { for (item in scopes.split(" ") where item == scope) { return true }; false }
