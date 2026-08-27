package llm4cj_external_consumer

import llm4cj.*

main(): Int64 {
    let codec = LlmWireCodec(LlmWireProtocol.Responses, openAiResponsesDialect())
    let request = LlmWireRequest(
        "demo-model",
        [LlmWireMessage(
            LlmWireRole.User,
            [LlmWireBlock.Text(LlmWireTextBlock("你好"))]
        )]
    )
    let payload = codec.encodeRequest(request)
    if (!payload.contains("demo-model")) { return 1 }

    let state = codec.decodeResponse(
        "{\"id\":\"resp_demo\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"你好，仓颉！\"}]}],\"usage\":{}}"
    )
    match (state) {
        case LlmWireResponseState.Terminal(LlmWireTerminal.Succeeded(reply)) =>
            for (block in reply.blocks) {
                match (block) {
                    case LlmWireBlock.Text(text) => println(text.text)
                    case _ => ()
                }
            }
            0
        case _ => 1
    }
}
