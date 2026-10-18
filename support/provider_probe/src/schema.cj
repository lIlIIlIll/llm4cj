package llm4cj_provider_probe

import llm4cj.*

// Expected results come from the hand-reviewed semantic fixture, not this probe.
func checkSchemaFixture(path: String): Int64 {
    let fixture = probeValue(LlmWireJson.parse(String.fromUtf8(readBytes(path))))
    var count: Int64 = 0
    for (test in fixture.field("cases").getOrThrow().values()) {
        let id = test.field("id").getOrThrow().stringValue().getOrThrow()
        let schema = test.field("schema").getOrThrow()
        let instance = test.field("instance").getOrThrow()
        let mode = match (test.field("mode").getOrThrow().stringValue().getOrThrow()) {
            case "Strict" => LlmWireToolInputValidationMode.Strict
            case "SupportedSubset" => LlmWireToolInputValidationMode.ValidateSupportedSubset
            case _ => throw IllegalArgumentException("unknown fixture mode")
        }
        let expected = test.field("expected_code").getOrThrow().stringValue().getOrThrow()
        let tool = LlmWireTool("check", "", schema)
        let call = LlmWireToolCallBlock("call", "check", LlmWireToolArguments.Complete(instance))
        let transcript = LlmWireTranscript(LlmWireInitialContext(tools: [LlmWireToolDeclaration(tool)]))
        let actual = match (validateReplyToolInputs(LlmWireReply(blocks: [LlmWireOutputBlock.ToolCall(call)]), transcript, mode: mode)) {
            case LlmWireResult.Ok(_) => "ok"
            case LlmWireResult.Err(error) => error.code
        }
        if (actual != expected) { println("schema fixture mismatch: " + id + ": expected " + expected + ", got " + actual); return 1 }
        count++
    }
    println("schema fixtures passed: " + count.toString())
    0
}
