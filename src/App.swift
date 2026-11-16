import AppKit
import Combine
import SwiftUI

@main
struct IPadDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("iPad 扩展屏", id: "main") {
            ContentView(model: model)
                .onAppear {
                    delegate.model = model
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: AppModel?

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var mainWindow: NSWindow?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(model?.runInBackground ?? false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.attachWindow()
            self.setUpStatusItem()
            self.observeModel()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    private func attachWindow() {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }) else { return }
        mainWindow = window
        window.delegate = self
        window.isReleasedWhenClosed = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model?.runInBackground == true else { return true }
        sender.orderOut(nil)
        return false
    }

    private func observeModel() {
        guard let model, cancellables.isEmpty else { return }
        model.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] (_: AppModel.Phase) in self?.refreshStatusMenu() }
            .store(in: &cancellables)
    }

    private func setUpStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "ipad.landscape",
                                     accessibilityDescription: "iPad 扩展屏")
        statusItem = item
        refreshStatusMenu()
    }

    private func refreshStatusMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        let phase = model?.phase ?? .idle

        let status = NSMenuItem(title: "状态：\(phase.title)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if let device = model?.selectedDevice {
            let deviceItem = NSMenuItem(title: "\(device.name) · \(device.transport.rawValue)",
                                        action: nil, keyEquivalent: "")
            deviceItem.isEnabled = false
            menu.addItem(deviceItem)
        }

        menu.addItem(.separator())

        if phase.isBusy {
            menu.addItem(NSMenuItem(title: "断开连接", action: #selector(toggleStream), keyEquivalent: "d"))
        } else {
            menu.addItem(NSMenuItem(title: "开始扩展", action: #selector(toggleStream), keyEquivalent: "s"))
        }
        menu.addItem(NSMenuItem(title: "显示窗口", action: #selector(showWindowAction), keyEquivalent: "o"))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        item.menu = menu

        item.button?.toolTip = "iPad 扩展屏 · \(phase.title)"
    }

    @objc private func toggleStream() {
        guard let model else { return }
        if model.phase.isBusy {
            model.stop()
        } else {
            model.start()
        }
        refreshStatusMenu()
    }

    @objc private func showWindowAction() {
        showWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        let target = mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil })
        target?.makeKeyAndOrderFront(nil)
        for extra in NSApp.windows where extra !== target && extra.canBecomeMain {
            extra.orderOut(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
