// 合成点击工具（三步式：move → down → up，补第二发双保险）。
// 2026-11-19 实测：单事件投递（旧 /tmp/click.swift）在部分会话下静默失效
//（AX 权限正常、鼠标移动事件有效），三步式 100% 生效。
// 用法：swift tools/synth-click.swift x y   （编译：swiftc -o /tmp/click2 tools/synth-click.swift）
import CoreGraphics
import Foundation
let args = CommandLine.arguments
let x = Double(args[1])!, y = Double(args[2])!
let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
move.post(tap: .cghidEventTap)
usleep(180000)
let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
down.post(tap: .cghidEventTap)
usleep(90000)
let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
up.post(tap: .cghidEventTap)
usleep(120000)
// 双保险：再补一次完整点击
let down2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
down2.post(tap: .cghidEventTap)
usleep(90000)
let up2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
up2.post(tap: .cghidEventTap)
