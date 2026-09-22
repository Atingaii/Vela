# macOS 分发信任检查

## 范围与触发

发布或核查 macOS DMG 时使用；独立于原生 WebView / IPC smoke。浏览器/CLI 下载方式影响隔离属性，不能以直接运行代替系统信任。

## 命令

`node scripts/assess-macos.mjs <app> <report.json> [--allow-unnotarized-preview]`

只读执行 codesign verify/display、spctl assess 与 stapler validate。只支持 macOS，报告父目录须存在。

## 输出契约

JSON 布尔值：`integrity`、`developer_id`、`gatekeeper_accepted`、`notarization_ticket`、`ready_for_default_open`、`preview_exception`。`checks` 保存各命令的 status/output，超时或启动失败 status 可为 null。

`ready_for_default_open` 仅在全部四项通过时为 true。`GITHUB_STEP_SUMMARY` 若存在则追加明确结果，不写凭据。

## 退出矩阵

| 情形 | 默认退出 | 显式预览例外 |
| --- | --- | --- |
| 全部通过 | 0 | 0 |
| 完整 ad-hoc、无系统信任 | 1 | 0，但 ready 为 false 并发出 warning |
| 签名完整性失败或命令未运行 | 1 | 1 |

## 好 / 基本 / 坏示例

好：Developer ID、spctl、stapler 全通过并保留报告。基本：明确未公证预览，附报告与首次单独允许步骤。坏：默认系统信任不通过，却以 smoke 全绿宣传默认安装可用。

## 测试

`scripts/test-macos-assessment.cjs` 覆盖 ad-hoc、损坏签名、各项命令失败/未完成。`.github/workflows/macos-trust.yml` 下载真实发行包，校验 SHA-256，挂载、复制并严格检查；失败也必须上传报告。预览发布的显式例外不影响此严格核查结果。

## 错误与正确

错误：codesign 返回 0 就声称「用户下载后直接打开」。正确：codesign 完整性与 Gatekeeper、公证分别记录；只有 ready 为 true 才作此声明。不得清除 quarantine 或关闭安全策略制造通过。
