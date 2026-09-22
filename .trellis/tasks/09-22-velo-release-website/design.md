# 设计

保留 Tauri 2 + Rust + HTML。外部品牌 Velo；内部持久标识保持兼容，详见 ADR 0007。
GitHub Actions tag v0.1.0-preview.1 触发 release；平台构建串行（Cargo jobs 1、测试线程 1），分别生成 Apple Silicon、Intel 与 Windows 安装包。
用独立 smoke 模式从实际安装产物启动 WebView 并完成页面加载/IPC往返，不启动供应商采集、hook 或读取真实会话；其结果只证明安装启动路径。
官网使用无构建依赖静态 HTML/CSS/JS，部署现有 Cloudflare Pages velo；保留旧站风格而非旧产品能力文案。下载使用固定预览 tag 链接，更新发行时同步。
