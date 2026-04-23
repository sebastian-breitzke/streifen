import Cocoa
import Network

/// Lightweight local HTTP server for debugging and external tool integration.
/// Listens on localhost:22222, responds with JSON state.
///
/// Endpoints:
///   GET /state         — Full state: all workspaces, windows, config
///   GET /workspace/N   — Single workspace detail
///   GET /windows       — Flat list of all windows across workspaces
///   GET /active        — Active workspace only
@MainActor
final class DebugServer {
    private var listener: NWListener?
    private weak var workspaceManager: WorkspaceManager?
    private let port: UInt16 = 22222

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            slog("error", "debug_server", ["err": "\(error)"])
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                slog("lifecycle", "debug_server_ready", ["port": self.port])
            case .failed(let error):
                slog("error", "debug_server", ["err": "\(error)"])
            default:
                break
            }
        }
        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let request = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                self.route(request: request, connection: connection)
            }
        }
    }

    private func route(request: String, connection: NWConnection) {
        // Parse HTTP request line: "GET /path HTTP/1.1"
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        let path = parts.count > 1 ? parts[1] : "/"

        let json: [String: Any]

        if path == "/state" || path == "/" {
            json = fullState()
        } else if path == "/active" {
            json = activeState()
        } else if path == "/windows" {
            json = windowList()
        } else if path.hasPrefix("/workspace/"),
                  let wsId = Int(path.replacingOccurrences(of: "/workspace/", with: "")) {
            json = workspaceState(wsId)
        } else {
            json = [
                "error": "Not found",
                "endpoints": ["/state", "/active", "/windows", "/workspace/{1-9}"]
            ]
        }

        sendJSON(json, connection: connection)
    }

    // MARK: - State Serialization

    private func fullState() -> [String: Any] {
        guard let mgr = workspaceManager else { return ["error": "no manager"] }
        let screen = NSScreen.managed?.visibleFrame
        var workspaces: [[String: Any]] = []
        for id in 1...9 {
            guard let ws = mgr.workspaces[id] else { continue }
            workspaces.append(serializeWorkspace(ws, screen: screen))
        }
        return [
            "activeWorkspace": mgr.activeWorkspaceId,
            "workspaces": workspaces,
            "screen": serializeScreen(),
            "config": serializeConfig(mgr.config),
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
    }

    private func activeState() -> [String: Any] {
        guard let mgr = workspaceManager else { return ["error": "no manager"] }
        let screen = NSScreen.managed?.visibleFrame
        return [
            "activeWorkspace": mgr.activeWorkspaceId,
            "workspace": serializeWorkspace(mgr.activeWorkspace, screen: screen),
            "screen": serializeScreen(),
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
    }

    private func windowList() -> [String: Any] {
        guard let mgr = workspaceManager else { return ["error": "no manager"] }
        let screen = NSScreen.managed?.visibleFrame
        var windows: [[String: Any]] = []
        for id in 1...9 {
            guard let ws = mgr.workspaces[id] else { continue }
            for (i, w) in ws.windows.enumerated() {
                var dict = serializeWindow(w, screen: screen)
                dict["workspace"] = id
                dict["index"] = i
                dict["focused"] = (id == mgr.activeWorkspaceId && i == ws.focusIndex)
                windows.append(dict)
            }
        }
        return [
            "count": windows.count,
            "windows": windows,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
    }

    private func workspaceState(_ wsId: Int) -> [String: Any] {
        guard let mgr = workspaceManager,
              let ws = mgr.workspaces[wsId] else {
            return ["error": "workspace \(wsId) not found"]
        }
        let screen = NSScreen.managed?.visibleFrame
        return [
            "workspace": serializeWorkspace(ws, screen: screen),
            "isActive": wsId == mgr.activeWorkspaceId,
            "screen": serializeScreen(),
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
    }

    // MARK: - Serialization Helpers

    private func serializeWorkspace(_ ws: Workspace, screen: NSRect?) -> [String: Any] {
        return [
            "id": ws.id,
            "windowCount": ws.windows.count,
            "focusIndex": ws.focusIndex,
            "scrollOffset": round(ws.scrollOffset * 10) / 10,
            "isVisible": ws.isVisible,
            "windows": ws.windows.enumerated().map { (i, w) in
                var dict = serializeWindow(w, screen: screen)
                dict["index"] = i
                dict["focused"] = (i == ws.focusIndex)
                return dict
            },
        ]
    }

    private func serializeWindow(_ w: TrackedWindow, screen: NSRect?) -> [String: Any] {
        var dict: [String: Any] = [
            "windowId": Int(w.windowId),
            "app": w.app.localizedName ?? "Unknown",
            "bundleId": w.bundleId ?? "",
            "title": w.title,
            "appSize": w.appSize.rawValue,
            "sliceCount": w.sliceCount,
            "totalSlices": ScreenClass.current.totalSlices,

            "frame": [
                "x": round(w.frame.origin.x),
                "y": round(w.frame.origin.y),
                "width": round(w.frame.width),
                "height": round(w.frame.height),
            ],
            "virtualX": round(w.virtualX * 10) / 10,
        ]
        // Read actual AX position for debugging
        if let axPos: CGPoint = try? w.axElement.attribute(.position) {
            dict["axPos"] = ["x": round(axPos.x), "y": round(axPos.y)]
        }
        // Flag if window appears off-screen
        if let screen {
            let isOffscreen = w.frame.origin.x > screen.maxX || w.frame.maxX < screen.origin.x
                || w.frame.origin.y > screen.maxY || w.frame.maxY < screen.origin.y
            dict["offscreen"] = isOffscreen
        }
        return dict
    }

    private func serializeScreen() -> [String: Any] {
        guard let screen = NSScreen.managed else {
            return ["error": "no screen"]
        }
        let full = screen.frame
        let visible = screen.visibleFrame
        return [
            "full": ["x": full.origin.x, "y": full.origin.y, "width": full.width, "height": full.height],
            "visible": ["x": visible.origin.x, "y": visible.origin.y, "width": visible.width, "height": visible.height],
        ]
    }

    private func serializeConfig(_ config: StreifenConfig) -> [String: Any] {
        return [
            "gap": config.gap,
            "pinnedApps": config.pinnedApps,
            "followApps": Array(config.followApps),
            "screenClass": ScreenClass.current.rawValue,
            "defaultSize": config.defaultSize.rawValue,
            "appSizes": config.appSizes.mapValues { $0.rawValue },
        ]
    }

    // MARK: - HTTP Response

    private func sendJSON(_ json: [String: Any], connection: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            connection.cancel()
            return
        }
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r\n
        """
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
