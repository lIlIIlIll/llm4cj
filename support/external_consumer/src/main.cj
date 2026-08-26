package llm4cj_external_consumer

import llm4cj.*

main(): Int64 {
    let payload = encodeResponsesWireRequest(LlmWireRequest(
        "consumer-model",
        [LlmWireMessage(
            LlmWireRole.User,
            [LlmWireBlock(LlmWireBlockKind.Text, text: "hello")]
        )]
    ))
    if (payload.contains("consumer-model")) { 0 } else { 1 }
}
