package llm4cj_provider_probe

import llm4cj.*

private func fixtureStructuredFormat(test: LlmWireJson): LlmWireStructuredOutput {
    match (test.field("format").getOrThrow().stringValue().getOrThrow()) {
        case "object" => LlmWireStructuredOutput.JsonObject
        case "schema" => LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("answer", test.field("schema").getOrThrow()))
        case "document" => LlmWireStructuredOutput.JsonSchemaDocument(test.field("schema").getOrThrow())
        case _ => throw IllegalArgumentException("unknown structured fixture format")
    }
}

private func checkStructuredResult(reply: LlmWireReply, test: LlmWireJson, raw: LlmWireJson): Bool {
    let format = fixtureStructuredFormat(test)
    let transcript = LlmWireTranscript(items: messageItems([userMessage("answer")]))
    let result = extractStructuredOutput(reply, LlmWireRequest("fixture-model", transcript, structuredOutput: format))
    var actualCode = ""
    var parsed: ?LlmWireJson = None
    var actualRaw: ?String = None
    let actual = match (result) {
        case LlmWireResult.Err(error) => actualCode = error.code; "Error"
        case LlmWireResult.Ok(output) =>
            actualRaw = output.rawText
            match (output.outcome) {
                case LlmWireStructuredOutputOutcome.Valid(value) => parsed = Some(value); "Valid"
                case LlmWireStructuredOutputOutcome.InvalidJson(error) => actualCode = error.code; "InvalidJson"
                case LlmWireStructuredOutputOutcome.SchemaViolation(error) => actualCode = error.code; "SchemaViolation"
                case LlmWireStructuredOutputOutcome.UnsupportedSchema(error) => actualCode = error.code; "UnsupportedSchema"
                case LlmWireStructuredOutputOutcome.Incomplete(_) => "Incomplete"
                case LlmWireStructuredOutputOutcome.Refused(_) => "Refused"
            }
    }
    if (actual != test.field("expected").getOrThrow().stringValue().getOrThrow()) { return false }
    match (test.field("expected_code")) { case Some(code) => if (actualCode != code.stringValue().getOrThrow()) { return false }; case None => () }
    if (actualRaw != raw.stringValue()) { return false }
    match (test.field("value")) {
        case Some(expected) => match (parsed) { case Some(value) => if (value.stringify() != expected.stringify()) { return false }; case None => return false }
        case None => ()
    }
    true
}

func checkStructuredFixture(path: String): Int64 {
    let fixture = probeValue(LlmWireJson.parse(String.fromUtf8(readBytes(path))))
    var checks: Int64 = 0
    for (item in fixture.field("cases").getOrThrow().values()) {
        for (dialect in item.field("dialects").getOrThrow().values()) {
            let name = dialect.stringValue().getOrThrow()
            let codec = codecFor(name, model: "fixture-model")
            let fixed = match (codec.decodeResponse(LlmWireHttpResponse(200, [], item.field("response").getOrThrow().stringify().toArray()))) {
                case LlmWireResult.Ok(LlmWireResponseState.Terminal(LlmWireTerminal.Completed(reply))) => reply
                case _ => throw IllegalStateException("structured fixed fixture did not decode")
            }
            for (test in item.field("variants").getOrThrow().values()) {
                if (!checkStructuredResult(fixed, test, item.field("raw_text").getOrThrow())) { println("structured fixed mismatch: " + name); return 1 }
                checks++
            }
            for (newline in ["\n", "\r\n"]) {
                let builder = StringBuilder()
                for (event in item.field("events").getOrThrow().values()) {
                    let data = match (event.stringValue()) { case Some(text) => text; case None => event.stringify() }
                    builder.append("data: " + data + newline + newline)
                }
                let bytes = builder.toString().toArray()
                for (chunk in [1,3,7,65536]) {
                    let streamed = match (decodeSse(codec, bytes, chunk, false).result) {
                        case LlmWireResult.Ok(LlmWireTerminal.Completed(reply)) => reply
                        case _ => throw IllegalStateException("structured stream fixture did not decode")
                    }
                    for (test in item.field("variants").getOrThrow().values()) {
                        if (!checkStructuredResult(streamed, test, item.field("raw_text").getOrThrow())) { println("structured stream mismatch: " + name); return 1 }
                        checks++
                    }
                }
            }
        }
    }
    println("structured fixture checks passed: " + checks.toString())
    0
}
