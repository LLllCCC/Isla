import Foundation
import AppKit
import JavaScriptCore

// Isla 插件宿主：独立子进程，主 App 通过 stdin/stdout 上的 JSON-RPC 调用。
// 每个插件一个 JSContext；插件崩溃/死循环不会拖死主进程。
// 协议：
//   main -> host  {"jsonrpc":"2.0","id":1,"method":"load","params":{...}}
//   main -> host  {"jsonrpc":"2.0","id":2,"method":"render","params":{"pluginID":"...","pageID":"..."}}
//   host -> main  {"jsonrpc":"2.0","id":2,"result":{"tree":{...}}}
//   host -> main  {"jsonrpc":"2.0","method":"invalidate","params":{"pluginID":"..."}}

final class PluginInstance {
    let id: String
    let directory: URL
    let logPath: URL
    let permissions: Set<String>
    let context: JSContext
    var pages: [String: JSValue] = [:]
    var cards: [String: JSValue] = [:]
    var capsules: [String: JSValue] = [:]
    var commands: [String: JSValue] = [:]
    /// 插件间事件：manifest 声明的发布/订阅白名单，以及已注册的 JS 处理函数。
    var publishes: Set<String> = []
    var subscribes: Set<String> = []
    var eventHandlers: [String: JSValue] = [:]
    let storageURL: URL
    var storage: [String: String]
    /// 主 App 推过来的剪贴板历史（JSON 字符串）与当前文本。
    var clipboardJSON = "[]"
    var clipboardCurrent = ""

    init(id: String, directory: URL, logPath: URL, permissions: Set<String>,
         context: JSContext, storageURL: URL, storage: [String: String]) {
        self.id = id
        self.directory = directory
        self.logPath = logPath
        self.permissions = permissions
        self.context = context
        self.storageURL = storageURL
        self.storage = storage
    }
}

var instances: [String: PluginInstance] = [:]

func writeLine(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    var line = data
    line.append(0x0A)
    try? FileHandle.standardOutput.write(contentsOf: line)
}

func respond(_ id: Any?, result: [String: Any]) {
    writeLine(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
}

func respondError(_ id: Any?, _ message: String) {
    writeLine(["jsonrpc": "2.0", "id": id ?? NSNull(),
               "error": ["code": -1, "message": message]])
}

func notify(_ method: String, _ params: [String: Any]) {
    writeLine(["jsonrpc": "2.0", "method": method, "params": params])
}

func appendLog(pluginID: String, path: URL, message: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(message)\n"
    try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let data = line.data(using: .utf8) else { return }
    if let fh = try? FileHandle(forWritingTo: path) {
        fh.seekToEndOfFile()
        try? fh.write(contentsOf: data)
        try? fh.close()
    } else {
        try? data.write(to: path)
    }
    notify("log", ["pluginID": pluginID, "message": message])
}

// MARK: - 生命周期

let prelude = """
var __pages = {};
var __cards = {};
var __capsules = {};
var __commands = {};
var __pluginDefault = undefined;
var module = { exports: {} };
var exports = module.exports;
var ctx = {
  locale: (typeof __locale === "string" ? __locale : "zh-Hans"),
  log: function(message) { __hostLog(String(message)); },
  pages: { register: function(def) { if (def && def.id) __pages[String(def.id)] = def; } },
  cards: { register: function(def) { if (def && def.id) __cards[String(def.id)] = def; } },
  capsule: { register: function(def) { if (def && def.id) __capsules[String(def.id)] = def; } },
  commands: { register: function(def) { if (def && def.id) __commands[String(def.id)] = def; } },
  storage: {
    get: function(key, fallback) {
      var raw = __storageGet(String(key));
      if (raw === null || raw === undefined) return fallback;
      try { return JSON.parse(raw); } catch (e) { return fallback; }
    },
    set: function(key, value) { __storageSet(String(key), JSON.stringify(value)); },
    remove: function(key) { __storageRemove(String(key)); }
  },
  clipboard: {
    history: function() {
      try { return JSON.parse(__clipboardHistory() || "[]"); } catch (e) { return []; }
    },
    read: function() { return __clipboardCurrent() || ""; },
    write: function(text) { return __clipboardWrite(String(text)); },
    copy: function(id) { return __clipboardCopy(String(id)); },
    pin: function(id, pinned) { return __clipboardPin(String(id), !!pinned); },
    remove: function(id) { return __clipboardRemove(String(id)); }
  },
  events: {
    publish: function(name, payload) {
      var json = "null";
      try { json = JSON.stringify(payload === undefined ? null : payload); } catch (e) {}
      return __eventsPublish(String(name), json);
    },
    subscribe: function(name, handler) {
      if (typeof handler !== "function") return false;
      return __eventsSubscribe(String(name), handler);
    }
  },
  rerender: function() { __hostRerender(); }
};
"""

func loadPlugin(_ reqID: Any?, _ params: [String: Any]) {
    guard let pluginID = params["pluginID"] as? String,
          let dirPath = params["directory"] as? String,
          let mainFile = params["main"] as? String,
          let logPath = params["logPath"] as? String else {
        respondError(reqID, "load 参数不完整")
        return
    }
    let directory = URL(fileURLWithPath: dirPath, isDirectory: true)
    let mainURL = directory.appendingPathComponent(mainFile)
    guard let source = try? String(contentsOf: mainURL, encoding: .utf8) else {
        respondError(reqID, "读不到入口文件：\(mainFile)")
        return
    }

    instances.removeValue(forKey: pluginID)

    let permissions = Set(params["permissions"] as? [String] ?? [])
    let context = JSContext()!
    let logURL = URL(fileURLWithPath: logPath)

    let dataDir = directory.appendingPathComponent("data", isDirectory: true)
    try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    let storageURL = dataDir.appendingPathComponent("storage.json")
    var storage: [String: String] = [:]
    if let data = try? Data(contentsOf: storageURL),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
        storage = obj
    }

    let instance = PluginInstance(id: pluginID, directory: directory, logPath: logURL,
                                  permissions: permissions, context: context,
                                  storageURL: storageURL, storage: storage)
    instance.publishes = Set(params["canPublish"] as? [String] ?? [])
    instance.subscribes = Set(params["canSubscribe"] as? [String] ?? [])
    instances[pluginID] = instance

    context.exceptionHandler = { _, exception in
        appendLog(pluginID: pluginID, path: logURL,
                  message: "JS 异常：\(exception?.toString() ?? "unknown")")
    }

    let logBlock: @convention(block) (String) -> Void = { message in
        appendLog(pluginID: pluginID, path: logURL, message: message)
    }
    context.setObject(logBlock, forKeyedSubscript: "__hostLog" as NSString)
    // 界面语言：宿主进程独立运行，拿不到 App 的语言设置，由 App 在 load 时传进来
    context.setObject(params["locale"] as? String ?? "zh-Hans", forKeyedSubscript: "__locale" as NSString)

    let storageGet: @convention(block) (String) -> String? = { key in
        guard permissions.contains("storage") else { return nil }
        return instance.storage[key]
    }
    context.setObject(storageGet, forKeyedSubscript: "__storageGet" as NSString)

    let storageSet: @convention(block) (String, String) -> Void = { key, value in
        guard permissions.contains("storage") else {
            appendLog(pluginID: pluginID, path: logURL, message: "缺少 storage 权限")
            return
        }
        instance.storage[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: instance.storage) {
            try? data.write(to: storageURL)
        }
    }
    context.setObject(storageSet, forKeyedSubscript: "__storageSet" as NSString)

    let storageRemove: @convention(block) (String) -> Void = { key in
        guard permissions.contains("storage") else { return }
        instance.storage.removeValue(forKey: key)
        if let data = try? JSONSerialization.data(withJSONObject: instance.storage) {
            try? data.write(to: storageURL)
        }
    }
    context.setObject(storageRemove, forKeyedSubscript: "__storageRemove" as NSString)

    let clipboardHistory: @convention(block) () -> String = {
        instance.clipboardJSON
    }
    context.setObject(clipboardHistory, forKeyedSubscript: "__clipboardHistory" as NSString)

    let clipboardCurrent: @convention(block) () -> String = {
        instance.clipboardCurrent
    }
    context.setObject(clipboardCurrent, forKeyedSubscript: "__clipboardCurrent" as NSString)

    let clipboardWrite: @convention(block) (String) -> Bool = { text in
        guard permissions.contains("clipboard") else {
            appendLog(pluginID: pluginID, path: logURL, message: "缺少 clipboard 权限")
            return false
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        instance.clipboardCurrent = text
        return true
    }
    context.setObject(clipboardWrite, forKeyedSubscript: "__clipboardWrite" as NSString)

    // 按 id 操作主 App 的历史条目：图片/文件不需要跨进程传数据。
    // 只发通知，主 App 执行后通过 clipboardSync + invalidate 回推最新状态。
    func historyAction(_ action: String, id: String, pinned: Bool = false) -> Bool {
        guard permissions.contains("clipboard") else {
            appendLog(pluginID: pluginID, path: logURL, message: "缺少 clipboard 权限")
            return false
        }
        var params: [String: Any] = ["action": action, "id": id]
        if action == "pin" { params["pinned"] = pinned }
        notify("clipboardCommand", params)
        return true
    }
    let clipboardCopy: @convention(block) (String) -> Bool = { id in
        historyAction("copy", id: id)
    }
    context.setObject(clipboardCopy, forKeyedSubscript: "__clipboardCopy" as NSString)
    let clipboardPin: @convention(block) (String, Bool) -> Bool = { id, pinned in
        historyAction("pin", id: id, pinned: pinned)
    }
    context.setObject(clipboardPin, forKeyedSubscript: "__clipboardPin" as NSString)
    let clipboardRemove: @convention(block) (String) -> Bool = { id in
        historyAction("remove", id: id)
    }
    context.setObject(clipboardRemove, forKeyedSubscript: "__clipboardRemove" as NSString)

    // 插件间事件总线：只转发 manifest 声明过的名字，不暴露任意广播。
    let eventsPublish: @convention(block) (String, String) -> Bool = { name, json in
        guard instance.publishes.contains(name) else {
            appendLog(pluginID: pluginID, path: logURL, message: "未声明发布事件：\(name)")
            return false
        }
        let payload: Any
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            payload = obj
        } else {
            payload = NSNull()
        }
        for target in instances.values where target.id != pluginID && target.subscribes.contains(name) {
            guard let handler = target.eventHandlers[name] else { continue }
            let value = JSValue(object: payload, in: target.context) ?? JSValue(undefinedIn: target.context)
            target.context.exception = nil
            handler.call(withArguments: [value])
            if let e = target.context.exception, !e.isUndefined {
                appendLog(pluginID: target.id, path: target.logPath,
                          message: "事件 \(name) 处理失败：\(e.toString() ?? "unknown")")
            }
        }
        return true
    }
    context.setObject(eventsPublish, forKeyedSubscript: "__eventsPublish" as NSString)

    let eventsSubscribe: @convention(block) (String, JSValue) -> Bool = { name, handler in
        guard instance.subscribes.contains(name) else {
            appendLog(pluginID: pluginID, path: logURL, message: "未声明订阅事件：\(name)")
            return false
        }
        instance.eventHandlers[name] = handler
        return true
    }
    context.setObject(eventsSubscribe, forKeyedSubscript: "__eventsSubscribe" as NSString)

    let rerender: @convention(block) () -> Void = {
        notify("invalidate", ["pluginID": pluginID])
    }
    context.setObject(rerender, forKeyedSubscript: "__hostRerender" as NSString)

    context.evaluateScript(prelude)

    // 支持 `export default { ... }` 与 CommonJS 两种写法，不引入完整模块系统。
    let transformed = source.replacingOccurrences(of: "export default",
                                                  with: "globalThis.__pluginDefault =")
    context.evaluateScript(transformed)
    if let exception = context.exception, !exception.isUndefined {
        respondError(reqID, "脚本执行失败：\(exception.toString() ?? "unknown")")
        instances.removeValue(forKey: pluginID)
        return
    }

    let defaultPlugin = context.objectForKeyedSubscript("__pluginDefault")
    let moduleExports = context.objectForKeyedSubscript("module")?.objectForKeyedSubscript("exports")
    let plugin: JSValue?
    if let d = defaultPlugin, !d.isUndefined, !d.isNull {
        plugin = d
    } else if let m = moduleExports, !m.isUndefined {
        plugin = m
    } else {
        plugin = nil
    }
    guard let plugin, plugin.isObject else {
        respondError(reqID, "插件没有导出对象（需要 export default { ... }）")
        instances.removeValue(forKey: pluginID)
        return
    }

    if let onload = plugin.objectForKeyedSubscript("onload"), onload.isObject,
       let ctxValue = context.objectForKeyedSubscript("ctx") {
        onload.call(withArguments: [ctxValue])
        if let exception = context.exception, !exception.isUndefined {
            respondError(reqID, "onload 失败：\(exception.toString() ?? "unknown")")
            instances.removeValue(forKey: pluginID)
            return
        }
    }

    let pageKeys = context.evaluateScript("Object.keys(__pages)")?.toArray() as? [String] ?? []
    let pageStore = context.objectForKeyedSubscript("__pages")
    for key in pageKeys {
        if let value = pageStore?.objectForKeyedSubscript(key) {
            instance.pages[key] = value
        }
    }
    let commandKeys = context.evaluateScript("Object.keys(__commands)")?.toArray() as? [String] ?? []
    let commandStore = context.objectForKeyedSubscript("__commands")
    for key in commandKeys {
        if let value = commandStore?.objectForKeyedSubscript(key) {
            instance.commands[key] = value
        }
    }
    let cardKeys = context.evaluateScript("Object.keys(__cards)")?.toArray() as? [String] ?? []
    let cardStore = context.objectForKeyedSubscript("__cards")
    for key in cardKeys {
        if let value = cardStore?.objectForKeyedSubscript(key) {
            instance.cards[key] = value
        }
    }
    let capsuleKeys = context.evaluateScript("Object.keys(__capsules)")?.toArray() as? [String] ?? []
    let capsuleStore = context.objectForKeyedSubscript("__capsules")
    for key in capsuleKeys {
        if let value = capsuleStore?.objectForKeyedSubscript(key) {
            instance.capsules[key] = value
        }
    }

    respond(reqID, result: ["ok": true, "pages": pageKeys, "cards": cardKeys, "capsules": capsuleKeys])
    appendLog(pluginID: pluginID, path: logURL,
              message: "loaded \(mainFile)；pages=\(pageKeys.count)")
}

// MARK: - 渲染 / 命令

func syncClipboard(_ reqID: Any?, _ params: [String: Any]) {
    let items = params["items"] as? [[String: Any]] ?? []
    let json: String
    if let data = try? JSONSerialization.data(withJSONObject: items),
       let text = String(data: data, encoding: .utf8) {
        json = text
    } else {
        json = "[]"
    }
    let current = params["current"] as? String ?? ""
    for instance in instances.values {
        instance.clipboardJSON = json
        instance.clipboardCurrent = current
    }
    respond(reqID, result: ["ok": true])
    for id in instances.keys {
        notify("invalidate", ["pluginID": id])
    }
}

func renderPage(_ reqID: Any?, _ params: [String: Any]) {
    guard let pluginID = params["pluginID"] as? String,
          let pageID = params["pageID"] as? String,
          let instance = instances[pluginID] else {
        respondError(reqID, "插件未加载")
        return
    }
    guard let page = instance.pages[pageID] else {
        respondError(reqID, "页面未注册：\(pageID)")
        return
    }
    guard let render = page.objectForKeyedSubscript("render"), render.isObject else {
        respondError(reqID, "页面缺少 render()")
        return
    }
    instance.context.exception = nil
    let result = render.call(withArguments: [])
    if let exception = instance.context.exception, !exception.isUndefined {
        respondError(reqID, "render 失败：\(exception.toString() ?? "unknown")")
        return
    }
    guard let value = result,
          let stringify = instance.context.objectForKeyedSubscript("JSON")?
            .objectForKeyedSubscript("stringify"),
          let jsonValue = stringify.call(withArguments: [value]),
          let json = jsonValue.toString(),
          let data = json.data(using: .utf8),
          let tree = try? JSONSerialization.jsonObject(with: data) else {
        respondError(reqID, "render 没有返回可序列化对象")
        return
    }
    respond(reqID, result: ["tree": tree])
}

func renderCard(_ reqID: Any?, _ params: [String: Any]) {
    guard let pluginID = params["pluginID"] as? String,
          let cardID = params["cardID"] as? String,
          let instance = instances[pluginID] else {
        respondError(reqID, "插件未加载")
        return
    }
    guard let card = instance.cards[cardID] else {
        respondError(reqID, "卡片未注册：\(cardID)")
        return
    }
    guard let render = card.objectForKeyedSubscript("render"), render.isObject else {
        respondError(reqID, "卡片缺少 render()")
        return
    }
    instance.context.exception = nil
    let result = render.call(withArguments: [])
    if let exception = instance.context.exception, !exception.isUndefined {
        respondError(reqID, "卡片渲染失败：\(exception.toString() ?? "unknown")")
        return
    }
    guard let value = result,
          let stringify = instance.context.objectForKeyedSubscript("JSON")?
            .objectForKeyedSubscript("stringify"),
          let jsonValue = stringify.call(withArguments: [value]),
          let json = jsonValue.toString(),
          let data = json.data(using: .utf8),
          let tree = try? JSONSerialization.jsonObject(with: data) else {
        respondError(reqID, "卡片没有返回可序列化对象")
        return
    }
    respond(reqID, result: ["tree": tree])
}

func renderCapsule(_ reqID: Any?, _ params: [String: Any]) {
    guard let pluginID = params["pluginID"] as? String,
          let capsuleID = params["capsuleID"] as? String,
          let instance = instances[pluginID] else {
        respondError(reqID, "插件未加载")
        return
    }
    guard let capsule = instance.capsules[capsuleID] else {
        respondError(reqID, "胶囊模式未注册：\(capsuleID)")
        return
    }
    guard let render = capsule.objectForKeyedSubscript("render"), render.isObject else {
        respondError(reqID, "胶囊模式缺少 render()")
        return
    }
    instance.context.exception = nil
    let result = render.call(withArguments: [])
    if let exception = instance.context.exception, !exception.isUndefined {
        respondError(reqID, "胶囊渲染失败：\(exception.toString() ?? "unknown")")
        return
    }
    guard let value = result,
          let stringify = instance.context.objectForKeyedSubscript("JSON")?
            .objectForKeyedSubscript("stringify"),
          let jsonValue = stringify.call(withArguments: [value]),
          let json = jsonValue.toString(),
          let data = json.data(using: .utf8),
          let capsuleValue = try? JSONSerialization.jsonObject(with: data) else {
        respondError(reqID, "胶囊没有返回可序列化对象")
        return
    }
    respond(reqID, result: ["capsule": capsuleValue])
}

func invokeCommand(_ reqID: Any?, _ params: [String: Any]) {
    guard let pluginID = params["pluginID"] as? String,
          let commandID = params["command"] as? String,
          let instance = instances[pluginID] else {
        respondError(reqID, "插件未加载")
        return
    }
    guard let command = instance.commands[commandID] else {
        respondError(reqID, "命令未注册：\(commandID)")
        return
    }
    guard let run = command.objectForKeyedSubscript("run"), run.isObject else {
        respondError(reqID, "命令缺少 run()")
        return
    }
    instance.context.exception = nil
    let payload = params["value"]
    let argument = payload.flatMap { JSValue(object: $0, in: instance.context) }
        ?? JSValue(undefinedIn: instance.context)
    run.call(withArguments: [argument])
    if let exception = instance.context.exception, !exception.isUndefined {
        let message = exception.toString() ?? "unknown"
        appendLog(pluginID: pluginID, path: instance.logPath, message: "命令 \(commandID) 失败：\(message)")
        respondError(reqID, "命令失败：\(message)")
        return
    }
    respond(reqID, result: ["ok": true])
}

// MARK: - 主循环

func handle(_ line: String) {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    let reqID = object["id"]
    let method = object["method"] as? String ?? ""
    let params = object["params"] as? [String: Any] ?? [:]

    switch method {
    case "load":
        loadPlugin(reqID, params)
    case "unload":
        if let pluginID = params["pluginID"] as? String {
            instances.removeValue(forKey: pluginID)
        }
        respond(reqID, result: ["ok": true])
    case "render":
        renderPage(reqID, params)
    case "renderCard":
        renderCard(reqID, params)
    case "renderCapsule":
        renderCapsule(reqID, params)
    case "clipboardSync":
        syncClipboard(reqID, params)
    case "invoke":
        invokeCommand(reqID, params)
    case "ping":
        respond(reqID, result: ["ok": true])
    default:
        respondError(reqID, "未知方法：\(method)")
    }
}

while let line = readLine() {
    handle(line)
}
