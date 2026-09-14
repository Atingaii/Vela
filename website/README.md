# Vela website

The official site is a static HTML/CSS/JavaScript application. It has no package dependencies, client analytics, account system or runtime build step. The 32 bilingual pages are deployed as static files. Product examples are explicitly marked as fictional.

Preview from the repository root:

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory website/dist
```

Open `http://127.0.0.1:4173`. Validate links and JavaScript with `python3 scripts/check-repository.py`.

`dist/` contains the deployable source. Cloudflare Pages project `velo` hosts the production target `https://velo.codes`. `wrangler.toml` declares the output directory; no build or Worker runtime is needed. `.openai/hosting.json` retains the historical Sites binding and is outside the deployed directory. The two hosts are not automatically synchronized.

## Deploy to Cloudflare

Use the Cloudflare account that owns `velo.codes`. One-time authentication uses the official CLI; credentials stay in the OS keychain, outside this repository:

```sh
npx --yes wrangler@4.131.1 login --scopes account:read user:read zone:read pages:write --use-keyring
```

Validate from the repository root, then deploy from this directory:

```sh
python3 scripts/check-repository.py
cd website
npx --yes wrangler@4.131.1 pages deploy dist --project-name velo --branch main
```

The custom domain must be associated with the Pages project, not just pointed at its `pages.dev` hostname. Do not change nameservers or unrelated DNS records. Deployment is explicit; a GitHub push alone does not publish the site. Stable asset URLs use `Cache-Control: public, max-age=0, must-revalidate`, so browsers validate cached files after updates.

Verify from the repository root after a deployment:

```sh
python3 scripts/verify-cloudflare-site.py --origin https://velo.codes --output output/parity/cloudflare-production.json
```

If the local Python installation has no default certificate bundle, set `SSL_CERT_FILE=/etc/ssl/cert.pem` for that command on macOS, provided that system CA file exists. Keep certificate verification enabled. The verifier covers all 32 pages, their referenced resources and local navigation targets; browser interaction testing is separate. Current deployment evidence is in [the production record](../docs/parity/cloudflare-production-evidence-2026-09-14.json).

## 中文说明

官网通过 Cloudflare Pages 项目 `velo` 部署到 `https://velo.codes`，目录为 `dist/`，无需构建、Worker 或付费服务。先从仓库根目录验证，再进入 `website` 执行上述部署命令。Cloudflare 凭据保存在系统钥匙串，不能提交到 Git。名称服务器及无关 DNS 保持不变，旧 Sites 配置保留但不自动同步；GitHub 推送本身不会触发官网发布。

UI changes follow the current direct-authoring authorization in the root `AGENTS.md`. Keep download links pointed at published GitHub releases and product claims consistent with `docs/status.md`. Do not publish internal prompts, synthetic examples as measurements, or user session data.

Product, integration and catalogue content is maintained in `scripts/build-website-catalogue.py`. Run it from the repository root after editing the bilingual copy; review the generated `website/dist` diff. Existing detailed scenario pages remain editable static HTML. Run `node scripts/test-website-browser.mjs --dist website/dist --output output/playwright/<new-directory>` with the repository browser test dependencies installed.
