# 请求与响应

请求由 `LlmWireRequest`、按顺序排列的 `LlmWireInstruction`、`LlmWireMessage` 和封闭的 `LlmWireBlock` 组成。可选 provider 字段默认不发送。streaming 是编码操作的选择，不属于可复用请求的语义。

`LlmWireRequestBuilder` 由 codec 创建。它保存 codec 与 model profile 的绑定，立即检查空模型、空 instruction 和非法 token 上限，并在 `build()` 时执行 dialect、capability 与 conversation 的完整校验。

固定响应以 `LlmWireOutputBlock` 表示 provider 输出，避免把只允许出现在请求历史中的 ToolResult、Image 等输入块放进 reply。返回值仍是 `LlmWireResponseState`：

- `Pending`：provider 仍处于 queued 或 in-progress；
- `Terminal(Succeeded)`：结构合法、成功完成，并且所有返回语义可安全表示；
- `Terminal(Incomplete)`：保留可用输出，并给出 token/length 等原因；
- `Terminal(Failed)`：provider 失败、取消或资源失败。

provider 的合法错误响应属于 wire outcome，不会伪装成 JSON 或 transport exception。格式错误、错误字段类型和溢出才抛出 `LlmWireError`。

固定响应会保留 Responses 的 URL/file annotations、output phase 和 token logprobs，也会保留 Messages citations、结构化 refusal details、service tier 与 server-tool usage。已知类型缺少必需字段属于 `InvalidWire`；仍未建模的合法 annotation、citation 或 streamed metadata 返回 `Unsupported`，不会删掉字段后返回 `Succeeded`。Chat tool call 只接受明确的 `type: "function"`；其他合法 tool 类型返回 `Unsupported`，缺失 discriminator 属于 `InvalidWire`。

tool arguments 不再被压成一个字符串状态：`Complete` 只保存 canonical `LlmWireJson` 对象，`InvalidJson` 保存非法文本，`InvalidShape` 保存非对象 JSON，`Partial` 只用于尚未完成或 incomplete 的流。成功终态要求 tool arguments 是完整 JSON object；encoder 从 canonical JSON 生成 wire text，不存在可与对象内容冲突的第二份 raw truth。

usage counter 使用 `Option<Int64>`。`None` 表示 provider 没有返回该字段，`Some(0)` 才表示 provider 明确报告零。

conversation 只接受可发送的 canonical history：assistant tool call 之后必须由一个 user tool-result turn 完整闭合当前 pending calls，不能混入普通内容、拆成不完整批次或在闭合前继续新对话。本库不提供会删除或重排非法历史的 lenient 编码模式。

空 block 列表和只包含空文本的 message 会以 `llm.message_empty` 拒绝。ToolResult turn 不允许与 Text 交错，因此 Chat encoder 不会重新排序“文本 + 工具结果”这种非法 canonical 输入。`Complete` tool arguments 在所有协议中都必须是 JSON object；历史 ToolCall name 与工具定义采用相同的 1–64 字节 ASCII 名称语法。

`LlmWireToolResultBlock.content` 是有序的 `LlmWireToolResultContent` 数组。text 与 image content 会按 provider dialect 编码。图片仍受 model profile 的 image capability、source 和 media type 规则约束。

Chat 固定响应保留所有 choice，并要求 index 从 0 连续排列。每个 `LlmWireChoice` 独立记录 `Completed`、`Incomplete` 或 `Refused` outcome。多 choice reply 必须调用 `toContinuationInput(choiceIndex)` 显式选择分支；无参数 projection 会以 `llm.continuation_choice_required` 拒绝含糊选择。

`LlmWireReply.toContinuationInput()` 只投影可安全继续发送的 text、完整 tool call 和 native replay block。`InvalidJson`、`InvalidShape` 或 `Partial` tool arguments 会明确失败；存在 display reasoning、refusal 或未知诊断 block 时也会以 `llm.continuation_projection_lossy` 失败，绝不静默丢弃语义。如果删除较早的不可回放 block 会改变后续 `NativeReplay.blockOrder`，projection 会以 `llm.native_replay_projection_order_invalid` 失败，而不是生成下一次请求必然拒绝的历史。带 choice index 的版本返回 `LlmWireResult<Array<LlmWireMessage>>`，让选择错误保持在稳定错误通道中。Responses encoder只聚合相邻普通 content，native item 与 message 的相对顺序保持不变。
