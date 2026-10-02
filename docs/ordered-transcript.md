# 有序 transcript 与动态上下文

v0.3.0 的请求以 `LlmWireTranscript` 保存一份输入事实。`LlmWireInitialContext` 保存初始 instructions 和工具声明池，`LlmWireInputItem` 按顺序保存 Message、InstructionUpdate、ToolDeclaration、ToolActivation、ToolDeactivation。`LlmWireRequest(model, transcript, ...)` 不再接受独立 messages/instructions/tools。builder 先设 initial context 或整个 transcript，再 append 输入项；静态输入使用相同模型。

`LlmWireToolDeclaration` 保存完整 `LlmWireTool`、显式 version 和 deferred 标记。`LlmWireToolDefinitionIdentity` 用名称及版本引用定义。deferred 声明先加入池但不进入 active 视图；激活后才可调用。首次声明、激活、撤销分别要求能力，声明后再调用的时序不能省略。重复同定义声明保持幂等；同名不同定义确定失败。定义替换和池扩展在当前内置契约中不支持。

历史调用按当时的有效定义验证，因此先调用 A、返回结果、再撤销 A 是合法历史。撤销后生成的新调用不能使用 A。`effectiveTools` 只读视图供新回复参数验证使用，不得用它替代逐时点历史验证。参数校验仍使用 `validateReplyToolInputs` 的 Disabled/ValidateSupportedSubset/Strict 三态，不另造 schema 校验器。

原生映射必须同时满足 dialect 契约、model capability 与绑定 model/endpoint/dialect/contract version 的 endpoint profile。配置未证实支持的端点时，不应设置动态能力。即使配置允许，服务端仍可能拒绝；原错误及已观测 usage 必须返回给调用方，库不会改写历史后重试。

| 输入项 | Responses | Anthropic Messages reference contract | Kimi Chat |
| --- | --- | --- | --- |
| 初始 instructions/tools | 初始 instruction/input + 顶层 tools | 顶层 system/tools；deferred 声明带 defer_loading | 初始 system.content + 顶层 tools |
| InstructionUpdate | 同一位置的 system/developer input | 同一位置的 system.content | 独立 system.content message |
| ToolDeclaration | 同一位置的 additional_tools，role developer | Unsupported：新 schema 不在声明池 | 独立 system.tools message，完整 function 定义 |
| ToolActivation | Unsupported | tool_addition + tool_reference | Unsupported |
| ToolDeactivation | Unsupported | tool_removal + tool_reference | Unsupported |

Anthropic 的 update 放在 user turn 后、下一 assistant turn前或 messages 尾端；不得切开 tool_use/tool_result。相关 beta header 由 codec 产生。Kimi system.tools 没有 content 字段，指令与工具更新不合并。Responses 不把新增定义提升到顶层 tools。已发送声明项和 native replay 都按其原位置继续回放。

transcript、嵌套 message/数组/schema 在构建时冻结；修改传入数组或 getter 返回的数组不改变已准备请求。`snapshot()` 返回 `LlmWireResult<String>`，`restore()` 返回 `LlmWireResult<LlmWireTranscript>`；新格式只接受 `llm4cj.transcript` version 1。保存 schema、定义、版本与历史顺序，不保存凭据或消费者运行时状态。恢复校验格式、字段、标签和 native replay allowlist，部分/待闭合历史仍可保存；恢复成功不等于可发送，build/encode 和工具视图重放继续执行时序与能力校验。恢复不自动迁移旧 API 输入。

输入片段不改写有利于 provider 的缓存前缀匹配，仍不保证缓存命中。cache usage 未报告时保持 unknown；明示零不等于缺失。详情及当前未运行的 live 项见 [缓存实验](cache-experiments.md)。
