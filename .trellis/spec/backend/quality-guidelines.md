# 后端验收

一次只启动一个 Cargo 构建/测试进程：

```sh
CARGO_BUILD_JOBS=1 cargo test --locked --workspace -- --test-threads=1
```

针对解析边界、缺失额度、账户隔离、限流持久化、原子写入失败添加有意义的测试。不得只测试实现本身。改动平台 API 必须通过 macOS/Windows CI；Linux 测试不证明 Keychain、Credential Manager、窗口和托盘行为。

`docs/migration-parity.md` 记录全量差异，不将部分适配标成全量完成。迁移完成前不以 UI 精简为由删除能力。

安装包发布还需运行 `scripts/smoke-installed.mjs <安装后的主程序> <报告>`：只允许显式 `--smoke-test <空目录>`，跳过采集与账户发现，检查实际 WebView、IPC、可见设置窗口与 bundled helper。必须检查真实 DMG / NSIS 的安装产物；模拟 IPC 不可代替该 gate。公开品牌 Velo，但旧配置目录、系统凭据服务和 helper 标识依 ADR 0007 保留。
