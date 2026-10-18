package llm4cj

import std.unittest.*
import std.unittest.testmacro.*

func codexEscapedPayload(byte: Byte, width: Int64, size: Int64): String {
    String.fromUtf8(Array<Byte>(size / width, repeat: byte)) + String.fromUtf8(Array<Byte>(size % width, repeat: 65u8))
}

func expectCodexRequestLimit(action: () -> Unit, message: String): Unit {
    try { action(); @Fail("oversized Codex requests must not produce sendable bytes") }
    catch (error: LlmWireError) {
        @Expect(error.kind, LlmWireErrorKind.BodyLimit); @Expect(error.code, "llm.codex_request_too_large")
        @Expect(error.message, message); @Expect(error.protocol, Some(LlmWireProtocol.Responses))
        @Expect(error.dialectId, "openai.codex.responses.v1"); @Expect(error.phase, Some(LlmTransportPhase.Encode))
    }
}

@Test
class CodexRequestLimitsTest {
    @TestCase
    func escapedHttpRequestsAcceptTheExactByteLimit() {
        let codec = codexTestCodec()
        let limit: Int64 = 8388608
        let overhead = codexHttpBody(codec, codexRequest("model", [codexText("x")])).size - 1
        for ((byte, width) in [(10u8, 2), (0u8, 6)]) {
            let payload = codexEscapedPayload(byte, width, limit - overhead)
            let prepared = codec.encodeRequest(codexRequest("model", [codexText(payload)]), streaming: true)
            @Expect(prepared.bodyText().size, limit)
            match (prepared.materialize()) {
                case LlmWireResult.Ok(sendable) => @Expect(sendable.body.size, limit)
                case LlmWireResult.Err(error) => throw error
            }
            let text = codexJson(prepared.bodyText()).field("input").getOrThrow().values()[0].field("content").getOrThrow().values()[0].field("text").getOrThrow()
            @Expect(text.stringValue(), Some(payload))
            expectCodexRequestLimit({ => let _ = codec.encodeRequest(codexRequest("model", [codexText(payload + "A")]), streaming: true) },
                "Codex request exceeds the 8 MiB JSON limit")
        }
    }

    @TestCase
    func escapedWebSocketFramesAcceptTheExactByteLimit() {
        let codec = codexTestCodec()
        let limit: Int64 = 8388608
        let overhead = codec.newResponsesWebSocketSession().prepare(codexRequest("model", [codexText("x")])).body.size - 1
        for ((byte, width) in [(10u8, 2), (0u8, 6)]) {
            let payload = codexEscapedPayload(byte, width, limit - overhead)
            let exact = codec.newResponsesWebSocketSession().prepare(codexRequest("model", [codexText(payload)]))
            @Expect(exact.body.size, limit)
            let root = codexJson(String.fromUtf8(exact.body))
            @Expect(root.field("type").getOrThrow().stringValue(), Some("response.create"))
            @Expect(root.field("input").getOrThrow().values()[0].field("content").getOrThrow().values()[0].field("text").getOrThrow().stringValue(), Some(payload))
            let ws = codec.newResponsesWebSocketSession()
            expectCodexRequestLimit({ => let _ = ws.prepare(codexRequest("model", [codexText(payload + "A")])) },
                "WebSocket request exceeds the 8 MiB JSON limit")
            let _ = ws.prepare(codexRequest("model", [codexText("next")]))
            let reply = succeededReply(codexUpdate(ws.push(("{\"type\":\"response.completed\",\"response\":" + codexFinalResponse() + "}").toArray())))
            let oversized = String.fromUtf8(Array<Byte>(4194305, repeat: 10u8))
            expectCodexRequestLimit({ => let _ = ws.prepare(codexRequest("model", [codexText(oversized)])) },
                "Codex request exceeds the 8 MiB JSON limit")
            let history = [codexText("next"), reply.toContinuationInput()[0], codexText("last")]
            let continued = codexJson(String.fromUtf8(ws.prepare(codexRequest("model", history)).body))
            @Expect(continued.field("previous_response_id").getOrThrow().stringValue(), Some("resp_1"))
            @Expect(continued.field("input").getOrThrow().values().size, 1)
        }
    }

    @TestCase
    func boundedRequestsPreserveOrdinaryEscaping() {
        let codec = codexTestCodec()
        let payload = "line\n\u{0000}\"\\text"
        let request = codexRequest("model", [codexText(payload)])
        let http = codexJson(codexHttpBody(codec, request))
        let frame = codexJson(String.fromUtf8(codec.newResponsesWebSocketSession().prepare(request).body))
        @Expect(http.field("input").getOrThrow().stringify(), frame.field("input").getOrThrow().stringify())
        @Expect(http.field("input").getOrThrow().values()[0].field("content").getOrThrow().values()[0].field("text").getOrThrow().stringValue(), Some(payload))
    }

    @TestCase
    func structuredSchemaDepthIncludesRequestWrappers() {
        let codec = codexTestCodec()
        var schema = "{\"type\":\"string\"}"
        for (_ in 0..252) { schema = "{\"type\":\"object\",\"additionalProperties\":" + schema + "}" }
        let exact = codexRequest("model", [codexText("hi")],
            structuredOutput: LlmWireStructuredOutput.JsonSchema(LlmWireJsonSchema("answer", codexJson(schema))))
        let http = codec.encodeRequest(exact, streaming: true)
        let _ = codexJson(http.bodyText())
        let _ = codexJson(String.fromUtf8(codec.newResponsesWebSocketSession().prepare(exact).body))
        let tooDeep = codexRequest("model", [codexText("hi")], structuredOutput: LlmWireStructuredOutput.JsonSchema(
            LlmWireJsonSchema("answer", codexJson("{\"type\":\"object\",\"additionalProperties\":" + schema + "}"))))
        expectCodexRequestLimit({ => let _ = codec.encodeRequest(tooDeep, streaming: true) }, "Codex request exceeds the 8 MiB JSON limit")
        expectCodexRequestLimit({ => let _ = codec.newResponsesWebSocketSession().prepare(tooDeep) }, "Codex request exceeds the 8 MiB JSON limit")
    }
}
