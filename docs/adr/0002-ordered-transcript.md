# ADR 0002：有序 transcript 与原生上下文更新

- 状态：接受；v0.3.0 breaking 候选。
- 决策日期：2026-10-02（Asia/Shanghai）。
- 跟踪：[issue #27](https://github.com/lIlIIlIll/llm4cj/issues/27)。

## 单一输入事实

`LlmWireRequest` 只接受 `LlmWireTranscript` 作为会话输入。transcript 有一个不可变 `LlmWireInitialContext` 和有序 `LlmWireInputItem` 数组。initial context 保存初始 instruction 及 `LlmWireToolDeclaration` 池；输入项联合只有 Message、InstructionUpdate、ToolDeclaration、ToolActivation、ToolDeactivation。静态请求就是没有后续更新的 transcript。

工具的 `LlmWireToolDefinitionIdentity` 由名称与显式版本组成；工具描述、schema、版本、声明顺序和 deferred 状态属于快照。相同定义的重复声明不再次改变有效视图；同名不同定义不允许隐式覆盖。激活和撤销引用已声明身份，不能顺便声明未知 schema。本版不开放同名替换、延迟池扩展或 Anthropic by-value inline 定义。今后只有专门的原生契约、fixture 与目标端点证据可以开放这些能力。

数组在边界复制，getter 返回副本；schema 使用已有的不可变 `LlmWireJsonSchema`/`LlmWireJson`。builder 是唯一可变构建过程，`build` 后的请求和已准备 bytes 不受调用方改动原数组影响。有效工具视图是顺序重放的派生结果，不能独立设置 `currentTools`。历史调用使用所在时点的 active 定义；回复参数验证使用请求末端的 active 视图。更新不能切开 pending tool call 与对应结果。

`snapshot`/`restore` 只处理 `llm4cj.transcript` 格式 version 1。缺少版本、旧格式与未知版本确定失败；不猜测升级，不读取或改写消费者数据库。native reasoning replay 保持已有来源、协议、签名、完整性与 assistant-turn/order 约束，不能充当上下文更新入口。

## 原生契约

一般 tools 或 prompt-cache capability 不意味着动态能力。`LlmWireContextUpdateCapabilities` 独立声明追加 system/developer 指令、首次声明、激活、撤销、替换、初始延迟池及池扩展。`LlmWireContextUpdateContract` 给出 dialect 的有版本映射；`LlmWireEndpointProfile` 把能力声明绑定到具体 model、endpoint、dialect ID 和 contractVersion，记录 evidenceSource 与 checkedAt。调用方声明是准入配置，不能称为服务端认证。

| 原生路径 | 指令更新 | 运行中首次声明 | 激活/撤销预声明项 | 延迟池 | 同名替换/池扩展 |
| --- | --- | --- | --- | --- | --- |
| OpenAI Responses | system/developer 输入项 | `additional_tools`，role developer | 不支持 | 不支持 | 不支持 |
| Anthropic Messages reference contract | `role: system` 文本 | 不支持 | `tool_addition`/`tool_removal` + `tool_reference` | `defer_loading` | 不支持 |
| Kimi Chat（明确支持的 endpoint/model） | 独立 system.content 项 | 独立 system.tools 项 | 不支持 | 不支持 | 不支持 |
| 其他 Responses/Chat/Messages endpoint | 由具体原生契约决定 | 由具体原生契约决定 | 由具体原生契约决定 | 由具体原生契约决定 | 不推断支持 |

Anthropic 工具引用契约使用 `mid-conversation-tool-changes-2026-07-01` beta；header 随 prepared request materialize，不由 consumer 拼接。指令更新本身不要求此 beta。system update 必须跟在 user turn 后，并在尾端或 assistant turn 前；连续 update 按原顺序保留，provider 将其作为同一连续 system section 校验。Kimi 的 system.tools 与 content 互斥，指令和工具必须分成有确定顺序的相邻原生项。Responses additional_tools 保持 role developer、完整定义和实际发生位置；不制造 tool_search 调用。

文档核对时间为 2026-10-02。Anthropic 已公开 `inline-tools-2026-09-15` 的 by-value 定义/替换，此特定能力需要额外条件与端点证据，因此未纳入 reference contract。Kimi 文档当前把动态工具限定在 `kimi-k3`，不得把其能力推广到任何 Chat Completions 外形的端点。

## 错误与缓存边界

输入错误沿现有 `LlmWireResult`/`LlmWireError` 通道返回。稳定原因包括 `llm.context_update_unsupported`、`llm.context_update_position_invalid`、`llm.tool_definition_conflict`、`llm.tool_reference_unknown`、`llm.endpoint_profile_capability_unsupported`、`llm.transcript_version_unsupported`。本版没有 Replacement 输入项：同名不同定义/版本以 `llm.tool_definition_conflict` 拒绝；profile 声称替换等超出原生契约的能力时，以 `llm.endpoint_profile_capability_unsupported` 拒绝，不增加未实现的专用错误码。诊断只保存有界 item index、工具身份、缺少能力与 profile/dialect 上下文。不能发送已知不支持的请求，也不能删除更新、提升工具到开头、改用消息文本、包装 call_tool、换模型或换协议重试。服务端拒绝保留实际 outcome 和已观测 usage。

确定性编码保证此前模型输入片段及相对顺序保持稳定，不要求整份 HTTP JSON 文本成为上次 body 的字节前缀。该保证不证明 GPU KV 存在、不保证保留时间或命中率。usage 的缺失仍是 unknown，明确的 0 才是零；真实缓存收益只能由逐端点、逐模型、逐选项的重复对照实验支持。

## Breaking 与消费者

删除旧的 request messages/instructions/tools 输入字段和旧 builder addInstruction/addMessage/addTool 入口，不保留重载、旧快照读取或双轨输入。库内支持程序、文档、fixtures、API baseline 与 external consumer 同步迁移。Axyndra 需要单独迁移，库本身不管理 AgentCore、Thread/Run、SQLite、工具执行、审批、Skill、凭据、网络或重试策略。固定消费版本/commit 的规则见 [迁移指南](../migrating-from-v0.2.md)。

## 依据

- [OpenAI Tool search：additional_tools](https://developers.openai.com/api/docs/guides/tools-tool-search#add-tools-at-a-specific-point-in-the-input)
- [Anthropic mid-conversation system messages and tool changes](https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages)
- [Kimi dynamically loaded tools](https://platform.kimi.ai/docs/guide/use-dynamic-tool-loading)

以上为 shape/语义核对来源，不是本候选 commit 的 live 兼容或缓存证明。
