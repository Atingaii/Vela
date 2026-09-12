# 本地构建产物

运行 `bash scripts/package-macos.sh` 生成 `Vela.app`、`Vela-macOS-arm64.zip` 和 SHA256SUMS。

默认开发构建使用本机 ad-hoc 签名，不等于 Developer ID 签名或 Apple 公证。配置 `VELA_SIGN_IDENTITY` 和已有 Keychain 中的 `VELA_NOTARY_PROFILE` 后，同一脚本支持正式签名与公证。不得将签名私钥或账户口令写入仓库。
