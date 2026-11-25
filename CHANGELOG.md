# Changelog

## v1.7.1 (build 111) — 2026-11-25

维护版本。

- 公开联系邮箱 `abuse@yopo.ccwu.cc`：README、SECURITY、CONTRIBUTING、issue 模板与落地页均可找到。
- CI/Release 迁移到 `macos-15`（macOS 13 runner 已退役）。
- 通过公开更新通道完成 1.7.0 → 1.7.1 真实自更新验收。

## v1.7.0 (build 110) — 2026-11-25

首个公开版本。

- 开源，MIT License。
- App 内更新：检查更新、下载安装包、直接更新并重启；启动后每 24 小时自动检查。
- 更新安全：Ed25519 appcast 签名、SHA-256、bundle id/版本/build、代码签名与自签证书叶哈希校验。
- 形态命名对齐：「居中垂帘」占真实菜单栏槽位、固定不可拖，不盖其它图标；「菜单栏胶囊」纯浮层、可直接拖动。
- 插件商店默认源迁移到 GitHub Pages，并自动从旧 WorkBuddy 源迁移。
- 英文界面补齐更新相关文案。
