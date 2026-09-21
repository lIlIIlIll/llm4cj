# ADR 0002：采用有序 transcript 表达请求上下文

- 状态：已接受
- 日期：2026-09-21

## 背景

请求同时维护 instructions、messages 和 tools 三个平行集合时，工具声明、指令变化与模型输入的相对位置无法表达。不同 provider 对中途更新的 wire 语义也不同：支持完整声明追加、引用激活/撤销或仅支持静态上下文的协议不能被同一个末端工具列表安全替代。

## 决策

1. `LlmWireRequest` 只接受一个 `LlmWireTranscript`，generation options 仍是 request 字段。
2. transcript 由不可变 initial context 和有序 `LlmWireInputItem` 组成。所有工具引用必须精确匹配 name/version；定义变化必须显式使用 replacement。
3. transcript 的公开数组通过 defensive copy 暴露；`LlmWireJson` 继续以 canonical String 作为不可变 JSON 表示。
4. builder 只追加 item。完整语义在 build 和 codec encode 时按顺序重放，工具 active view、调用/结果配对和更新位置由同一次验证决定。
5. transcript operation 通过 profile 绑定的 endpoint、contract version 和 capability entry 映射到 provider encoding。缺少明确映射、profile 或 requirement 时返回 Unsupported；不得 collapse、伪装文本、换协议或静默删除历史。
6. snapshot v1 的顶层格式固定为 `llm4cj.transcript`，只接受明确字段和可重放 block tags；未知版本、字段、tag、部分 tool arguments 或部分 native replay 均拒绝。
7. breaking cutover 删除 separated-input request builder 和旧 request 入口。消费者负责保存/迁移 versioned transcript snapshot；llm4cj 不读取消费者数据库。

## 时序不变量

- 初始声明先形成 declaration pool；相同 identity 的重复声明保留 transcript item 但只产生一次有效 wire 定义。
- 相同 name 的 schema、description 或 version 变化必须由显式 replacement 表达。
- activation、deactivation 和 replacement 均按发生位置生效；未声明、已激活或已撤销引用返回结构化错误。
- context update 不能插入未关闭的 tool call；并行调用只能由同一个合法 tool-result message 完整关闭。
- 历史调用绑定发生时的 active name/version，不得由 transcript 末端工具集合重写。

## Provider mapping

- OpenAI Responses：初始 context 使用静态 input/top-level tools；受 capability 允许的 declaration/update 使用 `additional_tools`，不伪造 tool search 回合。
- Anthropic Messages：初始 tools 位于顶层；受 capability 允许的 system update 使用 system text、tool reference 和对应 beta header。
- Kimi Chat：初始 tools 位于顶层；受明确 Kimi K3 profile 允许的动态完整声明使用 tools-only system message。
- 未验证的 endpoint、model、contract version 或缓存能力保持 Unsupported/Unknown。

## 后果

这是 v0.2.0 的 breaking API。静态请求也必须通过 initial context 加 Message item 构造；消费者需迁移构造、continuation 和持久化边界。wire codec 可以保持已有静态布局，但不能把时序能力从 provider 名称或 URL 推导出来。
