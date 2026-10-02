# 从 v0.2 迁移与 Axyndra 消费契约

v0.3.0 是有意的 breaking 变更。旧入口删除，没有兼容重载、旧快照读取或自动转换。

| v0.2 输入 | v0.3 输入 |
| --- | --- |
| request 的 instructions/messages/tools | request 的单一 transcript |
| builder addInstruction/addMessage/addTool | setInitialContext/setTranscript，然后 append/appendMessage |
| 当前全部工具每轮重新赋值 | 初始定义池 + 保留发生位置的声明/激活/撤销 |
| tools=true 推断全部工具变更 | 独立 context-update capability + endpoint profile + dialect 契约 |
| 以最后工具集合校验整段历史 | 逐时点 active 定义校验历史；validateReplyToolInputs(reply, transcript) 校验新回复 |
| 任意旧 JSON 会话快照 | 只读写 llm4cj.transcript version 1；其他版本失败 |

静态输入也先构造 `LlmWireInitialContext`/`LlmWireTranscript`，所有 message 作为 Message 输入项。`LlmWireTool` 本身仍保存 name、description 和 inputSchema；定义版本及 deferred 状态在 `LlmWireToolDeclaration`。模型生成选项仍属于 request；streaming 仍属于 encode 操作。

Axyndra 的适配边界如下：

1. 每个会话基线建立一次 initial context。宿主发现工具时 append ToolDeclaration；Anthropic reference contract 只能激活在池中已声明的定义。不要把当前全部发现工具重写到 initial context。
2. 把 instruction 更新、工具变化和普通消息写成不同输入项并保存位置。调用/结果继续使用 canonical ToolCall/ToolResult；thinking/native replay 保持来源与顺序。
3. 持久化新 snapshot。旧会话迁移由 Axyndra 在显式迁移步骤处理；库不能猜测旧数据的历史更新位置。未知版本走明确失败通道。
4. 请求准备前校验 profile 绑定的 endpoint/model/contractVersion；准备失败不发网络。网络层只使用 materialize 的 bytes/headers，避免丢弃 beta。服务端拒绝不触发 collapse、换协议/模型或删更新重试。
5. 对生成 reply 调用 `validateReplyToolInputs(reply, transcript, mode:)`，所有模式都验证工具在请求末端有效。撤销之前的历史调用保持原定义；已观测 usage 在失败路径进入 Axyndra 原计费记录，unknown 不补零。

该仓库的 external consumer 是本契约的编译/运行样本。[Axyndra 适配补丁](../support/axyndra/README.md) 新增 ProviderTranscriptExchange/ProviderTranscriptPort，直接接收一份 `LlmWireRequest` 并保留原 transcript，通过现有 credential/transport 边界发送；它没有重试或 provider fallback。现有静态 ModelRequest adapter 仍只表示初始上下文，无法恢复旧历史中已撤销定义的位置时明确失败。补丁的本地编译/离线 mock 证据不证明远端 Axyndra 已合入；Thread/SQLite、Skill、审批与工具执行策略不由库修改。

发布前需要当前 candidate 的本地门禁、coverage、API/fixture baseline、远端 CI、真实 provider smoke 与 consumer evidence。固定消费请使用实际发布的 v0.3.0 对应 tag，或已合入且通过对应门禁的完整 40 位 commitId。当前恢复候选尚无新的已验证发布 tag/commit；不要把浮动 main 或不可用的先前提交当作固定版本。

```toml
[dependencies]
# 将占位符替换为实际经过验证的完整 commit SHA。
llm4cj = { git = "https://github.com/lIlIIlIll/llm4cj.git", commitId = "<verified-full-40-character-sha>" }
```

详细不变量与原生能力矩阵见 [ADR](adr/0002-ordered-transcript.md) 和 [有序 transcript](ordered-transcript.md)。
