package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

private func schemaAcceptanceJson(source: String): LlmWireJson {
    match (LlmWireJson.parse(source)) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(error) => throw error
    }
}

private func schemaAcceptanceCode(schema: String, instance: String,
    mode!: LlmWireToolInputValidationMode = LlmWireToolInputValidationMode.Strict): String {
    let tool = LlmWireTool("check", "", schemaAcceptanceJson(schema))
    let call = LlmWireToolCallBlock("call", "check", LlmWireToolArguments.Complete(schemaAcceptanceJson(instance)))
    let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [LlmWireToolDeclaration(tool)]))
    match (validateReplyToolInputs(LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(call)]), transcript, mode: mode)) {
        case LlmWireResult.Ok(_) => ""
        case LlmWireResult.Err(error) => error.code
    }
}

@Test
class SchemaIndependentAcceptanceTest {
    @TestCase
    func preflightIncludesAbsentPropertiesAndBranches() {
        @Expect(schemaAcceptanceCode(#"{"properties":{"absent":{"pattern":"x"}}}"#, "{}"), "llm.tool_schema_unsupported")
        @Expect(schemaAcceptanceCode(#"{"anyOf":[true,{"pattern":"x"}]}"#, "{}"), "llm.tool_schema_unsupported")
        @Expect(schemaAcceptanceCode(#"{"properties":{"absent":{"minimum":"bad"}}}"#, "{}"), "llm.tool_schema_unsupported")
    }

    @TestCase
    func subsetNeverCertifiesUnknownRules() {
        let subset = LlmWireToolInputValidationMode.ValidateSupportedSubset
        @Expect(schemaAcceptanceCode(#"{"pattern":"x"}"#, "{}", mode: subset), "llm.tool_schema_unsupported")
        @Expect(schemaAcceptanceCode(#"{"anyOf":[true,{"pattern":"x"}]}"#, "{}", mode: subset), "llm.tool_schema_unsupported")
        @Expect(schemaAcceptanceCode(#"{"oneOf":[true,{"pattern":"x"}]}"#, "{}", mode: subset), "llm.tool_schema_unsupported")
        @Expect(schemaAcceptanceCode(#"{"oneOf":[true,{"properties":{"absent":{"pattern":"x"}}}]}"#, "{}", mode: subset), "llm.tool_schema_unsupported")
        @Expect(schemaAcceptanceCode(#"{"additionalProperties":false,"patternProperties":{"^x":{}}}"#, #"{"x":1}"#, mode: subset), "llm.tool_schema_unsupported")
        @Expect(schemaAcceptanceCode(#"{"properties":{"v":{"items":false,"prefixItems":[true]}}}"#, #"{"v":[1]}"#, mode: subset), "llm.tool_schema_unsupported")
        @Expect(schemaAcceptanceCode(#"{"allOf":[false,{"pattern":"x"}]}"#, "{}", mode: subset), "llm.tool_arguments_schema_violation")
        @Expect(schemaAcceptanceCode(#"{"oneOf":[true,true,{"pattern":"x"}]}"#, "{}", mode: subset), "llm.tool_arguments_schema_violation")
    }

    @TestCase
    func combinatorsPreserveExactMatchCounts() {
        @Expect(schemaAcceptanceCode(#"{"allOf":[true,{"maxProperties":0}]}"#, "{}"), "")
        @Expect(schemaAcceptanceCode(#"{"anyOf":[false,{"minProperties":1}]}"#, "{}"), "llm.tool_arguments_schema_violation")
        @Expect(schemaAcceptanceCode(#"{"oneOf":[false,true]}"#, "{}"), "")
        @Expect(schemaAcceptanceCode(#"{"oneOf":[true,true]}"#, "{}"), "llm.tool_arguments_schema_violation")
        @Expect(schemaAcceptanceCode(#"{"anyOf":[]}"#, "{}"), "llm.tool_schema_unsupported")
    }

    @TestCase
    func numericBoundsDoNotRoundLargeIntegersOrExpandExponents() {
        let schema = #"{"properties":{"v":{"minimum":9007199254740993,"exclusiveMaximum":9007199254740994}}}"#
        @Expect(schemaAcceptanceCode(schema, #"{"v":9007199254740993}"#), "")
        @Expect(schemaAcceptanceCode(schema, #"{"v":9007199254740992}"#), "llm.tool_arguments_schema_violation")
        @Expect(schemaAcceptanceCode(schema, #"{"v":9007199254740994}"#), "llm.tool_arguments_schema_violation")
        let tiny = #"{"properties":{"v":{"exclusiveMinimum":-1e-999999999999999999999999999999}}}"#
        @Expect(schemaAcceptanceCode(tiny, #"{"v":0}"#), "")
        @Expect(schemaAcceptanceCode(tiny, #"{"v":-2e-999999999999999999999999999999}"#), "llm.tool_arguments_schema_violation")
    }

    @TestCase
    func unicodeLengthsAndConstUseSemanticValues() {
        let unicode = #"{"properties":{"v":{"minLength":3,"maxLength":3}}}"#
        @Expect(schemaAcceptanceCode(unicode, #"{"v":"👍🏽é"}"#), "")
        @Expect(schemaAcceptanceCode(unicode, #"{"v":"👍é"}"#), "llm.tool_arguments_schema_violation")
        @Expect(schemaAcceptanceCode(#"{"const":{"a":1,"b":[0]}}"#, #"{"b":[-0e999999999999999999999999999999],"a":1.000}"#), "")
        @Expect(schemaAcceptanceCode(#"{"properties":{"v":{"const":1}}}"#, #"{"v":true}"#), "llm.tool_arguments_schema_violation")
    }

    @TestCase
    func booleanAndAdditionalSchemasAreApplied() {
        @Expect(schemaAcceptanceCode(#"{"properties":{"x":false}}"#, #"{"x":1}"#), "llm.tool_arguments_schema_violation")
        @Expect(schemaAcceptanceCode(#"{"additionalProperties":{"type":"integer","minimum":2}}"#, #"{"x":2,"y":3}"#), "")
        @Expect(schemaAcceptanceCode(#"{"additionalProperties":{"type":"integer","minimum":2}}"#, #"{"x":1}"#), "llm.tool_arguments_schema_violation")
        @Expect(schemaAcceptanceCode(#"{"properties":{"a":{"type":"array","items":false}}}"#, #"{"a":[0]}"#), "llm.tool_arguments_schema_violation")
    }
}
