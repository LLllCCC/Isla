# Isla 发布流程

## 版本号

- `BUILD_NUMBER` 是唯一的 build 号来源（`build.sh` 优先级：`ISLA_BUILD` > `BUILD_NUMBER` > 提交数）。
- 发版前把 `BUILD_NUMBER` 加一，提交，再打 `vX.Y.Z` tag。
- 首个公开版：`v1.7.0` / build `110`；当前：`v1.7.1` / build `111`。
- CI/Release 使用 `macos-15`。**不要改回 `macos-13`**：该镜像已于 2025-12-04 退役，任务会一直排队。

## GitHub Secrets

在 `Settings → Secrets and variables → Actions` 添加（值只在本机生成，不写进仓库）：

> 2026-11-25 已配置完成；换证书或轮换 appcast key 时按下表更新。

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

仓库 `Settings → Pages → Build and deployment` 选择 **Deploy from a branch**，分支 `gh-pages`、目录 `/`。
首发时已手动创建 `gh-pages`；后续 Release 工作流会把 `site/` 强制推送到 `gh-pages`，不需要 Actions Pages 部署权限。

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

arm64 runner 可能出现容量排队（十几分钟）；用 `gh run list` / `gh run view` 看进度，不要因为排队就重复推 tag。

## 本地验收

```bash
ISLA_VERSION=1.7.1 ISLA_BUILD=111 zsh ./build.sh
zsh ./tools/selfcheck.sh
zsh ./tools/make-dmg.sh
ISLA_APPCAST_KEY="$HOME/.isla-appcast-key.json" \
  zsh ./tools/make-appcast.sh 1.7.1 111 dist/Isla-1.7.1-111.zip dist/Isla-1.7.1-111.dmg release-notes/v1.7.1.md
```

App 内更新验收：用 `--update-now` + `ISLA_UPDATE_URL=http://127.0.0.1:PORT/appcast.json` 启动一个测试副本，
点击「直接更新并重启」，确认版本/build 变化、设置与辅助功能授权保留。

公开通道验收（每次发版后）：

```bash
# 线上 appcast 应指向新 build
curl -s "https://llllccc.github.io/Isla/appcast.json?t=$(date +%s)" \
  | python3 -c "import json,sys,base64; d=json.load(sys.stdin); p=json.loads(base64.b64decode(d['payload'])); print(p['version'], p['build'])"
# 旧版 App 打开「检查更新…」，确认能发现新版本并直接更新、重启
```

## 回滚

- App 内更新失败时，`Resources/update-helper.sh` 会恢复旧包；备份在
  `~/Library/Application Support/Isla/Backup/`，日志在 `~/Library/Logs/Isla/update.log`。
- Release 资产发布后不要删除旧 tag；更新器拒绝 build 回退，用户只会看到更新的版本。
