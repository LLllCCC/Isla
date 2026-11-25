# Isla 插件商店（静态源）

这个目录就是「远端商店」的全部内容：一个 `index.json` + 若干 zip 安装包 + 一个给人看的 `index.html`。
没有服务端逻辑，任何静态托管（GitHub Pages / Cloudflare Pages / 自建 nginx）都能直接用。

## 目录

```
store/
├─ index.json                 商店索引（App 只读这一个文件）
├─ index.html                 人看的落地页（可选）
└─ packages/
   ├─ com.example.clipboard-board-0.4.0.zip
   └─ com.example.web-dashboard-0.2.0.zip
```

## 索引格式（schema = 1）

```json
{
  "schema": 1,
  "name": "Isla 示例商店",
  "updatedAt": "2026-11-24T20:04:13Z",
  "plugins": [
    {
      "id": "com.example.clipboard-board",
      "name": "剪贴板看板",
      "version": "0.4.0",
      "summary": "一句话介绍",
      "author": "Isla",
      "minAppVersion": "1.5.12",
      "permissions": ["clipboard", "storage"],
      "package": "packages/com.example.clipboard-board-0.4.0.zip",
      "sha256": "e5dc…（64 位十六进制，必填）",
      "size": 3558
    }
  ]
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` / `name` / `version` | ✅ | `id` 只允许字母、数字、`.`、`-`、`_`，最长 128 |
| `package` | ✅ | 相对索引地址或绝对 https 地址；相对地址会继承索引 URL 的 query（托管平台的 sharecode） |
| `sha256` | ✅ | 小写/大写均可，App 会转小写比较；缺失或格式错 → 整个条目被忽略 |
| `size` | 建议 | 字节数；给了就必须与实际一致，否则拒绝安装 |
| `nameEn` / `summaryEn` | 可选 | 英文界面用；缺省回退中文。顶层索引也支持 `nameEn`（商店名） |
| `summary` / `author` / `permissions` | 可选 | `permissions` 只用于展示；真实权限以插件 manifest 为准，安装时仍逐项确认 |
| `minAppVersion` | 可选 | 低于此版本的 App 显示「需要更新」，安装按钮禁用 |

单个条目坏掉只会被丢掉，不会让整份索引解析失败（`plugins` 数组按元素容错）。

## 签名（Ed25519）

索引可以带发布者签名，防止「HTTPS 被绕过后塞进一份假索引」：

- `index.json` 增加 `publisher: { "name": "Isla", "keyID": "…", "publicKey": "base64" }`
- 同目录放 `index.json.sig`：对**写盘后的 `index.json` 原始字节**做 Ed25519 签名，64 字节的 base64 文本
- `keyID` = SHA-256(32 字节公钥) 的前 16 位十六进制

App 的校验规则：

| 情况 | 行为 |
|---|---|
| 有 `publisher` + 签名有效 + 公钥已信任 | 正常加载，显示「已签名 · 发布者 … · 指纹 …」 |
| 有 `publisher` + 签名有效 + 公钥未信任 | 显示发布者与指纹；安装前弹窗要求「信任并安装」 |
| 有 `publisher` + 签名缺失/无效 | **整份索引拒绝加载**（不会退回未签名） |
| 无 `publisher` + 存在合法 `.sig` | 拒绝加载（防止签名被剥掉后降级） |
| 无 `publisher` + 无签名 | 可以浏览，安装前二次确认「这个商店没有签名」 |

已信任的源换钥匙会直接拒绝加载，必须由用户手动重新信任——这是有意的（换了钥匙就是换了发布者身份）。

### 签名工具

```bash
# 只做一次：生成私钥（0600），打印 publicKey / keyID
./build/.tools/isla-sign keygen ~/.isla-store-key.json

# 把 publisher 写进索引并对写盘后的字节签名 → index.json.sig
./build/.tools/isla-sign sign store/index.json ~/.isla-store-key.json --name "Isla"

# 自检
./build/.tools/isla-sign verify store/index.json store/index.json.sig ~/.isla-store-key.json
```

`tools/make-store.sh` 在 `ISLA_STORE_KEY`（默认 `~/.isla-store-key.json`）存在时会自动签名。
**私钥只留在本机，绝不进仓库**（`.gitignore` 已忽略 `.isla-store-key.json`）；丢了私钥只能换新钥匙，
所有已信任旧钥匙的用户都会被拒绝，需要重新信任。


## 托管要求

1. **HTTPS**。App 只接受 https；`http://127.0.0.1` 仅用于本机调试（Info.plist 开了 `NSAllowsLocalNetworking`）。
2. `.zip` 的 `Content-Type` 建议 `application/zip`（python http.server / 各家静态托管都默认正确）。
3. 如果托管平台用 query token 做访问控制，把 token 保留在索引 URL 上即可：
   App 会把同一个 query 带到同源的相对安装包地址上；跨域绝对地址不会带（避免泄露 token）。
   官方源部署在 GitHub Pages，不使用 query token。

## 重新生成

```bash
./tools/make-store.sh          # 重打 packages、重算 sha256/size、重写 index.json
```

改完 `index.json` 要重新发布一次商店（内容变了，旧链接不会自动更新）。

第三方插件作者请看仓库里的 [`../docs/PLUGIN-DEV.md`](../docs/PLUGIN-DEV.md)。

## 安全模型（重要）

- **Ed25519 索引签名**证明「索引与发布者公钥匹配」；公钥是否可信由 App 侧的固定（首次信任 / 预置）决定。
  签名覆盖索引里的每个包的 SHA-256，因此也间接锁住了安装包。
- 签名**不等于代码审计**：它只说明「这份索引是这把钥匙的主人发的」，不说明插件代码安全。
- App 侧还有：https-only、索引 2 MB / 安装包 24 MB 上限、最多 200 个条目、zip 条目数 ≤ 5000、
  拒绝绝对路径与 `..`、安装时逐项确认权限、安装后记录插件目录完整性基线。
- 发布者签名已具备；后续可加「官方钥匙预置进二进制」与 Developer ID/公证。

## 当前示例源

`https://llllccc.github.io/Isla/index.json`
（GitHub Pages 托管本仓库 `store/`，在 Isla 设置 → 插件 → 插件商店里默认预置，可移除。）

> 线上为**签名版**（keyID `0b52676ad8e95289`），包含英文名；App 二进制预置了这把公钥，
> 打开即显示「已签名 · 发布者 Isla」，不需要手动信任。换钥匙时旧版本会拒绝加载，需发新版本或让用户手动重新信任。
