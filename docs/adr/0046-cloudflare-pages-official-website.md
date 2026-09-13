# ADR 0046: Cloudflare Pages for the official website

- Status: Accepted; deployment verification pending
- Date: 2026-09-14

## Context

The user requested the official website on their Cloudflare account at `velo.codes`. The existing website is a buildless static tree: 20 Chinese/English HTML pages and 11 shared assets. It has no server code, database, account service or runtime bindings. The previous public Sites deployment is independent of desktop releases.

## Decision

Deploy `website/dist` directly to Cloudflare Pages, using the `velo` project and the existing domain zone. Keep the static runtime and the GitHub release download destinations. Change canonical and alternate-language metadata to `https://velo.codes` without changing the website's visual implementation. Do not reinitialize the site or change the domain's nameservers.

Use Cloudflare's official Wrangler CLI with Pages write and account/user/zone read permissions. Domain association and its DNS record must be verified in the existing account. Preserve unrelated DNS records. No paid service or Worker is needed for this static website.

`website/wrangler.toml` records the deployable directory and project name. The existing `.openai/hosting.json` retains the historical Sites binding; it is not uploaded as a Pages asset. The two hosts are not automatically synchronized. Public HTML and stable asset names use revalidation rather than an immutable browser cache, so a new deployment does not leave visitors using an indefinitely stale stylesheet or script.

## Alternatives and consequences

- Keeping only Sites would not fulfill the requested Cloudflare account/domain ownership.
- Workers Static Assets could also host this tree, but adds no necessary capability here. Reconsider it if a concrete server-side requirement arises.
- Direct Upload avoids granting Cloudflare access to unrelated GitHub repositories. Deployments remain explicit CLI operations; this decision does not claim that automatic GitHub deployment is configured.

Website deployment does not change the desktop's acceptance state, signing, notarization or published download version. HTTPS, language routes, local assets and canonical metadata require verification against the deployed domain before reporting success.

## References

- [Cloudflare Pages custom domains](https://developers.cloudflare.com/pages/configuration/custom-domains/)
- [Cloudflare Pages Direct Upload](https://developers.cloudflare.com/pages/get-started/direct-upload/)
- [Cloudflare Pages headers](https://developers.cloudflare.com/pages/configuration/headers/)

## 中文说明

官网保留现有纯静态技术栈，采用用户 Cloudflare 账户中的 Pages 项目 `velo`，绑定 `velo.codes`。部署目录仅为 `website/dist`，无需 Worker、数据库或付费服务；名称服务器不变，旧 Sites 绑定保留作历史入口。网页和同名静态资源每次复用缓存前重新验证，避免更新后长期残留旧样式。后续通过 Wrangler 显式部署，尚未配置自动发布。官网上线不代表桌面全功能、签名或公证验收完成。
