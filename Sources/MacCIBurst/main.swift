import AppKit
import Foundation

private struct CurrentJob: Decodable {
    let repo: String
    let name: String
    let url: String
}

private struct RunnerStatus: Decodable {
    let state: String
    let desired: String
    let runnerName: String
    let runnerId: Int?
    let settingsURL: String
    let registered: Bool
    let online: Bool
    let busy: Bool
    let schedulable: Bool
    let serviceLoaded: Bool
    let freeGiB: Int
    let minimumFreeGiB: Int
    // Present since the tiered disk guard; older status output omits it.
    let softFreeGiB: Int?
    let currentJob: CurrentJob?
}

private struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    static func run(executable: String, arguments: [String]) -> CommandResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
            return CommandResult(
                status: process.terminationStatus,
                stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        } catch {
            return CommandResult(status: 127, stdout: "", stderr: error.localizedDescription)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateItem = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let diskItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var availableItem: NSMenuItem!
    private var drainItem: NSMenuItem!
    private var offItem: NSMenuItem!
    private var jobItem: NSMenuItem!
    private var settingsItem: NSMenuItem!
    private var refreshTimer: Timer?
    private var isRefreshing = false
    private var currentStatus: RunnerStatus?

    private var backendPath: String {
        if let override = ProcessInfo.processInfo.environment["MAC_CI_BURST_CTL"], !override.isEmpty {
            return override
        }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("mac-ci-burst").path
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        return NSString(string: "~/Library/Application Support/MacCIBurst/bin/mac-ci-burst").expandingTildeInPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func buildMenu() {
        statusItem.button?.title = "⚪️ CI"
        statusItem.button?.toolTip = "Opt-in GitHub Actions runner"
        let menu = NSMenu()
        let title = NSMenuItem(title: "Mac CI Burst Runner", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(stateItem)
        menu.addItem(detailItem)
        menu.addItem(diskItem)

        jobItem = NSMenuItem(title: "Open current job", action: #selector(openCurrentJob), keyEquivalent: "j")
        jobItem.target = self
        jobItem.isHidden = true
        menu.addItem(jobItem)
        menu.addItem(.separator())

        availableItem = NSMenuItem(title: "Make Available", action: #selector(makeAvailable), keyEquivalent: "a")
        availableItem.target = self
        menu.addItem(availableItem)
        drainItem = NSMenuItem(title: "Pause After Current Job", action: #selector(beginDrain), keyEquivalent: "d")
        drainItem.target = self
        menu.addItem(drainItem)
        offItem = NSMenuItem(title: "Turn Off", action: #selector(turnOff), keyEquivalent: "o")
        offItem.target = self
        menu.addItem(offItem)
        menu.addItem(.separator())

        settingsItem = NSMenuItem(title: "Open GitHub Runners", action: #selector(openGitHubRunners), keyEquivalent: "g")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let quit = NSMenuItem(title: "Quit Controller", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let backend = backendPath
        Task.detached(priority: .utility) { [weak self] in
            let result = CommandResult.run(executable: backend, arguments: ["tick"])
            await MainActor.run {
                guard let self else { return }
                self.isRefreshing = false
                self.consumeStatus(result)
            }
        }
    }

    private func consumeStatus(_ result: CommandResult) {
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let status = try? JSONDecoder().decode(RunnerStatus.self, from: data) else {
            currentStatus = nil
            statusItem.button?.title = "🔴 CI"
            stateItem.title = "Controller error"
            detailItem.title = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            detailItem.isHidden = detailItem.title.isEmpty
            diskItem.isHidden = true
            updateActions()
            return
        }

        currentStatus = status
        switch status.state {
        case "available": statusItem.button?.title = "🟢 CI"; stateItem.title = "Available for jobs"
        case "busy": statusItem.button?.title = "🟠 CI"; stateItem.title = "Running a CI job"
        case "draining": statusItem.button?.title = "🔵 CI"; stateItem.title = status.busy ? "Draining after current job" : "Finishing drain"
        case "starting": statusItem.button?.title = "🟡 CI"; stateItem.title = "Starting runner"
        case "disk-blocked": statusItem.button?.title = "🔴 CI"; stateItem.title = "Blocked by disk safety gate"
        case "setup-required": statusItem.button?.title = "⚪️ CI"; stateItem.title = "Runner registration required"
        default: statusItem.button?.title = "⚪️ CI"; stateItem.title = "Off"
        }

        if let job = status.currentJob {
            detailItem.title = "\(job.repo): \(job.name)"
            jobItem.title = "Open \(job.repo) job"
            jobItem.isHidden = false
        } else {
            detailItem.title = "\(status.runnerName) · GitHub: \(status.online ? "online" : "offline")"
            jobItem.isHidden = true
        }
        detailItem.isHidden = false
        var diskTitle = "Disk: \(status.freeGiB) GiB free (\(status.minimumFreeGiB) GiB required)"
        if let soft = status.softFreeGiB, status.freeGiB < soft {
            diskTitle += " · reclaiming below \(soft) GiB"
        }
        diskItem.title = diskTitle
        diskItem.isHidden = false
        updateActions()
    }

    private func updateActions() {
        guard let status = currentStatus else {
            availableItem.isEnabled = false; drainItem.isEnabled = false; offItem.isEnabled = false; settingsItem.isEnabled = false
            return
        }
        availableItem.isEnabled = status.registered && !status.busy && status.state != "available"
            && status.freeGiB >= status.minimumFreeGiB
        drainItem.isEnabled = status.registered && status.desired == "available"
        offItem.isEnabled = status.registered && !status.busy && status.state != "off"
        settingsItem.isEnabled = URL(string: status.settingsURL) != nil
    }

    private func perform(_ action: String) {
        availableItem.isEnabled = false; drainItem.isEnabled = false; offItem.isEnabled = false
        stateItem.title = "Applying \(action)…"
        let backend = backendPath
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CommandResult.run(executable: backend, arguments: [action])
            await MainActor.run {
                guard let self else { return }
                if result.status != 0 {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "CI runner action failed"
                    alert.informativeText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    alert.runModal()
                }
                self.refresh()
            }
        }
    }

    @objc private func makeAvailable() { perform("available") }
    @objc private func beginDrain() { perform("drain") }
    @objc private func turnOff() { perform("off") }
    @objc private func refreshAction() { refresh() }
    @objc private func openCurrentJob() {
        guard let value = currentStatus?.currentJob?.url, let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func openGitHubRunners() {
        guard let value = currentStatus?.settingsURL, let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()
