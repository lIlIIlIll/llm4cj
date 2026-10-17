# Provider fixtures

这些样本是离线回归输入，不包含凭据或真实用户数据。运行 `python3 scripts/check_fixtures.py` 验证；`--validate-only` 只检查来源、场景和库存。live provider evidence 始终记录为 `not_run`，离线通过不代表 endpoint 兼容性或缓存收益证明。

`manifest.json` 列出每个场景的 dialect、规范来源、核对日期、wire 输入和独立 canonical oracle。`schema_derived` 表示根据规范重建的样本，ID、模型、文本和原生回放数据均为合成值；`official_example` 表示官方示例。只有记录授权、采样日期和脱敏说明的样本才能标为 `authorized_capture`。`checked_at` 是规范核对日期，不是服务端采样日期。

| 稳定 dialect | 完整 fixed/stream 配对覆盖 | 额外协议语义 |
| --- | --- | --- |
| `openai.responses.v1` | 文本、拒绝、工具、reasoning、usage、失败 | assistant phase、消息边界、原生回放 |
| `openai.codex.responses.v1` | 同 Responses | SSE/WebSocket canonical 等价与增量下一请求 |
| `deepseek.responses.v1` | 同 Responses | reasoning content 与 dialect 回放身份 |
| `openai.chat.v1` | 文本、拒绝、工具、usage、失败、logprobs | 多 choice、截断参数分类 |
| `deepseek.chat.v1` | 同 Chat | `reasoning_content` 回放 |
| `kimi.chat.v1` | 同 Chat | `reasoning_content` 回放、Kimi 工具结果编码 |
| `anthropic.messages.v1` | 文本、拒绝、工具、thinking、usage、失败 | signature、后置累计 cache/server-tool usage |
| `deepseek.messages.v1` | 同 Messages | dialect 回放身份与工具结果编码 |

每个 named codec 都执行自己的基线、工具、拒绝、失败和截断场景。完整 Chat 截断参数矩阵及畸形 logprobs 在 OpenAI Chat 上执行，DeepSeek/Kimi 复用同一 fixed decoder、Chat stream decoder 和参数分类器的验证，并另行执行各自的截断完整对象及 logprobs 配对。此复用证明库内共享协议路径，不能当作其他 provider 的真实响应采样。三个 `transcripts` fixture 继续单独声明 endpoint/model/profile 和离线来源，不能代替 fixed/stream 覆盖。

oracle 是按规范及 canonical 契约独立审阅的数据，没有根据 probe 输出自动更新的命令。fixed、stream 每一侧先各自比较完整 oracle，再比较两侧 canonical 结果；保留 blocks/choice 顺序、参数 variant、全部 usage 的 `null`/零、来源、phase、message spans、logprobs 和 native replay snapshot。logprob 字面量使用字符串保留精度；snapshot 中的数字使用精确十进制比较，布尔不等于数字。

流式检查包含完整 buffer、逐字节、3/7 字节、CRLF 和尾 CR 分片；逐字节输入也切开 UTF-8 字符。每次比较完整语义。probe 保存 push 已产生的终态；缺协议终态仍是截断错误。可回放结果经过 continuation、snapshot v2、restore 和再次 materialize，检查恢复后的 snapshot、请求 body 与 headers；拒绝、非法参数或缺少 identity 的投影检查确切错误。畸形输入的 fixed/stream 错误上下文分别有 oracle，共同错误 kind/code 另外比较。

修改 fixture 时先核对来源与预期语义，再编辑输入及 oracle，运行 fixture gate、`scripts/check.sh` 和相关 coverage。fixture contract digest 由契约门禁维护，不能通过删除字段、跳过场景或降低门槛接受 decoder 的错误行为。

`transcripts/` 保存三条有序原生路径的 request goldens。`checked_at` 为核对日期，`profile` 固定 model、dialect、endpoint 与 contract_version，`body` 固定选项及原生项位置，`required_headers` 固定 codec 产生的原生 beta。`evidence: caller_declared`/`live_verified: false` 明确区分离线协议样本与真实服务端证据。完整 fixture digest 同时覆盖这三个文件；公共编码器与负例通过普通本地/CI 门禁执行。
