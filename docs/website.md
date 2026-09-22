# Velo 官网

源码：`website/`，无需构建。使用原站的白色网格、大标题、黄色按钮和深浅主题，内容为当前桌面额度与活动产品。自托管字体及 OFL 从仓库原网站历史恢复。

本地预览：`python3 -m http.server 4174 --bind 127.0.0.1 --directory website`。

部署至既有 Cloudflare Pages `velo`，域名 `velo.codes`：

```sh
wrangler pages deploy website --project-name velo --branch main --commit-hash <提交SHA>
```

需要 Wrangler 4 与 Pages write 权限。根目录 `wrangler.jsonc` 固定项目与输出路径；不使用 Workers 或数据库。部署前确认发布页的三种安装包及 SHA256SUMS 已存在；发布后验证首页、图片、CSS/JS、字体、旧链接跳转、深浅主题和下载地址。

截图使用明确的模拟账户数据，源码与复现说明见 `docs/assets/readme/`。更换预览 tag 时同步 README 与官网的所有下载链接；不可链接尚未通过安装 gate 的资产。


## 页面与视觉

- `/`：产品概要与当前用量界面截图；页头包含产品说明、使用指南和下载主按钮。
- `/product/`：账户、额度、屏幕位置与通知的详细界面截图和说明。
- `/download/`：平台安装包、首次打开说明与安装步骤。
- `/guide/`：macOS 首次打开步骤、账户配置、外观/提醒、hook 与 FAQ。
- 旧首页 `#download` / `#faq` 精确转到新页面，`/docs` 转到指南。不要恢复覆盖 `/download/*` 的旧跳转规则。

首屏使用当前产品 `notch.html` 截图，不再重绘产品 UI。产品页展示 `settings.html` 的账户、外观、位置、通知；2x 截图不改变软件样式，透明区域由官网画布承托。所有图片标注演示数据，可点击放大或查看原图；对话框支持 Escape、关闭后焦点恢复，手机可滚动查看原始尺寸。截图为浏览器渲染实际 UI，不作为原生系统/真实账号验收证据。

Mac 未公证的首次打开说明必须在下载按钮前可见，不能将签名完整性或直接启动 smoke 宣称为默认系统信任。此限制也在首页、指南、产品页和发布说明中保留。

favicon 从现有 `assets/mark.svg` 等比例转换：根目录 ICO 包含 16/32/48px；`favicon-v2-32.png` 供PNG图标使用，`apple-touch-icon-v2.png` 为180px。新资源名用于避免继续引用旧标签页图标；品牌SVG仍为单一图形来源。所有页面含相同图标声明。
