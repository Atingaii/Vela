# 当前验收门槛（持续更新，不是完成证明）

**2026-09-23 最新范围优先：当前只推进 macOS（Apple Silicon / Intel）。Windows、Linux 暂缓，等待用户明确启动。** 下方旧记录中的 Windows / 三平台待验项保留为历史，不再驱动当前实施。两类 Mac 原生 CI、实际 DMG 安装与签名升级以及 Swift 原生 UI/交互对照仍为门槛；详见 [ADR 0009](../../../../docs/adr/0009-macos-first-delivery.md)。

当前源码 `eeb5335` 已推送，仅 Mac 的 [CI 35840331022](https://github.com/Atingaii/Velo/actions/runs/35840331022) 的 Intel、Apple Silicon 和 browser 均已通过。报告 `macos-smoke-eeb5335-{intel,arm64}.json` 已核对并入库。文案提交 `6859771` 未改变客户端源码；本机已用该工作树重新构建 debug `.app`（`/tmp/velo-macos-current-visual-build.log`），复制到本次独立 bundle ID `com.atingaii.velo.parity.eeb5335` 后执行真实隔离启动。`macos-smoke-eeb5335-local.json` 记录版本/包版本 0.1.1-preview.1、WebView/IPC/helper/wake=true、providers_started=false、exit 0、无超时。此报告不代表 DMG、系统信任或视觉验收。Mac 仍锁屏，已请求用户手动解锁。

已将 `v0.1.1-preview.1` 标签固定到 `6859771`，触发 [发行检查 35842708336](https://github.com/Atingaii/Velo/actions/runs/35842708336)。发布 job 仍由两类 Mac DMG 安装和启动检查门控；标签存在不代表 Release 或 feed 已发布。官网 `6859771` 平台文案已部署至 Cloudflare（部署 `7d242192`），首页、下载、产品、指南和样式均与本地字节一致；下载仍指向确实存在的旧 `.4`，新链接待资产成功发布后更新。

最新补审：网页登录入口已前移系统能力检查，阻止 macOS 14 以下在创建窗口之前进入持久 profile 清理；保留 ADR 0006 的隔离策略。Rust 383 + helper 1 / 3 ignored 通过，详见 [WebKit 复核](2026-09-23-webkit-profile-capability.md)。该补丁 `6d4f408` 已纳入通过 Mac CI 的 `eeb5335`；`ca25fff` 保留为前一检查点，不混用 SHA。macOS 12/13 的真实网页登录能力门控仍未实机验证。Mac 仍锁屏，原生视觉、真实账号与最终安装包/升级验收继续待完成。

固定基准：`vinzdg/codenotch@117a38b8edae2ebd0944bc86b8760c6381685345`。用户要求首先完整迁移，再验收，再完成第 1 项边缘插件；不改变 UI 设计和业务语义。

## 剩余实现与负责范围

| 范围 | 当前明确剩余 | 负责人 |
| --- | --- | --- |
| 默认供应商调度 | 活跃 60 秒 / 空闲 300 秒、reset 和 Claude running/busy 边界已接，真实 Store 快照回归通过；实际账户边界按总表独立报告 | notch_parity |
| Devin 凭据 | Desktop 优先身份、CLI 空白、请求契约已实现，355 项 Cargo 批次通过 | notch_parity |
| 用量展示 | Gemini/Devin/Copilot/CommandCode 新输出、默认 Reading 去重、稳定 ID DOM 和 Codex extra 即时刷新已通过整合检查 | settings_parity / notch_parity |
| 原生 Windows 入口 | ae7ee93 的原生 Taskbar/Settings/IPC/helper smoke 成功；Grok / Kimi 进程与文件持有在 Windows CI 通过；新整合提交仍需对应 CI | update_flow / settings_parity，root 验收 CI |
| 语言与时间格式 | fr/de/uz、完整语言选择、原译文、macOS 系统时钟和原生菜单/What's New 已补；连续滑块、缺失音效、两处版本号、0.12 秒纯淡入已通过双引擎 | settings_parity |
| 自定义端点 | 源设置流程与定时探测已按本批 source review 补齐，离线 UI / Rust 回归通过；真实服务、文件选择与原生交互待验。userinfo 仍按本项目凭据边界拒绝 | settings_parity；root 原生验收 |
| 网页会话与账户代次 | 退出/切换清理自有 profile、登录后定向刷新、失败分类和旧请求代次门已补并通过离线回归；真实站点登录/退出、切号待验 | notch_parity / settings_parity；root 真实账号验收 |
| 唤醒与实例生命周期 | macOS NSWorkspace、Windows suspend/resume 真 API 订阅及 macOS 旧实例退休源码与单测已补；本批 macOS debug app 实测仅证明订阅注册/注销与 WebView/IPC 启动，实际睡眠恢复和 Windows 新批次 CI 尚待验 | update_flow / settings_parity；root 平台验收 |
| 自动更新与发行 | 真公钥和独立 feed；自动下载、下次启动安装；开关/代次取消；三平台签名产物与原子 feed 发布 | update_flow；root 密钥、发行与隔离升级验证 |
| 侧栏动效 | 源 spin/pulse、reading/contents/glide、数字变化、卡片进出、手柄 merge、keyed cell 和 native 降低透明度已补并通过双引擎；原生同场景视觉待解锁 | notch_parity |
| 最终视觉 / 官网 | 解锁后的固定 fixture 四边、设置逐页、材质与菜单交互；据真实软件截图同步官网、README 与下载说明 | root 复核；实现交 GPT-6-Sol max |

以上只列已定位的剩余差异，不豁免全量 `docs/migration-parity.md` 的最终检查。新发现必须按具体源文件和可复现场景加入，而不是仅因缺少同名函数而重写。

## 已完成的本轮检查边界

- `882093e` 的 macOS / Windows / browser CI 全通过。
- 新检查点 `a4a80dc` 的 CI `35818721637`：macOS 测试、debug app 构建、原生 WebView/IPC smoke 及 browser 已通过；Windows Grok Restart Manager / Kimi ownchild 通过；失败仅平台路径 fixture，已以 `242b3dd` 修正并重新运行 CI `35819584842`。
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

后续整体 Cargo 355 + helper 1、3 ignored 通过（`/tmp/velo-migration-language-update-tests.log`）。设置单独 Chromium/WebKit 各23/23通过；源语言字典逐条比对成功（含品牌别名 fr415/de540/uz628）。此结果尚不包含后续motion、菜单语言、Claude调度与隔离更新验证模式的新改动。

最新整合：Node 23/23 通过（`/tmp/velo-migration-current-node-tests.log`）；更新状态设置专测 Chromium 23/23 通过。全 UI Chromium 59 通过、1 失败：每日份额测试在新增 spring 尚未结束时读取最终比例，正在保留最终语义断言并等待收敛。原版卡片进入/离开、手柄缩放及状态透明度的后续差异尚在闭合，不能把这次结果当作最终视觉验收。

`242b3dd` 的 CI `35819584842`：macOS 原生测试/构建/WebView+IPC smoke、browser 成功；Windows 329 通过、1 失败、4 ignored，唯一失败为 Claude auth 子进程测试使用 PowerShell 启动导致超时。已以 `ae7ee93` 改成真实自有测试进程，保留成功/失败退出码、超时和回收检查，并重新推送；新 Windows 结果待获取。

新隔离更新模式进入 Cargo 后遇到 `updater.rs` 将已有 `semver::Version` 当作字符串再解析的编译错误，已发回实现者定点修复。实际升级验收尚未执行。Windows 更新还需 NSIS 临时安装目录与注册表位置证明，在该边界建立前 runner 明确拒绝执行，不能用复制 exe 冒充隔离安装。

上述类型错误及新增 loopback 测试污染旧共享 fixture 的问题修复后，Cargo 361 + helper 1 全通过、3 ignored（`/tmp/velo-migration-motion-update-rust-tests-final.log`）。包含 Claude 活跃调度、原生菜单语言初批、更新暂存/签名/隔离入口以及真实 Ollama loopback 原文与活动/速度闭环。尚不含后续设置开关立即刷新、连续滑块及剩余 tray/What's New 语言补齐。Windows auth 修复对应 CI 为 `35820700594`，截至本记录浏览器成功、macOS 进行中、Windows 排队。

随后 `35820700594` 的 Windows Cargo、debug 构建、原生启动检查均成功。已下载并保留 `docs/verification/native-parity-2026-09-23/windows-smoke-ae7ee93.json`：真实 Windows taskbar proxy、Settings WebView/IPC、bundled helper 均为 true，providers_started=false，exit 0，无超时。该提交内部版本仍为 0.1.0，不混同当前工作树的 0.1.1-preview.1，也不代表新 signed updater/最终 NSIS 已验收。

最新冻结整合检查：Cargo 362 + helper 1 通过、3 ignored（`/tmp/velo-migration-settings-final-rust.log`）；Node 25/25（`/tmp/velo-migration-integrated-final-node.log`）；Chromium / WebKit 各 63/63（`/tmp/velo-migration-integrated-final-chromium.log`、`/tmp/velo-migration-integrated-final-webkit.log`）。包括连续设置保存、版本及缺失音效、卡片/手柄动画、数字变化、稳定 ID 与降低透明度。当前正在重新构建原生 app，以上仍不能替代原生截图、真实账户或新安装包/签名升级验收。

本批原生 build 已完成，专用 macOS `Velo Parity.app` 的实际启动 smoke 通过：version 与 package_version 均 0.1.1-preview.1，WebView/IPC/helper 成功、未启动采集、exit 0，无超时。报告已入库。桌面工具再次明确返回锁屏，已异步请求手动解锁；继续提交 CI 与安装包检查，不能在解锁前改写视觉验收结果。

2026-09-23 网页会话/自定义端点/生命周期检查点：Rust 369 + helper 1 通过、3 ignored（`/tmp/velo-migration-native-wake-probe-rust.log`）；Node 27/27（`/tmp/velo-migration-web-endpoint-lifecycle-node.log`）；Chromium / WebKit 各 68/68（`/tmp/velo-migration-web-endpoint-lifecycle-chromium-final.log`、`/tmp/velo-migration-web-endpoint-lifecycle-webkit.log`）。逐项来源与实现边界见 [本批 source review](2026-09-23-web-endpoint-lifecycle-source-review.md)。`9eb92d0` 的 [CI 35823934689](https://github.com/Atingaii/Velo/actions/runs/35823934689) 在 macOS / Windows / browser 均为 green；对应 [macOS](../../../../docs/verification/native-parity-2026-09-23/macos-smoke-9eb92d0.json) 和 [Windows](../../../../docs/verification/native-parity-2026-09-23/windows-smoke-9eb92d0.json) 原生报告只验证该旧提交，不包含本批新功能。当前标准 Tauri debug `.app` 已构建，本批实际 [macOS smoke](../../../../docs/verification/native-parity-2026-09-23/macos-smoke-web-endpoint-lifecycle.json) 成功：`wake_subscription=true`、WebView/IPC/helper=true、providers_started=false、version/package_version 均 `0.1.1-preview.1`、exit 0 且未超时。它只证明唤醒 API 可注册/注销与隔离启动，不证明实际睡眠恢复。Mac 仍锁屏；原生逐屏视觉、真实网页登录/账户、Windows 本批原生运行、三平台安装包和真实升级未验。任务不标完成、不归档。

2026-09-23 实例接管最终源码检查：macOS 已改以 NSBundle 包 ID 与内核 `proc` 出生时间 tuple 识别严格更早的实例，避免 LaunchServices 缺失 `launchDate` 时跳过旧进程。`/tmp/velo-migration-instance-final-rust.log` 的全量 Rust 369 + helper 1 再次通过、3 ignored。标准 Tauri debug `.app` 正为此版本重建，上一份 `macos-smoke-web-endpoint-lifecycle.json` 属前一检查点，尚不能证明这次最终重建包；待新的隔离原生 smoke 留证后再更新结论。

最终实例接管源码对应的标准 Tauri debug app 重建成功（`/tmp/velo-migration-instance-final-native-build.log`），重新执行的隔离 smoke 成功（`/tmp/velo-migration-instance-final-native-smoke.json`），已更新上述入库 macOS 报告。唤醒订阅、WebView/IPC、helper 均通过，版本 0.1.1-preview.1，未启动供应商、exit 0、无超时。此 smoke 主动跳过实例接管，不能冒充新旧实例接管的桌面实测。自动更新默认值亦与固定 Swift Info.plist 核对为开启，保留用户显式关闭，无需额外修改。

5176a88 的 CI 35826483051：macOS 原生与浏览器通过，Windows Cargo 360 通过、1 失败、4 ignored。失败为自定义 localhost 扫描测试返回空（日志 `/tmp/velo-ci-5176a88-failed.log`），已在下一批工作树补双栈解析与真实 IPv4/IPv6 回归，Windows 复验尚待新提交。该 SHA 的发行包验证 35826536749 已通过 Apple Silicon DMG 挂载/复制/签名完整性/原生启动；报告 `smoke-package-macos-arm64-5176a88.json` 与 `trust-package-macos-arm64-5176a88.json` 已入库，明确未通过 Developer ID/Gatekeeper/公证，不代表当前未提交的界面修复。新工作树 Rust 376 + helper 1、3 ignored 已通过，日志 `/tmp/velo-parity-controls-geometry-rust.log`。用户新增分级协作采用 `docs/agents/model-delegation.md`，后续 Sol/Luna max；本批旧 Sol High 会话无法原地重配且新 Luna 因环境线程上限未创建，未冒称新模型运行。


最新换边与设置检查点：Rust379+helper1/3ignored，Node27，Chromium/WebKit各84通过。LM Studio断开状态初次失败已修复并保留断言；accounts数量、连续阈值和新页面初始页复核完成。原生包重建中，源审计见2026-09-23-edge-crossing-review.md。Mac仍锁屏，最终视觉/真实账号/新Windows/安装包与签名更新继续待验。


本批最终标准 Tauri debug app 构建成功（`/tmp/velo-parity-crossing-native-build-final.log`），隔离 native smoke 成功：WebView/IPC/helper/wake_subscription=true，providers_started=false，0.1.1-preview.1，exit 0、无超时。报告已保存为 `docs/verification/native-parity-2026-09-23/macos-smoke-controls-edge-crossing.json`。该报告验证启动与订阅，不是锁屏期间的视觉/鼠标/实际睡眠恢复验收。


925ae99 已推送，普通 CI 35830483977 启动。旧5176a88发行验证的 Intel macOS 15在DMG构建/签名校验通过后，隔离原生smoke约1.8秒以foreign Objective-C exception/SIGABRT退出，未生成成功报告；失败日志 /tmp/velo-intel-package-failed-job.log。该旧run35826536749其余过期工作已取消，arm64历史证据仍保留。新增按实际可执行文件及启动时间过滤的崩溃采集，保留异常原因和最后异常调用栈；失败不转为成功。普通CI新增macos-15-intel优先串行验证。诊断脚本Node全套28通过（/tmp/velo-macos-diagnostic-node.log），客户端未改。根因仍待新Intel运行的栈证据，不能因构建成功宣称安装可用。

最新 CI 状态：925ae99 的 [CI 35830483977](https://github.com/Atingaii/Velo/actions/runs/35830483977) macOS 与 browser 成功，Windows 的 IPv6-only 自定义端点扫描失败。并发工作树中的 `custom_endpoint.rs` 已调整为 IPv4/IPv6 双族并发扫描；Rust 380 + helper 1 通过、3 ignored（`/tmp/velo-ipv6-race-rust-full.log`），对应 Windows CI 待验证。当前 `966de00` 的 [CI 35831142333](https://github.com/Atingaii/Velo/actions/runs/35831142333) 在 Intel macOS 15.7.9 再次 SIGABRT；`native-smoke-diagnostic.json` 没有 matching_crashes。Root 正推进隔离 LLDB 诊断；后续源码核对又发现实际 SDK 兼容问题：`NSScreen.CGDirectDisplayID` 仅 macOS 26 可用。当前工作树的 `src-tauri/src/native_notch.rs` 已改为按 Swift 源读取 `deviceDescription[NSScreenNumber]`，并增加真实 `NSNumber` 解析测试；Intel macOS 15 CI 对此修正仍待验证。当前证据不能证明崩溃根因已在 CI 中确认，也不能据此宣称全量迁移完成。

显示器兼容与双地址族修复已提交为 `36f36da`；其新增 cache input 中使用的状态函数被 GitHub 工作流表达式校验拒绝（普通 YAML 语法检查未覆盖此语义），已由 `5eb1f7b` 改为合法的显式缓存输入。新 [CI 35833823218](https://github.com/Atingaii/Velo/actions/runs/35833823218) 已启动，目标平台结果待收取。本机 Rust 381 + helper 1 / 3 ignored、Node 32 和 UI 脚本检查通过；标准 debug `.app` 构建及隔离启动通过，见 `docs/verification/native-parity-2026-09-23/macos-smoke-display-id-36f36da.json`。版本和包版本均 0.1.1-preview.1，WebView/IPC/helper/wake_subscription=true，未启动供应商，exit 0，无超时。仅该源码检查点的 Apple Silicon 隔离启动通过，不代替 Intel/Windows、视觉或真实账号验收。

发行预审另修两项门槛：`publish` 仅接受 tag push，不接受选择 tag 的手动验证；`gh release create` 之前通过 `preview-update-feed.mjs --check` 校验 tag 与 package/Tauri/Cargo 版本及三平台签名资产的完整性。预检不写文件、不访问 GitHub，签名非空不等于加密验签。新增 LLDB 两项 POSIX 进程组生命周期测试在 Windows 跳过，避免不存在的负 PID 语义使测试本身挂死；门槛/解析测试与真实 Windows 应用回归保留。当前 Node 全套 33/33 通过（`/tmp/velo-release-preflight-node-final.log`），生产 LLDB 仍限 30 秒。新增脚本修复待 Intel 证据收取后统一推送，不中断现有作业。

`5eb1f7b` 在 macOS 15.7.9 Intel 的真实 debug `.app` 启动检查已通过：`macos15-intel-smoke-5eb1f7b.json` 记录 x86_64、版本 0.1.1-preview.1、WebView/IPC/helper/wake_subscription=true、providers_started=false、exit 0、无超时。先前的启动 SIGABRT 在该修复检查点没有再出现。上传报告和编译缓存完成后，已推送脚本修复 `29028a3`，旧 run 剩余作业被新 push 取消，不能将旧 run 当作全平台通过。新 [CI 35835575597](https://github.com/Atingaii/Velo/actions/runs/35835575597) 验证整合提交，Windows 与最终包检查继续进行。macOS 12 直接 AppKit/Foundation API 的 SDK 静态补审未发现其它未门控的新 API，仍不代替 macOS 12 实机验证。

`29028a3` 的 Intel 作业在 Node 超时测试中因 heartbeat 尚未生成而失败，未执行客户端；其 Apple Silicon 原生与 browser 已通过，Windows Rust 已通过并在构建应用。`smoke-installed.test.mjs` 的孙进程现立即写递增心跳，测试给 5 秒启动余量，并保留有效 PID、真实心跳、超时后停止增长的断言；生产 45 秒上限与回收逻辑未改。定向三轮各 3/3、Node 全套 33/33 通过（`/tmp/velo-smoke-runner-fixture-full-node.log`）。这项修复是测试启动时序稳定性，不冒充新的客户端启动修复。
