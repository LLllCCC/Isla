# Contributing

欢迎 issue 和 PR。这个项目是一个 macOS 菜单栏 App，构建只用 Command Line Tools，不需要 Xcode 工程。

## 开发

```bash
./build.sh
open build/Isla.app
./tools/selfcheck.sh --ci     # 编译断言 + 更新 helper + 英文漏翻审计
./tools/selfcheck.sh          # 全量（需要 App 正在运行、dist 里有安装包）
```

- 只支持 macOS 14+；Swift 5 语法。
- 本机只有 CLT 时没有 `@State` 宏，设置页用 `SettingsNav: ObservableObject` 之类的 ObservableObject 规避；新增 UI 不要引入 `@State` 宏。
- 新增用户可见中文文案要同步补 `Resources/en.lproj/Localizable.strings`，然后跑 `python3 tools/i18n-audit.py`。
- 改胶囊锚点/加宽方向时跑 `tools/sim/anchor`；改 appcast/更新校验时跑 `tools/sim/update` 和 `tools/test-update-helper.sh`。
- 不要提交 `build/`、`dist/`、私钥、证书、`.p12`、`*.dmg`、`*.zip`。

## 更新器相关

- appcast 使用单文件 envelope（base64 payload + Ed25519 signature）；公钥固定在 `UpdateService.pinnedPublicKeys`。
- 更新包必须通过：HTTPS、SHA-256/大小、zip 路径检查、bundle id/版本/build、`codesign --verify --strict`、自签证书叶哈希固定。
- 安装 helper 在 `Resources/update-helper.sh`；改它必须跑 `tools/test-update-helper.sh`，并保证失败能回滚旧包。
- 发布流程见 [docs/RELEASE.md](docs/RELEASE.md)。

## PR

- 一个 PR 只做一件事；说明动机、复现步骤、验证方式。
- UI 改动附截图（不要包含个人菜单栏图标、用户名或第三方 App 通知）。
- 不要修改 `com.yopo.isla` bundle id 或安装路径：更新和 TCC 辅助功能授权依赖它。
- 安全问题不要开公开 issue，见 [SECURITY.md](SECURITY.md)。
