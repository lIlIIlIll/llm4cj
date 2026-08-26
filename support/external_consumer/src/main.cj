package llm4cj_external_consumer

import llm4cj.*

main(): Int64 {
    let request = LlmWireRequest(
        "demo-model",
        [LlmWireMessage(
            LlmWireRole.User,
            [LlmWireBlock(LlmWireBlockKind.Text, text: "你好")]
        )]
    )
    let payload = encodeLlmWireRequest(LlmWireProtocol.Responses, request)
    if (!payload.contains("demo-model")) { return 1 }

    let reply = decodeLlmWireReply(
        LlmWireProtocol.Responses,
        "{\"id\":\"resp_demo\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"你好，仓颉！\"}]}],\"usage\":{}}"
    )
    for (block in reply.blocks) {
        if (let LlmWireBlockKind.Text <- block.kind) { println(block.text) }
    }
    0
}
