import Foundation

enum RuntimeDoctorService {
    enum ServiceError: LocalizedError {
        case unsupported(RuntimeKind)

        var errorDescription: String? {
            switch self {
            case .unsupported(let kind):
                return "\(kind.displayName) 观察模式尚未接入。"
            }
        }
    }

    static func inspect(_ kind: RuntimeKind) async throws -> RuntimeSnapshot {
        switch kind {
        case .node:
            return try await inspectNodeEnvironment()
        case .python:
            return try await inspectPythonEnvironment()
        }
    }

    static func inspectNodeEnvironment() async throws -> RuntimeSnapshot {
        let guiPathEntries = splitPath(ProcessInfo.processInfo.environment["PATH"] ?? "")
        async let loginPathText = shell("print -r -- $PATH", login: true)
        async let currentNodePathsText = shell("whence -pa node")
        async let currentNpmPathsText = shell("whence -pa npm")
        async let loginNodePathsText = shell("whence -pa node", login: true)
        async let loginNpmPathsText = shell("whence -pa npm", login: true)

        let loginPathEntries = splitPath((try? await loginPathText) ?? "")
        let currentNodePaths = uniqueLines((try? await currentNodePathsText) ?? "")
        let currentNpmPaths = uniqueLines((try? await currentNpmPathsText) ?? "")
        let loginNodePaths = uniqueLines((try? await loginNodePathsText) ?? "")
        let loginNpmPaths = uniqueLines((try? await loginNpmPathsText) ?? "")

        let activeNodePath = currentNodePaths.first
        let activeNpmPath = currentNpmPaths.first
        let loginNodePath = loginNodePaths.first
        let loginNpmPath = loginNpmPaths.first

        let discoveredPaths = try await discoverCandidateNodePaths(existing: currentNodePaths)
        let runtimes = try await buildRuntimeInstallations(paths: discoveredPaths, guiPathEntries: guiPathEntries, activeNodePath: activeNodePath)

        let activeNodeVersion: String? = try await {
            if let activeNodePath { return try await versionForBinary(at: activeNodePath) }
            return nil
        }()
        let loginNodeVersion: String? = try await {
            if let loginNodePath { return try await versionForBinary(at: loginNodePath) }
            return nil
        }()
        let activeNpmVersion: String? = try await {
            if let activeNpmPath { return try await npmVersionValue(npmPath: activeNpmPath) }
            return nil
        }()
        let loginNpmVersion: String? = try await {
            if let loginNpmPath { return try await npmVersionValue(npmPath: loginNpmPath) }
            return nil
        }()
        let npmPrefix = try await {
            if let activeNpmPath { return try await npmMetadataValue(npmPath: activeNpmPath, command: "prefix -g") }
            return nil
        }()
        let globalRootPath = try await {
            if let activeNpmPath { return try await npmMetadataValue(npmPath: activeNpmPath, command: "root -g") }
            return nil
        }()
        let globalBinPath = npmPrefix.map { URL(fileURLWithPath: $0).appendingPathComponent("bin").path }
        let latestCheck = try await {
            if let activeNpmPath { return try await fetchNpmLatestCheck(npmPath: activeNpmPath) }
            return RuntimeLatestRegistryResult.notChecked(source: "npm registry")
        }()
        let globalPackages = try await buildGlobalPackages(npmPath: activeNpmPath, globalRootPath: globalRootPath, npmPrefix: npmPrefix, latestCheck: latestCheck)
        let shellGlobalPackageCount: Int? = try await {
            guard let loginNpmPath else { return nil }
            let shellPrefix = try await npmMetadataValue(npmPath: loginNpmPath, command: "prefix -g")
            let shellRoot = try await npmMetadataValue(npmPath: loginNpmPath, command: "root -g")
            let shellPackages = try await buildGlobalPackages(npmPath: loginNpmPath, globalRootPath: shellRoot, npmPrefix: shellPrefix, latestCheck: .notChecked(source: "npm registry"))
            return shellPackages.count
        }()

        let issues = buildIssues(
            runtimes: runtimes,
            activeNodePath: activeNodePath,
            activeNodeSource: runtimes.first(where: { $0.isActive })?.source ?? .unknown,
            npmPrefix: npmPrefix,
            globalBinPath: globalBinPath,
            globalPackages: globalPackages,
            guiPathEntries: guiPathEntries,
            loginPathEntries: loginPathEntries,
            loginNodePath: loginNodePath
        )

        let reportMarkdown = buildReport(
            activeNodeVersion: activeNodeVersion,
            activeNodePath: activeNodePath,
            activeNodeSource: runtimes.first(where: { $0.isActive })?.source ?? .unknown,
            loginNodeVersion: loginNodeVersion,
            activeNpmVersion: activeNpmVersion,
            activeNpmPath: activeNpmPath,
            npmPrefix: npmPrefix,
            globalBinPath: globalBinPath,
            guiPathEntries: guiPathEntries,
            loginPathEntries: loginPathEntries,
            runtimes: runtimes,
            globalPackages: globalPackages,
            issues: issues
        )

        let guiExecutable: RuntimeExecutableSnapshot? = if activeNodePath != nil || activeNodeVersion != nil {
            RuntimeExecutableSnapshot(
                name: RuntimeKind.node.displayName,
                version: activeNodeVersion,
                path: activeNodePath,
                provider: runtimes.first(where: { $0.isActive })?.source ?? .unknown
            )
        } else {
            nil
        }
        let loginExecutable: RuntimeExecutableSnapshot? = if loginNodePath != nil || loginNodeVersion != nil {
            RuntimeExecutableSnapshot(
                name: RuntimeKind.node.displayName,
                version: loginNodeVersion,
                path: loginNodePath,
                provider: runtimes.first(where: { $0.path == loginNodePath || $0.resolvedPath == loginNodePath })?.source ?? guiExecutable?.provider ?? .unknown
            )
        } else {
            nil
        }
        let npmSnapshot = RuntimePackageManagerSnapshot(
            identifier: "npm",
            displayName: "npm",
            guiVersion: activeNpmVersion,
            guiPath: activeNpmPath,
            loginShellVersion: loginNpmVersion,
            loginShellPath: loginNpmPath,
            prefix: npmPrefix,
            globalBinPath: globalBinPath,
            globalRootPath: globalRootPath,
            shellToolCount: shellGlobalPackageCount
        )

        return RuntimeSnapshot(
            kind: .node,
            activeExecutable: loginExecutable ?? guiExecutable,
            loginShellExecutable: loginExecutable,
            guiExecutable: guiExecutable,
            packageManagers: [npmSnapshot],
            pathSnapshot: RuntimePathSnapshot(guiEntries: guiPathEntries, loginShellEntries: loginPathEntries),
            installations: runtimes,
            toolEntries: globalPackages,
            issues: issues,
            pathPolicy: RuntimePATHPolicyCatalog.policy(.minimalTrusted, runtimeName: RuntimeKind.node.displayName),
            reportMarkdown: reportMarkdown
        )
    }

    static func inspectPythonEnvironment() async throws -> RuntimeSnapshot {
        let guiPathEntries = splitPath(ProcessInfo.processInfo.environment["PATH"] ?? "")
        async let loginPathText = shell("print -r -- $PATH", login: true)

        async let currentPython3PathsText = shell("whence -pa python3")
        async let currentPythonPathsText = shell("whence -pa python")
        async let loginPython3PathsText = shell("whence -pa python3", login: true)
        async let loginPythonPathsText = shell("whence -pa python", login: true)

        async let currentPip3PathsText = shell("whence -pa pip3")
        async let currentPipPathsText = shell("whence -pa pip")
        async let loginPip3PathsText = shell("whence -pa pip3", login: true)
        async let loginPipPathsText = shell("whence -pa pip", login: true)

        async let currentUvPathsText = shell("whence -pa uv")
        async let loginUvPathsText = shell("whence -pa uv", login: true)
        async let currentPipxPathsText = shell("whence -pa pipx")
        async let loginPipxPathsText = shell("whence -pa pipx", login: true)
        async let currentPyenvPathsText = shell("whence -pa pyenv")
        async let loginPyenvPathsText = shell("whence -pa pyenv", login: true)
        async let currentCondaPathsText = shell("whence -pa conda")
        async let loginCondaPathsText = shell("whence -pa conda", login: true)
        async let loginCondaDefaultEnvText = shell("print -r -- ${CONDA_DEFAULT_ENV:-}", login: true)

        let loginPathEntries = splitPath((try? await loginPathText) ?? "")

        let currentPythonPaths = uniqueLines(((try? await currentPython3PathsText) ?? "") + "\n" + ((try? await currentPythonPathsText) ?? ""))
        let loginPythonPaths = uniqueLines(((try? await loginPython3PathsText) ?? "") + "\n" + ((try? await loginPythonPathsText) ?? ""))
        let currentPipPaths = uniqueLines(((try? await currentPip3PathsText) ?? "") + "\n" + ((try? await currentPipPathsText) ?? ""))
        let loginPipPaths = uniqueLines(((try? await loginPip3PathsText) ?? "") + "\n" + ((try? await loginPipPathsText) ?? ""))
        let currentUvPaths = uniqueLines((try? await currentUvPathsText) ?? "")
        let loginUvPaths = uniqueLines((try? await loginUvPathsText) ?? "")
        let currentPipxPaths = uniqueLines((try? await currentPipxPathsText) ?? "")
        let loginPipxPaths = uniqueLines((try? await loginPipxPathsText) ?? "")
        let currentPyenvPaths = uniqueLines((try? await currentPyenvPathsText) ?? "")
        let loginPyenvPaths = uniqueLines((try? await loginPyenvPathsText) ?? "")
        let currentCondaPaths = uniqueLines((try? await currentCondaPathsText) ?? "")
        let loginCondaPaths = uniqueLines((try? await loginCondaPathsText) ?? "")
        let loginCondaDefaultEnv = ((try? await loginCondaDefaultEnvText) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let activePythonPath = currentPythonPaths.first
        let loginPythonPath = loginPythonPaths.first
        let activePipPath = currentPipPaths.first
        let loginPipPath = loginPipPaths.first
        let activeUvPath = currentUvPaths.first
        let loginUvPath = loginUvPaths.first
        let activePipxPath = currentPipxPaths.first
        let loginPipxPath = loginPipxPaths.first
        let activePyenvPath = currentPyenvPaths.first
        let loginPyenvPath = loginPyenvPaths.first
        let activeCondaPath = currentCondaPaths.first
        let loginCondaPath = loginCondaPaths.first

        let discoveredPaths = try await discoverCandidatePythonPaths(existing: currentPythonPaths)
        let runtimes = try await buildPythonInstallations(paths: discoveredPaths, guiPathEntries: guiPathEntries, activePythonPath: activePythonPath)

        let activePythonVersion = try await executableVersion(path: activePythonPath, args: ["--version"])
        let loginPythonVersion = try await executableVersion(path: loginPythonPath, args: ["--version"])
        let activePipVersion = try await executableVersion(path: activePipPath, args: ["--version"], compact: true)
        let loginPipVersion = try await executableVersion(path: loginPipPath, args: ["--version"], compact: true)
        let activeUvVersion = try await executableVersion(path: activeUvPath, args: ["--version"], compact: true)
        let loginUvVersion = try await executableVersion(path: loginUvPath, args: ["--version"], compact: true)
        let activePipxVersion = try await executableVersion(path: activePipxPath, args: ["--version"], compact: true)
        let loginPipxVersion = try await executableVersion(path: loginPipxPath, args: ["--version"], compact: true)
        let activePyenvVersion = try await executableVersion(path: activePyenvPath, args: ["--version"], compact: true)
        let loginPyenvVersion = try await executableVersion(path: loginPyenvPath, args: ["--version"], compact: true)
        let activeCondaVersion = try await executableVersion(path: activeCondaPath, args: ["--version"], compact: true)
        let loginCondaVersion = try await executableVersion(path: loginCondaPath, args: ["--version"], compact: true)

        let activePythonModulePipVersion = try await pythonModulePipVersion(pythonPath: activePythonPath)
        let loginPythonModulePipVersion = try await pythonModulePipVersion(pythonPath: loginPythonPath)
        let activePythonUserBase = try await pythonUserBase(pythonPath: activePythonPath)
        let loginPythonUserBase = try await pythonUserBase(pythonPath: loginPythonPath)
        let activePythonUserBin = activePythonUserBase.map { URL(fileURLWithPath: $0).appendingPathComponent("bin").path }
        let loginPythonUserBin = loginPythonUserBase.map { URL(fileURLWithPath: $0).appendingPathComponent("bin").path }
        let userLocalBinPath = loginPythonUserBin ?? activePythonUserBin ?? NSString(string: "~/.local/bin").expandingTildeInPath

        let pipSnapshot = RuntimePackageManagerSnapshot(
            identifier: "pip",
            displayName: "pip",
            guiVersion: activePipVersion,
            guiPath: activePipPath,
            loginShellVersion: loginPipVersion,
            loginShellPath: loginPipPath,
            prefix: activePythonUserBase ?? loginPythonUserBase,
            globalBinPath: activePythonUserBin ?? loginPythonUserBin,
            globalRootPath: nil,
            shellToolCount: nil
        )
        let modulePipSnapshot = RuntimePackageManagerSnapshot(
            identifier: "python-module-pip",
            displayName: "python -m pip",
            guiVersion: activePythonModulePipVersion,
            guiPath: activePythonPath,
            loginShellVersion: loginPythonModulePipVersion,
            loginShellPath: loginPythonPath,
            prefix: activePythonUserBase ?? loginPythonUserBase,
            globalBinPath: activePythonUserBin ?? loginPythonUserBin,
            globalRootPath: nil,
            shellToolCount: nil
        )
        let uvSnapshot = RuntimePackageManagerSnapshot(
            identifier: "uv",
            displayName: "uv",
            guiVersion: activeUvVersion,
            guiPath: activeUvPath,
            loginShellVersion: loginUvVersion,
            loginShellPath: loginUvPath,
            prefix: nil,
            globalBinPath: userLocalBinPath,
            globalRootPath: nil,
            shellToolCount: nil
        )
        let pipxSnapshot = RuntimePackageManagerSnapshot(
            identifier: "pipx",
            displayName: "pipx",
            guiVersion: activePipxVersion,
            guiPath: activePipxPath,
            loginShellVersion: loginPipxVersion,
            loginShellPath: loginPipxPath,
            prefix: nil,
            globalBinPath: userLocalBinPath,
            globalRootPath: nil,
            shellToolCount: nil
        )
        let pyenvSnapshot = RuntimePackageManagerSnapshot(
            identifier: "pyenv",
            displayName: "pyenv",
            guiVersion: activePyenvVersion,
            guiPath: activePyenvPath,
            loginShellVersion: loginPyenvVersion,
            loginShellPath: loginPyenvPath,
            prefix: nil,
            globalBinPath: nil,
            globalRootPath: nil,
            shellToolCount: nil
        )
        let condaSnapshot = RuntimePackageManagerSnapshot(
            identifier: "conda",
            displayName: "conda",
            guiVersion: activeCondaVersion,
            guiPath: activeCondaPath,
            loginShellVersion: loginCondaVersion,
            loginShellPath: loginCondaPath,
            prefix: nil,
            globalBinPath: nil,
            globalRootPath: nil,
            shellToolCount: nil
        )

        let issues = buildPythonIssues(
            runtimes: runtimes,
            activePythonPath: activePythonPath,
            loginPythonPath: loginPythonPath,
            activePipPath: activePipPath,
            loginPipPath: loginPipPath,
            activePythonModulePipVersion: activePythonModulePipVersion,
            loginPythonModulePipVersion: loginPythonModulePipVersion,
            guiPathEntries: guiPathEntries,
            loginPathEntries: loginPathEntries,
            userLocalBinPath: userLocalBinPath,
            hasUv: loginUvPath != nil || activeUvPath != nil,
            hasPipx: loginPipxPath != nil || activePipxPath != nil,
            hasPyenv: loginPyenvPath != nil || activePyenvPath != nil,
            hasConda: loginCondaPath != nil || activeCondaPath != nil,
            loginCondaDefaultEnv: loginCondaDefaultEnv
        )

        let toolEntries = try await buildPythonToolEntries(
            guiPathEntries: guiPathEntries,
            loginPathEntries: loginPathEntries,
            activePythonPath: activePythonPath,
            loginPythonPath: loginPythonPath,
            userLocalBinPath: userLocalBinPath,
            packageManagers: [pipSnapshot, modulePipSnapshot, uvSnapshot, pipxSnapshot, pyenvSnapshot, condaSnapshot]
        )

        let reportMarkdown = buildPythonReport(
            activePythonVersion: activePythonVersion,
            activePythonPath: activePythonPath,
            activePythonSource: runtimes.first(where: { $0.isActive })?.source ?? .unknown,
            loginPythonVersion: loginPythonVersion,
            packageManagers: [pipSnapshot, modulePipSnapshot, uvSnapshot, pipxSnapshot, pyenvSnapshot, condaSnapshot],
            guiPathEntries: guiPathEntries,
            loginPathEntries: loginPathEntries,
            runtimes: runtimes,
            toolEntries: toolEntries,
            issues: issues
        )

        let guiExecutable: RuntimeExecutableSnapshot? = if activePythonPath != nil || activePythonVersion != nil {
            RuntimeExecutableSnapshot(
                name: RuntimeKind.python.displayName,
                version: activePythonVersion,
                path: activePythonPath,
                provider: runtimes.first(where: { $0.isActive })?.source ?? .unknown
            )
        } else {
            nil
        }
        let loginExecutable: RuntimeExecutableSnapshot? = if loginPythonPath != nil || loginPythonVersion != nil {
            RuntimeExecutableSnapshot(
                name: RuntimeKind.python.displayName,
                version: loginPythonVersion,
                path: loginPythonPath,
                provider: runtimes.first(where: { $0.path == loginPythonPath || $0.resolvedPath == loginPythonPath })?.source ?? guiExecutable?.provider ?? .unknown
            )
        } else {
            nil
        }

        return RuntimeSnapshot(
            kind: .python,
            activeExecutable: loginExecutable ?? guiExecutable,
            loginShellExecutable: loginExecutable,
            guiExecutable: guiExecutable,
            packageManagers: [pipSnapshot, modulePipSnapshot, uvSnapshot, pipxSnapshot, pyenvSnapshot, condaSnapshot].filter {
                $0.guiPath != nil || $0.loginShellPath != nil || $0.guiVersion != nil || $0.loginShellVersion != nil
            },
            pathSnapshot: RuntimePathSnapshot(guiEntries: guiPathEntries, loginShellEntries: loginPathEntries),
            installations: runtimes,
            toolEntries: toolEntries,
            issues: issues,
            pathPolicy: RuntimePATHPolicyCatalog.policy(.minimalTrusted, runtimeName: RuntimeKind.python.displayName),
            reportMarkdown: reportMarkdown
        )
    }

    static func runNpmCommand(npmPath: String, args: [String]) async throws -> String {
        let npmDir = URL(fileURLWithPath: npmPath).deletingLastPathComponent().path
        let mergedPath = "\(npmDir):" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
        return try await ShellService.runSynchronous(executable: npmPath, args: args, environment: ["PATH": mergedPath])
    }

    static func runLaunchctlSetenv(command: String) async throws -> String {
        try await shell(command)
    }

    static func repairUserNpmPrefix(npmPath: String, targetPrefix: String) async throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: targetPrefix),
            withIntermediateDirectories: true
        )
        _ = try await runNpmCommand(npmPath: npmPath, args: ["config", "set", "prefix", targetPrefix])
    }

    private static func shell(_ command: String, login: Bool = false) async throws -> String {
        try await ShellService.runSynchronous(
            executable: "/bin/zsh",
            args: [login ? "-lc" : "-c", command]
        )
    }

    private static func npmMetadataValue(npmPath: String, command: String) async throws -> String? {
        let npmDir = URL(fileURLWithPath: npmPath).deletingLastPathComponent().path
        let out = try await shell("PATH=\(shellQuote(npmDir)):$PATH \(shellQuote(npmPath)) \(command)")
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "undefined" ? nil : trimmed
    }

    private static func npmVersionValue(npmPath: String) async throws -> String? {
        let npmDir = URL(fileURLWithPath: npmPath).deletingLastPathComponent().path
        let out = try await shell("PATH=\(shellQuote(npmDir)):$PATH \(shellQuote(npmPath)) -v")
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct RuntimeLatestRegistryResult {
        let source: String
        let checkedAt: Date?
        let latestVersions: [String: String]
        let missingLatestNames: Set<String>
        let failureReason: String?

        static func notChecked(source: String) -> Self {
            RuntimeLatestRegistryResult(
                source: source,
                checkedAt: nil,
                latestVersions: [:],
                missingLatestNames: [],
                failureReason: nil
            )
        }

        func state(for packageName: String, currentVersion: String) -> RuntimeLatestCheckState {
            guard let checkedAt else {
                return .notChecked(source: source)
            }
            if let failureReason {
                return .failed(reason: failureReason, source: source, checkedAt: checkedAt)
            }
            if missingLatestNames.contains(packageName) {
                return .missingLatest(source: source, checkedAt: checkedAt)
            }
            if let latest = latestVersions[packageName] {
                if latest == currentVersion {
                    return .upToDate(version: latest, source: source, checkedAt: checkedAt)
                }
                return .outdated(current: currentVersion, latest: latest, source: source, checkedAt: checkedAt)
            }
            return .upToDate(version: currentVersion, source: source, checkedAt: checkedAt)
        }
    }

    private static func fetchNpmLatestCheck(npmPath: String) async throws -> RuntimeLatestRegistryResult {
        let npmDir = URL(fileURLWithPath: npmPath).deletingLastPathComponent().path
        let checkedAt = Date()
        let marker = "__CELLAR_NPM_OUTDATED_EXIT:"
        let text = try await shell("PATH=\(shellQuote(npmDir)):$PATH \(shellQuote(npmPath)) outdated -g --json 2>&1\nprint \"\(marker)$?\"")
        guard let markerRange = text.range(of: marker, options: .backwards) else {
            return RuntimeLatestRegistryResult(
                source: "npm registry",
                checkedAt: checkedAt,
                latestVersions: [:],
                missingLatestNames: [],
                failureReason: "没有取得 npm outdated 的退出状态"
            )
        }
        let body = String(text[..<markerRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let statusText = String(text[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let exitStatus = Int(statusText) ?? 1

        guard !body.isEmpty else {
            if exitStatus <= 1 {
                return RuntimeLatestRegistryResult(
                    source: "npm registry",
                    checkedAt: checkedAt,
                    latestVersions: [:],
                    missingLatestNames: [],
                    failureReason: nil
                )
            }
            return RuntimeLatestRegistryResult(
                source: "npm registry",
                checkedAt: checkedAt,
                latestVersions: [:],
                missingLatestNames: [],
                failureReason: "npm outdated 退出码 \(exitStatus)"
            )
        }

        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let reason = body.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RuntimeLatestRegistryResult(
                source: "npm registry",
                checkedAt: checkedAt,
                latestVersions: [:],
                missingLatestNames: [],
                failureReason: reason?.isEmpty == false ? reason : "registry 响应不是 JSON"
            )
        }
        if let error = json["error"] {
            return RuntimeLatestRegistryResult(
                source: "npm registry",
                checkedAt: checkedAt,
                latestVersions: [:],
                missingLatestNames: [],
                failureReason: npmErrorReason(error) ?? "npm registry 查询失败"
            )
        }
        if exitStatus > 1 {
            return RuntimeLatestRegistryResult(
                source: "npm registry",
                checkedAt: checkedAt,
                latestVersions: [:],
                missingLatestNames: [],
                failureReason: "npm outdated 退出码 \(exitStatus)"
            )
        }
        var result: [String: String] = [:]
        var missingLatestNames = Set<String>()
        for (name, value) in json {
            if let dict = value as? [String: Any] {
                if let latest = dict["latest"] as? String, !latest.isEmpty {
                    result[name] = latest
                } else {
                    missingLatestNames.insert(name)
                }
            }
        }
        return RuntimeLatestRegistryResult(
            source: "npm registry",
            checkedAt: checkedAt,
            latestVersions: result,
            missingLatestNames: missingLatestNames,
            failureReason: nil
        )
    }

    private static func npmErrorReason(_ value: Any) -> String? {
        if let text = value as? String {
            return text
        }
        guard let dict = value as? [String: Any] else { return nil }
        if let summary = dict["summary"] as? String, !summary.isEmpty {
            return summary
        }
        if let message = dict["message"] as? String, !message.isEmpty {
            return message
        }
        if let code = dict["code"] as? String, !code.isEmpty {
            return code
        }
        return nil
    }

    private static func buildGlobalPackages(
        npmPath: String?,
        globalRootPath: String?,
        npmPrefix: String?,
        latestCheck: RuntimeLatestRegistryResult
    ) async throws -> [RuntimeGlobalPackage] {
        guard let npmPath, let globalRootPath else { return [] }
        let npmDir = URL(fileURLWithPath: npmPath).deletingLastPathComponent().path
        let text = try await shell("PATH=\(shellQuote(npmDir)):$PATH \(shellQuote(npmPath)) ls -g --depth=0 --json 2>/dev/null")
        guard let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = json["dependencies"] as? [String: Any] else {
            return []
        }

        var packages: [RuntimeGlobalPackage] = []
        for (name, value) in dependencies {
            guard let dict = value as? [String: Any] else { continue }
            let version = (dict["version"] as? String) ?? "?"
            let installLocation = URL(fileURLWithPath: globalRootPath).appendingPathComponent(name).path
            let bins = packageBins(at: installLocation)
            let managed = npmPrefix.map { installLocation.hasPrefix($0) } ?? false
            packages.append(
                RuntimeGlobalPackage(
                    name: name,
                    currentVersion: version,
                    latestCheckState: latestCheck.state(for: name, currentVersion: version),
                    binaries: bins,
                    installLocation: installLocation,
                    prefix: npmPrefix ?? globalRootPath,
                    managedByCurrentRuntime: managed,
                    sourceLabel: "npm global",
                    shellPath: bins.first.flatMap { bin in
                        npmPrefix.map { URL(fileURLWithPath: $0).appendingPathComponent("bin").appendingPathComponent(bin).path }
                    },
                    guiPath: bins.first.flatMap { bin in
                        npmPrefix.map { URL(fileURLWithPath: $0).appendingPathComponent("bin").appendingPathComponent(bin).path }
                    },
                    isVisibleInShell: true,
                    isVisibleInGUI: true,
                    hasNameConflict: false,
                    statusNote: managed ? "受当前 npm prefix 管理" : "不在当前 npm prefix 作用域"
                )
            )
        }
        return packages.sorted { $0.name < $1.name }
    }

    private static func packageBins(at installLocation: String) -> [String] {
        let packageJSON = URL(fileURLWithPath: installLocation).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let bin = json["bin"] as? String {
            let packageName = (json["name"] as? String) ?? URL(fileURLWithPath: installLocation).lastPathComponent
            return [packageName, bin]
        }
        if let bin = json["bin"] as? [String: Any] {
            return bin.keys.sorted()
        }
        return []
    }

    private static func buildRuntimeInstallations(
        paths: [String],
        guiPathEntries: [String],
        activeNodePath: String?
    ) async throws -> [RuntimeInstallation] {
        try await withThrowingTaskGroup(of: RuntimeInstallation.self) { group in
            for path in paths {
                group.addTask {
                    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                    let source = classifyNodeSource(path: path, resolvedPath: resolved)
                    let version = (try? await versionForBinary(at: path)) ?? "Unavailable"
                    let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
                    let priority = guiPathEntries.firstIndex(of: dir)
                    let isActive = path == activeNodePath
                    let note = runtimeNote(source: source, resolvedPath: resolved)
                    let health: RuntimeHealth = isActive ? .healthy : ((priority != nil) ? .warning : .healthy)
                    return RuntimeInstallation(
                        path: path,
                        resolvedPath: resolved,
                        version: version,
                        source: source,
                        pathPriority: priority,
                        isActive: isActive,
                        health: health,
                        note: note
                    )
                }
            }

            var installations: [RuntimeInstallation] = []
            for try await item in group { installations.append(item) }
            return installations.sorted {
                if $0.isActive != $1.isActive { return $0.isActive }
                if ($0.pathPriority ?? .max) != ($1.pathPriority ?? .max) { return ($0.pathPriority ?? .max) < ($1.pathPriority ?? .max) }
                return $0.path < $1.path
            }
        }
    }

    private static func buildPythonInstallations(
        paths: [String],
        guiPathEntries: [String],
        activePythonPath: String?
    ) async throws -> [RuntimeInstallation] {
        try await withThrowingTaskGroup(of: RuntimeInstallation.self) { group in
            for path in paths {
                group.addTask {
                    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                    let source = classifyPythonSource(path: path, resolvedPath: resolved)
                    let version = (try? await versionForBinary(at: path, args: ["--version"])) ?? "Unavailable"
                    let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
                    let priority = guiPathEntries.firstIndex(of: dir)
                    let isActive = path == activePythonPath
                    let note = runtimeNote(kind: .python, source: source, resolvedPath: resolved)
                    let health: RuntimeHealth = isActive ? .healthy : ((priority != nil) ? .warning : .healthy)
                    return RuntimeInstallation(
                        path: path,
                        resolvedPath: resolved,
                        version: version,
                        source: source,
                        pathPriority: priority,
                        isActive: isActive,
                        health: health,
                        note: note
                    )
                }
            }

            var installations: [RuntimeInstallation] = []
            for try await item in group { installations.append(item) }
            return installations.sorted {
                if $0.isActive != $1.isActive { return $0.isActive }
                if ($0.pathPriority ?? .max) != ($1.pathPriority ?? .max) { return ($0.pathPriority ?? .max) < ($1.pathPriority ?? .max) }
                return $0.path < $1.path
            }
        }
    }

    private static func buildIssues(
        runtimes: [RuntimeInstallation],
        activeNodePath: String?,
        activeNodeSource: RuntimeSourceKind,
        npmPrefix: String?,
        globalBinPath: String?,
        globalPackages: [RuntimeGlobalPackage],
        guiPathEntries: [String],
        loginPathEntries: [String],
        loginNodePath: String?
    ) -> [RuntimeIssue] {
        var issues: [RuntimeIssue] = []

        let hasUsrLocal = runtimes.contains { $0.path == "/usr/local/bin/node" || $0.resolvedPath.hasPrefix("/usr/local/") }
        let hasHomebrew = runtimes.contains { $0.path == "/opt/homebrew/bin/node" || $0.resolvedPath.contains("/Cellar/node/") || $0.resolvedPath.contains("/opt/homebrew/") }
        if hasUsrLocal && hasHomebrew {
            issues.append(RuntimeIssue(
                title: "Node 来源混用",
                currentState: "同时发现 /usr/local 与 Homebrew Node。",
                explanation: "默认版本可能因 PATH 顺序而漂移，同一台机器上的命令行为也会变得不稳定。",
                recommendation: "保留一套主要来源，另一套改为只识别不参与 PATH 竞争。",
                severity: .high
            ))
        }

        if activeNodeSource == .homebrew, let npmPrefix, npmPrefix.hasPrefix("/usr/local") {
            issues.append(RuntimeIssue(
                title: "npm prefix 与当前 Node 不一致",
                currentState: "当前 Node 来自 Homebrew，但 npm prefix 指向 /usr/local。",
                explanation: "这通常意味着全局包可能要求 sudo，或者继续落到旧目录里，难以判断真实来源。",
                recommendation: "把 npm prefix 调整到用户级目录，例如 ~/.npm-global，并让对应 bin 进入 PATH。",
                severity: .high
            ))
        }

        if let globalBinPath, let npmPrefix, npmPrefix.contains(".npm-global"), !loginPathEntries.contains(globalBinPath) {
            issues.append(RuntimeIssue(
                title: "用户级全局 bin 未进入 PATH",
                currentState: "用户级 npm prefix 已配置，但登录 shell 的 PATH 没有包含 \(globalBinPath)。",
                explanation: "包虽然安装成功，但命令未必能直接被终端或脚本发现。",
                recommendation: "把该路径加入 shell 启动配置，避免命令已安装但不可发现。",
                severity: .warning
            ))
        }

        if guiPathEntries != loginPathEntries {
            issues.append(RuntimeIssue(
                title: "GUI 与 Shell 路径存在策略性差异",
                currentState: "GUI 环境与登录 shell 没有完全复制同一份 PATH。",
                explanation: "GUI 环境已具备运行所需核心路径，但不会完整复制 Shell 的全部 PATH，以避免引入临时路径、系统注入路径和 App 私有路径。",
                recommendation: "这是当前默认策略；若 GUI 已可用，则无需修复。只有在 GUI 无法访问目标运行时时，才需要执行环境统一。",
                severity: .info
            ))
        }

        if let activeNodePath, let loginNodePath, activeNodePath != loginNodePath {
            issues.append(RuntimeIssue(
                title: "GUI 与终端默认 Node 不同",
                currentState: "GUI 当前激活的 Node 是 \(activeNodePath)，而登录 shell 默认解析到 \(loginNodePath)。",
                explanation: "你在终端里看到的版本并不一定就是 Cellar 实际使用的版本。",
                recommendation: "如果你希望两者一致，请统一 launchd / GUI 环境与 shell 启动脚本的 PATH 顺序。",
                severity: .warning
            ))
        }

        if activeNodePath == nil {
            issues.append(RuntimeIssue(
                title: "GUI 当前未接入 Node",
                currentState: "当前 GUI 进程没有解析到 node。",
                explanation: "终端里的 Node 可能是可用的，但 Cellar 并没有继承到同一环境，所以可观测性与全局包管理都会受限。",
                recommendation: "先统一 GUI 与 Shell 环境，再回到运行时面板继续治理。",
                severity: .high
            ))
        }

        for package in globalPackages where !package.binaries.isEmpty {
            let missing = package.binaries.filter { bin in
                guard let globalBinPath else { return true }
                return !FileManager.default.fileExists(atPath: URL(fileURLWithPath: globalBinPath).appendingPathComponent(bin).path)
            }
            if !missing.isEmpty {
                issues.append(RuntimeIssue(
                    title: "全局包记录与可执行文件不一致",
                    currentState: "\(package.name) 记录了 \(missing.joined(separator: ", "))，但当前全局 bin 路径下未找到对应可执行文件。",
                    explanation: "npm 记录仍然存在，但实际命令入口已经缺失，通常意味着 prefix、bin 路径或安装状态发生了漂移。",
                    recommendation: "尝试重装该包，或检查 prefix / bin 路径是否仍指向当前运行时。",
                    severity: .warning
                ))
            }
        }

        if runtimes.map(\.source).filter({ $0 != .unknown }).count > 1 {
            issues.append(RuntimeIssue(
                title: "检测到多套 Node 来源",
                currentState: "当前机器上同时存在多套 Node provider。",
                explanation: "多来源本身不一定是错误，但如果没有明确的主来源，就很容易出现切换和诊断误判。",
                recommendation: "建议先明确一套主来源，其余来源保留为备用或只做识别。",
                severity: .info
            ))
        }

        return issues.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.title < rhs.title
        }
    }

    private static func buildReport(
        activeNodeVersion: String?,
        activeNodePath: String?,
        activeNodeSource: RuntimeSourceKind,
        loginNodeVersion: String?,
        activeNpmVersion: String?,
        activeNpmPath: String?,
        npmPrefix: String?,
        globalBinPath: String?,
        guiPathEntries: [String],
        loginPathEntries: [String],
        runtimes: [RuntimeInstallation],
        globalPackages: [RuntimeGlobalPackage],
        issues: [RuntimeIssue]
    ) -> String {
        var lines: [String] = []
        lines.append("# Cellar Runtime Report")
        lines.append("")
        lines.append("Generated: \(Date().formatted(date: .abbreviated, time: .standard))")
        lines.append("")
        lines.append("## Active Node")
        lines.append("- Version: \(activeNodeVersion ?? "Not found")")
        lines.append("- Path: \(activeNodePath ?? "Not found")")
        lines.append("- Source: \(activeNodeSource.rawValue)")
        lines.append("")
        lines.append("## Active npm")
        lines.append("- Version: \(activeNpmVersion ?? "Not found")")
        lines.append("- Path: \(activeNpmPath ?? "Not found")")
        lines.append("- Prefix: \(npmPrefix ?? "Not found")")
        lines.append("- Global bin: \(globalBinPath ?? "Not found")")
        lines.append("")
        lines.append("## PATH Snapshot")
        lines.append("### GUI PATH")
        for item in guiPathEntries { lines.append("- \(item)") }
        lines.append("")
        lines.append("### Login Shell PATH")
        for item in loginPathEntries { lines.append("- \(item)") }
        lines.append("")
        lines.append("## Installed Runtimes")
        for runtime in runtimes {
            lines.append("- \(runtime.version) | \(runtime.path) | \(runtime.source.rawValue) | \(runtime.isActive ? "Active" : "Inactive")")
        }
        lines.append("")
        lines.append("## Global Packages")
        for package in globalPackages {
            let latest = package.latestCheckState.reportSummary
            let bins = package.binaries.isEmpty ? "-" : package.binaries.joined(separator: ", ")
            lines.append("- \(package.name) | current \(package.currentVersion) | latest \(latest) | bins \(bins)")
        }
        lines.append("")
        lines.append("## Issues")
        if issues.isEmpty {
            lines.append("- No obvious conflicts found.")
        } else {
            for issue in issues {
                lines.append("- [\(issue.severity.title)] \(issue.title)")
                lines.append("  Current: \(issue.currentState)")
                lines.append("  Why: \(issue.explanation)")
                lines.append("  Recommendation: \(issue.recommendation)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func buildPythonIssues(
        runtimes: [RuntimeInstallation],
        activePythonPath: String?,
        loginPythonPath: String?,
        activePipPath: String?,
        loginPipPath: String?,
        activePythonModulePipVersion: String?,
        loginPythonModulePipVersion: String?,
        guiPathEntries: [String],
        loginPathEntries: [String],
        userLocalBinPath: String,
        hasUv: Bool,
        hasPipx: Bool,
        hasPyenv: Bool,
        hasConda: Bool,
        loginCondaDefaultEnv: String
    ) -> [RuntimeIssue] {
        var issues: [RuntimeIssue] = []

        let hasHomebrew = runtimes.contains { $0.source == .homebrew }
        let hasPyenvRuntime = runtimes.contains { $0.source == .pyenv } || hasPyenv
        let hasCondaRuntime = runtimes.contains { $0.source == .conda } || hasConda

        if guiPathEntries != loginPathEntries {
            issues.append(RuntimeIssue(
                title: "GUI 与 Shell 路径存在策略性差异",
                currentState: "GUI 环境与登录 shell 没有完全复制同一份 PATH。",
                explanation: "GUI 环境只保留运行当前 Python 及工具入口所需的核心路径，不完整复制 Shell PATH。",
                recommendation: "只要 GUI 已能看到推荐 Python，这属于正常策略差异；当前阶段无需修复。",
                severity: .info
            ))
        }

        if activePythonPath == nil, loginPythonPath != nil {
            issues.append(RuntimeIssue(
                title: "GUI 当前未接入 Python",
                currentState: "登录 shell 可以解析到 Python，但 Cellar 当前 GUI 进程没有解析到同一解释器。",
                explanation: "这会影响 GUI 侧对 pip、pipx、uv 和 PATH 的观察结果，但不代表终端里的 Python 不可用。",
                recommendation: "可先执行“最小可信对齐”让 Cellar 当前会话接入核心 Python PATH；若需要长期生效，再手动执行 GUI 修复命令。",
                severity: .high
            ))
        }

        if let activePythonPath, let loginPythonPath, activePythonPath != loginPythonPath {
            issues.append(RuntimeIssue(
                title: "GUI 与终端默认 Python 不同",
                currentState: "GUI 当前激活的 Python 是 \(activePythonPath)，而登录 shell 默认解析到 \(loginPythonPath)。",
                explanation: "你在终端里执行的 `python3`，不一定就是 Cellar 当前 GUI 观察到的同一套解释器。",
                recommendation: "先把 Shell 环境视为主参考环境，再决定是否需要对齐 GUI。",
                severity: .warning
            ))
        }

        if let loginPythonPath, loginPythonPath == "/usr/bin/python3" {
            issues.append(RuntimeIssue(
                title: "系统 Python 正在充当主环境",
                currentState: "当前登录 shell 默认解析到 /usr/bin/python3。",
                explanation: "系统 Python 更适合作为系统依赖，而不是长期开发主环境。",
                recommendation: "若日常开发依赖 Python，建议明确使用 Homebrew、pyenv 或 conda 中的一套主来源。",
                severity: .warning
            ))
        }

        if let activePipPath, let loginPipPath, activePipPath != loginPipPath {
            issues.append(RuntimeIssue(
                title: "GUI 与终端默认 pip 不同",
                currentState: "GUI 当前看到的是 \(activePipPath)，终端默认看到的是 \(loginPipPath)。",
                explanation: "这通常意味着 `pip` 命令与当前主 Python 的关系并不稳定，容易造成包装到了另一套环境。",
                recommendation: "优先参考 `python -m pip` 的结果，再判断是否要整理 PATH。",
                severity: .warning
            ))
        }

        if let activePipPath, let activePythonPath, !activePipPath.hasPrefix(URL(fileURLWithPath: activePythonPath).deletingLastPathComponent().path) {
            issues.append(RuntimeIssue(
                title: "`pip` 与当前 Python 可能不是同一套环境",
                currentState: "当前 GUI 看到的 `pip` 位于 \(activePipPath)，而当前 Python 位于 \(activePythonPath)。",
                explanation: "`pip` 命令可能被另一套 PATH 来源抢先解析，而 `python -m pip` 会跟随当前解释器。",
                recommendation: "排障时优先使用 `python -m pip`，避免把包装到错误的环境里。",
                severity: .warning
            ))
        }

        if activePythonModulePipVersion == nil, loginPythonModulePipVersion == nil {
            issues.append(RuntimeIssue(
                title: "`python -m pip` 当前不可用",
                currentState: "当前没有检测到可直接跟随 Python 解释器工作的 pip 模块。",
                explanation: "这通常意味着 pip 尚未就绪，或当前 Python 环境并没有启用 pip 模块。",
                recommendation: "先确认当前主 Python 是否自带 pip，再决定后续处理方式。",
                severity: .info
            ))
        }

        if (hasUv || hasPipx) && !loginPathEntries.contains(userLocalBinPath) {
            issues.append(RuntimeIssue(
                title: "Python 工具入口目录未进入 PATH",
                currentState: "检测到 uv 或 pipx，但登录 shell 的 PATH 没有包含 \(userLocalBinPath)。",
                explanation: "工具可能已安装，但命令入口不会被终端或 GUI 稳定发现。",
                recommendation: "把该目录补进你的登录 shell 配置，例如 `~/.zprofile`，或先执行 `pipx ensurepath` 生成对应补丁。",
                severity: .warning
            ))
        }

        if hasHomebrew && hasPyenvRuntime {
            issues.append(RuntimeIssue(
                title: "Homebrew Python 与 pyenv 并存",
                currentState: "当前同时发现 Homebrew Python 与 pyenv 管理的 Python。",
                explanation: "这不一定错误，但如果没有明确主来源，很容易造成 shell 与 GUI 的解释结果漂移。",
                recommendation: "先明确日常主来源，再决定其余来源只保留识别还是参与 PATH 竞争。",
                severity: .info
            ))
        }

        if hasCondaRuntime {
            issues.append(RuntimeIssue(
                title: "检测到 conda 运行时",
                currentState: "当前环境里发现了 conda 相关 Python 来源或 conda 命令。",
                explanation: "conda 往往会通过 shell 初始化和 base 激活影响默认 PATH，需要单独看待。",
                recommendation: "先把 conda 视为独立来源；若它不该成为默认 Python，请检查 base 自动激活与 shell 初始化片段。",
                severity: .info
            ))
        }

        if hasCondaRuntime, loginCondaDefaultEnv == "base" {
            issues.append(RuntimeIssue(
                title: "conda base 当前自动激活",
                currentState: "登录 shell 当前处于 conda 的 base 环境，这会直接影响默认 Python 与 PATH。",
                explanation: "当 base 在 shell 启动时自动激活，Homebrew、pyenv 或系统 Python 都可能被 conda 的解释器与工具入口覆盖。",
                recommendation: "如果你不希望 base 充当默认 Python，可考虑执行 `conda config --set auto_activate_base false`；需要恢复时可执行 `conda config --set auto_activate_base true`。",
                severity: .warning
            ))
        }

        return issues.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.title < $1.title
        }
    }

    private static func buildPythonReport(
        activePythonVersion: String?,
        activePythonPath: String?,
        activePythonSource: RuntimeSourceKind,
        loginPythonVersion: String?,
        packageManagers: [RuntimePackageManagerSnapshot],
        guiPathEntries: [String],
        loginPathEntries: [String],
        runtimes: [RuntimeInstallation],
        toolEntries: [RuntimeToolEntry],
        issues: [RuntimeIssue]
    ) -> String {
        var lines: [String] = []
        lines.append("# Cellar Runtime Report")
        lines.append("")
        lines.append("Generated: \(Date().formatted(date: .abbreviated, time: .standard))")
        lines.append("")
        lines.append("## Active Python")
        lines.append("- Version: \(activePythonVersion ?? "Not found")")
        lines.append("- Path: \(activePythonPath ?? "Not found")")
        lines.append("- Source: \(activePythonSource.rawValue)")
        lines.append("- Login shell version: \(loginPythonVersion ?? "Not found")")
        lines.append("")
        lines.append("## Runtime Tools")
        if packageManagers.isEmpty {
            lines.append("- No Python-adjacent tools discovered.")
        } else {
            for manager in packageManagers {
                lines.append("- \(manager.displayName) | GUI \(manager.guiVersion ?? "Not found") | Shell \(manager.loginShellVersion ?? "Not found") | GUI path \(manager.guiPath ?? "Not found") | Shell path \(manager.loginShellPath ?? "Not found")")
            }
        }
        lines.append("")
        lines.append("## PATH Snapshot")
        lines.append("### GUI PATH")
        for item in guiPathEntries { lines.append("- \(item)") }
        lines.append("")
        lines.append("### Login Shell PATH")
        for item in loginPathEntries { lines.append("- \(item)") }
        lines.append("")
        lines.append("## Installed Runtimes")
        for runtime in runtimes {
            lines.append("- \(runtime.version) | \(runtime.path) | \(runtime.source.rawValue) | \(runtime.isActive ? "Active" : "Inactive")")
        }
        lines.append("")
        lines.append("## Global Tool Entrypoints")
        if toolEntries.isEmpty {
            lines.append("- No obvious Python tool entrypoints found.")
        } else {
            for tool in toolEntries {
                lines.append("- \(tool.name) | source \(tool.sourceLabel) | shell \(tool.shellPath ?? "Not found") | GUI \(tool.guiPath ?? "Not found") | conflict \(tool.hasNameConflict ? "yes" : "no")")
            }
        }
        lines.append("")
        lines.append("## Issues")
        if issues.isEmpty {
            lines.append("- No obvious Python runtime conflicts found.")
        } else {
            for issue in issues {
                lines.append("- [\(issue.severity.title)] \(issue.title)")
                lines.append("  Current: \(issue.currentState)")
                lines.append("  Why: \(issue.explanation)")
                lines.append("  Recommendation: \(issue.recommendation)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private struct PythonToolMetadata: Sendable {
        let name: String
        let sourceLabel: String
        let ownerName: String?
        let version: String?
        let installLocation: String
        let prefix: String
        let shellPath: String?
        let guiPath: String?
        let managedByCurrentRuntime: Bool
        let isVisibleInShell: Bool
        let isVisibleInGUI: Bool
        let hasNameConflict: Bool
        let statusNote: String
    }

    private struct PipxToolRecord: Sendable {
        let appName: String
        let packageName: String
        let version: String?
        let installLocation: String
    }

    private struct UVToolRecord: Sendable {
        let appName: String
        let packageName: String
        let version: String?
        let installLocation: String
    }

    private static func discoverCandidateNodePaths(existing: [String]) async throws -> [String] {
        let globText = try await shell("""
        print -rl -- \
        /opt/homebrew/bin/node(N) \
        /usr/local/bin/node(N) \
        /usr/bin/node(N) \
        ~/.nvm/versions/node/*/bin/node(N) \
        ~/.fnm/node-versions/*/installation/bin/node(N) \
        ~/.volta/bin/node(N) \
        /Library/Frameworks/NodeJS.framework/Versions/Current/bin/node(N)
        """)
        return uniqueLines(existing.joined(separator: "\n") + "\n" + globText)
    }

    private static func discoverCandidatePythonPaths(existing: [String]) async throws -> [String] {
        let globText = try await shell("""
        print -rl -- \
        /opt/homebrew/bin/python3(N) \
        /usr/local/bin/python3(N) \
        /usr/bin/python3(N) \
        ~/.pyenv/shims/python3(N) \
        ~/.pyenv/versions/*/bin/python3(N) \
        ~/miniconda3/bin/python(N) \
        ~/anaconda3/bin/python(N) \
        ~/mambaforge/bin/python(N) \
        ~/micromamba/bin/python(N) \
        /Library/Frameworks/Python.framework/Versions/*/bin/python3(N)
        """)
        return uniqueLines(existing.joined(separator: "\n") + "\n" + globText)
    }

    private static func buildPythonToolEntries(
        guiPathEntries: [String],
        loginPathEntries: [String],
        activePythonPath: String?,
        loginPythonPath: String?,
        userLocalBinPath: String,
        packageManagers: [RuntimePackageManagerSnapshot]
    ) async throws -> [RuntimeToolEntry] {
        let pipxRecords = loadPipxToolRecords()
        let uvRecords = loadUVToolRecords()
        let homebrewTools = loadHomebrewPythonToolRecords(guiPathEntries: guiPathEntries, loginPathEntries: loginPathEntries)

        var metadataByName: [String: PythonToolMetadata] = [:]
        let preferredPythonDir = URL(fileURLWithPath: loginPythonPath ?? activePythonPath ?? "").deletingLastPathComponent().path

        func addRecord(
            name: String,
            sourceLabel: String,
            ownerName: String?,
            version: String?,
            installLocation: String,
            preferredPath: String?,
            managedByCurrentRuntime: Bool,
            statusNote: String
        ) {
            let shellPath = preferredPath ?? resolveExecutable(named: name, in: loginPathEntries)
            let guiPath = preferredPath ?? resolveExecutable(named: name, in: guiPathEntries)
            let visibleInShell = shellPath != nil
            let visibleInGUI = guiPath != nil
            let conflictPaths = Set([shellPath, guiPath].compactMap { $0 })
            let hasConflict = conflictPaths.count > 1
            metadataByName[name] = PythonToolMetadata(
                name: name,
                sourceLabel: sourceLabel,
                ownerName: ownerName,
                version: version,
                installLocation: installLocation,
                prefix: URL(fileURLWithPath: installLocation).deletingLastPathComponent().path,
                shellPath: shellPath,
                guiPath: guiPath,
                managedByCurrentRuntime: managedByCurrentRuntime,
                isVisibleInShell: visibleInShell,
                isVisibleInGUI: visibleInGUI,
                hasNameConflict: hasConflict,
                statusNote: statusNote
            )
        }

        for record in pipxRecords {
            let managed = preferredPythonDir.isEmpty ? false : record.installLocation.hasPrefix(preferredPythonDir)
            addRecord(
                name: record.appName,
                sourceLabel: "pipx",
                ownerName: record.packageName,
                version: record.version,
                installLocation: record.installLocation,
                preferredPath: resolveExecutable(named: record.appName, in: [userLocalBinPath]),
                managedByCurrentRuntime: managed,
                statusNote: managed ? "当前 Python 作用域可直接访问该工具" : "由 pipx 独立管理，建议优先看 PATH 可见性"
            )
        }

        for record in uvRecords where metadataByName[record.appName] == nil {
            let managed = preferredPythonDir.isEmpty ? false : record.installLocation.hasPrefix(preferredPythonDir)
            addRecord(
                name: record.appName,
                sourceLabel: "uv tool",
                ownerName: record.packageName,
                version: record.version,
                installLocation: record.installLocation,
                preferredPath: resolveExecutable(named: record.appName, in: [userLocalBinPath]),
                managedByCurrentRuntime: managed,
                statusNote: managed ? "当前 Python 作用域可直接访问该工具" : "由 uv tool 独立管理，建议优先看 PATH 可见性"
            )
        }

        for tool in homebrewTools where metadataByName[tool.name] == nil {
            metadataByName[tool.name] = tool
        }

        let localBinTools = loadLocalBinPythonTools(userLocalBinPath: userLocalBinPath, preferredPythonDir: preferredPythonDir)
        for tool in localBinTools where metadataByName[tool.name] == nil {
            metadataByName[tool.name] = tool
        }

        return metadataByName.values
            .map {
                RuntimeToolEntry(
                    name: $0.name,
                    currentVersion: $0.version ?? "-",
                    latestCheckState: .notChecked(source: "\($0.sourceLabel) metadata"),
                    binaries: [$0.name],
                    installLocation: $0.installLocation,
                    prefix: $0.prefix,
                    managedByCurrentRuntime: $0.managedByCurrentRuntime,
                    sourceLabel: $0.sourceLabel,
                    shellPath: $0.shellPath,
                    guiPath: $0.guiPath,
                    isVisibleInShell: $0.isVisibleInShell,
                    isVisibleInGUI: $0.isVisibleInGUI,
                    hasNameConflict: $0.hasNameConflict,
                    statusNote: $0.statusNote
                )
            }
            .sorted { lhs, rhs in
                if lhs.isVisibleInShell != rhs.isVisibleInShell { return lhs.isVisibleInShell }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private static func loadPipxToolRecords() -> [PipxToolRecord] {
        let metadataURL = URL(fileURLWithPath: NSString(string: "~/.local/share/pipx/metadata").expandingTildeInPath)
        let venvsURL = URL(fileURLWithPath: NSString(string: "~/.local/pipx/venvs").expandingTildeInPath)
        var result: [PipxToolRecord] = []

        if let files = try? FileManager.default.contentsOfDirectory(at: metadataURL, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let mainPackage = json["main_package"] as? [String: Any] else { continue }
                let packageName = (mainPackage["package_or_url"] as? String) ?? file.deletingPathExtension().lastPathComponent
                let version = mainPackage["package_version"] as? String
                let apps = ((mainPackage["apps"] as? [String]) ?? []) + ((mainPackage["apps_of_dependencies"] as? [String]) ?? [])
                for app in apps {
                    result.append(PipxToolRecord(
                        appName: app,
                        packageName: packageName,
                        version: version,
                        installLocation: venvsURL.appendingPathComponent(packageName).appendingPathComponent("bin").appendingPathComponent(app).path
                    ))
                }
            }
        }

        if result.isEmpty, let envs = try? FileManager.default.contentsOfDirectory(at: venvsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for env in envs {
                let binURL = env.appendingPathComponent("bin")
                guard let commands = try? FileManager.default.contentsOfDirectory(at: binURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
                for command in commands {
                    let name = command.lastPathComponent
                    guard isLikelyPythonToolCommand(name) else { continue }
                    result.append(PipxToolRecord(
                        appName: name,
                        packageName: env.lastPathComponent,
                        version: nil,
                        installLocation: command.path
                    ))
                }
            }
        }

        return dedupePipxRecords(result)
    }

    private static func loadUVToolRecords() -> [UVToolRecord] {
        let toolsURL = URL(fileURLWithPath: NSString(string: "~/.local/share/uv/tools").expandingTildeInPath)
        guard let envs = try? FileManager.default.contentsOfDirectory(at: toolsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var result: [UVToolRecord] = []
        for env in envs where env.lastPathComponent != ".lock" {
            let binURL = env.appendingPathComponent("bin")
            guard let commands = try? FileManager.default.contentsOfDirectory(at: binURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            let version = readPythonVersion(from: env.appendingPathComponent("pyvenv.cfg"))
            for command in commands {
                let name = command.lastPathComponent
                guard isLikelyPythonToolCommand(name) else { continue }
                result.append(UVToolRecord(
                    appName: name,
                    packageName: env.lastPathComponent,
                    version: version,
                    installLocation: command.path
                ))
            }
        }
        return dedupeUVRecords(result)
    }

    private static func loadHomebrewPythonToolRecords(
        guiPathEntries: [String],
        loginPathEntries: [String]
    ) -> [PythonToolMetadata] {
        let candidates = ["black", "ruff", "mypy", "poetry", "pipenv", "http", "httpie", "ipython", "jupyter", "jupyter-lab", "jupyter-notebook", "aider", "cookiecutter"]
        return candidates.compactMap { name in
            let shellPath = resolveExecutable(named: name, in: loginPathEntries)
            let guiPath = resolveExecutable(named: name, in: guiPathEntries)
            let path = shellPath ?? guiPath
            guard let path else { return nil }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard resolved.contains("/Cellar/") || path.contains("/opt/homebrew/") || path.contains("/usr/local/bin") else { return nil }
            return PythonToolMetadata(
                name: name,
                sourceLabel: "brew",
                ownerName: nil,
                version: nil,
                installLocation: path,
                prefix: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                shellPath: shellPath,
                guiPath: guiPath,
                managedByCurrentRuntime: path.contains("/opt/homebrew/") || resolved.contains("/Cellar/"),
                isVisibleInShell: shellPath != nil,
                isVisibleInGUI: guiPath != nil,
                hasNameConflict: Set([shellPath, guiPath].compactMap { $0 }).count > 1,
                statusNote: "由 Homebrew 提供，可与 pyenv / pipx / uv tool 并存"
            )
        }
    }

    private static func loadLocalBinPythonTools(userLocalBinPath: String, preferredPythonDir: String) -> [PythonToolMetadata] {
        let dirURL = URL(fileURLWithPath: userLocalBinPath)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.compactMap { entry in
            let name = entry.lastPathComponent
            guard isLikelyPythonToolCommand(name) else { return nil }
            let resolved = entry.resolvingSymlinksInPath().path
            let sourceLabel: String
            if resolved.contains("/pipx/venvs/") {
                sourceLabel = "pipx"
            } else if resolved.contains("/.local/share/uv/tools/") {
                sourceLabel = "uv tool"
            } else if resolved.contains("/Cellar/") || resolved.contains("/opt/homebrew/") {
                sourceLabel = "brew"
            } else {
                sourceLabel = "unknown"
            }
            let managed = !preferredPythonDir.isEmpty && resolved.hasPrefix(preferredPythonDir)
            return PythonToolMetadata(
                name: name,
                sourceLabel: sourceLabel,
                ownerName: nil,
                version: nil,
                installLocation: entry.path,
                prefix: userLocalBinPath,
                shellPath: entry.path,
                guiPath: entry.path,
                managedByCurrentRuntime: managed,
                isVisibleInShell: true,
                isVisibleInGUI: true,
                hasNameConflict: false,
                statusNote: managed ? "当前 Python 作用域可直接访问该工具" : "当前位于用户级 bin，是否属于主 Python 需结合来源判断"
            )
        }
    }

    private static func resolveExecutable(named name: String, in entries: [String]) -> String? {
        for entry in entries {
            let candidate = URL(fileURLWithPath: entry).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func readPythonVersion(from pyvenvURL: URL) -> String? {
        guard let text = try? String(contentsOf: pyvenvURL, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("version_info = ") {
                return "Python " + line.replacingOccurrences(of: "version_info = ", with: "")
            }
        }
        return nil
    }

    private static func dedupePipxRecords(_ records: [PipxToolRecord]) -> [PipxToolRecord] {
        var seen = Set<String>()
        return records.filter { seen.insert("\($0.packageName):\($0.appName)").inserted }
    }

    private static func dedupeUVRecords(_ records: [UVToolRecord]) -> [UVToolRecord] {
        var seen = Set<String>()
        return records.filter { seen.insert("\($0.packageName):\($0.appName)").inserted }
    }

    private static func isLikelyPythonToolCommand(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("python") || lower.hasPrefix("pip") || lower.hasPrefix("activate") || lower.hasPrefix("deactivate") || lower == "__pycache__" {
            return false
        }
        if lower.hasSuffix(".bat") || lower.hasSuffix(".ps1") || lower.hasSuffix(".fish") || lower.hasSuffix(".csh") || lower.hasSuffix(".nu") || lower.hasSuffix(".py") {
            return false
        }
        return !name.hasPrefix(".")
    }

    private static func executableVersion(path: String?, args: [String], compact: Bool = false) async throws -> String? {
        guard let path else { return nil }
        let value = try await versionForBinary(at: path, args: args)
        return compact ? compactVersionText(value) : value
    }

    private static func pythonModulePipVersion(pythonPath: String?) async throws -> String? {
        guard let pythonPath else { return nil }
        let out = try await ShellService.runSynchronous(executable: pythonPath, args: ["-m", "pip", "--version"])
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : compactVersionText(trimmed)
    }

    private static func pythonUserBase(pythonPath: String?) async throws -> String? {
        guard let pythonPath else { return nil }
        let out = try await ShellService.runSynchronous(executable: pythonPath, args: ["-m", "site", "--user-base"])
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func versionForBinary(at path: String, args: [String] = ["-v"]) async throws -> String {
        let out = try await ShellService.runSynchronous(executable: path, args: args)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func classifyNodeSource(path: String, resolvedPath: String) -> RuntimeSourceKind {
        let lower = resolvedPath.lowercased()
        if lower.contains("/.nvm/") { return .nvm }
        if lower.contains("/.fnm/") { return .fnm }
        if lower.contains("/.volta/") || path.contains("/.volta/") { return .volta }
        if lower.contains("/opt/homebrew/") || lower.contains("/cellar/node/") { return .homebrew }
        if lower.contains("nodejs.framework") { return .officialPkg }
        if lower.contains(".app/contents/") { return .embedded }
        if path == "/usr/bin/node" { return .system }
        if path == "/usr/local/bin/node" || lower.hasPrefix("/usr/local/") { return .legacyManual }
        return .unknown
    }

    nonisolated static func classifyPythonSource(path: String, resolvedPath: String) -> RuntimeSourceKind {
        let lower = resolvedPath.lowercased()
        if lower.contains("/.pyenv/") || path.contains("/.pyenv/") { return .pyenv }
        if lower.contains("miniconda") || lower.contains("anaconda") || lower.contains("mambaforge") || lower.contains("micromamba") || lower.contains("/conda/") {
            return .conda
        }
        if lower.contains("/opt/homebrew/") || lower.contains("/cellar/python") { return .homebrew }
        if lower.contains("/library/frameworks/python.framework") { return .officialPkg }
        if lower.contains(".app/contents/") { return .embedded }
        if path == "/usr/bin/python3" { return .system }
        if path == "/usr/local/bin/python3" || lower.hasPrefix("/usr/local/") { return .legacyManual }
        return .unknown
    }

    nonisolated private static func runtimeNote(kind: RuntimeKind, source: RuntimeSourceKind, resolvedPath: String) -> String {
        switch source {
        case .homebrew: return "适合纳入 Cellar 的后续治理范围"
        case .legacyManual: return "建议只识别并给出清理建议，不直接接管"
        case .nvm, .fnm, .volta: return "由 shell 级版本管理器接管，Cellar 负责解释和提示"
        case .pyenv: return "由 pyenv 接管，Cellar 负责解释 shell 与 GUI 是否看到同一套 Python"
        case .conda: return "conda 来源应单独识别，避免与 Homebrew 或 pyenv 混作一套环境"
        case .officialPkg: return "来源于官网安装包，通常会占据 /usr/local"
        case .embedded: return "应用私有运行时，默认不应参与系统级切换"
        case .system:
            return kind == .python ? "系统预装 Python 通常只作保底使用，不建议长期充当开发主环境" : "系统预装路径，通常不作为主运行时"
        case .unknown: return resolvedPath.contains("python") ? "来源未知，建议先确认这是哪一套 Python" : "来源未知，建议先确认路径和归属"
        }
    }

    nonisolated private static func runtimeNote(source: RuntimeSourceKind, resolvedPath: String) -> String {
        runtimeNote(kind: .node, source: source, resolvedPath: resolvedPath)
    }

    nonisolated private static func compactVersionText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: " from ") {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }

    nonisolated private static func uniqueLines(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    nonisolated static func splitPath(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ":")
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
