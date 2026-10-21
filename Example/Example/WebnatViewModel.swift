//
//  WebnatViewModel.swift
//  Example
//
//  Created by auhgnayuo on 2025/11/14.
//

import Foundation
import WebKit
import Webnat

@MainActor
class WebnatViewModel: ObservableObject {
    @Published var logs: [LogEntry] = []
    @Published var connectionCount: Int = 0
    
    private var webView: WKWebView?
    private var webnat: Webnat?
    
    // UTF-8 边界字符测试数据
    private let utf8BoundaryChars: [String: Any] = [
        "ascii": "Hello World! 123",
        "latin1": "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏ",
        "cjk": "你好世界！中文测试",
        "emoji": "😀😁😂🤣😃😄😅",
        "mixed": "Hello 你好 😀 世界 World! 测试 Test 123",
        "boundaries": "\u{0000}\u{007F}\u{0080}\u{07FF}\u{0800}\u{FFFF}",
        "special": "\n\r\t\\/\"'`{}[]()<>",
        "empty": "",
        "long": String(repeating: "A", count: 1000) + String(repeating: "你", count: 100) + String(repeating: "😀", count: 50),
        "array": ["Hello World! 123", "你好世界！中文测试", "😀😁😂🤣😃😄😅"],
        "nested": [
            "level1": [
                "level2": [
                    "level3": "Hello 你好 😀 世界 World! 测试 Test 123"
                ]
            ]
        ]
    ]
    
    func setup(webView: WKWebView) {
        self.webView = webView
        self.webnat = Webnat.of(webView)
        
        // 注册消息监听器
        registerListeners()
        
        // 注册方法处理函数
        registerMethodHandlers()
        
        // 定期检查连接数
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateConnectionCount()
            }
        }
    }
    
    private func updateConnectionCount() {
        connectionCount = webnat?.connections.count ?? 0
    }
    
    private func registerListeners() {
        guard let webnat = webnat else { return }
        
        // 注册 raw 消息监听
        webnat.onRaw { [weak self] raw, connection in
            guard let self = self else { return }
            let message = self.formatMessage(raw)
            self.addLog(type: .received, category: .raw, message: "收到 Raw 消息: \(message)")
        }
        
        // 注册 broadcast 消息监听
        webnat.onBroadcast(name: "test-broadcast") { [weak self] param, connection in
            guard let self = self else { return }
            let message = self.formatMessage(param)
            self.addLog(type: .received, category: .broadcast, message: "收到 Broadcast 消息: \(message)")
        }
    }
    
    private func registerMethodHandlers() {
        guard let webnat = webnat else { return }
        
        // 注册 test-method 方法处理函数
        webnat.onMethod(name: "test-method") { [weak self] param, callback, notify, connection in
            guard let self = self else {
                callback(nil, NSError(domain: "WebnatExample", code: -1, userInfo: [NSLocalizedDescriptionKey: "ViewModel is nil"]))
                return {}
            }
            
            let message = self.formatMessage(param)
            self.addLog(type: .received, category: .method, message: "收到 Method 调用: \(message)")
            
            // 发送通知
            notify(["progress": 50, "message": "处理中..."])
            
            // 模拟异步处理
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let result: [String: Sendable?] = [
                    "success": true,
                    "result": "Method 调用成功",
                    "receivedParam": param as Sendable?
                ]
                callback(result, nil)
            }
            
            return {}
        }
    }
    
    private func formatMessage(_ message: Any?) -> String {
        guard let message = message else {
            return "nil"
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: message, options: .prettyPrinted),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        
        return "\(message)"
    }
    
    func addLog(type: LogEntry.LogType, category: LogEntry.LogCategory, message: String) {
        let entry = LogEntry.create(type: type, category: category, message: message)
        logs.append(entry)
        
        // 限制日志数量，避免内存问题
        if logs.count > 1000 {
            logs.removeFirst(100)
        }
    }
    
    func sendRaw() {
        guard let webnat = webnat,
              let connection = webnat.connections.values.first else {
            addLog(type: .error, category: .raw, message: "没有可用的连接")
            return
        }
        
        let param = utf8BoundaryChars
        let message = formatMessage(param)
        addLog(type: .sent, category: .raw, message: "发送 Raw 消息: \(message)")
        
        webnat.raw(param, connection: connection)
    }
    
    func sendBroadcast() {
        guard let webnat = webnat,
              let connection = webnat.connections.values.first else {
            addLog(type: .error, category: .broadcast, message: "没有可用的连接")
            return
        }
        
        let param = utf8BoundaryChars
        let message = formatMessage(param)
        addLog(type: .sent, category: .broadcast, message: "发送 Broadcast 消息: \(message)")
        
        webnat.broadcast(name: "test-broadcast", param: param, connection: connection)
    }
    
    func sendMethod() {
        guard let webnat = webnat,
              let connection = webnat.connections.values.first else {
            addLog(type: .error, category: .method, message: "没有可用的连接")
            return
        }
        
        let param = utf8BoundaryChars
        let message = formatMessage(param)
        addLog(type: .sent, category: .method, message: "发送 Method 调用: \(message)")
        
        if #available(iOS 13.0, *) {
            Task {
                do {
                    let result = try await webnat.method(
                        "test-method",
                        param: param,
                        timeout: 5.0,
                        onNotification: { [weak self] notification in
                            guard let self = self else { return }
                            let notifMessage = self.formatMessage(notification)
                            self.addLog(type: .received, category: .method, message: "收到 Method 通知: \(notifMessage)")
                        },
                        connection: connection
                    )
                    let resultMessage = self.formatMessage(result)
                    self.addLog(type: .received, category: .method, message: "Method 调用成功: \(resultMessage)")
                } catch {
                    self.addLog(type: .error, category: .method, message: "Method 调用失败: \(error.localizedDescription)")
                }
            }
        } else {
                let _ = webnat.method(
                    "test-method",
                    param: param,
                    timeout: 5.0,
                    callback: { [weak self] result, error in
                        guard let self = self else { return }
                        if let error = error {
                            self.addLog(type: .error, category: .method, message: "Method 调用失败: \(error.localizedDescription)")
                        } else {
                            let resultMessage = self.formatMessage(result)
                            self.addLog(type: .received, category: .method, message: "Method 调用成功: \(resultMessage)")
                        }
                    },
                    connection: connection)
        }
    }
    
    func clearLogs() {
        logs.removeAll()
    }
}
