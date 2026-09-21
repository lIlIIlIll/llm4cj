# 从 v0.1 迁移

v0.2.0 是一次有意的 breaking release，不提供旧 API shim、deprecated forwarding 或旧 snapshot 猜测升级。先重新编译调用方，再逐个迁移 request construction 和 profile factory。

| v0.1.0 形态 | v0.2.0 形态 |
| --- | --- |
| instructions/messages/tools 三个平行 request 字段 | `LlmWireRequest(model, LlmWireTranscript(...))` |
| `LlmWireRequestBuilder` / `newRequestBuilder()` | 删除；使用 transcript constructor 或 `LlmWireTranscriptBuilder` |
| model profile 可省略 transcript identity | 每个 profile 必须传 `LlmWireTranscriptCapabilities(endpointProfileId, contractVersion)` |
| 末端 tools 列表决定所有历史 call | 按有序 item 的时点 active view 校验 call/result |
| tool name-only 操作 | `LlmWireToolRef(name, version)` 精确引用 |
| 固定请求可独立保存 provider native fields | 使用 versioned `LlmWireTranscript.snapshot()`；unknown version/field/tag 拒绝 |
| usage 缺失归一化为零 | None=unknown，Some(0)=observed zero，另有 usage source |
| OpenAI/Anthropic/Kimi 动态更新无统一契约 | profile capability 明确绑定 provider-specific encoding；Unsupported fail closed |

## 迁移顺序

1. 将初始 system/developer instructions 和 tools 放入 `LlmWireInitialContext`。
2. 将每个历史 message 按原顺序包装成 `LlmWireInputItem.Message`；不要排序、合并或折叠 system items。
3. 用 `ToolDeclaration`、`ToolActivation`、`ToolDeactivation` 或 `ToolReplacement` 表达真实时序；只有对应 profile capability 才能编码。
4. 更新所有终态 match，区分 Completed、ProviderFailed 和 Cancelled，并保留 failure usage。
5. 用 `scripts/check.sh`、offline fixtures 和 external consumer gate 验证；provider/cache live evidence 另行记录，不用离线 fixture 代替。

Axyndra 等消费者必须显式迁移自己的 domain conversion、snapshot storage 和 database migration。llm4cj 不读取消费者数据库，也不提供 unrestricted provider-native JSON escape hatch。
