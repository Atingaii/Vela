# Vela 本轮视觉资产

2026-09-14；内置 `image_gen` 生成，原始输出另保留于 Codex generated_images。采用项目已有品牌与用户提供的截图作为设计上下文；未将概念图作为产品实拍。

## 客户端概念参考

`desktop-brand-concept.png`：内部设计参考，不打包到客户端、不作为官网功能证据。参考当前工作流截图和 Vela 官网截图，探索中性侧栏、橙色重点、语义图标、原生下拉与单行名称的组合。实现保留真实数据和既有功能，使用 26px 标题，未照搬概念图中的大标题、状态、步骤数或虚构搜索字段。

生成提示词核心：1440×1024 macOS engineering workspace; Vela editorial engineering brand; readable 15–16px body; quiet light sidebar and white reading area; warm amber primary creation action; faint header-only technical grid; semantic branch/document/terminal icons derived from actual purpose; single-line title and two-line summary; one contained contextual menu; no hashes/long absolute paths by default; no invented performance figures or feature completeness claim.

## 跨会话记忆插图

原始项目资产：`assets/vela-product-illustrations/01-context-stitch.png`。
官网发布副本：`website/dist/assets/vela-context-stitch.png`。

用途：首页、产品介绍和项目记忆用例，解释为什么需要保留有来源、经审阅的上下文。图片不表示模型自动采纳或自动改进。中英页面复用无内嵌文字的图，标题、说明、alt 分别本地化。

生成提示词：

> One standalone 16:9 editorial illustration for Vela's bilingual engineering website. Pure white background, fine lightly wobbly black hand-drawn pen lines, sparse orange accents, enormous white space; no gradient, shadow, paper texture, corporate PPT diagram or cute mascot. 小黑 is a small irregular solid-black creature with white dot eyes, slender limbs and a serious blank expression. It performs the central action: carefully lifting an orange reviewed bookmark from a fading conversation and stitching it into an open notebook bridging the gap to the next conversation. Only the two simplified conversation windows and the larger notebook. The character is the mechanism, not a spectator. No conveyor belts, fish, toolboxes or stamps. Approximately 50–55% subject, at least 40% empty white space. No baked-in words, title, logo, statistics or automatic-improvement claim; captions remain accessible live bilingual text.

质量检查：白底、少量橙色、角色承担缝合动作、无文字错误、无密集架构；原图 1672×941，约 1 MB。官网以自然比例按需加载，不在客户端加入图片、动画或后台渲染负担。
