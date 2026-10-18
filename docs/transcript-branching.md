# Transcript 分支与续接

`forkAt(k)` 返回保留原始 initial context 和前 `k` 个输入项的新 transcript；范围为 `[0, k)`，合法边界为零到 item 数量。零保留初始上下文但不保留输入项。方法只验证保留的前缀，因此丢弃尾部的问题不影响较早的安全分支。

分支边界不能留下未闭合的工具调用。并行调用必须由一个结果消息全部闭合。声明、激活、撤销和指令更新保留原位置；不会从后续输入借用定义，也不会合并到初始上下文。完整 message、native replay、message spans、phase 和 block order 保持不变，不提供任意起点或块内切片。

缓存断点保留原坐标：初始上下文断点始终保留，输入项及 message block 断点仅在所属输入项被保留时留下。续接保留全部原有断点，不自动增加断点。Custom tool 的完整原始文本可以续接，结果必须匹配原调用的工具种类。音频 replay 保持完整 assistant message 的原始末尾位置；过期时间仍在发送时通过显式时钟检查。

`appendContinuation(reply)` 要求单个 choice；多 choice 使用 `appendContinuation(reply, choiceIndex)` 按公开 choice index 选择分支。只验证选中分支的工具可见性，未选分支不会影响结果。函数复用 continuation 投影屏障；refusal、display reasoning、非法或部分工具参数明确失败。Incomplete choice 中身份有效且参数完整的调用仍可以续接。

源 transcript 必须已经闭合。续接结果可以暂时以新 assistant 工具调用结束；应用追加全部工具结果后，才能 build 或 encode。此数据操作不执行工具，不选择 schema 校验策略，不做摘要、缓存保证、存储或 agent 调度。需要 schema 屏障时，在续接前对选中 reply 显式调用 `validateReplyToolInputs`。

三个方法返回 `LlmWireResult<LlmWireTranscript>`。失败不改变源、reply 或其他分支；成功结果与输入和 getter 返回的嵌套数组隔离。分支 helper 不代替目标 codec、模型和端点的编码前校验。未增加新语义的结果继续写入 transcript snapshot version 2。

越界 fork 返回 `llm.transcript_index_invalid`；多 choice 未选择、所选 index 缺失和重复分别返回 `llm.continuation_choice_required`、`llm.continuation_choice_missing` 和 `llm.continuation_choice_ambiguous`。续接错误保留 reply 的已观测 usage。工具及投影错误继续使用原有错误码。

Fork 的复制量随保留内容增长；不可变 continuation 随已有历史和新增内容增长。长会话逐项构造仍应使用 request builder；这些 helper 不改变 builder 每次 append 仅冻结新增输入的行为。

完整公开调用见 [transcript consumer](../support/transcript_consumer/src/main.cj)。`scripts/check.sh` 会构建该外部 consumer，并通过独立 fixture 核对三个原生协议的 prefix、续接 body、headers 及 snapshot。
