(function () {
  const $ = (s) => document.querySelector(s);

  // 多语言：window.isla.locale 是当前界面语言（zh-Hans / en…）。
  const I18N = {
    zh: {
      title: "数据面板", visits: "打开次数", visitsHint: "存在插件自己的 storage",
      clipLen: "剪贴板字符", readClip: "读取剪贴板", last7: "最近 7 天打开", times: "次",
      copyTime: "复制当前时间", overview: "回到概览", testNet: "测试网络", reset: "重置统计",
      foot: '这个页面由插件自己的 HTML/CSS 渲染；<code>storage</code>、<code>clipboard</code>、<code>ui</code> 都通过宿主注入的 <code>window.isla</code> 受限桥访问。未声明 <code>network</code> 权限时，所有 http(s) 请求会被拦截。',
      copied: "已复制 ", copyFailed: "复制失败：", clipEmpty: "剪贴板是空的",
      noPerm: "没有 clipboard 权限", readOk: "已读取剪贴板", noOverview: "打不开概览页",
      testing: "测试中…", netOk: "网络请求成功（已声明 network）",
      netBlocked: "网络请求被拦截（未声明 network 权限）", resetOk: "统计已重置",
      resetFailed: "重置失败：", noBridge: "isla 桥未注入", initFailed: "初始化失败，查看插件日志",
      weekPrefix: "周", timesSuffix: " 次", week: ["日", "一", "二", "三", "四", "五", "六"]
    },
    en: {
      title: "Data Dashboard", visits: "Opens", visitsHint: "Stored in the plugin's own storage",
      clipLen: "Clipboard chars", readClip: "Read clipboard", last7: "Opens in the last 7 days", times: "times",
      copyTime: "Copy current time", overview: "Back to overview", testNet: "Test network", reset: "Reset stats",
      foot: 'This page is rendered by the plugin\'s own HTML/CSS; <code>storage</code>, <code>clipboard</code> and <code>ui</code> all go through the host-injected <code>window.isla</code> bridge. Without the <code>network</code> permission, every http(s) request is blocked.',
      copied: "Copied ", copyFailed: "Copy failed: ", clipEmpty: "Clipboard is empty",
      noPerm: "No clipboard permission", readOk: "Clipboard read", noOverview: "Cannot open the overview",
      testing: "Testing…", netOk: "Network OK (network declared)",
      netBlocked: "Network blocked (no network permission)", resetOk: "Stats reset",
      resetFailed: "Reset failed: ", noBridge: "isla bridge not injected", initFailed: "Init failed, check the plugin log",
      weekPrefix: "Week", timesSuffix: " times", week: ["S", "M", "T", "W", "T", "F", "S"]
    }
  };
  const isEn = String((window.isla && window.isla.locale) || "").toLowerCase().indexOf("en") === 0;
  const T = isEn ? I18N.en : I18N.zh;
  const t = (k) => T[k];
  const WEEK = T.week;

  function applyI18n() {
    document.querySelectorAll("[data-i18n]").forEach((el) => {
      const key = el.getAttribute("data-i18n");
      if (T[key]) el.textContent = T[key];
    });
    document.querySelectorAll("[data-i18n-html]").forEach((el) => {
      const key = el.getAttribute("data-i18n-html");
      if (T[key]) el.innerHTML = T[key];
    });
    document.title = T.title;
  }
  let toastTimer = null;

  function toast(text) {
    const el = $("#toast");
    el.textContent = text;
    el.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("show"), 1600);
  }

  async function log(message) {
    try { if (window.isla) await window.isla.log(message); } catch (e) { /* 日志失败不影响页面 */ }
  }

  function renderBars(history, today) {
    const bars = $("#bars");
    const days = $("#days");
    bars.innerHTML = "";
    days.innerHTML = "";
    const max = Math.max(1, ...history.map((n) => Number(n) || 0));
    let total = 0;
    for (let i = 0; i < 7; i++) {
      const count = Number(history[i]) || 0;
      total += count;
      const bar = document.createElement("div");
      bar.className = "bar" + (i === today ? " today" : "");
      bar.style.height = Math.max(3, Math.round((count / max) * 54)) + "px";
      bar.title = T.weekPrefix + " " + WEEK[i] + ": " + count + " " + T.times;
      bars.appendChild(bar);
      const label = document.createElement("span");
      label.textContent = WEEK[i];
      days.appendChild(label);
    }
    $("#chartTotal").textContent = total + " " + T.times;
  }

  async function refreshClipboard() {
    if (!window.isla) return;
    try {
      const text = await window.isla.clipboard.readText();
      $("#clipLen").textContent = (text || "").length;
      $("#clipPreview").textContent = text ? text.slice(0, 40) : t("clipEmpty");
    } catch (e) {
      $("#clipPreview").textContent = t("noPerm");
      await log("clipboard read failed: " + e);
    }
  }

  function bind() {
    $("#copyTime").addEventListener("click", async () => {
      const now = new Date();
      const text = now.getFullYear() + "-" + String(now.getMonth() + 1).padStart(2, "0") + "-" +
        String(now.getDate()).padStart(2, "0") + " " +
        String(now.getHours()).padStart(2, "0") + ":" +
        String(now.getMinutes()).padStart(2, "0") + ":" +
        String(now.getSeconds()).padStart(2, "0");
      try {
        await window.isla.clipboard.writeText(text);
        toast(t("copied") + text);
        await refreshClipboard();
        await log("clipboard.writeText ok");
      } catch (e) {
        toast(t("copyFailed") + e);
      }
    });

    $("#readClip").addEventListener("click", async () => {
      await refreshClipboard();
      toast(t("readOk"));
    });

    $("#overview").addEventListener("click", async () => {
      const ok = await window.isla.ui.openPage("overview");
      if (!ok) toast(t("noOverview"));
    });

    $("#testNet").addEventListener("click", async () => {
      toast(t("testing"));
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 2500);
      try {
        await fetch("https://example.com/?ping=" + Date.now(),
                    { signal: controller.signal, cache: "no-store" });
        toast(t("netOk"));
        await log("network test: allowed");
      } catch (e) {
        toast(t("netBlocked"));
        await log("network test: blocked");
      } finally {
        clearTimeout(timer);
      }
    });

    $("#reset").addEventListener("click", async () => {
      try {
        await window.isla.storage.remove("visits");
        await window.isla.storage.remove("history");
        $("#visits").textContent = "0";
        renderBars([0, 0, 0, 0, 0, 0, 0], new Date().getDay());
        toast(t("resetOk"));
      } catch (e) {
        toast(t("resetFailed") + e);
      }
    });
  }

  async function init() {
    applyI18n();
    bind();
    if (!window.isla) {
      toast(t("noBridge"));
      return;
    }
    try {
      await log("dashboard ready");
      let visits = Number((await window.isla.storage.get("visits")) || 0) + 1;
      await window.isla.storage.set("visits", visits);
      $("#visits").textContent = visits;

      let history = await window.isla.storage.get("history");
      if (!Array.isArray(history) || history.length !== 7) {
        history = [0, 0, 0, 0, 0, 0, 0];
      }
      const today = new Date().getDay();
      history[today] = Number(history[today] || 0) + 1;
      await window.isla.storage.set("history", history);
      renderBars(history, today);

      await refreshClipboard();

      // 默认拒绝网络：没声明 network 权限时，这条请求应被宿主规则拦截。
      try {
        await fetch("https://example.com/?probe=" + Date.now(), { cache: "no-store" });
        await log("network probe: allowed");
      } catch (e) {
        await log("network probe: blocked");
      }
    } catch (e) {
      await log("init failed: " + e);
      toast(t("initFailed"));
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init, { once: true });
  } else {
    init();
  }
})();
