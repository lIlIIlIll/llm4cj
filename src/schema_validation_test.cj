package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

// Independent expected values follow JSON Schema 2020-12 validation/core,
// checked 2026-10-18. Assertions exercise the public tool barrier only.
private func schemaResult(schema: String, instance: String, mode!: LlmWireToolInputValidationMode = LlmWireToolInputValidationMode.Strict,
    limits!: LlmWireSchemaValidationLimits = LlmWireSchemaValidationLimits(), count!: Int64 = 1): LlmWireResult<Unit> {
    let tool = LlmWireTool("check", "", jsonFactoryValue(LlmWireJson.parse(schema)))
    let value = jsonFactoryValue(LlmWireJson.parse(instance))
    let blocks = Array<LlmWireOutputBlock>(count, {index => LlmWireOutputBlock.ToolCall(LlmWireToolCallBlock("call-" + index.toString(), "check", LlmWireToolArguments.Complete(value)))})
    validateReplyToolInputs(LlmWireReply(blocks: blocks, usage: LlmWireUsage(outputTokens: Some(7))),
        LlmWireTranscript(LlmWireInitialContext(tools: [LlmWireToolDeclaration(tool)])), mode: mode, limits: limits)
}

private func schemaCode(result: LlmWireResult<Unit>): String {
    match (result) { case LlmWireResult.Ok(_) => "ok"; case LlmWireResult.Err(error) => error.code }
}

private func valueSchema(rule: String): String { "{\"properties\":{\"v\":" + rule + "}}" }

@Test
class SchemaValidationTest {
    @TestCase
    func inclusiveExclusiveBoundsUseExactDecimalOrder() {
        for ((rule, passing, failing) in [
            ("{\"minimum\":1}", "1.0", "0.99999999999999999999999999"),
            ("{\"maximum\":1}", "10e-1", "1.00000000000000000000000001"),
            ("{\"exclusiveMinimum\":1}", "1.00000000000000000000000001", "1.0"),
            ("{\"exclusiveMaximum\":1}", "0.99999999999999999999999999", "1e0"),
            ("{\"minimum\":9007199254740993}", "9007199254740993", "9007199254740992"),
            ("{\"maximum\":-9007199254740993}", "-9007199254740993", "-9007199254740992"),
            ("{\"minimum\":1e99999999999999999999999999}", "10e99999999999999999999999998", "9e99999999999999999999999998"),
            ("{\"maximum\":-1e-99999999999999999999999999}", "-10e-100000000000000000000000000", "-9e-100000000000000000000000000"),
            ("{\"maximum\":12300e-4}", "1.230", "1.23000001"),
            ("{\"minimum\":-0}", "0e-999999999999999999999", "-1e-999999999999999999999")
        ]) {
            for (mode in [LlmWireToolInputValidationMode.Strict, LlmWireToolInputValidationMode.ValidateSupportedSubset]) {
                @Expect(schemaCode(schemaResult(valueSchema(rule), "{\"v\":" + passing + "}", mode: mode)), "ok")
                @Expect(schemaCode(schemaResult(valueSchema(rule), "{\"v\":" + failing + "}", mode: mode)), "llm.tool_arguments_schema_violation")
                @Expect(schemaCode(schemaResult(valueSchema(rule), "{\"v\":\"inapplicable\"}", mode: mode)), "ok")
            }
        }
    }

    @TestCase
    func countBoundsAndUnicodeUseMathematicalIntegersAndScalars() {
        for ((keyword, exact, below, above) in [
            ("minLength", "\"中😀\"", "\"😀\"", "\"中😀x\""),
            ("maxLength", "\"中😀\"", "\"😀\"", "\"中😀x\""),
            ("minItems", "[0,1]", "[0]", "[0,1,2]"), ("maxItems", "[0,1]", "[0]", "[0,1,2]"),
            ("minProperties", "{\"a\":0,\"b\":1}", "{\"a\":0}", "{\"a\":0,\"b\":1,\"c\":2}"),
            ("maxProperties", "{\"a\":0,\"b\":1}", "{\"a\":0}", "{\"a\":0,\"b\":1,\"c\":2}")
        ]) {
            let schema = valueSchema("{\"" + keyword + "\":20e-1}")
            @Expect(schemaResult(schema, "{\"v\":" + exact + "}").isOk(), true)
            @Expect(schemaResult(schema, "{\"v\":" + below + "}").isOk(), keyword == "maxLength" || keyword == "maxItems" || keyword == "maxProperties")
            @Expect(schemaResult(schema, "{\"v\":" + above + "}").isOk(), keyword == "minLength" || keyword == "minItems" || keyword == "minProperties")
            @Expect(schemaResult(schema, "{\"v\":false}").isOk(), true)
            @Expect(schemaCode(schemaResult(valueSchema("{\"" + keyword + "\":-1}"), "{}")), "llm.tool_schema_unsupported")
            @Expect(schemaCode(schemaResult(valueSchema("{\"" + keyword + "\":0.5}"), "{}")), "llm.tool_schema_unsupported")
        }
        for ((text, length) in [("\"\"", "0"), ("\"😀\"", "1"), ("\"e\\u0301\"", "2"), ("\"👩‍💻\"", "3"), ("\"\\u0000\"", "1")]) {
            @Expect(schemaResult(valueSchema("{\"minLength\":" + length + ",\"maxLength\":" + length + "}"), "{\"v\":" + text + "}").isOk(), true)
        }
        @Expect(schemaResult(valueSchema("{\"maxItems\":1e9999999999999999999999}"), "{\"v\":[]}").isOk(), true)
        @Expect(schemaCode(schemaResult(valueSchema("{\"minItems\":1e9999999999999999999999}"), "{\"v\":[]}")), "llm.tool_arguments_schema_violation")
        @Expect(schemaResult(valueSchema("{\"minLength\":-0e999999999999999999}"), "{\"v\":\"\"}").isOk(), true)
    }

    @TestCase
    func constUsesJsonEqualityAndPointerEscapesEvidence() {
        let schema = valueSchema("{\"const\":{\"a\":1,\"b\":[true,2]}}")
        @Expect(schemaResult(schema, "{\"v\":{\"b\":[true,2.0],\"a\":1e0}}").isOk(), true)
        @Expect(schemaCode(schemaResult(schema, "{\"v\":{\"b\":[1,2],\"a\":1}}")), "llm.tool_arguments_schema_violation")
        @Expect(schemaCode(schemaResult(valueSchema("{\"const\":[1,2]}"), "{\"v\":[2,1]}")), "llm.tool_arguments_schema_violation")
        match (schemaResult("{\"properties\":{\"a/~b\":{\"minimum\":2}}}", "{\"a/~b\":1}")) {
            case LlmWireResult.Err(error) =>
                @Expect(error.diagnosticJson.getOrThrow().contains("/properties/a~1~0b/minimum"), true)
                @Expect(error.diagnosticJson.getOrThrow().contains("/a~1~0b"), true)
                @Expect(error.usage.getOrThrow().outputTokens, Some(7))
            case _ => @Fail("minimum must reject with escaped pointers and observed usage")
        }
    }

    @TestCase
    func booleanSubschemasAndAdditionalPropertiesShareEvaluator() {
        for ((schema, instance, valid) in [
            ("{\"properties\":{\"v\":false}}", "{}", true), ("{\"properties\":{\"v\":false}}", "{\"v\":null}", false),
            ("{\"properties\":{\"v\":true}}", "{\"v\":null}", true),
            (valueSchema("{\"items\":false}"), "{\"v\":[]}", true), (valueSchema("{\"items\":false}"), "{\"v\":[1]}", false),
            ("{\"properties\":{\"known\":true},\"additionalProperties\":{\"type\":\"integer\",\"minimum\":2}}", "{\"known\":false,\"extra\":2.0}", true),
            ("{\"additionalProperties\":{\"type\":\"integer\"}}", "{\"extra\":1.1}", false),
            ("{\"additionalProperties\":true}", "{\"extra\":false}", true),
            ("{\"allOf\":[true,{}]}", "{}", true), ("{\"allOf\":[true,false]}", "{}", false),
            ("{\"anyOf\":[false,true]}", "{}", true), ("{\"anyOf\":[false,false]}", "{}", false),
            ("{\"oneOf\":[false,true]}", "{}", true), ("{\"oneOf\":[true,true]}", "{}", false)
        ]) { @Expect(schemaResult(schema, instance).isOk(), valid) }
    }

    @TestCase
    func unknownRulesNeverBecomeSuccessAndCombinatorsUseThreeValues() {
        let violation = "llm.tool_arguments_schema_violation"; let unsupported = "llm.tool_schema_unsupported"
        for ((schema, expected) in [
            ("{\"allOf\":[{\"type\":\"string\"},{\"future\":1}]}", violation),
            ("{\"anyOf\":[{\"type\":\"string\"},{\"future\":1}]}", unsupported),
            ("{\"anyOf\":[{}, {\"future\":1}]}", unsupported),
            ("{\"anyOf\":[{\"type\":\"string\",\"future\":1},{\"type\":\"number\"}]}", violation),
            ("{\"oneOf\":[{}, {}, {\"future\":1}]}", violation),
            ("{\"oneOf\":[{}, {\"future\":1}]}", unsupported),
            ("{\"oneOf\":[true,{\"properties\":{\"absent\":{\"pattern\":\"x\"}}}]}", unsupported),
            ("{\"oneOf\":[true,{\"items\":{\"future\":1}}]}", unsupported),
            ("{\"oneOf\":[true,{\"$defs\":{\"unused\":{\"future\":1}}}]}", unsupported),
            ("{\"oneOf\":[true,{\"definitions\":{\"unused\":{\"future\":1}}}]}", unsupported),
            ("{\"oneOf\":[true,{\"type\":\"string\",\"properties\":{\"absent\":{\"future\":1}}}]}", unsupported),
            ("{\"oneOf\":[{\"type\":\"string\"}, {\"future\":1}]}", unsupported),
            ("{\"oneOf\":[{\"type\":\"string\"}, {\"type\":\"number\"}]}", violation),
            ("{\"oneOf\":[{}, {\"type\":\"string\"}]}", "ok"),
            ("{\"type\":\"string\",\"future\":1}", violation),
            ("{\"anyOf\":[],\"type\":\"string\"}", violation),
            ("{\"allOf\":[{\"anyOf\":[{},{}]}],\"oneOf\":[{},false]}", "ok")
        ]) {
            @Expect(schemaCode(schemaResult(schema, "{}", mode: LlmWireToolInputValidationMode.ValidateSupportedSubset)), expected)
            if (schema.contains("future") || schema.contains("[]")) { @Expect(schemaCode(schemaResult(schema, "{}")), unsupported) }
        }
        for (keyword in ["allOf", "anyOf", "oneOf"]) {
            for (form in ["[]", "{}", "null", "true", "[1]", "[{},null]"]) {
                for (mode in [LlmWireToolInputValidationMode.Strict, LlmWireToolInputValidationMode.ValidateSupportedSubset]) {
                    @Expect(schemaCode(schemaResult("{\"" + keyword + "\":" + form + "}", "{}", mode: mode)), unsupported)
                }
            }
        }
    }

    @TestCase
    func fullPreflightIncludesUnusedSchemaLocationsButNotAnnotationData() {
        for (schema in [
            "{\"properties\":{\"absent\":{\"pattern\":\"x\"}}}", "{\"items\":{\"$ref\":\"#/a\"}}",
            "{\"additionalProperties\":{\"future\":true}}", "{\"$defs\":{\"unused\":{\"future\":0}}}",
            "{\"definitions\":{\"unused\":{\"future\":0}}}", "{\"$defs\":[]}", "{\"definitions\":{\"unused\":1}}",
            "{\"anyOf\":[{}, {\"properties\":{\"absent\":{\"future\":0}}}]}"
        ]) {
            for (mode in [LlmWireToolInputValidationMode.Strict, LlmWireToolInputValidationMode.ValidateSupportedSubset]) {
                @Expect(schemaCode(schemaResult(schema, "{}", mode: mode)), "llm.tool_schema_unsupported")
            }
            @Expect(schemaResult(schema, "{}", mode: LlmWireToolInputValidationMode.Disabled).isOk(), true)
        }
        @Expect(schemaResult("{\"default\":{\"future\":1},\"examples\":[{\"future\":1}],\"$defs\":{\"ok\":true}}", "{}").isOk(), true)
        for (rule in ["{\"exclusiveMinimum\":true}", "{\"minimum\":\"1\"}", "{\"properties\":{\"v\":1}}", "{\"items\":[]}"]) {
            @Expect(schemaCode(schemaResult(rule, "{}")), "llm.tool_schema_unsupported")
        }
        for (schema in ["{\"patternProperties\":{\".*\":true},\"additionalProperties\":false}", "{\"properties\":{\"v\":{\"prefixItems\":[true],\"items\":false}}}"]) {
            @Expect(schemaCode(schemaResult(schema, "{\"v\":[1]}", mode: LlmWireToolInputValidationMode.ValidateSupportedSubset)), "llm.tool_schema_unsupported")
        }
    }

    @TestCase
    func loweredWorkAndDepthLimitsHaveExactBoundariesAndAreGlobal() {
        // {} schema + {} value: 4 input bytes, 2 DOM visits, 1 preflight,
        // 1 evaluation. A second call shares the remaining work, not a reset.
        @Expect(schemaResult("{}", "{}", limits: LlmWireSchemaValidationLimits(maxWork: 8)).isOk(), true)
        match (schemaResult("{}", "{}", limits: LlmWireSchemaValidationLimits(maxWork: 7))) {
            case LlmWireResult.Err(error) => @Expect(error.code, "llm.schema_validation_limit"); @Expect(error.kind, LlmWireErrorKind.LimitExceeded); @Expect(error.usage.getOrThrow().outputTokens, Some(7))
            case _ => @Fail("B-1 work must fail")
        }
        @Expect(schemaResult("{}", "{}", count: 2, limits: LlmWireSchemaValidationLimits(maxWork: 16)).isOk(), true)
        @Expect(schemaCode(schemaResult("{}", "{}", count: 2, limits: LlmWireSchemaValidationLimits(maxWork: 15))), "llm.schema_validation_limit")
        @Expect(schemaResult("{}", "{\"v\":[]}", limits: LlmWireSchemaValidationLimits(maxDepth: 2)).isOk(), true)
        @Expect(schemaCode(schemaResult("{}", "{\"v\":[]}", limits: LlmWireSchemaValidationLimits(maxDepth: 1))), "llm.schema_validation_limit")
        for ((depth, work) in [(0,1), (257,1), (1,0), (1,67108865)]) {
            try { let _ = LlmWireSchemaValidationLimits(maxDepth: depth, maxWork: work); @Fail("limits cannot exceed hard bounds or be zero") }
            catch (error: LlmWireError) { @Expect(error.code, "llm.schema_validation_limits_invalid") }
        }
    }
}
