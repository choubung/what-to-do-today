import CoreFoundation
import Foundation

struct TodoMCPServer {
    private typealias Object = [String: Any]

    private enum State {
        case awaitingInitialize, awaitingReady, ready
    }

    private static let protocolVersions = ["2025-11-25", "2025-06-18"]
    private let version: String
    private let openStore: () throws -> TodoStore
    private let didChangeStore: () -> Void
    private var state = State.awaitingInitialize
    private var store: TodoStore?

    init(version: String, openStore: @escaping () throws -> TodoStore, didChangeStore: @escaping () -> Void) {
        self.version = version
        self.openStore = openStore
        self.didChangeStore = didChangeStore
    }

    mutating func run() throws {
        while let line = readLine() {
            guard let response = response(to: Data(line.utf8)) else { continue }
            var output = try JSONSerialization.data(withJSONObject: response)
            output.append(0x0a)
            try FileHandle.standardOutput.write(contentsOf: output)
        }
    }

    mutating func response(to data: Data) -> [String: Any]? {
        let message: Any
        do {
            message = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            return rpcError(nil, code: -32700, message: "Parse error")
        }
        guard let request = message as? Object, request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return rpcError(nil, code: -32600, message: "Invalid request")
        }
        guard let id = request["id"] else {
            if method == "notifications/initialized", state == .awaitingReady { state = .ready }
            return nil
        }
        guard Self.isRequestID(id) else {
            return rpcError(nil, code: -32600, message: "Invalid request ID")
        }
        let params = request["params"] as? Object
        guard request["params"] == nil || params != nil else {
            return rpcError(id, code: -32602, message: "Invalid params")
        }
        let result: Object
        switch method {
        case "ping":
            result = [:]
        case "initialize":
            guard state == .awaitingInitialize else {
                return rpcError(id, code: -32600, message: "Session already initialized")
            }
            guard let requested = params?["protocolVersion"] as? String,
                  params?["capabilities"] is Object,
                  let client = params?["clientInfo"] as? Object,
                  client["name"] is String, client["version"] is String else {
                return rpcError(id, code: -32602, message: "Invalid initialization parameters")
            }
            let supported = Self.protocolVersions
            result = [
                "protocolVersion": supported.contains(requested) ? requested : supported[0],
                "serverInfo": ["name": "what-to-do-today", "version": version],
                "capabilities": ["tools": [:] as Object],
                "instructions": "Use the IDs returned by list tools when editing. If multiple tasks match a title, ask which one the user means."
            ]
            state = .awaitingReady
        default:
            guard state == .ready else {
                return rpcError(id, code: -32000, message: "Session not initialized")
            }
            switch method {
            case "tools/list":
                result = ["tools": TodoMCPTool.allCases.map(\.definition)]
            case "tools/call":
                guard let name = params?["name"] as? String, let tool = TodoMCPTool(rawValue: name) else {
                    return rpcError(id, code: -32602, message: "Unknown or missing tool name")
                }
                guard let arguments = (params?["arguments"] ?? Object()) as? Object else {
                    return rpcError(id, code: -32602, message: "Arguments must be an object")
                }
                result = call(tool, arguments: arguments)
            default:
                return rpcError(id, code: -32601, message: "Method not found")
            }
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private mutating func call(_ tool: TodoMCPTool, arguments: Object) -> Object {
        do {
            try tool.validate(arguments)
            let payload = try tool.execute(in: connection(), arguments: arguments)
            if !tool.isReadOnly { didChangeStore() }
            let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return [
                "content": [["type": "text", "text": String(decoding: encoded, as: UTF8.self)]],
                "structuredContent": payload
            ]
        } catch let error as TodoMCPInputError {
            return toolError(error.message)
        } catch let error as TodoStoreError {
            switch error {
            case .missingCategory:
                return toolError("카테고리를 찾을 수 없어요. list_categories로 카테고리를 다시 확인해 주세요.")
            case .invalidCategoryName, .duplicateCategoryName, .lastCategory, .invalidCategoryDestination,
                 .emptyTitle, .missingTask, .invalidReminder, .completedTaskReminder, .unavailableAppGroup:
                return toolError(error.localizedDescription)
            default:
                return toolError("할 일 저장 공간에서 요청을 처리하지 못했어요.")
            }
        } catch {
            return toolError("할 일 저장 공간에서 요청을 처리하지 못했어요.")
        }
    }

    private mutating func connection() throws -> TodoStore {
        if let store { return store }
        let opened = try openStore()
        store = opened
        return opened
    }

    private func toolError(_ message: String) -> Object {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func rpcError(_ id: Any?, code: Int, message: String) -> Object {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private static func isRequestID(_ id: Any) -> Bool {
        if id is String { return true }
        guard let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.rounded() == number.doubleValue
    }
}
