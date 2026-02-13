import AppKit
import Foundation

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let repo = "chenglun11/TicTracker"
    private let checkInterval: TimeInterval = 24 * 60 * 60

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Public

    func checkInBackground() {
        let lastCheck = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - lastCheck > checkInterval else { return }
        check(silent: true)
    }

    func checkNow() {
        check(silent: false)
    }

    // MARK: - Core

    private func check(silent: Bool) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        DevLog.shared.info("Update", "检查更新 (silent=\(silent))")

        Task {
            do {
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.setValue("TicTracker/\(currentVersion)", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    DevLog.shared.error("Update", "GitHub HTTP \(code)")
                    if !silent { showError("GitHub 返回错误（HTTP \(code)）") }
                    return
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    if !silent { showError("解析失败") }
                    return
                }

                // 从 assets 中找到 zip 下载链接
                let zipURL = findZipAssetURL(in: json)

                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")

                let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

                if isNewer(latestVersion, than: currentVersion) {
                    DevLog.shared.info("Update", "发现新版本 \(latestVersion)（当前 \(currentVersion)）")
                    let skipped = UserDefaults.standard.string(forKey: "skippedVersion")
                    if silent && skipped == latestVersion { return }
                    showUpdateAlert(version: latestVersion, zipURL: zipURL)
                } else if !silent {
                    showUpToDateAlert()
                }
            } catch {
                if !silent { showError("检查失败：\(error.localizedDescription)") }
            }
        }
    }

    private func findZipAssetURL(in json: [String: Any]) -> String? {
        guard let assets = json["assets"] as? [[String: Any]] else { return nil }
        // 找 TicTracker-*.zip
        for asset in assets {
            if let name = asset["name"] as? String, name.hasSuffix(".zip"),
               let url = asset["browser_download_url"] as? String {
                return url
            }
        }
        return nil
    }

    // MARK: - Download & Install

    private func downloadAndInstall(zipURLString: String) {
        guard let zipURL = URL(string: zipURLString) else {
            showError("下载链接无效")
            return
        }

        // 显示下载进度窗口
        let progressWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        progressWindow.title = "正在更新"
        progressWindow.center()

        let stack = NSStackView(frame: NSRect(x: 20, y: 15, width: 260, height: 50))
        stack.orientation = .vertical
        stack.spacing = 8

        let label = NSTextField(labelWithString: "正在下载新版本…")
        label.alignment = .center
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(progress)
        progressWindow.contentView?.addSubview(stack)
        progressWindow.makeKeyAndOrderFront(nil)

        Task.detached {
            do {
                // 下载到磁盘，不占内存
                let (tmpFile, _) = try await URLSession.shared.download(from: zipURL)

                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TicTrackerUpdate")
                try? FileManager.default.removeItem(at: tempDir)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                let zipPath = tempDir.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: tmpFile, to: zipPath)

                // ditto 解压（在后台线程等待，不阻塞主线程）
                let extract = Process()
                extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                extract.arguments = ["-xk", zipPath.path, tempDir.path]
                try extract.run()
                extract.waitUntilExit()

                guard extract.terminationStatus == 0 else {
                    await MainActor.run { progressWindow.close(); self.showError("解压失败") }
                    return
                }

                // 找到解压出的 .app
                let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                    await MainActor.run { progressWindow.close(); self.showError("未找到应用程序") }
                    return
                }

                let bundlePath = await MainActor.run { Bundle.main.bundlePath }
                let currentAppURL = URL(fileURLWithPath: bundlePath)
                let destination = currentAppURL

                // 备份当前版本
                let backupURL = tempDir.appendingPathComponent("TicTracker-backup.app")
                try FileManager.default.moveItem(at: currentAppURL, to: backupURL)

                // 移入新版本
                do {
                    try FileManager.default.moveItem(at: newApp, to: destination)
                } catch {
                    // 回滚
                    try? FileManager.default.moveItem(at: backupURL, to: currentAppURL)
                    await MainActor.run { progressWindow.close(); self.showError("替换失败：\(error.localizedDescription)") }
                    return
                }

                // 清理临时文件
                try? FileManager.default.removeItem(at: tempDir)

                await MainActor.run {
                    progressWindow.close()
                    // 等当前进程退出后再启动新版本
                    let pid = ProcessInfo.processInfo.processIdentifier
                    let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"\(destination.path)\""
                    let relaunch = Process()
                    relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                    relaunch.arguments = ["-c", script]
                    try? relaunch.run()
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run { progressWindow.close(); self.showError("更新失败：\(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Version Compare

    private func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    // MARK: - Alerts

    private func showUpdateAlert(version: String, zipURL: String?) {
        let wasAccessory = NSApp.activationPolicy() == .accessory
        if wasAccessory { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "发现新版本 v\(version)"
        alert.informativeText = "当前版本 \(currentVersion)，最新版本 \(version)。"

        if zipURL != nil {
            alert.addButton(withTitle: "下载并更新")
        }
        alert.addButton(withTitle: "稍后提醒")
        alert.addButton(withTitle: "跳过此版本")
        alert.alertStyle = .informational

        let response = alert.runModal()

        if zipURL != nil && response == .alertFirstButtonReturn {
            downloadAndInstall(zipURLString: zipURL!)
            return
        }

        let skipButton: NSApplication.ModalResponse = zipURL != nil ? .alertThirdButtonReturn : .alertSecondButtonReturn
        if response == skipButton {
            UserDefaults.standard.set(version, forKey: "skippedVersion")
        }

        if wasAccessory { NSApp.setActivationPolicy(.accessory) }
    }

    private func showUpToDateAlert() {
        let wasAccessory = NSApp.activationPolicy() == .accessory
        if wasAccessory { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "当前版本 \(currentVersion) 已是最新。"
        alert.addButton(withTitle: "好")
        alert.alertStyle = .informational
        alert.runModal()

        if wasAccessory { NSApp.setActivationPolicy(.accessory) }
    }

    private func showError(_ message: String) {
        let wasAccessory = NSApp.activationPolicy() == .accessory
        if wasAccessory { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "检查更新失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.alertStyle = .warning
        alert.runModal()

        if wasAccessory { NSApp.setActivationPolicy(.accessory) }
    }
}
