# 请求与响应

v0.2.0 请求只有一个事实来源：`LlmWireTranscript`。初始上下文保存按顺序排列的 instructions 和 tool declarations；`items` 保存 Message、InstructionUpdate、ToolDeclaration、ToolActivation、ToolDeactivation 和 ToolReplacement。数组属性返回 defensive copy，不提供 setter 或独立 current-tools 状态。

`LlmWireTranscriptBuilder` 可以先追加 item，但 `build()`/`encodeRequest()` 会执行完整的 tool identity、active view、call/result adjacency、schema 和 provider placement 校验。pending tool call 中间插入上下文更新、未知 ref、重复 active/deactive、未关闭结果和无法表达的 replacement 都返回结构化错误。

固定响应仍使用 `LlmWireOutputBlock` 与 `LlmWireReply`。`toContinuationInput()` 只投影可安全重放的 text、完整 tool call 和允许的 native replay，并保持 block order。失败、取消和 incomplete outcome 不会被改写为成功。

## Prepared request 生命周期

1. 选择与 endpoint/model 对应的 profile 和 transcript capability identity。
2. 构造 `LlmWireInitialContext` 与有序 `LlmWireInputItem`。
3. 调用 `codec.encodeRequest(request, streaming:)`；验证失败时没有 prepared bytes。
4. 调用 `materialize()`，合并 required/user headers 并交给应用自己的 HTTP client。
5. 将 bounded HTTP body 或 SSE bytes 交回 codec；固定与流式 decoder 使用同一 canonical semantics。

## Usage 与错误

计数缺失保持 unknown；明确的零不会被归一化为缺失。cache read/write source 只报告 decoder 实际看到的 provider field path，不代表服务端命中率或收益。provider retry、endpoint 选择和凭据仍由应用负责。
