# Isla 插件模板

复制这个目录就能开始写插件。完整 API 见 [`../PLUGIN-DEV.md`](../PLUGIN-DEV.md)。

```
plugin-template/
├─ manifest.json      插件声明：id、名字、权限、要贡献哪些页面/卡片/胶囊/命令
├─ main.js            声明式页面（kind = "js"）的逻辑，运行在插件宿主里
└─ web/index.html     自定义网页（kind = "web"），完整 HTML/CSS/JS
```

## 改这三处就能跑

1. `manifest.json` 里的 `id`（只能用字母/数字/点/横线/下划线）、`name`、`main`。
2. `main.js` 里的 `export default { onload(ctx) { … } }`。
3. 想加页面就在 `contributes.pages` 里加一条，`kind` 选 `js`（声明式）或 `web`（自由网页）。

## 本地调试

- 把这个目录复制到 `~/Library/Application Support/Isla/Plugins/com.example.plugin-template/`，
  然后在 **Isla → 设置 → 插件** 里点「重新扫描」并启用。
- 或者在设置里点「安装插件…」直接选这个文件夹。
- 改完 `main.js` / `manifest.json`，1~2 秒内自动生效（设置里的「自动重载（开发模式）」默认开着）。
- 出错了看 **设置 → 插件 → 已安装 → 查看日志**，日志在 `~/Library/Logs/Isla/plugins/<插件 id>.log`。

## 打包给别人

把目录压成 zip（**顶层直接是 manifest.json，不要多套一层文件夹**），对方在
「设置 → 插件 → 安装插件…」里选这个 zip 即可；或者放进商店索引发布。
