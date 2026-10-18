# 请求能力预检

`inspectRequestCapabilities(codec, request, streaming: false)` 返回有界的静态报告。它复用严格请求校验和编码表示检查，一次列出可独立判断的限制，不调用 resolver，也不发送网络请求。

```cangjie
import llm4cj.*

func inspect(codec: LlmWireCodec, request: LlmWireRequest): Unit {
    let report = inspectRequestCapabilities(codec, request, streaming: true)
    for (diagnostic in report.diagnostics) {
        println(diagnostic.featureId + ": " + diagnostic.code)
    }
    println(report.complete)
}
```

诊断的 `kind` 为 `Requirement`、`Unsupported` 或 `Invalid`。每条诊断提供稳定的 `featureId`、错误 `code`、库定义的安全 `message`、`inputItemIndex` 和 `blockIndex`；全局或初始上下文位置为 `-1`。`Requirement` 还保留 `requirementState`：`Unknown` 需要在最终 materialize 时解决，`Satisfied` 仅表示本地声明满足要求，不证明服务端已经验证。

报告使用 codec 已绑定的 endpoint profile。`profileId` 和 `contractVersion` 标识该声明；要检查另一组声明，应通过已有 model-profile 工厂构造另一个 codec。预检不根据模型名称推测能力，也不改写或回退请求。普通 capability 未声明允许时仍返回 `Unsupported`，不会擅自转成可由 resolver 放行的要求。只有对应选项的静态检查通过后才报告其 requirement；其他独立选项的错误不影响该 requirement。

诊断按输入项、block、固定检查次序排列，返回数组是独立副本。严格编码保留首错行为，报告首条不一定等于严格入口首错。无法 replay 的 transcript 会保留结构错误，并继续检查独立选项；需要有效工具状态的检查被跳过，`complete` 为 false。

报告最多保留 128 条和 64 KiB 诊断文本，每条 message 不超过 256 UTF-8 bytes。检查还限制为 100,000 次输入节点、容器元素和检查访问，以及 16 MiB 被检查的字符串或 JSON 数据。预算在复制、解析和扫描前检查；超限时 `truncated` 为 true、`complete` 为 false。结构前提错误优先保留。消息不包含 prompt、schema 内容、凭据、URL、headers 或 cache key。

检查包括 thinking、tools/custom format、structured output、service tier、cache 及 audio 的静态约束，并保留动态声明和 block 的原始位置。cache 的无效目标不会参与其 TTL 顺序或自动缓存冲突推导。初始上下文和全局选项的位置为 `-1`；同一位置的相同 feature/code 合并为一条诊断。

`complete` 只表示本轮静态检查完成。报告不证明实际写出的 body 大小、调用方 headers、resolver 的返回值或 materialize 时的外部条件。应用仍须调用 `encodeRequest` 和 `materialize`，并处理它们的拒绝；报告不提供发送许可。

音频 replay 的时钟由 `materialize(nowEpochSeconds: Some(now))` 显式提供。缺少时钟不会变成可由 resolver 放行的 Unknown；静态报告可能完整且无诊断，而 materialize 仍以 `llm.audio_replay_clock_required` 或 `llm.audio_replay_expired` 拒绝。此新增 API 纳入尚未发布的 v0.3.0，不改变严格发送入口。
