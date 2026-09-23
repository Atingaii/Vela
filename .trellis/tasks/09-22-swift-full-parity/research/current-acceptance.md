# 当前验收门槛（持续更新，不是完成证明）

固定基准：`vinzdg/codenotch@117a38b8edae2ebd0944bc86b8760c6381685345`。用户要求首先完整迁移，再验收，再完成第 1 项边缘插件；不改变 UI 设计和业务语义。

## 剩余实现与负责范围

| 范围 | 当前明确剩余 | 负责人 |
| --- | --- | --- |
| 默认供应商调度 | 内置默认账户补活跃 60 秒 / 空闲 300 秒、额度 reset 边界；保留独立在途请求、关闭代次和原版 Claude 续期边界 | notch_parity |
| Devin 凭据 | Devin Desktop 优先身份、CLI 空白和请求契约 | notch_parity |
| 用量展示 | Gemini API 总月 / 总日 / 来源月窗口、预算和账户元数据；Devin 金额分组与 cents；Copilot 标签；CommandCode 无计费状态 | settings_parity；共享调用层由 notch_parity 接线 |
| 原生 Windows 入口 | App Paths 所属应用解析；任务栏代理与设置显隐原生 smoke；Grok / Kimi 进程与真实文件持有检查 | update_flow / settings_parity，root 验收 CI |
| 自动更新与发行 | 真公钥和独立 feed；自动下载、下次启动安装；开关/代次取消；三平台签名产物与原子 feed 发布 | update_flow；root 密钥、发行与隔离升级验证 |
| 最终视觉 / 官网 | 解锁后的固定 fixture 四边、设置逐页、材质与菜单交互；据真实软件截图同步官网、README 与下载说明 | root 复核；实现交 GPT-6-Sol High |

以上只列已定位的剩余差异，不豁免全量 `docs/migration-parity.md` 的最终检查。新发现必须按具体源文件和可复现场景加入，而不是仅因缺少同名函数而重写。

## 已完成的本轮检查边界

- `882093e` 的 macOS / Windows / browser CI 全通过。
- `d132ff1` 对应 CI `35817407268` 的 macOS / browser 通过，Windows 在 Tauri 原生窗口 API 的 feature gate 处编译失败，尚未执行新的活动测试。已补 Windows 限定的 feature，待新提交 CI；不复用旧 CI。
- 后续本机 Cargo 340 + helper 1 通过，3 ignored；Chromium / WebKit 各 55 通过。
- 新 debug binary 在本次隔离 `com.atingaii.velo.parity` app 中实际 WebView/IPC smoke 成功，未覆盖正式应用，未启动账户采集。
- Mac 仍锁屏；当前不能更新原生视觉验收结论。既有截图保留具体版本和场景，不能改名当成新实现证据。
- Kiro CLI/API enrichment 与独立 429 退避已完成离线验证；音频合法静音文件和坏文件均经过真实 AVAudioPlayer 初始化测试，不播放声音。Node 18/18 通过。
- 真实账号只额外验证本机 Codex 只读额度调用；其他真实账号 / Windows 人工体验未由离线 fixtures 代替。

## 发布门槛

1. 当前剩余源码行为闭合，针对固定源逐项复查。
2. 对应提交的全量本机检查和原生 CI 通过；真实 DMG / NSIS 安装后 smoke 留存报告。
3. macOS 签名完整性与 Gatekeeper / Apple 公证分别报告。用户没有 Apple Developer 账号，发行明确标为未公证预览，并给出系统设置中单独允许该应用的步骤，不关闭系统保护。
4. 验证真实包签名、篡改拒绝、隔离旧版本到新版本的更新路径。旧公开包没有有效 updater 公钥，需要用户重新安装，不能宣称它会自动更新。
5. 视觉与交互对照未通过前，不宣称“完全一致”或开始边缘插件验收。
