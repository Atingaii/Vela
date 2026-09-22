# 实现边界

差距位于官网信息结构和静态head资源，不在桌面应用。维持纯静态HTML/CSS/JS与现有CF部署；不引入框架、后端或桌面重发包。

首页 / 保留介绍与截图，提炼下载CTA；/download/承接三个已发布安装包；/guide/承接上手步骤与FAQ。共享现有样式，静态页头保持一致，使用aria-current。页脚承接GitHub、更新记录及许可。

旧hash用已有app.js作精确兼容跳转；保留无JS时的首页相关CTA锚点。CF旧路由转向实际新页面，避免/download/*原规则吞掉新页面。新增sitemap项目、独立canonical/meta。favicon使用现有SVG图形等比例转换为32px PNG、16/32/48 ICO与180px Apple icon；不重画品牌。

首屏示意通过HTML/CSS直接绘制桌面工作区、额度圆环与详情卡，避免放大位图产生模糊。三个按钮展示静态示例状态，hover/focus/click统一更新详情，aria-pressed明确当前项；不调用供应商API。原始截图与品牌素材仍保留。
