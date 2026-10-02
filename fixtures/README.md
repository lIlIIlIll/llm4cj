# Provider fixtures

这些样本是离线回归输入，不包含凭据或真实用户数据。`source` 指向对应 provider 的公开协议文档；`captured` 记录样本最后核对日期。fixture 只证明本仓库对所列 shape 的行为，不代表 endpoint 兼容性认证。

`transcripts/` 保存三条有序原生路径的 request goldens。`checked_at` 为核对日期，`profile` 固定 model、dialect、endpoint 与 contract_version，`body` 固定选项及原生项位置，`required_headers` 固定 codec 产生的原生 beta。`evidence: caller_declared`/`live_verified: false` 明确区分离线协议样本与真实服务端证据。完整 fixture digest 同时覆盖这三个文件；公共编码器与负例通过普通本地/CI 门禁执行。
