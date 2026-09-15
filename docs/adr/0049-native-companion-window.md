# ADR 0049 — 原生伴随窗口与收拢状态

日期：2026-09-15。状态：Accepted（实现与验证见本轮证据，不代表产品总验收）。

## 背景

Blume 1.0.74 的本机观察 N19 确認普通窄窗、可展开悬浮条、取消固定之间的转换。Vela 当前最小900px宽，无法作为伴随工具。普通置顶大窗口不能满足这个任务。用户要求按已核实的流程改造应用框架，同时保持低后台占用和现有完整工程功能。

## 决策

保留同一个 AppKit 主窗口、WKWebView 和 helper；完整工作区与伴随布局共享 DOM、项目、草稿和会话。收拢时隐藏主窗口，用仅含原生控件的 NSPanel 显示入口和真实状态摘要。展开复用原窗口，禁止创建第二个 renderer/helper。

原生 renderer bridge 只新增 `system.window.get` 与 `system.window.set`。前者只接受空参数；后者只接受一个枚举 `action`：workspace、companion、pin、expand、unpin。返回布局、固定/收拢和全屏状态。任意 frame、level、文件路径或代码不能从 renderer 输入。全屏中拒绝改变模式；切屏时约束恢复框到可见区域。模式不写入 Core store，本轮不增加偏好迁移或启动时自动置顶。

## 取舍与边界

- 相比新建第二个 WebView，原生小面板增加少量宿主代码，可保留完整上下文且不复制进程。
- 相比纯 CSS 缩窄，宿主面板可真实收拢、移动与展开；业务视图仍需独立的响应式排版和功能验收。
- 完整工作区容纳 Workflow/Memory/Library/Lab；窄布局提供所有导航，宽表仅在其容器内滚动，不删功能。
- 计数沿用宿主已确认的全局 dashboard，不将未知进程存活推导为真实运行，不新增轮询定时器。
- 关闭窗口保留原有菜单栏行为；退出应用回收小面板、主窗口及 helper。恢复焦点、全屏、多屏与小尺寸应分别验证。

## 重新考虑的条件

只有实际可访问性、窗口焦点、恢复或资源测量证明单 WebView 与原生面板不能可靠满足任务时，再调整窗口结构。不会因视觉需求改成 Electron 或新增常驻服务。

## English

One AppKit window, WKWebView and helper serve both workspace and companion layouts. A native-only collapsible panel preserves context without a second renderer. A narrow enum-only bridge controls presentation; it grants no filesystem, shell or execution capability. Implementation and native lifecycle verification remain separate from this accepted decision.
