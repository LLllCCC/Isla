// ───────────────────────────────────────────────────────────────
// Isla 插件模板 · 声明式页面（manifest 里 kind = "js"）
//
// 这个文件在插件宿主进程里运行（JavaScriptCore），不是网页：
//   · 没有 window / document / fetch / Node API
//   · 能用的只有下面这些 ctx.* 方法
//   · 每次渲染都重新执行 render()，所以别在里面做重活
//
// 完整 API 说明见 docs/PLUGIN-DEV.md
// ───────────────────────────────────────────────────────────────

// 1) 多语言：ctx.locale 是当前界面语言（"zh-Hans" / "en" …）
//    manifest 里的 name/title 也有 nameEn/titleEn 字段，由主 App 处理；
//    页面正文这类自己写的文案，就用下面这种查表方式。
const zh = {
  hello: "你好，Isla",
  intro: "这个页面由插件宿主渲染，视觉与主 App 一致。",
  counter: "点击次数",
  bump: "加一",
  reset: "清零",
  cardTitle: "模板卡片",
  capsule: "模板",
  cmdTitle: "打个招呼",
  said: "已打招呼"
}
const en = {
  hello: "Hello, Isla",
  intro: "This page is rendered by the plugin host, with the app's own look.",
  counter: "Clicks",
  bump: "Bump",
  reset: "Reset",
  cardTitle: "Template card",
  capsule: "Template",
  cmdTitle: "Say hello",
  said: "Said hello"
}
const T = String(ctx.locale || "").toLowerCase().indexOf("en") === 0 ? en : zh

export default {
  onload(ctx) {
    // 2) 页面：返回一个节点树，主 App 负责渲染
    //    常用节点：page / section / text / row / list / card / stat / button /
    //              toggle / textField / picker / slider / divider / image / progress
    ctx.pages.register({
      id: "hello",
      render() {
        const n = Number(ctx.storage.get("count", 0)) || 0
        const saidAt = ctx.storage.get("saidAt")
        return {
          type: "page",
          children: [
            {
              type: "section",
              title: T.hello,
              children: [
                { type: "text", text: T.intro },
                {
                  type: "row",
                  title: T.counter,
                  value: String(n),
                  children: [
                    { type: "button", title: T.bump, icon: "plus", action: { command: "bump" } },
                    { type: "button", title: T.reset, icon: "arrow.counterclockwise", action: { command: "reset" } }
                  ]
                }
              ]
            },
            {
              type: "section",
              title: T.cmdTitle,
              children: [
                {
                  type: "list",
                  items: [
                    {
                      type: "row",
                      title: T.said,
                      subtitle: saidAt ? new Date(saidAt).toLocaleTimeString() : "—"
                    }
                  ]
                }
              ]
            }
          ]
        }
      }
    })

    // 3) 概览卡片：画在面板「概览」页的小卡片
    ctx.cards.register({
      id: "hello-card",
      render() {
        const n = Number(ctx.storage.get("count", 0)) || 0
        return { type: "card", title: T.cardTitle, value: String(n), subtitle: T.counter }
      }
    })

    // 4) 胶囊模式：用户在「胶囊 → 显示内容」里选中后，胶囊显示这一行文字
    ctx.capsule.register({
      id: "hello-capsule",
      render() {
        const n = Number(ctx.storage.get("count", 0)) || 0
        return { text: T.capsule + " " + n }
      }
    })

    // 5) 命令：出现在菜单「插件命令」里，也可以被别的插件调用
    ctx.commands.register({
      id: "bump",
      title: T.bump,
      run() { bump() }
    })
    ctx.commands.register({
      id: "reset",
      title: T.reset,
      run() {
        ctx.storage.set("count", 0)
        ctx.rerender()
      }
    })
    ctx.commands.register({
      id: "hello-say",
      title: T.cmdTitle,
      run() {
        ctx.storage.set("saidAt", Date.now())
        ctx.events.publish("template.ping", { at: Date.now() })
        ctx.rerender()
      }
    })

    // 6) 事件：订阅别人发来的事件
    ctx.events.subscribe("template.pong", function (payload) {
      ctx.storage.set("lastPong", payload && payload.at ? payload.at : Date.now())
      ctx.rerender()
    })

    function bump() {
      const n = (Number(ctx.storage.get("count", 0)) || 0) + 1
      ctx.storage.set("count", n)
      ctx.rerender() // 告诉宿主「数据变了，请重新渲染」
    }
  },

  onunload() {
    // 插件被卸载/禁用时调用（要清理定时器之类）
  }
}
