// 剪贴板看板 · 示例插件（Phase 1c 完整版）
// 主 App 把剪贴板历史同步给宿主；插件用 id 操作条目：
//   ctx.clipboard.copy(id)        复制（文本 / 图片 / 文件都由主 App 写回）
//   ctx.clipboard.pin(id, bool)   固定 / 取消固定（影响主 App 历史）
//   ctx.clipboard.remove(id)      删除（影响主 App 历史）


// 多语言：ctx.locale 是当前界面语言（zh-Hans / en…）。
// 插件自己写的文案按语言查表；manifest 里的 name/title 由主 App 处理（nameEn/titleEn）。
const T = (function () {
  const zh = {
    section: "PHASE 1C · 剪贴板看板",
    intro: "文本 / 图片 / 文件都可复制；固定和删除会同步主 App 历史。",
    total: "共 ", pinnedCount: " 条 · 固定 ", pinnedTail: " 条",
    current: "当前剪贴板",
    empty: "（空）",
    sort: "排序",
    newest: "最新在前",
    oldest: "最早在前",
    limit: "显示条数",
    pinned: "已固定",
    nothing: "没有可显示的条目，复制点什么再来。",
    refresh: "刷新",
    recent: "最近复制",
    copyTry: "复制点什么试试",
    image: "图片",
    files: "文件",
    text: "文本",
    itemsTail: " 条",
    items: " 条",
    copyLatest: "复制最近一条",
    copyPrev: "复制上一条",
    copyItem: "复制条目",
    copied: "已复制：",
    togglePin: "固定 / 取消固定",
    unpinned: "已取消固定",
    pinnedPrefix: "已固定：",
    deleteItem: "删除条目",
    deleted: "已删除：",
    toggleSort: "切换排序"
  }
  const en = {
    section: "PHASE 1C · Clipboard Board",
    intro: "Text, images and files can be copied; pinning and deleting sync with the main app history.",
    total: "", pinnedCount: " items · ", pinnedTail: " pinned",
    current: "Current clipboard",
    empty: "(empty)",
    sort: "Sort",
    newest: "Newest first",
    oldest: "Oldest first",
    limit: "Items shown",
    pinned: "Pinned",
    nothing: "Nothing to show yet — copy something first.",
    refresh: "Refresh",
    recent: "Recent copy",
    copyTry: "Copy something to try",
    image: "Image",
    files: "Files",
    text: "Text",
    itemsTail: " items",
    items: " items",
    copyLatest: "Copy latest",
    copyPrev: "Copy previous",
    copyItem: "Copy item",
    copied: "Copied: ",
    togglePin: "Pin / unpin",
    unpinned: "Unpinned",
    pinnedPrefix: "Pinned: ",
    deleteItem: "Delete item",
    deleted: "Deleted: ",
    toggleSort: "Toggle sort"
  }
  const isEn = String(ctx.locale || "").toLowerCase().indexOf("en") === 0
  return isEn ? en : zh
})()

export default {
  onload(ctx) {
    let sort = ctx.storage.get("sort", "newest") || "newest"
    let limit = Number(ctx.storage.get("limit", 6)) || 6
    let notice = ""

    function itemRow(it) {
      return {
        type: "row",
        title: it.preview,
        children: [
          {
            type: "button",
            title: "",
            icon: "doc.on.doc",
            compact: true,
            action: { command: "copy", value: it.id }
          },
          {
            type: "button",
            title: "",
            icon: it.pinned ? "pin.slash" : "pin",
            compact: true,
            action: { command: "togglePin", value: it.id }
          },
          {
            type: "button",
            title: "",
            icon: "trash",
            compact: true,
            action: { command: "remove", value: it.id }
          }
        ]
      }
    }

    function renderPage() {
      const all = ctx.clipboard.history()
      const pinnedItems = all.filter(function (it) { return it.pinned })
      const rest = all.filter(function (it) { return !it.pinned })
      const ordered = sort === "oldest" ? rest.slice().reverse() : rest
      const shown = ordered.slice(0, limit)

      const children = [
        {
          type: "section",
          title: T.section,
          children: [
            { type: "text", text: T.intro, style: "body" },
            {
              type: "text",
              text: notice || T.total + all.length + T.pinnedCount + pinnedItems.length + T.pinnedTail,
              style: "caption",
              tone: notice ? "accent" : "tertiary"
            }
          ]
        },
        {
          type: "row",
          title: T.current,
          value: (ctx.clipboard.read() || T.empty).slice(0, 36)
        },
        {
          type: "picker",
          id: "sort",
          title: T.sort,
          value: sort,
          options: [
            { title: T.newest, value: "newest" },
            { title: T.oldest, value: "oldest" }
          ],
          action: { command: "setSort" }
        },
        {
          type: "slider",
          id: "limit",
          title: T.limit,
          value: String(limit),
          min: 3,
          max: 20,
          step: 1,
          action: { command: "setLimit" }
        },
        { type: "divider" }
      ]

      if (pinnedItems.length > 0) {
        children.push({ type: "section", title: T.pinned, children: pinnedItems.map(itemRow) })
        children.push({ type: "divider" })
      }

      if (shown.length > 0) {
        children.push({ type: "list", children: shown.map(itemRow) })
      } else {
        children.push({ type: "text", text: T.nothing, style: "caption", tone: "tertiary" })
      }

      children.push({ type: "divider" })
      children.push({ type: "button", title: T.refresh, icon: "arrow.clockwise", action: { command: "refresh" } })

      return { type: "page", children: children }
    }

    function itemByID(id) {
      return ctx.clipboard.history().filter(function (it) { return it.id === id })[0]
    }

    function notifyChanged(action) {
      ctx.events.publish("clipboard.board.changed", {
        action: action,
        count: ctx.clipboard.history().length
      })
    }

    ctx.pages.register({ id: "board", render: renderPage })

    // 概览卡片：最近一条复制内容 + 总数。
    ctx.cards.register({
      id: "recent",
      render: function () {
        const all = ctx.clipboard.history()
        if (all.length === 0) {
          return { type: "card", title: T.recent, value: "—", subtitle: T.copyTry }
        }
        const first = all[0]
        const kind = first.kind === "image" ? T.image : (first.kind === "files" ? T.files : T.text)
        return {
          type: "card",
          title: T.recent,
          value: first.preview.slice(0, 18),
          subtitle: kind + " · " + all.length + T.itemsTail
        }
      }
    })

    // 胶囊模式：显示当前历史条数。
    ctx.capsule.register({
      id: "count",
      render: function () {
        return { text: ctx.clipboard.history().length + T.items }
      }
    })

    ctx.commands.register({
      id: "copy-latest",
      title: T.copyLatest,
      run: function () {
        const all = ctx.clipboard.history()
        if (all.length > 0) {
          ctx.clipboard.copy(all[0].id)
          notifyChanged("copy-latest")
        }
      }
    })

    ctx.commands.register({
      id: "copy-previous",
      title: T.copyPrev,
      run: function () {
        const all = ctx.clipboard.history()
        if (all.length > 1) {
          ctx.clipboard.copy(all[1].id)
          notifyChanged("copy-previous")
        }
      }
    })

    ctx.commands.register({
      id: "copy",
      title: T.copyItem,
      run: function (value) {
        const it = itemByID(String(value || ""))
        if (!it) return
        if (ctx.clipboard.copy(it.id)) {
          notice = T.copied + it.preview.slice(0, 28)
          notifyChanged("copy")
          ctx.rerender()
        }
      }
    })

    ctx.commands.register({
      id: "togglePin",
      title: T.togglePin,
      run: function (value) {
        const it = itemByID(String(value || ""))
        if (!it) return
        ctx.clipboard.pin(it.id, !it.pinned)
        notice = it.pinned ? T.unpinned : T.pinnedPrefix + it.preview.slice(0, 24)
        notifyChanged("pin")
        ctx.rerender()
      }
    })

    ctx.commands.register({
      id: "remove",
      title: T.deleteItem,
      run: function (value) {
        const it = itemByID(String(value || ""))
        if (!it) return
        ctx.clipboard.remove(it.id)
        notice = T.deleted + it.preview.slice(0, 24)
        notifyChanged("remove")
        ctx.rerender()
      }
    })

    ctx.commands.register({
      id: "setSort",
      title: T.toggleSort,
      run: function (value) {
        sort = String(value || "newest")
        ctx.storage.set("sort", sort)
        notice = ""
        ctx.rerender()
      }
    })

    ctx.commands.register({
      id: "setLimit",
      title: T.limit,
      run: function (value) {
        limit = Math.max(3, Math.min(20, Number(value) || 6))
        ctx.storage.set("limit", limit)
        notice = ""
        ctx.rerender()
      }
    })

    ctx.commands.register({
      id: "refresh",
      title: T.refresh,
      run: function () {
        notice = ""
        ctx.rerender()
      }
    })
  },
  onunload() {}
}
