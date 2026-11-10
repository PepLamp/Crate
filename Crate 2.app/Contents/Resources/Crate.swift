import AppKit
import Darwin
import Foundation
import WebKit

private let bridgePort: UInt16 = 47824
private let webPort = 47823

final class CrateApplication: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var server: Process?
    private let automationQueue = DispatchQueue(label: "app.crate.automation")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Crate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        menu.addItem(appMenuItem)
        NSApp.mainMenu = menu
        if let icon = NSImage(contentsOfFile: Bundle.main.resourceURL!.appendingPathComponent("Crate.png").path) {
            NSApp.applicationIconImage = icon
        }
        startAutomationBridge()
        startWebServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.terminate()
    }

    private func startAutomationBridge() {
        let ready = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            guard listener >= 0 else {
                ready.signal()
                return
            }

            var reuse: Int32 = 1
            setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(bridgePort).bigEndian
            address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)

            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(listener, 8) == 0 else {
                close(listener)
                ready.signal()
                return
            }
            ready.signal()

            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                self.automationQueue.async {
                    self.handleAutomationRequest(client)
                }
            }
        }
        _ = ready.wait(timeout: .now() + 2)
    }

    private func handleAutomationRequest(_ client: Int32) {
        defer { close(client) }
        var input = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while input.count <= 8_000_000 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            if let end = buffer[..<count].firstIndex(of: 10) {
                input.append(contentsOf: buffer[..<end])
                break
            }
            input.append(contentsOf: buffer[..<count])
        }

        do {
            let request = try JSONSerialization.jsonObject(with: input) as? [String: Any]
            guard let request,
                  let language = request["lang"] as? String,
                  language == "AppleScript",
                  var source = request["script"] as? String else {
                throw BridgeError("Invalid automation request")
            }
            let arguments = request["args"] as? [String] ?? []
            if !arguments.isEmpty {
                let literals = arguments.map(Self.appleScriptString).joined(separator: ", ")
                source = source.replacingOccurrences(
                    of: "on run argv",
                    with: "on run\n set argv to {\(literals)}"
                )
            }

            guard let script = NSAppleScript(source: source) else {
                throw BridgeError("Could not compile the AppleScript")
            }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? error.description
                throw BridgeError(message)
            }
            sendResponse(["result": result.stringValue ?? ""])
        } catch {
            sendResponse(["error": error.localizedDescription])
        }

        func sendResponse(_ response: [String: String]) {
            guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
            data.append(10)
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var sent = 0
                while sent < data.count {
                    let count = send(client, base.advanced(by: sent), data.count - sent, 0)
                    guard count > 0 else { return }
                    sent += count
                }
            }
        }
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private func startWebServer() {
        let resources = Bundle.main.resourceURL!.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["\(resources)/server.pl", "\(webPort)", resources]
        do {
            try process.run()
            server = process
            waitForWebServer()
        } catch {
            showError("Crate could not start its local server: \(error.localizedDescription)")
        }
    }

    private func waitForWebServer() {
        DispatchQueue.global(qos: .userInitiated).async {
            let url = URL(string: "http://127.0.0.1:\(webPort)/ping")!
            var ready = false
            for _ in 0..<40 {
                let semaphore = DispatchSemaphore(value: 0)
                var succeeded = false
                URLSession.shared.dataTask(with: url) { _, response, _ in
                    succeeded = (response as? HTTPURLResponse)?.statusCode == 200
                    semaphore.signal()
                }.resume()
                if semaphore.wait(timeout: .now() + 0.25) == .success, succeeded {
                    ready = true
                    break
                }
            }
            DispatchQueue.main.async {
                if ready {
                    self.showWindow()
                } else {
                    self.showError("Crate's local server did not start.")
                }
            }
        }
    }

    private func showWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1240, height: 820)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Crate"
        window.center()

        let webView = WKWebView(frame: window.contentView?.bounds ?? .zero)
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(webPort)/")!))

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Crate could not start"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}

private struct BridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

let application = NSApplication.shared
let delegate = CrateApplication()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
