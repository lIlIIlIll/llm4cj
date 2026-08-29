package llm4cj_external_consumer

import llm4cj.*
import std.convert.*

main(): Int64 {
    let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
    let request = LlmWireRequest(
        "demo-model",
        [LlmWireMessage(
            LlmWireRole.User,
            [LlmWireBlock.Text(LlmWireTextBlock("你好"))]
        )]
    )
    let payload = match (codec.encodeRequest(request).materialize()) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 1
    }
    if (!String.fromUtf8(payload.body).contains("demo-model")) { return 1 }

    let state = match (codec.decodeResponse(LlmWireHttpResponse(
        200, [LlmWireHeader("x-request-id", "req_demo")],
        "{\"id\":\"resp_demo\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"你好，仓颉！\"}]}],\"usage\":{}}".toArray()
    ))) {
        case LlmWireResult.Ok(value) => value
        case LlmWireResult.Err(_) => return 1
    }
    match (state) {
        case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) =>
            for (block in reply.blocks) {
                match (block) {
                    case LlmWireOutputBlock.Text(text) => println(text.text)
                    case _ => ()
                }
            }
            0
        case _ => 1
    }
}
