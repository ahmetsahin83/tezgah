import Foundation

/// Browser tools: Claude opens, reads, clicks and types in the project's preview tab, which
/// shows beside the conversation so the user watches along.
extension WorkspaceStore {
    func registerBrowserTools() {
        func object(_ properties: [String: [String: any Sendable]], required: [String] = []) -> [String: any Sendable] {
            ["type": "object", "properties": properties, "required": required]
        }

        register("browser_open", "Open a URL (e.g. http://localhost:3000) in Tezgah's preview tab, next to the conversation, and wait for it to load.",
                 object(["url": ["type": "string"]], required: ["url"])) { store, arguments, tab in
            guard let text = arguments["url"] as? String, let url = BrowserSession.url(from: text) else { return .error("A valid url is required.") }
            guard let session = store.browser(for: tab, creating: true) else { return .error("This Claude session is not in Tezgah anymore.") }
            session.showActivity("Açıyor: \(url.host() ?? url.absoluteString)")
            if let error = await session.openAndWait(url) { return .error(error) }
            return .text("Loaded “\(session.title)” — \(session.url?.absoluteString ?? text)" + Self.newProblems(session))
        }

        register("browser_screenshot", "Screenshot the preview. Coordinates in the image are CSS pixels, as browser_click takes them.",
                 object(["full_page": ["type": "boolean", "description": "Whole page instead of the visible part"]])) { store, arguments, tab in
            guard let session = store.browser(for: tab) else { return Self.noPage }
            session.showActivity("Ekran görüntüsü alıyor")
            try? await Task.sleep(for: .milliseconds(150)) // let a freshly shown tab lay out
            do {
                let png = try await session.screenshot(fullPage: arguments["full_page"] as? Bool ?? false)
                return MCPToolResult(content: [.image(png), .text("\(session.title) — \(session.url?.absoluteString ?? "")")])
            } catch {
                return .error("Screenshot failed: \(error.localizedDescription)")
            }
        }

        register("browser_read", "The page as text: title, URL, headings, and the interactive elements with a CSS selector and position for each. Cheaper than a screenshot for finding what to click.",
                 object([:])) { store, _, tab in
            guard let session = store.browser(for: tab) else { return Self.noPage }
            session.showActivity("Sayfayı okuyor")
            do { return .text(try await session.evaluate(Self.readScript)) } catch { return .error(Self.describe(error)) }
        }

        register("browser_click", "Click an element by CSS selector, by its visible text, or at x/y (CSS pixels from a screenshot).",
                 object([
                     "selector": ["type": "string"], "text": ["type": "string", "description": "Visible text of a button or link"],
                     "x": ["type": "number"], "y": ["type": "number"],
                 ])) { store, arguments, tab in
            guard let session = store.browser(for: tab) else { return Self.noPage }
            let target = Self.json(["selector": arguments["selector"], "text": arguments["text"], "x": arguments["x"], "y": arguments["y"]])
            session.showActivity("Tıklıyor")
            do {
                let described = try await session.evaluate("const t = \(target);\n" + Self.clickScript)
                session.showActivity("Tıkladı: \(described.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).prefix(40))")
                _ = await session.waitForLoad(timeout: .seconds(10))
                return .text("Clicked \(described). Now at \(session.url?.absoluteString ?? "")" + Self.newProblems(session))
            } catch {
                return .error(Self.describe(error))
            }
        }

        register("browser_type", "Type into an input or textarea (works with React and similar), optionally submitting the form with Enter.",
                 object([
                     "selector": ["type": "string"], "text": ["type": "string"],
                     "submit": ["type": "boolean"], "append": ["type": "boolean", "description": "Keep what is already there"],
                 ], required: ["selector", "text"])) { store, arguments, tab in
            guard let session = store.browser(for: tab) else { return Self.noPage }
            let input = Self.json(["selector": arguments["selector"], "text": arguments["text"], "submit": arguments["submit"], "append": arguments["append"]])
            session.showActivity("Yazıyor")
            do {
                let described = try await session.evaluate("const t = \(input);\n" + Self.typeScript)
                if arguments["submit"] as? Bool == true { _ = await session.waitForLoad(timeout: .seconds(10)) }
                return .text("Typed into \(described)." + Self.newProblems(session))
            } catch {
                return .error(Self.describe(error))
            }
        }

        register("browser_eval", "Run JavaScript in the page as the body of an async function; `return` a value to get it back as JSON.",
                 object(["script": ["type": "string"]], required: ["script"])) { store, arguments, tab in
            guard let session = store.browser(for: tab) else { return Self.noPage }
            guard let script = arguments["script"] as? String else { return .error("script is required") }
            session.showActivity("JavaScript çalıştırıyor")
            do { return .text(try await session.evaluate(script)) } catch { return .error(Self.describe(error)) }
        }

        register("browser_console", "Console messages, uncaught errors and failed requests since the last call.",
                 object([:])) { store, _, tab in
            guard let session = store.browser(for: tab) else { return Self.noPage }
            let logs = session.takeNewLogsForClaude()
            guard !logs.isEmpty else { return .text("No new console messages.") }
            return .text(logs.map { "[\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n"))
        }

        register("browser_scroll", "Scroll the page: to \"top\" or \"bottom\", by dy pixels, or until a selector is in view.",
                 object(["to": ["type": "string", "enum": ["top", "bottom"]], "dy": ["type": "number"], "selector": ["type": "string"]])) { store, arguments, tab in
            guard let session = store.browser(for: tab) else { return Self.noPage }
            let input = Self.json(["to": arguments["to"], "dy": arguments["dy"], "selector": arguments["selector"]])
            do {
                return .text(try await session.evaluate("""
                const t = \(input);
                if (t.selector) { const e = document.querySelector(t.selector); if (!e) throw new Error('No element for ' + t.selector); e.scrollIntoView({block: 'center'}); }
                else if (t.to === 'top') scrollTo(0, 0);
                else if (t.to === 'bottom') scrollTo(0, document.documentElement.scrollHeight);
                else scrollBy(0, t.dy || innerHeight * 0.8);
                return { scrollY: Math.round(scrollY), height: document.documentElement.scrollHeight, viewport: innerHeight };
                """))
            } catch {
                return .error(Self.describe(error))
            }
        }

        register("browser_set_viewport", "Set the page size, e.g. to check a mobile layout: a preset (\"iPhone 16\", \"iPhone SE\", \"iPad\", \"Dizüstü\", \"Masaüstü\"), width and height, or \"fill\" for the tab's size.",
                 object(["preset": ["type": "string"], "width": ["type": "number"], "height": ["type": "number"]])) { store, arguments, tab in
            guard let session = store.browser(for: tab, creating: true) else { return Self.noPage }
            if let preset = arguments["preset"] as? String {
                if preset.lowercased() == "fill" {
                    session.viewport = nil
                } else if let match = BrowserSession.Viewport.presets.first(where: { $0.name.lowercased() == preset.lowercased() }) {
                    session.viewport = match
                } else {
                    return .error("Unknown preset. Use one of: \(BrowserSession.Viewport.presets.map(\.name).joined(separator: ", ")), fill")
                }
            } else if let width = (arguments["width"] as? NSNumber)?.doubleValue, let height = (arguments["height"] as? NSNumber)?.doubleValue {
                session.viewport = BrowserSession.Viewport(name: "Özel", width: width, height: height)
            }
            try? await Task.sleep(for: .milliseconds(250))
            let size = session.viewport.map { "\(Int($0.width))×\(Int($0.height))" } ?? "the tab's size"
            return .text("Viewport is now \(size).")
        }
    }

    // MARK: Helpers

    private func register(
        _ name: String, _ description: String, _ schema: [String: any Sendable],
        run: @escaping @MainActor (WorkspaceStore, [String: Any], UUID) async -> MCPToolResult
    ) {
        mcpServer.register(MCPTool(name: name, description: description, inputSchema: schema) { [weak self] arguments, tab in
            guard let self else { return .error("Tezgah is closing.") }
            return await run(self, arguments, tab)
        })
    }

    /// The preview of the calling session's project, brought into view beside the conversation.
    func browser(for tab: UUID, creating: Bool = false) -> BrowserSession? {
        guard let (_, project) = claudeTab(tab) else { return nil }
        guard creating || !project.browsers.isEmpty else { return nil }
        return showBrowser(in: project, beside: tab)
    }

    private static let noPage = MCPToolResult.error("No preview open yet. Call browser_open first.")

    /// New errors, so Claude notices a broken page without asking.
    private static func newProblems(_ session: BrowserSession) -> String {
        let problems = session.takeNewLogsForClaude().filter { $0.level == .error || $0.level == .network }
        guard !problems.isEmpty else { return "" }
        return "\n\nNew errors in the page:\n" + problems.prefix(10).map { "- \($0.message)" }.joined(separator: "\n")
    }

    private static func json(_ values: [String: Any?]) -> String {
        let clean = values.compactMapValues { $0 }
        let data = (try? JSONSerialization.data(withJSONObject: clean)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        return (nsError.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? nsError.localizedDescription
    }

    /// Finds the element, scrolls it into view, shows a ripple and clicks it like a user would.
    private static let clickScript = #"""
    const visible = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    let el;
    if (t.selector) {
      el = document.querySelector(t.selector);
      if (!el) throw new Error('No element matches ' + t.selector);
    } else if (t.text) {
      const wanted = t.text.trim().toLowerCase();
      const candidates = [...document.querySelectorAll('button, a, [role=button], input[type=submit], input[type=button], label, summary, [onclick]')].filter(visible);
      el = candidates.find(e => (e.innerText || e.value || '').trim().toLowerCase() === wanted)
        || candidates.find(e => (e.innerText || e.value || '').trim().toLowerCase().includes(wanted));
      if (!el) throw new Error('No button or link with text ' + JSON.stringify(t.text));
    } else if (t.x != null && t.y != null) {
      el = document.elementFromPoint(t.x, t.y);
      if (!el) throw new Error('Nothing at ' + t.x + ',' + t.y);
    } else throw new Error('Give a selector, text, or x and y');
    if (t.x == null) el.scrollIntoView({ block: 'center', inline: 'center' });
    const r = el.getBoundingClientRect();
    const x = t.x ?? r.left + r.width / 2, y = t.y ?? r.top + r.height / 2;
    window.__tezgahRipple && window.__tezgahRipple(x, y);
    const opts = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, button: 0 };
    el.dispatchEvent(new PointerEvent('pointerdown', opts));
    el.dispatchEvent(new MouseEvent('mousedown', opts));
    if (el.focus) el.focus();
    el.dispatchEvent(new PointerEvent('pointerup', opts));
    el.dispatchEvent(new MouseEvent('mouseup', opts));
    el.click();
    const label = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 60);
    return `<${el.tagName.toLowerCase()}>` + (label ? ` "${label}"` : '');
    """#

    /// Sets the value through the native setter so frameworks that track input see the change.
    private static let typeScript = #"""
    const el = document.querySelector(t.selector);
    if (!el) throw new Error('No element matches ' + t.selector);
    el.scrollIntoView({ block: 'center' });
    el.focus();
    const r = el.getBoundingClientRect();
    window.__tezgahRipple && window.__tezgahRipple(r.left + 12, r.top + r.height / 2);
    if (el.isContentEditable) {
      if (!t.append) el.textContent = '';
      document.execCommand('insertText', false, t.text);
    } else {
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      setter.call(el, (t.append ? el.value : '') + t.text);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    if (t.submit) {
      const enter = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
      const proceed = el.dispatchEvent(new KeyboardEvent('keydown', enter));
      el.dispatchEvent(new KeyboardEvent('keyup', enter));
      if (proceed && el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
    }
    return `<${el.tagName.toLowerCase()}${el.name ? ` name="${el.name}"` : ''}>`;
    """#

    /// A compact outline: what is on the page and how to reach each control.
    private static let readScript = #"""
    const visible = e => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
    const selectorFor = e => {
      if (e.id && document.querySelectorAll('#' + CSS.escape(e.id)).length === 1) return '#' + CSS.escape(e.id);
      for (const attr of ['data-testid', 'data-test', 'name', 'aria-label', 'placeholder']) {
        const v = e.getAttribute(attr);
        if (v) { const s = `${e.tagName.toLowerCase()}[${attr}=${JSON.stringify(v)}]`; if (document.querySelectorAll(s).length === 1) return s; }
      }
      const path = [];
      for (let n = e; n && n.nodeType === 1 && path.length < 5; n = n.parentElement) {
        let part = n.tagName.toLowerCase();
        if (n.id) { path.unshift('#' + CSS.escape(n.id)); break; }
        const same = n.parentElement ? [...n.parentElement.children].filter(c => c.tagName === n.tagName) : [];
        if (same.length > 1) part += `:nth-of-type(${same.indexOf(n) + 1})`;
        path.unshift(part);
      }
      return path.join(' > ');
    };
    const controls = [...document.querySelectorAll('a[href], button, input, select, textarea, [role=button], [role=link], [role=tab], [role=checkbox], [contenteditable=true], summary')]
      .filter(visible).slice(0, 120).map(e => {
        const r = e.getBoundingClientRect();
        const text = (e.innerText || e.value || e.getAttribute('aria-label') || e.getAttribute('placeholder') || e.getAttribute('title') || '').trim().replace(/\s+/g, ' ').slice(0, 70);
        const kind = e.tagName.toLowerCase() + (e.type && e.tagName !== 'BUTTON' ? `[${e.type}]` : '');
        return `${kind} "${text}" → ${selectorFor(e)} @ ${Math.round(r.left + r.width / 2)},${Math.round(r.top + r.height / 2)}`;
      });
    const headings = [...document.querySelectorAll('h1, h2, h3')].filter(visible).slice(0, 30)
      .map(h => `${h.tagName.toLowerCase()}: ${h.innerText.trim().slice(0, 100)}`);
    const text = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n').slice(0, 5000);
    return {
      title: document.title, url: location.href,
      viewport: `${innerWidth}×${innerHeight}`, scrollY: Math.round(scrollY), pageHeight: document.documentElement.scrollHeight,
      headings, controls, text
    };
    """#
}
