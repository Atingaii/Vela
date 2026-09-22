# Velo 官网

源码：`website/`，无需构建。使用原站的白色网格、大标题、黄色按钮和深浅主题，内容为当前桌面额度与活动产品。自托管字体及 OFL 从仓库原网站历史恢复。

本地预览：`python3 -m http.server 4174 --bind 127.0.0.1 --directory website`。

部署至既有 Cloudflare Pages `velo`，域名 `velo.codes`：

```sh
wrangler pages deploy website --project-name velo --branch main --commit-hash <提交SHA>
```

需要 Wrangler 4 与 Pages write 权限。根目录 `wrangler.jsonc` 固定项目与输出路径；不使用 Workers 或数据库。部署前确认发布页的三种安装包及 SHA256SUMS 已存在；发布后验证首页、图片、CSS/JS、字体、旧链接跳转、深浅主题和下载地址。

截图使用明确的模拟账户数据，源码与复现说明见 `docs/assets/readme/`。更换预览 tag 时同步 README 与官网的所有下载链接；不可链接尚未通过安装 gate 的资产。
