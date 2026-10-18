import Foundation

/// iOS Simulator tools: Claude boots a device, installs and launches the app, looks at the
/// screen and drives it, in the project's device tab beside the conversation.
extension WorkspaceStore {
    func registerSimulatorTools() {
        func object(_ properties: [String: [String: any Sendable]], required: [String] = []) -> [String: any Sendable] {
            ["type": "object", "properties": properties, "required": required]
        }

        simulatorTool("simulator_list_devices", "List available iOS simulators and which are booted.", object([:])) { session, _ in
            await session.refreshDevices()
            let lines = session.devices.map { "\($0.isBooted ? "●" : "○") \($0.name) · \($0.runtime) — \($0.udid)" }
            return .text(lines.isEmpty ? "No simulators. Install one in Xcode › Settings › Components." : lines.joined(separator: "\n"))
        }

        simulatorTool("simulator_boot", "Boot a simulator (by name like \"iPhone 17\" or UDID) and show it in Tezgah's device tab. Without a device, uses the booted one or the first iPhone.",
                      object(["device": ["type": "string"]])) { session, arguments in
            await session.refreshDevices()
            let wanted = (arguments["device"] as? String).flatMap { session.find($0) }
            if arguments["device"] != nil, wanted == nil { return .error("No simulator matches \(arguments["device"]!). Call simulator_list_devices.") }
            guard let device = wanted ?? session.device ?? session.devices.first(where: \.isBooted) ?? session.devices.first else {
                return .error("No simulators available.")
            }
            session.showActivity("Açıyor: \(device.name)")
            if let error = await session.use(device) { return .error(error) }
            return .text("\(device.name) (\(device.runtime)) is booted and shown in Tezgah. UDID \(device.udid). Use it with xcodebuild -destination 'id=\(device.udid)'."
                         + (session.hasAXe ? "" : "\nNote: tapping, swiping and typing need AXe, which is not installed."))
        }

        simulatorTool("simulator_install", "Install a built .app on the device (e.g. from xcodebuild's DerivedData/Build/Products/Debug-iphonesimulator).",
                      object(["app_path": ["type": "string"]], required: ["app_path"])) { session, arguments in
            guard let path = arguments["app_path"] as? String else { return .error("app_path is required") }
            session.showActivity("Kuruyor: \((path as NSString).lastPathComponent)")
            do { try await session.install(path) } catch { return .error(error.localizedDescription) }
            return .text("Installed \((path as NSString).lastPathComponent).")
        }

        simulatorTool("simulator_launch", "Launch (or relaunch) an app by bundle id, then return a screenshot.",
                      object(["bundle_id": ["type": "string"]], required: ["bundle_id"])) { session, arguments in
            guard let bundle = arguments["bundle_id"] as? String else { return .error("bundle_id is required") }
            session.showActivity("Başlatıyor: \(bundle)")
            do {
                let pid = try await session.launch(bundle)
                return await Self.screenshotResult(session, note: "Launched \(bundle) (\(pid)).")
            } catch {
                return .error(error.localizedDescription)
            }
        }

        simulatorTool("simulator_screenshot", "Screenshot of the device. Coordinates in it are points, as simulator_tap takes them.", object([:])) { session, _ in
            session.showActivity("Ekran görüntüsü alıyor")
            return await Self.screenshotResult(session, note: nil)
        }

        simulatorTool("simulator_describe_ui", "The accessibility tree of the screen: labels, roles and frames, for finding what to tap. Needs AXe.", object([:])) { session, _ in
            session.showActivity("Ekranı okuyor")
            do { return .text(String(try await session.describeUI().prefix(20_000))) } catch { return .error(error.localizedDescription) }
        }

        simulatorTool("simulator_tap", "Tap at x/y in points (from simulator_screenshot or simulator_describe_ui). Needs AXe.",
                      object(["x": ["type": "number"], "y": ["type": "number"]], required: ["x", "y"])) { session, arguments in
            guard let x = (arguments["x"] as? NSNumber)?.doubleValue, let y = (arguments["y"] as? NSNumber)?.doubleValue else { return .error("x and y are required") }
            session.showActivity("Dokunuyor: \(Int(x)), \(Int(y))")
            do { try await session.tap(x: x, y: y) } catch { return .error(error.localizedDescription) }
            return await Self.screenshotResult(session, note: "Tapped \(Int(x)),\(Int(y)).")
        }

        simulatorTool("simulator_swipe", "Swipe from one point to another, in points; e.g. scroll up with start y 600, end y 200. Needs AXe.",
                      object(["start_x": ["type": "number"], "start_y": ["type": "number"], "end_x": ["type": "number"], "end_y": ["type": "number"]],
                             required: ["start_x", "start_y", "end_x", "end_y"])) { session, arguments in
            func value(_ key: String) -> Double? { (arguments[key] as? NSNumber)?.doubleValue }
            guard let sx = value("start_x"), let sy = value("start_y"), let ex = value("end_x"), let ey = value("end_y") else { return .error("All four coordinates are required") }
            session.showActivity("Kaydırıyor")
            do { try await session.swipe(from: CGPoint(x: sx, y: sy), to: CGPoint(x: ex, y: ey)) } catch { return .error(error.localizedDescription) }
            return await Self.screenshotResult(session, note: "Swiped.")
        }

        simulatorTool("simulator_type", "Type text into the focused field (tap the field first). Needs AXe.",
                      object(["text": ["type": "string"]], required: ["text"])) { session, arguments in
            guard let text = arguments["text"] as? String else { return .error("text is required") }
            session.showActivity("Yazıyor")
            do { try await session.type(text) } catch { return .error(error.localizedDescription) }
            return .text("Typed \(text.count) characters.")
        }

        simulatorTool("simulator_button", "Press a hardware button: home, lock, side-button, siri or apple-pay. Needs AXe.",
                      object(["button": ["type": "string", "enum": ["home", "lock", "side-button", "siri", "apple-pay"]]], required: ["button"])) { session, arguments in
            guard let button = arguments["button"] as? String else { return .error("button is required") }
            session.showActivity("Tuş: \(button)")
            do { try await session.pressButton(button) } catch { return .error(error.localizedDescription) }
            return await Self.screenshotResult(session, note: "Pressed \(button).")
        }

        simulatorTool("simulator_open_url", "Open a URL or deep link on the device.",
                      object(["url": ["type": "string"]], required: ["url"])) { session, arguments in
            guard let url = arguments["url"] as? String else { return .error("url is required") }
            session.showActivity("Açıyor: \(url)")
            do { try await session.openURL(url) } catch { return .error(error.localizedDescription) }
            return await Self.screenshotResult(session, note: "Opened \(url).")
        }

        simulatorTool("simulator_set_appearance", "Switch the device to light or dark mode.",
                      object(["mode": ["type": "string", "enum": ["light", "dark"]]], required: ["mode"])) { session, arguments in
            let dark = arguments["mode"] as? String == "dark"
            do { try await session.setAppearance(dark: dark) } catch { return .error(error.localizedDescription) }
            return await Self.screenshotResult(session, note: "Now in \(dark ? "dark" : "light") mode.")
        }

        simulatorTool("simulator_logs", "Recent device log lines, optionally only from one process (the app's executable name).",
                      object(["process": ["type": "string"], "seconds": ["type": "integer", "description": "How far back, default 30"]])) { session, arguments in
            session.showActivity("Logları okuyor")
            do {
                return .text(try await session.logs(process: arguments["process"] as? String, seconds: (arguments["seconds"] as? NSNumber)?.intValue ?? 30))
            } catch {
                return .error(error.localizedDescription)
            }
        }
    }

    private func simulatorTool(
        _ name: String, _ description: String, _ schema: [String: any Sendable],
        run: @escaping @MainActor (SimulatorSession, [String: Any]) async -> MCPToolResult
    ) {
        mcpServer.register(MCPTool(name: name, description: description, inputSchema: schema) { [weak self] arguments, tab in
            guard let self, let (_, project) = self.claudeTab(tab) else { return .error("This Claude session is not in Tezgah anymore.") }
            guard let session = self.showSimulator(in: project, beside: tab) else { return .error("Could not open the device tab.") }
            if session.devices.isEmpty { await session.refreshDevices() }
            return await run(session, arguments)
        })
    }

    private static func screenshotResult(_ session: SimulatorSession, note: String?) async -> MCPToolResult {
        guard let png = await session.screenshotForClaude(settle: true) else {
            return note.map { .text($0 + " (No screenshot: is a device booted?)") } ?? .error("No booted device. Call simulator_boot first.")
        }
        var content: [MCPToolResult.Content] = [.image(png)]
        if let note { content.append(.text(note)) }
        return MCPToolResult(content: content)
    }
}
