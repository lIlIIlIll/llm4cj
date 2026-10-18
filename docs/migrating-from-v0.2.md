# 从 v0.2 迁移与 Axyndra 消费契约

v0.3.0 是有意的 breaking 变更。旧请求入口删除，没有兼容重载或自动转换。transcript snapshot 读取规则与旧请求 API 的迁移分开处理。

| v0.2 输入 | v0.3 输入 |
| --- | --- |
| request 的 instructions/messages/tools | request 的单一 transcript |
| builder addInstruction/addMessage/addTool | setInitialContext/setTranscript，然后 append/appendMessage |
| 当前全部工具每轮重新赋值 | 初始定义池 + 保留发生位置的声明/激活/撤销 |
| tools=true 推断全部工具变更 | 独立 context-update capability + endpoint profile + dialect 契约 |
| 以最后工具集合校验整段历史 | 逐时点 active 定义校验历史；validateReplyToolInputs(reply, transcript) 校验新回复 |
| 任意旧 JSON 会话快照 | 写 llm4cj.transcript version 2，读取 version 1 和 2；其他格式和版本失败 |
| LlmWireJson.string/array 直接返回值 | 返回 LlmWireResult；显式处理构造限额错误 |
| 只保存 Responses blocks | 同时保存 messageSpans，保留 assistant message 边界与 phase |

静态输入也先构造 `LlmWireInitialContext`/`LlmWireTranscript`，所有 message 作为 Message 输入项。`LlmWireTool` 本身仍保存 name、description 和 inputSchema；定义版本及 deferred 状态在 `LlmWireToolDeclaration`。模型生成选项仍属于 request；streaming 仍属于 encode 操作。

Axyndra 的适配边界如下：

1. 每个会话基线建立一次 initial context。宿主发现工具时 append ToolDeclaration；Anthropic reference contract 只能激活在池中已声明的定义。不要把当前全部发现工具重写到 initial context。
2. 把 instruction 更新、工具变化和普通消息写成不同输入项并保存位置。调用/结果继续使用 canonical ToolCall/ToolResult；thinking/native replay 保持来源与顺序。
3. 持久化 version 2 snapshot。已存在的 version 1 transcript 可直接读取，其 messageSpans 保持为空；库不能恢复旧数据未保存的 message 边界、phase 或历史更新位置。消费者自有的旧会话格式仍需显式迁移。未知版本走明确失败通道。
4. 请求准备前校验 profile 绑定的 endpoint/model/contractVersion；准备失败不发网络。网络层只使用 materialize 的 bytes/headers，避免丢弃 beta。服务端拒绝不触发 collapse、换协议/模型或删更新重试。
5. 对生成 reply 调用 `validateReplyToolInputs(reply, transcript, mode:)`，所有模式都验证工具在请求末端有效。撤销之前的历史调用保持原定义；已观测 usage 在失败路径进入 Axyndra 原计费记录，unknown 不补零。

该仓库的 external consumer 是本契约的编译/运行样本。[Axyndra 适配补丁](../support/axyndra/README.md) 新增 ProviderTranscriptExchange/ProviderTranscriptPort，直接接收一份 `LlmWireRequest` 并保留原 transcript，通过现有 credential/transport 边界发送；它没有重试或 provider fallback。现有静态 ModelRequest adapter 仍只表示初始上下文，无法恢复旧历史中已撤销定义的位置时明确失败。补丁的本地编译/离线 mock 证据不证明远端 Axyndra 已合入；Thread/SQLite、Skill、审批与工具执行策略不由库修改。

较早的有序 transcript 基线为 [b8bd5b6fd41349900a3806212c63f62694379385](https://github.com/lIlIIlIll/llm4cj/commit/b8bd5b6fd41349900a3806212c63f62694379385)，其[实施与证据](issue-27-implementation.md)只对应该提交。该基线不包含本页的 JSON factory 和 snapshot version 2 变更。验证当前候选时固定相应 PR 的完整 head commit；`v0.3.0` tag 尚未发布。

## 处理可失败的 JSON 构造

`parse`、`number`、`string`、`array` 和 `object` 返回 `LlmWireResult<LlmWireJson>`。`nullValue` 与 `boolean` 仍直接返回值。以下完整程序检查 string 与 array 的结果：

```cj
package llm4cj_json_migration

import llm4cj.*

main(): Int64 {
	let text = match (LlmWireJson.string("hello")) {
		case LlmWireResult.Ok(value) => value
		case LlmWireResult.Err(_) => return 1
	}
	let array = match (LlmWireJson.array([text, LlmWireJson.boolean(true)])) {
		case LlmWireResult.Ok(value) => value
		case LlmWireResult.Err(_) => return 1
	}
	if (array.values()[0].stringValue() != Some("hello")) { return 1 }
	println(array.stringify())
	0
}
```

输出为 `["hello",true]`。限制按转义后的完整 JSON 计算：一个独立合法的子值，放进 array 或 object 后仍可能超出 8 MiB 或 256 层。构造失败时处理 `Err`，不要以空值替代。

## 保留 Responses 消息边界

`LlmWireChoice.messageSpans` 与 `LlmWireMessage.messageSpans` 保存 `LlmWireAssistantMessageSpan(blockStart, blockCount, phase:)`。继续对话时使用 `toContinuationInput` 返回的完整 message，再包装为 `LlmWireInputItem.Message` 追加到 transcript；不要只提取 `blocks` 重建 message。

OpenAI Responses 与 Codex wire 接受缺失或 null phase、`commentary`、`final_answer`，对应 `Unspecified`、`Commentary`、`Final`。旧 wire 别名 `analysis`、`final` 不再视为 OpenAI phase。相邻同 phase message 仍有独立 span；version 1 恢复后的空 spans 不代表边界已恢复。

## 校验工具参数的值语义

schema 的 `integer` 现在按数学值判断：`1`、`1.0`、`10e-1` 都是整数。`enum` 对象忽略键顺序、数组保持顺序，数值使用精确十进制比较；布尔值与数值不同。无需将大整数或指数转成浮点数。`Disabled` 仍只关闭 schema 校验。

在截断终态中，最终工具参数若是完整 JSON object 则为 `Complete`，合法非对象为 `InvalidShape`，非法或未闭合 JSON 为 `InvalidJson`；choice 仍为 `Incomplete`。只有有效 identity 加 `Complete` 参数能进入 continuation。应用执行工具前仍需按自己的终态策略及 `validateReplyToolInputs` 结果作决定。

## 固定依赖版本

将下列占位值替换为已验收的完整提交 SHA：

```toml
[dependencies]
llm4cj = { git = "https://github.com/lIlIIlIll/llm4cj.git", commitId = "<verified-full-commit-sha>" }
```

详细不变量与原生能力矩阵见 [ADR](adr/0002-ordered-transcript.md) 和 [有序 transcript](ordered-transcript.md)。
