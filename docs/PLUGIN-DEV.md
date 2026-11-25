# Isla 插件开发指南

> 面向第三方插件作者。读完这一篇就能写出能在面板里跑起来的插件。
> 可直接复制的模板：[`plugin-template/`](plugin-template/)（`manifest.json` + `main.js` + `web/index.html`）。
> 架构与历史设计见 [`PLUGIN-ARCHITECTURE.md`](PLUGIN-ARCHITECTURE.md)，商店索引格式见 [`../store/README.md`](../store/README.md)。

---

## 0. 五分钟上手

```bash
cp -R docs/plugin-template ~/Library/Application\ Support/Isla/Plugins/com.example.plugin-template
```

然后在 Isla 里：**设置 → 插件 → 重新扫描 → 启用**。面板里会出现「模板页面」和「Web 页面示例」两个新页签，
概览里多一张「模板卡片」。

改 `main.js` 后 1~2 秒自动生效（设置里的「自动重载（开发模式）」默认开着）。

---

## 1. 插件是什么、跑在哪

- 插件是**一个文件夹**（或一个 zip），里面必须有 `manifest.json`。
- 代码跑在**独立的宿主进程** `IslaPluginHost` 里（JavaScriptCore），每个插件一个 JS 上下文，互不串味。
- 宿主有 2 秒调用超时；插件崩溃/死循环只会影响它自己，**不会拖垮灵动岛**。
- 主 App 通过受限桥与插件通信：插件拿不到你的剪贴板历史、写不了文件、不能联网，
  除非它在 `manifest.json` 里**声明了对应权限**，并且用户在安装时逐项确认过。

### 目录结构

```
com.example.my-plugin/
├─ manifest.json     必需
├─ main.js           必需（路径由 manifest.main 指定）
├─ icon.png          可选（manifest.icon）
├─ styles.css        仅 kind = "web" 的页面用
├─ web/index.html    仅 kind = "web" 的页面用
└─ data/             宿主自动创建的插件私有目录（storage.json 在这里）
```

---

## 2. manifest.json

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | ✅ | 只能用字母、数字、`.`、`-`、`_`；建议 `com.作者.插件名` |
| `name` | ✅ | 界面里显示的名字 |
| `nameEn` | | 英文界面用的名字，缺省回退 `name` |
| `version` | ✅ | 语义化版本，商店用它判断是否需要更新 |
| `description` / `descriptionEn` | | 一句话说明 |
| `minAppVersion` | | 低于这个 App 版本不给装（例：`"1.6.4"`） |
| `apiVersion` | | 插件 API 版本，**缺省 1**；写高于 App 支持的版本会被拒绝并提示升级 |
| `main` | ✅ | 入口 JS，相对插件目录（例：`"main.js"`） |
| `icon` | | SF Symbol 名或 `icon.png` |
| `permissions` | | 权限 id 数组，见第 5 节 |
| `contributes` | | 贡献页面/卡片/胶囊/命令，见下 |
| `events` | | `{ "publish": [...], "subscribe": [...] }`，事件名 |

### contributes

```jsonc
"contributes": {
  "pages": [
    { "id": "hello", "title": "模板页面", "titleEn": "Template Page",
      "icon": "hand.wave", "kind": "js", "preferredHeight": 240 },
    { "id": "webdemo", "title": "Web 页面示例", "kind": "web",
      "entry": "web/index.html", "preferredHeight": 260 }
  ],
  "panelCards": [
    { "id": "hello-card", "title": "模板卡片", "defaultSize": { "w": 180, "h": 76 } }
  ],
  "capsuleModes": [ { "id": "hello-capsule", "title": "模板胶囊" } ],
  "commands":     [ { "id": "hello-say",  "title": "打个招呼" } ]
}
```

- `kind` 省略或 `"js"` = 声明式页面（原生渲染，跟主 App 观感一致）；`"web"` = WKWebView 自定义页（自由 HTML/CSS/JS）。
- `entry` 只有 `kind: "web"` 需要，路径相对插件目录。
- `preferredHeight` 是页面理想高度，面板会按内容量高。
- 每个 contribution 都可以加 `titleEn`，英文界面自动切换。

---

## 3. 声明式页面（kind = "js"）

`main.js` 导出 `onload(ctx)`，在里面注册页面；每次渲染主 App 都会重新调用你的 `render()`。

```js
export default {
  onload(ctx) {
    ctx.pages.register({
      id: "hello",
      render() {
        return {
          type: "page",
          children: [
            { type: "section", title: "标题", children: [
              { type: "text", text: "正文" },
              { type: "row", title: "一行", value: "值", children: [
                { type: "button", title: "按钮", icon: "plus", action: { command: "bump" } }
              ]}
            ]}
          ]
        }
      }
    })
  }
}
```

### 节点类型

| type | 常用字段 | 说明 |
|---|---|---|
| `page` | `children` | 页面根 |
| `section` | `title`, `children` | 小节 |
| `text` | `text`, `style` | 正文；`style` 可用 `title`/`subtitle`/`caption` |
| `card` | `title`, `value`, `subtitle` | 大数字卡片 |
| `stat` | `title`, `value` | 统计小块 |
| `list` | `items` / `children` | 列表 |
| `row` | `title`, `subtitle`, `value`, `children` | 一行（左侧文字、右侧控件） |
| `button` | `title`, `icon`, `action`, `compact` | 按钮；`action: { command, value }` 调自己的命令 |
| `toggle` | `value`, `action` | 开关 |
| `textField` | `value`, `placeholder`, `action` | 输入框 |
| `picker` | `value`, `options: [{title, value}]`, `action` | 下拉 |
| `slider` | `value`, `min`, `max`, `step`, `action` | 滑杆 |
| `divider` / `spacer` | — | 分隔线 / 弹性空白 |
| `image` | `value`（路径或 URL） | 图片 |
| `progress` | `progress`（0…1） | 进度条 |

所有节点都支持 `id`（给交互控件做状态用）。

### 交互怎么闭环

按钮/开关/输入框在渲染树里只是**描述**；用户操作时，主 App 会带着 `action.command` 回调你的命令：

```js
ctx.commands.register({
  id: "bump",
  title: "加一",
  run(value) {
    const n = (Number(ctx.storage.get("count", 0)) || 0) + 1
    ctx.storage.set("count", n)
    ctx.rerender()          // 改完数据调用它，主 App 会重新拉一次 render()
  }
})
```

---

## 4. Web 页面（kind = "web"）

`entry` 指向的 HTML 在 WKWebView 里打开，完整 HTML/CSS/JS 随便写。
主 App 注入一个受限桥 `window.isla`：

| 成员 | 说明 |
|---|---|
| `isla.plugin` | `{ id, page }` |
| `isla.version` | App 版本号 |
| `isla.locale` | 当前界面语言（`"zh-Hans"` / `"en"`…） |
| `isla.dark` | 是否深色外观 |
| `isla.permissions` | 本插件被授予的权限数组 |
| `isla.storage.get/set/remove` | 插件私有存储（异步，返回 Promise） |
| `isla.clipboard.readText/writeText` | 剪贴板文本读写 |
| `isla.ui.openPage(id)` | 跳到另一个插件页 |
| `isla.log(...)` | 写插件日志 |
| `isla.call(method, params)` | 底层 RPC（一般用上面的封装即可） |

**网络默认是关的**：`manifest.permissions` 里没有 `"network"` 时，WebView 里的 http(s) 请求会被宿主拦掉。
需要联网就声明 `network` 权限（用户安装时要确认）。

---

## 5. 权限

| 权限 id | 作用 | 敏感 |
|---|---|---|
| `storage` | 在插件自己的 `data/` 目录里存数据 | |
| `clipboard` | 读/写剪贴板、读历史、按 id 复制/固定/删除 | ✅ |
| `events`（在 `events` 段里声明） | 收发跨插件事件 | |
| `network` | 访问网络（域名白名单），Web 页不声明会被拦 | ✅ |
| `notifications` | 发系统通知（规划中） | |
| `nowplaying` / `lyrics` | 读当前播放信息/歌词（规划中） | |
| `shelf` | 读写暂存架文件路径（规划中） | |
| `files` | 通过系统文件选择器访问你选的文件（规划中） | |

> 目前**已经真正接上 ctx API 的是** `storage` 与 `clipboard`（以及 `events` 事件总线）；
> 其余权限已经在 manifest 目录里预留，等实现后再开放。声明了但还没实现的权限不会报错，只是暂时没 API 可用。

安装时 App 会**逐项列出**插件要什么权限；未声明的能力一律拒绝。

---

## 6. JS 侧 API 一览（ctx）

| 方法 | 说明 |
|---|---|
| `ctx.locale` | 当前界面语言（`"zh-Hans"` / `"en"` …），用来做自己的文案表 |
| `ctx.log(msg)` | 写日志到 `~/Library/Logs/Isla/plugins/<id>.log` |
| `ctx.storage.get(key, fallback)` / `set(key, value)` / `remove(key)` | 插件私有存储，值按 JSON 序列化 |
| `ctx.clipboard.history()` | 剪贴板历史数组（`{id, kind, preview, pinned}`） |
| `ctx.clipboard.read()` / `write(text)` | 当前剪贴板文本 |
| `ctx.clipboard.copy(id)` / `pin(id, bool)` / `remove(id)` | 操作历史条目 |
| `ctx.events.publish(name, payload)` / `subscribe(name, fn)` | 事件总线；订阅/发布范围由 `events` 段声明 |
| `ctx.rerender()` | 数据变了，请求重新渲染 |
| `ctx.pages/cards/capsule/commands.register({...})` | 注册贡献物 |

JS 环境里**没有** `window`/`document`/`fetch`/`setTimeout`/`require`。

---

## 7. 多语言

- 插件名、页面标题、卡片标题、胶囊标题、命令标题：在 manifest 里补 `nameEn` / `titleEn` 即可，主 App 自动切换。
- 插件自己写的正文（按钮文案、提示语）：用 `ctx.locale` 自己查表，模板里有现成写法。
- Web 页：读 `window.isla.locale`。

---

## 8. 版本与兼容

- `minAppVersion`：低于这个版本的 App 不给装（商店索引里也会带上，App 会显示「需要 Isla ≥ x.y.z」）。
- `apiVersion`：缺省 1。App 支持到的版本写在 `PluginManager.supportedAPIVersion`；
  插件声明更高版本会被拒绝，并提示「需要更新的 Isla」。
- manifest 里**没见过的字段会被忽略**（向前兼容，你可以先写新字段再等 App 支持）；
  但**没声明的权限会被拒绝**（安全优先）。
- 商店索引带 Ed25519 发布者签名：索引被改动、或者发布者换钥匙，App 会直接拒绝加载。

---

## 9. 打包与分发

**给朋友（离线）**：把插件目录压成 zip，**顶层直接是 manifest.json，不要多套一层文件夹**，
对方在「设置 → 插件 → 安装插件…」里选 zip 即可。

**上商店**：在商店索引里加一条（字段见 [`../store/README.md`](../store/README.md)）：

```jsonc
{
  "id": "com.example.my-plugin",
  "name": "我的插件",
  "nameEn": "My Plugin",
  "version": "0.1.0",
  "summary": "一句话说明",
  "summaryEn": "One-line summary",
  "author": "作者",
  "minAppVersion": "1.6.4",
  "permissions": ["storage"],
  "package": "packages/com.example.my-plugin-0.1.0.zip",
  "sha256": "…64 位十六进制…",
  "size": 12345
}
```

`sha256` 与 `size` 必填，App 会强校验；索引由发布者签名，App 侧按源固定公钥。

---

## 10. 调试

| 现象 | 去哪看 |
|---|---|
| 插件不出现 | 设置 → 插件 → 重新扫描；看「已安装」里的错误信息 |
| 页面空白 | 设置 → 插件 → 该插件 → 查看日志（JS 异常会写在这里） |
| 权限被拒 | 权限总览里会写「未声明的能力一律拒绝」 |
| 改了没生效 | 确认「自动重载（开发模式）」是开的；也可以在设置里禁用再启用 |
| Web 页白屏 | 看该插件日志；网络请求需要 `network` 权限 |

宿主日志目录：`~/Library/Logs/Isla/plugins/<插件 id>.log`

---

## 11. 已知限制

- 没有 `setTimeout` / 定时器：需要定时任务就用事件或让主 App 重新拉取。
- 没有网络（除声明 `network` 权限外）、没有文件系统访问、没有原生代码。
- 声明式页面的控件集合是固定的（上面那张表）；要自由布局就用 `kind: "web"`。
- 插件崩溃不会影响主 App，但该插件当次渲染会失败；修好保存后自动恢复。
