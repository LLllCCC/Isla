import SwiftUI
import AppKit
import WebKit

// MARK: - Phase 3：Web 自定义页
//
// 只有 manifest 里 `kind: "web"` 的页面走这里：
// - WKWebView 跑在 WebContent 进程，页面是插件目录里的本地 HTML；
// - 通过 `window.isla` 暴露受限能力（storage / clipboard / ui / log）；
// - 默认禁止一切 http(s) 请求，除非 manifest 声明了 network 权限；
// - 主题色由宿主注入的 CSS 变量提供，保证和面板一致。

private let islaWebHandlerName = "isla"

final class PluginWebRuleList {
    static let shared = PluginWebRuleList()

    private var list: WKContentRuleList?
    private var compiling = false
    private var waiters: [(WKContentRuleList?) -> Void] = []

    private static let denyAllJSON = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
    """

    /// 编译「禁止所有网络请求」的规则；已编译则直接回调。
    func withDenyList(_ done: @escaping (WKContentRuleList?) -> Void) {
        if let list { done(list); return }
        waiters.append(done)
        guard !compiling else { return }
        compiling = true
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "isla-deny-network",
            encodedContentRuleList: Self.denyAllJSON
        ) { [weak self] list, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.list = list
                self.compiling = false
                let pending = self.waiters
                self.waiters = []
                pending.forEach { $0(list) }
            }
        }
    }
}

// MARK: - 能力桥

final class PluginWebBridge: NSObject, WKScriptMessageHandlerWithReply {
    let pluginID: String
    let directory: URL
    let permissions: Set<String>
    weak var webView: WKWebView?

    private let storageURL: URL
    private var storage: [String: String] = [:]

    init(pluginID: String, directory: URL, permissions: [String]) {
        self.pluginID = pluginID
        self.directory = directory
        self.permissions = Set(permissions)
        storageURL = directory
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("storage.json")
        super.init()
        if let data = try? Data(contentsOf: storageURL),
           let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            storage = map
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String else {
            replyHandler(nil, L("请求格式错误"))
            return
        }
        let params = body["params"] as? [String: Any] ?? [:]

        switch method {
        case "storage.get":
            guard permissions.contains("storage") else { return fail(replyHandler, L("缺少 storage 权限")) }
            let key = params["key"] as? String ?? ""
            guard let raw = storage[key], let data = raw.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            else { replyHandler(NSNull(), nil); return }
            replyHandler(value, nil)

        case "storage.set":
            guard permissions.contains("storage") else { return fail(replyHandler, L("缺少 storage 权限")) }
            guard let key = params["key"] as? String,
                  let value = params["value"],
                  let encoded = Self.encodeJSON(value) else {
                return fail(replyHandler, L("storage.set 参数无效"))
            }
            storage[key] = encoded
            persistStorage()
            replyHandler(true, nil)

        case "storage.remove":
            guard permissions.contains("storage") else { return fail(replyHandler, L("缺少 storage 权限")) }
            if let key = params["key"] as? String { storage.removeValue(forKey: key) }
            persistStorage()
            replyHandler(true, nil)

        case "clipboard.readText":
            guard permissions.contains("clipboard") else { return fail(replyHandler, L("缺少 clipboard 权限")) }
            replyHandler(NSPasteboard.general.string(forType: .string) ?? "", nil)

        case "clipboard.writeText":
            guard permissions.contains("clipboard") else { return fail(replyHandler, L("缺少 clipboard 权限")) }
            let text = params["text"] as? String ?? ""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            replyHandler(true, nil)

        case "ui.openPage":
            let id = params["id"] as? String ?? ""
            replyHandler(openPage(id), nil)

        case "app.info":
            replyHandler([
                "version": AppInfo.version,
                "pluginID": pluginID,
                "dark": Theme.isDarkUI,
                "permissions": Array(permissions).sorted()
            ], nil)

        case "scrollState":
            let atTop = params["atTop"] as? Bool ?? true
            let atBottom = params["atBottom"] as? Bool ?? true
            (webView as? IslaWebView)?.scrollState = .init(atTop: atTop, atBottom: atBottom)
            replyHandler(true, nil)

        case "log":
            let text = params["message"] as? String ?? ""
            appendLog(text)
            replyHandler(true, nil)

        default:
            fail(replyHandler, String(format: L("未知能力：%@"), method))
        }
    }

    private func fail(_ reply: @escaping (Any?, String?) -> Void, _ message: String) {
        reply(nil, message)
    }

    private func persistStorage() {
        guard let data = try? JSONSerialization.data(withJSONObject: storage) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: storageURL)
    }

    private static func encodeJSON(_ value: Any) -> String? {
        let options: JSONSerialization.WritingOptions = JSONSerialization.isValidJSONObject(value)
            ? [] : .fragmentsAllowed
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func openPage(_ id: String) -> Bool {
        let candidates = [id, "plugin.\(pluginID).\(id)"]
        for candidate in candidates {
            if let desc = PageRegistry.descriptors.first(where: { $0.id == candidate }) {
                DispatchQueue.main.async { IslandStore.shared.page = desc.page }
                return true
            }
        }
        appendLog("ui.openPage 找不到页面：\(id)")
        return false
    }

    private func appendLog(_ message: String) {
        let url = PluginManager.shared.logsDirectory.appendingPathComponent("\(pluginID).log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) [web] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - WKWebView 承载

/// 面板是 nonactivating 浮层：默认第一次点击只会把 WebView 设为焦点，
/// 用户会觉得"点一下没反应"。这里让首击直接落到网页内容上。
final class IslaWebView: WKWebView {
    /// 网页滚动位置（由注入脚本上报）：决定滚轮到边界后是否交给面板翻页。
    struct ScrollState {
        var atTop = true
        var atBottom = true
    }
    var scrollState = ScrollState()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // 提前把 WebView 设成 first responder，网页里的按钮就不需要"第一下只聚焦"。
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }
}

struct PluginWebPageView: View {
    let pluginID: String
    let pageID: String
    let entry: String
    let directory: URL
    let permissions: [String]
    var height: CGFloat = 360
    /// 插件注册表 revision：更新/热重载后变化，用来强制重建 WKWebView。
    var revision: Int = 0

    var body: some View {
        PluginWebViewBox(pluginID: pluginID, pageID: pageID, entry: entry,
                         directory: directory, permissions: permissions)
            .id(revision)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.6)
            )
    }
}

private struct PluginWebViewBox: NSViewRepresentable {
    let pluginID: String
    let pageID: String
    let entry: String
    let directory: URL
    let permissions: [String]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let ucc = WKUserContentController()
        let bridge = PluginWebBridge(pluginID: pluginID, directory: directory, permissions: permissions)
        context.coordinator.bridge = bridge
        ucc.addScriptMessageHandler(bridge, contentWorld: .page, name: islaWebHandlerName)
        ucc.addUserScript(WKUserScript(source: Self.prelude(pluginID: pluginID, pageID: pageID,
                                                           permissions: permissions),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: Self.themeScript(),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc

        let web = IslaWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.appearance = NSAppearance(named: Theme.isDarkUI ? .darkAqua : .aqua)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        context.coordinator.webView = web
        bridge.webView = web

        let index = directory.appendingPathComponent(entry)
        let load = { [weak web] in
            guard let web else { return }
            web.loadFileURL(index, allowingReadAccessTo: directory)
        }
        if permissions.contains("network") {
            load()
        } else {
            // 先把"禁止网络"规则挂上再加载，避免页面首帧就发出请求。
            PluginWebRuleList.shared.withDenyList { list in
                if let list { web.configuration.userContentController.add(list) }
                load()
            }
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let signature = "\(Theme.isDarkUI)|\(Theme.nsAccent.description)"
        guard signature != context.coordinator.themeSignature else { return }
        context.coordinator.themeSignature = signature
        web.appearance = NSAppearance(named: Theme.isDarkUI ? .darkAqua : .aqua)
        web.evaluateJavaScript(Self.applyThemeJS())
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: islaWebHandlerName,
                                                                            contentWorld: .page)
        coordinator.bridge = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: PluginWebViewBox
        var bridge: PluginWebBridge?
        weak var webView: WKWebView?
        var themeSignature = ""

        init(_ parent: PluginWebViewBox) {
            self.parent = parent
            super.init()
            themeSignature = "\(Theme.isDarkUI)|\(Theme.nsAccent.description)"
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.isFileURL {
                let root = parent.directory.standardizedFileURL.path
                let path = url.standardizedFileURL.path
                decisionHandler(path.hasPrefix(root + "/") ? .allow : .cancel)
                return
            }
            if url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(parent.permissions.contains("network") ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            showError(error, in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showError(error, in: webView)
        }

        private func showError(_ error: Error, in web: WKWebView) {
            let escaped = (error.localizedDescription)
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
            let html = """
            <html><body style="margin:0;padding:14px;font:12px -apple-system;color:#e88;background:transparent">
            插件页加载失败<br><span style="opacity:.7">\(escaped)</span>
            </body></html>
            """
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    // MARK: 注入脚本

    private static func prelude(pluginID: String, pageID: String, permissions: [String]) -> String {
        let perms = permissions.map { "\"\(escapeJS($0))\"" }.joined(separator: ",")
        return """
        (function () {
          const handler = window.webkit && window.webkit.messageHandlers.isla;
          if (!handler) { return; }
          const call = (method, params) => handler.postMessage({ method: method, params: params || {} });
          window.isla = {
            plugin: { id: "\(escapeJS(pluginID))", page: "\(escapeJS(pageID))" },
            version: "\(escapeJS(AppInfo.version))",
            locale: "\(escapeJS(Locale.preferredLanguages.first ?? "zh-Hans"))",
            permissions: [\(perms)],
            dark: \(Theme.isDarkUI ? "true" : "false"),
            call: call,
            storage: {
              get: key => call("storage.get", { key: String(key) }),
              set: (key, value) => call("storage.set", { key: String(key), value: value }),
              remove: key => call("storage.remove", { key: String(key) })
            },
            clipboard: {
              readText: () => call("clipboard.readText"),
              writeText: text => call("clipboard.writeText", { text: String(text) })
            },
            ui: {
              openPage: id => call("ui.openPage", { id: String(id) })
            },
            log: function () {
              const text = Array.prototype.map.call(arguments, String).join(" ");
              return call("log", { message: text });
            }
          };

          // 把滚动边界上报给宿主：滚轮到顶/到底后，滚轮才用来翻页。
          const reportScroll = function () {
            const el = document.scrollingElement || document.documentElement;
            const y = (window.scrollY || el.scrollTop || 0);
            const viewport = window.innerHeight || el.clientHeight || 0;
            const height = el.scrollHeight || 0;
            call("scrollState", {
              atTop: y <= 1,
              atBottom: y + viewport >= height - 1
            }).catch(function () {});
          };
          window.addEventListener("scroll", reportScroll, { passive: true });
          window.addEventListener("resize", reportScroll, { passive: true });
          setTimeout(reportScroll, 0);
        })();
        """
    }

    private static func themeScript() -> String {
        """
        (function () {
          const css = `\(themeCSS())`;
          const apply = () => {
            const style = document.createElement("style");
            style.id = "isla-theme";
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
          };
          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", apply, { once: true });
          } else {
            apply();
          }
          window.__islaApplyTheme = function (vars) {
            for (const k in vars) { document.documentElement.style.setProperty(k, vars[k]); }
          };
        })();
        """
    }

    static func themeCSS() -> String {
        """
        :root {
          --isla-text: \(css(NSColor(Theme.textPrimary)));
          --isla-text-2: \(css(NSColor(Theme.textSecondary)));
          --isla-text-3: \(css(NSColor(Theme.textTertiary)));
          --isla-accent: \(css(Theme.nsAccent));
          --isla-surface: \(css(NSColor(Theme.surface)));
          --isla-surface-hi: \(css(NSColor(Theme.surfaceHi)));
          --isla-stroke: \(css(NSColor(Theme.stroke)));
          --isla-solid: \(css(NSColor(Theme.canvasSolid)));
          --isla-radius: \(Int(Theme.rCard))px;
          color-scheme: \(Theme.isDarkUI ? "dark" : "light");
        }
        html, body {
          margin: 0;
          height: 100%;
          background: transparent;
          color: var(--isla-text);
          font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
          font-size: 12px;
          -webkit-font-smoothing: antialiased;
        }
        * { box-sizing: border-box; }
        button {
          font: inherit;
          color: var(--isla-text);
          background: var(--isla-surface);
          border: 0.6px solid var(--isla-stroke);
          border-radius: 8px;
          padding: 5px 10px;
          cursor: pointer;
        }
        button:hover { background: var(--isla-surface-hi); }
        button.primary { color: #06110c; background: var(--isla-accent); border-color: transparent; }
        ::-webkit-scrollbar { width: 6px; }
        ::-webkit-scrollbar-thumb { background: var(--isla-stroke); border-radius: 3px; }
        """
    }

    static func applyThemeJS() -> String {
        let vars: [String: String] = [
            "--isla-text": css(NSColor(Theme.textPrimary)),
            "--isla-text-2": css(NSColor(Theme.textSecondary)),
            "--isla-text-3": css(NSColor(Theme.textTertiary)),
            "--isla-accent": css(Theme.nsAccent),
            "--isla-surface": css(NSColor(Theme.surface)),
            "--isla-surface-hi": css(NSColor(Theme.surfaceHi)),
            "--isla-stroke": css(NSColor(Theme.stroke)),
            "--isla-solid": css(NSColor(Theme.canvasSolid))
        ]
        let literal = vars.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ",")
        return "window.__islaApplyTheme && window.__islaApplyTheme({\(literal)});"
    }

    private static func css(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#ffffff" }
        return String(format: "rgba(%d, %d, %d, %.2f)",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)),
                      c.alphaComponent)
    }

    private static func escapeJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
