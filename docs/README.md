# llm4cj 文档

按任务选择入口：

| 目标 | 文档 |
| --- | --- |
| 安装并运行第一个离线程序 | [getting-started.md](getting-started.md) |
| 为 endpoint 选择协议 | [choosing-a-protocol.md](choosing-a-protocol.md) |
| 构造 request、读取 reply | [requests-and-replies.md](requests-and-replies.md) |
| 处理 SSE 与有界 HTTP body | [streaming-and-transport.md](streaming-and-transport.md) |
| 使用 tools、thinking、structured output | [tools-thinking-and-structured-output.md](tools-thinking-and-structured-output.md) |
| 处理错误与容量限制 | [errors-and-limits.md](errors-and-limits.md) |
| 查找所有 public API | [api-reference.md](api-reference.md) |
| 理解组件责任 | [architecture.md](architecture.md) |
| 维护测试、coverage 与 release | [testing-and-releasing.md](testing-and-releasing.md) |

初次采用建议依次阅读“安装”“协议选择”“请求与响应”。维护者再阅读“架构”和“测试与发布”。所有示例默认离线，不需要 provider credential。
