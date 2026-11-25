# Isla 插件体系规划

> **要写插件请看 [`PLUGIN-DEV.md`](PLUGIN-DEV.md)**（这份是架构与历史设计）

> 版本：1.5.0 工作区规划稿（对应已装 build 18）  
> 目标：让 Isla 具备 Obsidian 式「装一个插件就多一页/多一个组件」的能力，同时不把主 App 的稳定性和安全性押上去。

## 0. 结论先说

**可以做，而且值得做；但当前 1.6.x 的固定 enum 架构不够，必须先做一层注册表重构。**

推荐路线不是「把第三方 Swift 代码直接塞进主进程」，也不是「照搬 Obsidian 的 Node 全权限」，而是：

- **独立插件宿主进程**（XPC / 独立 helper）运行 JavaScriptCore；
- 插件只拿到 **manifest 声明的权限** 和一套 **受控 API**；
- 面板页、概览卡片优先用 **声明式原生 UI** 渲染，保证和现有设计语言一致；
- 只有确实需要复杂自定义界面的插件，才开放 **WKWebView 沙盒页** 作为兜底；
- 主 App 负责注册表、布局、渲染、权限和生命周期，插件崩溃/死循环不能拖死灵动岛。

这套模式和 Raycast、VS Code 的扩展宿主思路一致：扩展在独立进程里跑，主进程只通过消息协议调用受限能力。

参考：
- Raycast：JavaScriptCore + XPC extension host，扩展 UI 用声明式组件树映射到 AppKit  
  https://www.raycast.com/blog/how-raycast-api-extensions-work
- VS Code：extension host 独立进程，扩展不能直接碰 UI DOM  
  https://code.visualstudio.com/api/advanced-topics/extension-host  
  https://vscode-docs.readthedocs.io/en/stable/extensions/our-approach/
- Obsidian：manifest + onload/onunload + registerView 的插件生命周期  
  https://docs.obsidian.md/Plugins/Getting+started/Anatomy+of+a+plugin  
  https://docs.obsidian.md/Plugins/User+interface/Views
- Apple XPC / App Sandbox 的权限隔离  
  https://developer.apple.com/library/archive/documentation/General/Conceptual/MOSXAppProgrammingGuide/AppRuntime/AppRuntime.html

---

## 1. 当前代码的兼容性审计

### 能直接复用的部分

- `IslandStore`：页状态、翻页、页面方向、剪贴板/暂存数据源，适合继续做页面宿主。
- `PanelContent`：现有面板布局、页签、画布、卡片视觉，是插件页的渲染底座。
- `CanvasLayout`：组件盒模型、磁吸、受限排列，可以继续给插件卡片用。
- `SettingsWindow`：分组卡片、滑杆、开关等控件，可以抽成插件设置表单的渲染器。
- `IslandController`：面板尺寸、中心线、动画、悬浮逻辑，不需要为插件重写。

### 不够兼容、必须重构的部分

| 现状 | 问题 | 目标 |
|---|---|---|
| `PanelPage` 是固定 enum（overview/clipboard/shelf） | 插件无法动态加页；页签顺序写死 | 改为 `PageRegistry` + `PageDescriptor`，核心页也注册进去 |
| `PanelContent` 用 `switch page` 渲染 | 每加一页都要改主代码 | 按 descriptor 的 `kind` 找 renderer，未知类型交给插件页宿主 |
| `ModuleID` 是固定 enum（7 个内置模块） | 插件不能注册概览卡片 | 改为 `WidgetRegistry`，内置模块迁移为 builtin provider |
| `SettingsStore` 里模块开关/顺序按 enum 存 | 插件组件无法持久化顺序和启用状态 | 改为按字符串 id 存 `enabledWidgets` / `widgetOrder` |
| `CanvasLayout` 直接用 `ModuleID.allCases` | 插件卡片没有布局盒 | 布局盒按 widget id 注册，内置与插件统一 |
| 页签 `tabOrder` 当前由 `PanelPage.allCases` 推导 | 插件页没有稳定插入点 | 注册表维护 `sortKey/insertionOrder`，仍按「先左、再右、交替」排 |
| 面板高度写死 `panelChromeHeight` 和固定画布 | 插件页内容高度不同 | 由页面 descriptor 提供 `preferredHeight`，面板继续动态量高 |

**结论：不是「重写整个 App」，而是把「固定枚举 + switch」换成「注册表 + descriptor + renderer」；视觉、窗口、磁吸、动画、设置框架都能保留。**

---

## 2. 三种插件技术路线比较

| 路线 | UI 能力 | 安全/稳定 | 开发体验 | 与现有设计一致 | 结论 |
|---|---|---|---|---|---|
| A. 原生 Swift `.bundle` 直接加载 | 最强，能写任意 SwiftUI/AppKit | 最差：崩溃、内存、私有 API 都能拖死主 App；签名/公证复杂 | 最好（对会 Swift 的人） | 最好 | 不作为默认，最多保留「可信内置插件」 |
| B. JS 扩展宿主 + 声明式原生 UI | 中高：列表、表单、卡片、图表、Markdown 足够 | 好：独立进程、权限声明、可 watchdog 重启 | 好：TypeScript/JS，像 Obsidian/Raycast | 最好：强制走现有组件和主题 | **推荐主路线** |
| C. WKWebView 自定义页 | 最高：任意 HTML/CSS/JS | 较好：WebContent 独立进程，但内存/性能更重，样式容易跑偏 | 好：前端开发者熟悉 | 差，容易变成「网页套壳」 | **只做兜底页**，不放概览卡片 |

**推荐组合：B 为主 + C 为辅。**  
概览里的卡片、胶囊上的 widget、设置页、简单列表/表单一律走 B；只有插件明确声明 `customPage: web` 且用户安装时确认，才用 C 打开一个独立自定义页。

---

## 3. 目标架构

```
Isla 主进程
├─ PageRegistry / WidgetRegistry / CommandRegistry
├─ PanelHost（现有 PanelContent 重构）
├─ PluginManager（安装、启用、权限、版本）
├─ PluginBridge（JSON-RPC 客户端）
└─ XPC: com.yopo.isla.plugin-host
      ├─ PluginHost（生命周期、watchdog、日志）
      ├─ JSContext #1  plugin A
      ├─ JSContext #2  plugin B
      └─ 能力代理：Clipboard / Shelf / HTTP / Notification / Storage
```

### 3.1 插件宿主

- **第一版用独立 helper 子进程**（`IslaPluginHost`，随 App 一起放在 `Contents/MacOS/`），主进程通过 stdin/stdout 上的 JSON-RPC 通信。
  原因：当前是 ad-hoc 签名的本地构建，XPC service 需要正确的嵌套签名，容易在「自己编译自己装」的场景失效；helper 子进程同样能隔离崩溃，且没有签名门槛。
  等要上商店、拿到 Developer ID 再换 XPC（协议不变，只换传输层）。
- 一个宿主进程内可以放多个 `JSContext`；每个插件一个 context，变量和全局对象隔离。
- 每个插件调用有 **超时**（默认 2s，渲染/网络可声明更长），超时或异常只杀该 context，必要时重启宿主。
- 插件不能直接 `Process`、`NSAppleScript`、任意文件读写、任意网络；这些必须走宿主代理和权限检查。
- 插件日志写入 `~/Library/Logs/Isla/plugins/<id>.log`，设置页可查看最近错误。

### 3.2 插件目录

```
~/Library/Application Support/Isla/Plugins/
└─ com.example.clipboard-board/
   ├─ manifest.json
   ├─ main.js
   ├─ icon.png
   ├─ styles.css          # 仅 web 自定义页使用
   └─ data/               # 宿主分配的插件私有数据目录
```

开发模式支持从任意文件夹加载；正式安装支持 `.zip`（后续再做商店签名包）。

### 3.3 Manifest

```json
{
  "id": "com.example.clipboard-board",
  "name": "剪贴板看板",
  "version": "0.1.0",
  "minAppVersion": "1.7.0",
  "main": "main.js",
  "icon": "icon.png",
  "permissions": ["clipboard", "storage", "notifications"],
  "contributes": {
    "pages": [
      {
        "id": "board",
        "title": "剪贴板看板",
        "icon": "square.grid.2x2",
        "kind": "native",
        "preferredHeight": 300
      }
    ],
    "panelCards": [
      {
        "id": "latest-clip",
        "title": "最近复制",
        "defaultSize": { "w": 180, "h": 76 }
      }
    ],
    "capsuleModes": [
      { "id": "clip-count", "title": "剪贴板计数" }
    ],
    "commands": [
      { "id": "open-board", "title": "打开剪贴板看板" }
    ]
  }
}
```

**多语言（可选，向后兼容）**：`nameEn` / `descriptionEn` 与每个 contribution 的 `titleEn`
用于英文界面；缺省回退中文，老版本 App 会忽略这些字段，照常加载。
Web 页的 `window.isla` 额外提供 `locale`（如 `en` / `zh-Hans`），插件正文可按语言自取文案。

**API 版本**：`apiVersion`（缺省 1）。App 支持到 1；声明更高版本的插件会被拒绝并提示更新 App。
注意老版本 App 不认识 `apiVersion`，所以**跨大版本仍应同时写 `minAppVersion`**。

权限在首次启用时逐项展示，后续新增权限必须重新确认。

### 3.4 插件 API（第一版）

生命周期：

```ts
export default {
  onload(ctx) {},
  onunload() {},
  onEnable() {},
  onDisable() {},
}
```

注册：

```ts
ctx.pages.register({
  id: "board",
  title: "剪贴板看板",
  icon: "square.grid.2x2",
  render: () => ({
    type: "page",
    children: [
      { type: "section", title: "最近复制" },
      { type: "list", items: [...] },
    ],
  }),
})

ctx.cards.register({
  id: "latest-clip",
  render: () => ({ type: "card", title: "最近复制", value: "..." }),
})

ctx.commands.register({
  id: "open-board",
  title: "打开剪贴板看板",
  run: () => ctx.pages.open("board"),
})
```

能力（全部要权限）：

- `ctx.storage.get/set/remove`：按插件 id 命名空间隔离，单插件配额默认 5 MB。
- `ctx.clipboard.read/write/watch`：`clipboard` 权限。
- `ctx.shelf.add/list/remove`：`shelf` 权限。
- `ctx.notifications.show`：`notifications` 权限。
- `ctx.http.fetch`：`network` 权限 + 域名 allowlist；禁止本地地址和任意端口。
- `ctx.nowPlaying.get/watch`：`nowplaying` 权限。
- `ctx.files.pick()`：只能通过系统文件选择器拿到用户显式授权的目录/文件，不能扫全盘。
- `ctx.ui.openPage/toast`：打开本插件注册的页面或发轻提示。

**不提供**：任意 shell、任意 AppleScript、原生动态库、直接访问其他插件数据、直接改主 App 布局/窗口。

### 3.5 声明式 UI 组件（第一版）

优先支持这些，足够覆盖 80% 插件：

`page`、`section`、`list`、`row`、`grid`、`card`、`stat`、`text`、`markdown`、`button`、`textField`、`toggle`、`picker`、`progress`、`divider`、`spacer`、`image`。

渲染方式：
- 插件返回 JSON render tree；
- 主进程把 tree 转成 SwiftUI 视图；
- 不暴露任意 CSS/布局，主题、字号、圆角、间距全部走 `Theme`；
- 每次 render 生成完整 tree，宿主可以做 diff（先全量替换，后续再优化 JSON Patch）。

**为什么不让插件直接写 SwiftUI/HTML：** 一旦允许任意布局，插件会和 Isla 的圆角、字号、动画、中心线体系打架；声明式组件可以强制一致。

### 3.6 自定义页兜底（WKWebView）

只对 `kind: "web"` 的页面开放：

- `WKWebView` 运行在 WebContent 进程；
- 通过 `WKScriptMessageHandler` 暴露上面同一套 `ctx` 能力的子集；
- 不允许 `file://` 任意读，不允许 `universalAccessFromFileURLs`；
- 页面必须使用宿主注入的 `theme.css`，默认禁止外部网络（除非有 `network` 权限）；
- 适合：复杂图表、富文本编辑器、第三方服务嵌入；不适合概览卡片。

### 3.7 页签顺序

现有规则保留：**概览永远在中间；新增页按「左、右、左、右」交替放到外侧。**

注册表给每个页面 `sortKey`：
- 内置核心页固定 `0/1/2`；
- 插件页默认按安装顺序取递增 sortKey；
- `PageRegistry.orderedTabs()` 生成：`left + [overview] + right`。

插件页被禁用/卸载后，页签自动移除；当前页被移除时回到概览。

### 3.8 面板尺寸

- 每个页面 descriptor 提供 `preferredHeight`（可选）；
- 面板继续用现有动态量高，不写死；
- 插件页最小高度 220，最大不超过屏幕可视高度的 70%；
- 插件卡片按 `defaultSize` 注册到 `CanvasLayout`，参与磁吸/受限排列，和内置卡片同一套规则。

---

## 4. 分阶段实施

### Phase 0：注册表重构（不改用户可见功能）

- 新增 `PageRegistry`、`WidgetRegistry`、`CommandRegistry`；
- 内置 3 页、7 个模块迁移成 builtin descriptor；
- `PanelContent` 从 `switch page` 改为按 descriptor 渲染；
- `SettingsStore` 的模块开关/顺序改为字符串 id；
- `CanvasLayout` 从 `ModuleID.allCases` 改为注册表；
- 保留 1.6.x 所有视觉与交互，回归测试必须通过。

**产出：** 功能等价，但已经能容纳动态页面/卡片。

### Phase 1：插件 MVP

- 插件目录 + manifest 解析 + 启用/禁用；
- JSContext + XPC 宿主 + JSON-RPC；
- 一个「剪贴板看板」示例插件：列表 + 按钮 + 存储 + 剪贴板权限；
- 插件页出现在页签（概览居中，插件页按左右交替）；
- 插件设置 schema 自动生成；
- 插件管理器设置页：安装文件夹、启用、权限、日志、卸载；
- 崩溃/超时隔离。

**验收：** 不改主代码即可装一个插件、多一页、读写剪贴板、重启 App 后仍保留数据。

### Phase 2：概览卡片 + 胶囊 + 命令

- 插件注册概览卡片，进入画布、磁吸、受限排列；
- 插件注册胶囊模式（例如显示剪贴板条数、番茄钟剩余）；
- 命令面板/右键菜单注册命令；
- 开发模式热重载；
- 插件间事件总线（只允许声明订阅的公开事件）。

### Phase 3：Web 自定义页 + 商店

- ✅ WKWebView 自定义页 + 能力桥（build 81）；
- ⏳ 插件代码签名：**索引级 Ed25519 发布者签名已完成（build 97）**——`publisher` + `index.json.sig`、
  按源固定公钥、未信任/未签名安装前二次确认；**文件级代码签名（Developer ID / 公证）仍未做**；
- ✅ 权限审核第一版（权限目录 / 敏感标记 / 总览与详情，build 93）；
- ✅ SHA-256 完整性校验（安装记录 / 扫描对比 / 改动提示 / 信任当前文件，build 86）与本地目录更新（build 82）；
- ✅ 插件商店/索引第一版 = 随 App 分发的本地目录（build 81）；**远端商店第一版（build 97）**：
  静态 `index.json`（schema 1）+ zip 包，`StoreClient` 负责 https-only / 大小上限 / SHA-256 / zip 路径检查，
  `PluginStore` 负责源管理、安装编排与 UI；默认示例源托管在 GitHub Pages（`store/` 目录可自托管），
  索引格式与托管要求见 [`store/README.md`](../store/README.md)；发布者签名仍未做；
- ⏳ 版本兼容矩阵与自动禁用不兼容插件（`minAppVersion` 校验已具备）。

---

## 5. 安全模型

1. **默认拒绝**：manifest 没写的权限一律没有。
2. **进程隔离**：插件代码不跑在主 App 进程；宿主崩溃可重启。
3. **能力代理**：剪贴板、网络、文件、通知都由主 App 检查权限后代理。
4. **网络 allowlist**：插件只能访问 manifest 声明的域名；默认禁止 localhost/局域网。
5. **数据隔离**：每插件独立目录和 storage namespace，不能读其他插件数据。
6. **代码签名**：正式插件包签名 + hash；开发模式允许未签名但显式标记「本地开发」。
7. **不可信 UI**：声明式组件不允许任意 CSS/HTML；Web 页单独沙盒。
8. **可审计**：安装、启用、权限变更、崩溃都写日志。

---

## 6. 风险与取舍

| 风险 | 影响 | 应对 |
|---|---|---|
| JS 插件仍可能写死循环 | 宿主卡住 | 每插件超时、watchdog、宿主重启 |
| 声明式 UI 表现力有限 | 复杂插件做不了 | Web 自定义页兜底，但只做整页 |
| 注册表重构触碰面板布局 | 可能回归现有视觉 | Phase 0 功能等价 + 截图回归 + `verify.sh` |
| 插件生态早期为空 | 没人写 | 先做 2-3 个官方示例（剪贴板看板、单词卡片、倒计时） |
| 权限提示打扰 | 用户反感 | 首次启用集中确认，后续新增权限才再问 |
| 和 Obsidian 比不够自由 | 开发者预期落差 | 文档明确「安全优先，不提供 Node/Shell」 |

---

## 7. 第一版建议先做的 3 个官方插件

1. **剪贴板看板**：列表、搜索、固定、删除、点击回填剪贴板。验证页面、列表、权限、存储。
2. **倒计时/考试日卡片**：注册概览卡片 + 胶囊模式。验证卡片布局、磁吸、胶囊状态。
3. **单词卡片**：表单 + 卡片翻转 + 本地存储。验证表单、动画、设置 schema。

这三个能覆盖页面、卡片、胶囊、设置、权限、存储六条主链路，做完再考虑商店。

---

## 8. 对当前版本的直接结论

- **当前 1.6.0 不能直接挂插件**：`PanelPage` / `ModuleID` 固定 enum，`switch` 渲染，页签顺序也只认 enum。
- 但不是推倒重来：窗口、面板、动画、磁吸、设置 UI 都可以保留。
- 建议下一个大版本 **1.7.0 = Phase 0 注册表重构**，**1.8.0 = Phase 1 插件 MVP**。
- 如果只想先验证概念，可以先做「单插件、单自定义页、只读剪贴板」的最小 demo，不动概览卡片。

---

## 9. 分发给朋友用（多用户）

目标是「我把 App 和几个插件发给朋友，他们自己也能写插件」。这会引入几个新要求：

### 9.1 安装路径必须是用户可写的

```
~/Library/Application Support/Isla/Plugins/<plugin-id>/
```

不放 `Contents/Resources`（App 升级会覆盖、且需要签名），也不要求管理员权限。设置页提供「打开插件文件夹」，朋友把插件包拖进去即可。

### 9.2 三种安装方式

| 方式 | 场景 | 实现 |
|---|---|---|
| 拖文件夹 | 开发/朋友互传 | 设置页拖入 → 校验 manifest → 复制到 Plugins 目录 |
| `.zip` 导入 | 发微信/网盘 | 解压到临时目录 → 校验 → 落位 |
| 未签名警告 | 朋友自写插件 | manifest 缺签名时标「本地开发」，允许启用但显示黄条 |

不需要公证：插件不是可执行文件（JS），真正的执行权在宿主进程，权限由 manifest 控制。这一点比原生插件包安全得多，也是选 JS 路线的一个额外收益。

### 9.3 版本兼容

- manifest 必填 `minAppVersion`；不满足就禁用并提示升级。
- 宿主 API 带版本号（`apiVersion: 1`）；主 App 升级时保留旧 API 至少一个大版本。
- 插件崩溃/超时：只禁用该插件，设置页显示最近 20 行日志。

### 9.4 朋友写插件需要什么

1. 一份 `PLUGIN-AUTHORING.md`（manifest 字段、API、16 种声明式组件、三个完整示例）。
2. 一个「开发模式」：从任意文件夹加载 + 改 `main.js` 后自动重载（不用反复装）。
3. 一个「日志」入口：`~/Library/Logs/Isla/plugins/<id>.log`。

> 结论：多人使用不改变架构，只增加**安装路径、版本校验、开发模式、文档**四件事。

---

## 10. 歌词能力：内置还是插件？

用户想要「胶囊里显示 QQ音乐/网易云/Apple Music 的歌词」。可行性已单独验证，见 [`LYRICS-FEASIBILITY.md`](LYRICS-FEASIBILITY.md)。在插件体系里的定位：

- **第一版做成内置能力**（`LyricsService` + 胶囊内容模式「歌词」），因为它是胶囊的核心体验，不该依赖插件运行时。
- **同时把接口暴露成插件能力** `ctx.lyrics.get/watch`（需要 `lyrics` 权限），这样插件可以基于它做「歌词卡片」「歌词海报」之类。
- 这也正好是插件 API 的第一个真实用例：`lyrics` 权限 + `nowPlaying` 权限 + 声明式卡片，能跑通「能力代理 → 权限检查 → 渲染」整条链路。

**为什么先内置**：插件宿主还没写，而歌词是用户当下就要的功能；先内置可以把「取歌词」这件事的数据结构、缓存、失败回退打磨好，将来插件只是复用同一份实现。
