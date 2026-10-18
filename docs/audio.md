# OpenAI Chat 音频输入、输出与续传

使用 OpenAI Chat Completions 的 typed audio blocks，可以保留音频 bytes、转写、格式和续传所需的 ID/过期时间。应用负责读取有效媒体、HTTP、音频播放/转码和时钟。llm4cj 不解析媒体容器，也不为 PCM16 推断采样率、声道或字节序。

## 选择 capability

音频只支持内置 `openai.chat.v1` dialect。应用按实际模型声明 capability；声明本身不代表 provider smoke 已通过。

| 方向 | 格式 | 额外条件 |
| --- | --- | --- |
| user 输入 | WAV、MP3 | `input.modalities` 含 Audio，且 `audio.inputFormats` 明确允许 |
| 固定输出 | WAV、MP3、AAC、FLAC、Opus、PCM16 | `audio.fixedOutputFormats` 明确允许 |
| SSE 输出 | WAV、MP3、AAC、FLAC、Opus、PCM16 | `audio.streamOutputFormats` 明确允许 |
| assistant 续传 | 完成的音频 ID | 独立的 `audio.assistantReplay=true`，相同 provider/requested model，未过期 |

`LlmWireAudioVoice` 包含 Alloy、Ash、Ballad、Coral、Echo、Fable、Nova、Onyx、Sage、Shimmer、Verse、Marin、Cedar。请求必须同时属于这个已知 voice 集合和 profile 的 `audio.voices`。没有默认 voice，不接受任意字符串或 custom voice 对象。

完整可编译的公开 consumer 见 [`support/provider_probe/src/audio.cj`](../support/provider_probe/src/audio.cj)。其中 `audioProbeCodec` 展示格式、voice 和 replay capability，`audioProbeRequest` 展示 user text/audio 的有序输入。fixture 使用合成 bytes，仅测试 wire；发送实际请求时请替换为有效 WAV/MP3。

## 编码与解码

1. 用 `LlmWireAudioInputBlock.fromBytes(format, bytes)` 构造输入，把 `LlmWireBlock.AudioInput` 放在 user message 的准确位置。工厂复制输入 bytes，拒绝空输入和其他格式。
2. 用 request 的 `audioOutput: Some(LlmWireAudioOutputOptions(format, voice))`，或 builder 的 `setAudioOutput`，显式选择输出。编码前会验证完整请求，输出与 structured output 的组合会被拒绝。
3. 保存 `prepared.responseContext`。将它通过 `responseContext: Some(context)` 传给固定解码或 SSE decoder。格式来自原请求；响应中的实际 model alias 仍原样保留。纯文本的既有解码不需要 context。
4. 读取 `LlmWireOutputBlock.Audio`。`bytes` getter 返回独立数组，`transcript` 属于音频块，不会额外复制成 Text block。普通 message content 先保留，音频块位于最后。

固定终态和 SSE `[DONE]` 都要求实际观测非空 ID、data 字段、transcript 字段与非负 `expires_at`。空 data/空 transcript 与字段缺失不同：空值可以表示，缺失会拒绝。`stop` 可产生 Complete；`length`、`content_filter` 保留 Incomplete outcome 和 Partial 音频，不能续传。

`extractStructuredOutput` 会拒绝包含音频的 completed choice，即使调用方另行传入 JSON request 且 text 恰好是合法 JSON，也不会将音频悄悄忽略。音频与缓存位置共用 snapshot v3，但显式 cache breakpoint 仍只支持 Anthropic；Chat 音频可使用既有 OpenAI 自动缓存选项。

SSE 可以在 choice 已结束后发送只含 `audio.expires_at` 的更新；`finish_reason` 省略或 null 均可。该更新不会重复结束 choice，仍需等待 `[DONE]`。非 null 的重复 finish reason、expiry 后的音频数据或缺失终态元数据会失败。

## Base64 framing 与限额

每个 JSON `audio.data` 字段必须是一个完整、规范的 RFC4648 base64 segment。库逐字段校验和解码，再按顺序拼接 bytes；带 padding 的独立 segment 可以连续出现。跨 JSON 字段拆分 base64 quantum 的 framing 明确不支持。空白、URL-safe alphabet、非法 padding 与非零 padding bits 均拒绝。

这是本版本明确支持的 wire 子集。官方 schema 将 data 描述为 base64 音频 bytes，没有保证跨字段 base64 fragment 的行为；离线 fixtures 不构成对 provider 实际 SSE framing 的观测。HTTP/网络 chunk 可以任意拆开 UTF-8、JSON、base64 或 SSE 行，decoder 会先完成 transport framing。

每个输入请求和每个输出响应的 decoded audio 总量最多 4 MiB，包括所有 message/choice。解码先检查编码长度、padding 与累计 bytes，再分配 decoded 数组。SSE 同时受 total semantic、retained state、block、event 和 framing 限额约束。snapshot/完整请求仍受 8 MiB JSON 限制。

## 续传与持久化

只从完成的 reply/choice 调用 `toContinuationInput` 获取 `AudioReplay`。token 的构造封闭，保留 provider、请求 model、格式、ID、bytes、转写、expiry 与原块位置。它只能位于 assistant message 的原始最终位置，前缀只能包含普通 Text；重排或混入 ToolCall/native block 会被拒绝。发往 OpenAI 的 replay 只编码 `audio:{id:...}`，不会上传旧输出 bytes。

在即将发送时调用 `prepared.materialize(nowEpochSeconds: Some(now))`。`now` 是应用提供的非负 Unix 秒数，必须严格小于请求中每个 replay 的 expiry。库没有隐式实时时钟，也不会让 requirement resolver 代替过期检查。

含音频的 transcript 写 snapshot version 3；无音频继续写 version 2。恢复支持 version 1/2/3，校验 v3 音频字段、framing、预算、角色与位置；不会把缺少的 metadata 或 Partial 输出提升为可续传 token。

## 离线证据

[`fixtures/audio/openai-chat.json`](../fixtures/audio/openai-chat.json) 按官方 schema 手写 request、fixed、SSE 和独立 oracle，标记 `schema_derived:true`、`live:not_run`。已构建 consumer 后，在仓库根运行以下比较：

```sh
python3 support/provider_probe/check_audio.py \
  support/provider_probe/target/release/bin/main fixtures/audio/openai-chat.json
```

脚本比较六种格式的完整请求、固定与三种网络 chunk 宽度的 canonical reply、usage、continuation、snapshot 恢复和再次编码；不会从 candidate 输出更新 oracle。

协议依据核对于 2026-10-18：[音频指南](https://developers.openai.com/api/docs/guides/audio-chat-completions)、[Chat create schema](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)、[SSE audio delta schema](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events)。这些支持 schema-derived 验证；六种格式的真实媒体播放与 provider 网络调用尚未执行。
