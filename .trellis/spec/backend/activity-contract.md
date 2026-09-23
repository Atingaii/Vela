# 会话活动与账户隔离

## 1. 范围 / 触发

`activity.rs` / `activity/antigravity.rs` → `activity` 事件 / `get_activity` → 刘海与 Phone Link v3。行为来源固定 Swift `AntigravityActivityMonitor`、`ActivitySummary`、`PhoneLinkSnapshotBuilder`。

## 2. 签名

- `Activity { id, provider, state, name, detail, waiting_for: Option<String>, since: u64, queued: u32, focusable: bool }`；`since` 是 epoch 毫秒，新增字段保留默认值。
- `profile_activity(&Profile, &mut BTreeMap<String, Ctx>) -> Vec<Activity>`。
- `activity::antigravity::read(roots: &[PathBuf], now: u64) -> Vec<Activity>`，roots 是账户主目录（其下有 brain / conversations）。
- `phone_link::activity_json(&Activity) -> Value`。

## 3. 契约

Codex profile 的 turns、names 和 rollout 全部从自己的 home 读取，Ctx 按 profile ID 分开。Antigravity profile 只读取自己的 brain；默认账户沿用 Swift 聚合多个安装目录。独立账户活动 ID 加 profile 前缀，不用数组下标。轮询仍为一个线程，每 2 秒采样；profile registry 按固定 Swift AppDelegate 在启动时发现，不新增周期发现。停用的账户不采样，移除/停用账户释放专用数据库连接。

跳回会话时 WebView 只发送稳定会话 ID。后端按当前活动解析 PID，并严格复核采集时的进程出生时间和账户启用状态。`focusable` 只来自实际可定位的来源；固定 Swift 的 Codex/Cursor/Antigravity/Gemini API 不提供 processID，不增加猜测定位。Claude/Grok/Kimi 分别采用自己的来源证据，Windows 进程出生时间以 GetProcessTimes 的毫秒值为准。

Antigravity 每个 root 选最新 transcript，解析后从有效会话中取最新一条；不是先跨 root 选文件。只读最多 64 KiB 尾部，倒序判定 USER_INPUT / PLANNER_RESPONSE / tool response，忽略 bookkeeping。busy 时只读 `conversations/<id>.db` 最新 `steps.status`，2 表示权限等待，不创建或修改第三方 DB。

桌面状态为 busy / waiting / success / idle；优先级 waiting > busy > success > idle。同优先级按 since 倒序。等待原因保留 Question / Approval / Permission，展示使用上游翻译。Phone v3 的 success 映射 idle，等待原因通过 `waitingFor` 保留，未知原因 null。

## 4. 验证 / 错误矩阵

| 输入 | 结果 |
| --- | --- |
| 用户输入 / 工具响应 | busy，超过 60 秒后不再显示 |
| 无工具的最终 planner response | success，9 秒后不再显示 |
| ask_question | waiting / Question，不因超时消失 |
| 写文件工具要求 ArtifactMetadata.RequestFeedback | waiting / Approval |
| busy + 最新 steps.status=2 | waiting / Permission，读取包含 WAL |
| DB 缺失 / 不兼容 / 读取失败 | 保留 transcript 判断，不写入 DB |
| 尾部截断或坏 JSON 行 | 忽略该行，沿用 Swift 倒序解析 |
| 另一个 root 的较新会话已过期 | 仍可显示旧 root 中有效的等待会话 |

## 5. Good / Base / Bad

Good：工作与个人 Codex 使用相同 thread ID 也不会共享名称和活动。
Base：完成在桌面呈绿色脉冲，手机协议输出 idle + Complete。
Bad：从默认 ~/.codex 读取所有账户，或仅凭 transcript mtime 将等待批准显示为工作中。

## 6. 必需测试

两个账户同 thread ID 的名称/来源/稳定 ID；另一账户无 transcript 不借用数据；问题、批准、工具结果、bookkeeping；9/60 秒边界；WAL 中的最新权限状态；多个 root 的过期筛选；64 KiB 上限；手机状态与 waitingFor；浏览器账户隔离、等待/完成颜色、中文原因和排序。

## 7. Wrong / Correct

Wrong：`waitingFor:null` 固定输出；将桌面 success 原样作为手机 v3 状态。
Correct：手机通过专用投影保留等待原因并映射 success → idle。

Claude profile 隔离与 Codex/Cursor 生命周期已有实现及阶段测试；Windows Grok/Kimi 适配、真实客户端与双平台体验仍需按当前检查点验收。本契约不表示全量会话迁移完成。
