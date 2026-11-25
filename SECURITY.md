# Security Policy

## 报告漏洞

请不要在公开 issue 里披露可被利用的漏洞。优先使用 GitHub 的
[Private vulnerability reporting](https://github.com/LLllCCC/Isla/security/advisories/new)，
或发邮件给仓库维护者（见 GitHub 个人主页）。请附复现步骤、影响范围和版本/build。

## 更新信任模型

- App 更新源只允许 HTTPS。
- `appcast.json` 是单文件 envelope：payload 的原始字节用 Ed25519 签名，公钥固定在 App 二进制内（`UpdateService.pinnedPublicKeys`）。
- 更新包还必须通过：SHA-256、大小、zip 路径检查、bundle id / version / build、`codesign --verify --strict`，以及自签证书叶证书 SHA-256 固定。
- 更新器拒绝 build 回退和超过 90 天的 appcast；自动检查不会静默安装，安装前需要用户确认。

## 密钥与凭据

- 仓库不包含任何私钥、证书、`.p12`、商店/更新源凭据。
- 发布用 secrets 只放在 GitHub Actions secrets；本地签名工具默认读取 `~/.isla-store-key.json` / `~/.isla-appcast-key.json`，权限 0600。
- 如果发现密钥泄露，请立即轮换并发布新版本；更新公钥轮换需要旧版本能验证新公钥的过渡方案。

## 插件

插件索引有 Ed25519 签名，但签名不等于代码审计。安装/更新时 Isla 会逐项确认权限；不要安装来路不明的插件。
