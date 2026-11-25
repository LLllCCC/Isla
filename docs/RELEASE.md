# Isla 发布流程

## 版本号

- `BUILD_NUMBER` 是唯一的 build 号来源（`build.sh` 优先级：`ISLA_BUILD` > `BUILD_NUMBER` > 提交数）。
- 发版前把 `BUILD_NUMBER` 加一，提交，再打 `vX.Y.Z` tag。
- 首个公开版：`v1.7.0` / build `110`。

## GitHub Secrets

在 `Settings → Secrets and variables → Actions` 添加（值只在本机生成，不写进仓库）：

| Secret | 用途 |
|---|---|
| `ISLA_SIGN_CERT_P12` | 自签证书 + 私钥导出的 `.p12`，base64 后一行 |
| `ISLA_SIGN_CERT_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `ISLA_KEYCHAIN_PASSWORD` | CI 临时 keychain 的随机密码 |
| `ISLA_APPCAST_KEY` | `~/.isla-appcast-key.json` 的完整 JSON 内容 |

- 证书必须是 `Isla Self Signed`，否则 App 内更新会因为证书固定校验失败而拒绝安装。
- `ISLA_APPCAST_KEY` 是 App 更新专用 Ed25519 私钥，与插件商店 key 分开；公钥已固定在 `UpdateService.pinnedPublicKeys`。
- 不要把任何私钥/证书提交到仓库；`.gitignore` 已忽略相关文件。

## GitHub Pages

仓库 `Settings → Pages → Build and deployment` 选择 **GitHub Actions**。
首次 Release 会自动部署 `site/`：落地页 + 插件商店 `index.json`/`.sig`/`packages` + `appcast.json`。

公开地址：

- 落地页 / 插件商店：`https://llllccc.github.io/Isla/`
- App 更新源：`https://llllccc.github.io/Isla/appcast.json`

## 发布

```bash
# 1. 改 BUILD_NUMBER、写 release-notes/vX.Y.Z.md，提交
git add -A && git commit -m "release: vX.Y.Z"
git tag vX.Y.Z
git push origin main --tags
```

tag 推送后 `.github/workflows/release.yml` 会：

1. 导入自签证书并构建（缺少证书直接失败，不会静默 ad-hoc）；
2. 生成 DMG / ZIP / sha256；
3. 用 appcast 私钥生成并签名 `appcast.json`；
4. 创建 draft Release、上传资产、再 publish；
5. 部署 Pages。

## 本地验收

```bash
ISLA_VERSION=1.7.0 ISLA_BUILD=110 zsh ./build.sh
zsh ./tools/selfcheck.sh
zsh ./tools/make-dmg.sh
ISLA_APPCAST_KEY="$HOME/.isla-appcast-key.json" \
  zsh ./tools/make-appcast.sh 1.7.0 110 dist/Isla-1.7.0-110.zip dist/Isla-1.7.0-110.dmg release-notes/v1.7.0.md
```

App 内更新验收：用 `--update-now` + `ISLA_UPDATE_URL=http://127.0.0.1:PORT/appcast.json` 启动一个测试副本，
点击「直接更新并重启」，确认版本/build 变化、设置与辅助功能授权保留。

## 回滚

- App 内更新失败时，`Resources/update-helper.sh` 会恢复旧包；备份在
  `~/Library/Application Support/Isla/Backup/`，日志在 `~/Library/Logs/Isla/update.log`。
- Release 资产发布后不要删除旧 tag；更新器拒绝 build 回退，用户只会看到更新的版本。
