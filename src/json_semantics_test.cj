package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

func jsonFactoryValue(result: LlmWireResult<LlmWireJson>): LlmWireJson {
    match (result) { case LlmWireResult.Ok(value) => value; case LlmWireResult.Err(error) => throw error }
}

private func exactSchemaResult(schema: String, arguments: String, mode: LlmWireToolInputValidationMode): LlmWireResult<Unit> {
    let tool = LlmWireTool("lookup", "", jsonFactoryValue(LlmWireJson.parse(schema)))
    let call = LlmWireToolCallBlock("call", "lookup", LlmWireToolArguments.Complete(jsonFactoryValue(LlmWireJson.parse(arguments))))
    let reply = LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(call)])
    let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [LlmWireToolDeclaration(tool)]))
    validateReplyToolInputs(reply, transcript, mode: mode)
}

@Test
class JsonValueSemanticsRegressionTest {
    @TestCase
    func integerTypeUsesExactDecimalValueInEveryMode() {
        let schema = "{\"type\":\"object\",\"properties\":{\"v\":{\"type\":\"integer\"}}}"
        for (mode in [LlmWireToolInputValidationMode.ValidateSupportedSubset, LlmWireToolInputValidationMode.Strict]) {
            for (number in ["1", "1.0", "1e0", "10e-1", "-0.0e-999999999999999999999999999999", "9007199254740993", "1e999999999999999999999999999999", "1000.00e-2", "100000000000000000000e-9", "1.00000000001e+11", "-0.0000001E+7"]) {
                @Expect(exactSchemaResult(schema, "{\"v\":" + number + "}", mode).isOk(), true)
            }
            for (number in ["1.1", "1e-1", "10e-2", "1e-999999999999999999999999999999", "9007199254740993.1", "0.00000000001e+9", "1.00000000001e-9"]) {
                @Expect(exactSchemaResult(schema, "{\"v\":" + number + "}", mode).isOk(), false)
            }
        }
        @Expect(exactSchemaResult(schema, "{\"v\":1.1}", LlmWireToolInputValidationMode.Disabled).isOk(), true)
    }

    @TestCase
    func enumUsesJsonValueEqualityAndPreservesArrayOrder() {
        let cases = [
            ("1", "1.0", true), ("100", "1e2", true), ("1e999999999999999999999999999999", "10e999999999999999999999999999998", true),
            ("10e999999999999999999999999999999", "1e1000000000000000000000000000000", true),
            ("1e-999999999999999999999999999999", "10e-1000000000000000000000000000000", true),
            ("0", "-0e999999999999999999999999999999", true), ("true", "1", false), ("true", "true", true), ("true", "false", false),
            ("-1", "-1.00", true), ("-1", "1", false), ("1e+0000", "1.000", true),
            ("100000000000000000000", "1e20", true), ("100000000000000000000e-9", "1e11", true),
            ("0.00001e+10", "1e5", true), ("0.00000000001e+9", "1e-2", true),
            ("1.00000000001e-9", "100000000001e-20", true), ("-0.0000001E+7", "-1", true),
            ("1.00000000000000000001", "1.00000000000000000002", false),
            ("9007199254740992", "9007199254740993", false), ("1e999999999999999999999999999999", "1e999999999999999999999999999998", false),
            ("{\"a\":1,\"b\":[2,3]}", "{\"b\":[2.0,3e0],\"a\":1.00}", true),
            ("[1,2]", "[2,1]", false), ("[1]", "[1,2]", false), ("{\"a\":1}", "{\"b\":1}", false),
            ("{\"a\":1}", "{\"a\":2}", false), ("{\"a\":1}", "{\"a\":1,\"b\":2}", false), ("\"x\"", "\"x\"", true), ("\"x\"", "\"y\"", false), ("null", "null", true)
        ]
        for (mode in [LlmWireToolInputValidationMode.ValidateSupportedSubset, LlmWireToolInputValidationMode.Strict]) {
            for ((expected, actual, equal) in cases) {
                let schema = "{\"properties\":{\"v\":{\"enum\":[" + expected + "]}}}"
                @Expect(exactSchemaResult(schema, "{\"v\":" + actual + "}", mode).isOk(), equal)
            }
        }
    }

    @TestCase
    func enumEqualityDoesNotInheritProviderNodeCountLimit() {
        let bytes = Array<Byte>(200001, {index => if (index % 2 == 0) { b'0' } else { b',' }})
        let array = "[" + String.fromUtf8(bytes) + "]"
        let schema = "{\"properties\":{\"v\":{\"enum\":[" + array + "]}}}"
        for (mode in [LlmWireToolInputValidationMode.ValidateSupportedSubset, LlmWireToolInputValidationMode.Strict]) {
            @Expect(exactSchemaResult(schema, "{\"v\":" + array + "}", mode).isOk(), true)
        }
    }

    @TestCase
    func schemaViolationRetainsOnlyBoundedEvidence() {
        let name = String.fromUtf8(Array<Byte>(100000, repeat: b'x'))
        let schema = "{\"properties\":{\"" + name + "\":{\"enum\":[\"" + name + "\"]}}}"
        match (exactSchemaResult(schema, "{\"" + name + "\":false}", LlmWireToolInputValidationMode.Strict)) {
            case LlmWireResult.Err(error) =>
                @Expect(error.code, "llm.tool_arguments_schema_violation")
                @Expect(error.message.size < 256, true)
                @Expect(error.diagnosticJson.getOrThrow().size < 1024, true)
                @Expect(error.diagnosticJson.getOrThrow().contains("path exceeds 128 bytes"), true)
                @Expect(error.diagnosticJson.getOrThrow().contains("100004 bytes"), true)
            case _ => @Fail("enum mismatch must fail with bounded evidence")
        }
    }

    @TestCase
    func nestedLongPathsAndLargeTypeUnionsKeepBoundedDiagnostics() {
        let name = String.fromUtf8(Array<Byte>(100000, repeat: b'x'))
        let union = "[\"string\",\"string\",\"string\",\"string\",\"string\",\"string\",\"string\",\"string\",\"string\",\"string\",\"string\",\"string\"]"
        let schema = "{\"properties\":{\"" + name + "\":{\"properties\":{\"inner\":{\"type\":" + union + "}}}}}"
        for (mode in [LlmWireToolInputValidationMode.ValidateSupportedSubset, LlmWireToolInputValidationMode.Strict]) {
            match (exactSchemaResult(schema, "{\"" + name + "\":{\"inner\":false}}", mode)) {
                case LlmWireResult.Err(error) =>
                    @Expect(error.code, "llm.tool_arguments_schema_violation")
                    @Expect(error.diagnosticJson.getOrThrow().size < 1024, true)
                    @Expect(error.diagnosticJson.getOrThrow().contains("path exceeds 128 bytes"), true)
                    @Expect(error.diagnosticJson.getOrThrow().contains("multiple allowed types"), true)
                case _ => @Fail("type mismatch must preserve bounded nested evidence")
            }
        }
    }
}
