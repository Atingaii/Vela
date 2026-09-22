# README 配图

- `vela-hero.png`：Vela 品牌头图，使用内置 imagegen 生成；不是应用截图。
- `usage-panel.png`：当前 `src-tauri/ui/notch.html` 的浏览器渲染。灰绿底色和「演示数据」标签仅用于文档展示，不修改产品源文件。
- `accounts-settings.png`：当前 `src-tauri/ui/settings.html` 的账户页浏览器渲染。
- 截图基于 `63fef23` 的产品界面，使用 `demo-bridge.js` 中的模拟账户、额度与会话，不读取真实凭据，不访问供应商。
- 配图不能作为 macOS / Windows 原生行为或真实账户验收证据。供应商图形直接来自仓库，来源见 [图形说明](../../../src-tauri/glyphs/NOTICE.md)。

## 截图复现

在仓库根目录安装依赖后，启动 `npm run preview`。另一个终端中准备图形 fixture：

```sh
mkdir -p output/playwright/vela-readme
node --input-type=module <<'JS'
import fs from 'node:fs';
const glyphs = Object.fromEntries(['claude', 'codex', 'cursor'].map(id => [id, {
  kind: 'svg', scale: id === 'claude' ? .97 : 1,
  svg: fs.readFileSync(`src-tauri/glyphs/swift/${id}.svg`, 'utf8')
}]));
fs.writeFileSync('output/playwright/vela-readme/glyphs.js',
  'window.__README_GLYPHS__=' + JSON.stringify(glyphs) + ';\n');
JS
npx --yes --package @playwright/cli playwright-cli -s=vela-readme open http://127.0.0.1:4173 --browser chrome
npx --yes --package @playwright/cli playwright-cli -s=vela-readme run-code --filename docs/assets/readme/capture.js
npx --yes --package @playwright/cli playwright-cli -s=vela-readme close
```

需要本机安装 Chrome。脚本会覆盖两张文档截图；演示桥接仅由截图脚本注入，应用本身不会加载。截图完成后停止预览服务，并仅清理本次生成的临时 fixture 与 CLI 日志。

## 头图生成提示词

工具：内置 `imagegen`，未使用 CLI/API fallback。

```text
Use case: logo-brand. Create a finished premium open-source software README hero banner for Vela, a quiet desktop companion that shows AI coding tool usage and activity at the screen edge. Wide 2.5:1 composition, approximately 1800 by 720. Restrained contemporary Swiss graphic design, unusually clean and beautiful, dark warm charcoal #202326 with very subtle paper grain, ivory #f5f3ed and muted mint #69c8b3. Main subject on the right: a large sculptural abstract letter V made from two folded sail-like surfaces in matte ivory and mint, precise crisp edges with gentle directional light, a tiny triangular mint sail above its upper right. The left half has generous negative space and a large perfectly legible ivory wordmark "Vela", beneath it smaller exact text "Your AI workflow, at a glance." Only these two texts. Subtle thin circular arcs subtly imply a usage meter behind the sculptural V. Minimal composition, editorial software identity, not flashy, no neon glow, no purple gradients, no robots, no stars or sparkles, no fake application UI, no other provider logos, no watermarks. Fill entire banner edge to edge without frame. This is a brand illustration, not a product screenshot.
```
