import Foundation
#if !targetEnvironment(macCatalyst)
import MetricKit
#endif

/// Keeps the log of a run that stopped until it has been sent (GTA-159). The app keeps only the last two runs, and a
/// player who restarts twice after a stop (load the save, try again) pushes the stop out of the log they send
/// (log ycwycf). A run counts as stopped when the game stopped with a message ("Native trap", "... stopped:"), or when
/// the app ended while the game was running in the foreground: iOS closed it (most often for memory) or it crashed
/// without a message. Leaving the app first (home, app switcher) is not a stop.
enum RunEnd {
    static let stoppedName = "native-port-stopped.log"
    static let diagnosticsName = "ios-diagnostics.log"
    private static var defaults: UserDefaults { .standard }
    private static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Whether the game runs in the foreground right now (it started, and the app is active).
    static func playing(_ on: Bool) { defaults.set(on, forKey: "runEndPlaying") }

    /// At launch, before the logs rotate: if the last run (`log`) stopped, copies it to native-port-stopped.log and
    /// returns why. `becomesPrevious`: the rotation will keep it as native-port-previous.log too, so a log sent now
    /// needn't carry it twice.
    static func keepIfStopped(log: URL, becomesPrevious: Bool) -> String? {
        let wasPlaying = defaults.bool(forKey: "runEndPlaying")
        defaults.set(false, forKey: "runEndPlaying")
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let message = tail.contains("Native trap") || tail.contains("Native boot stopped:") || tail.contains("Native game thread stopped:")
        guard message || wasPlaying else {
            // A newer played run replaces the previous log: a stop kept earlier is no longer in it.
            if becomesPrevious { defaults.set(false, forKey: "runEndStoppedIsPrevious") }
            return nil
        }
        let stopped = documents.appendingPathComponent(stoppedName)
        try? FileManager.default.removeItem(at: stopped)
        try? FileManager.default.copyItem(at: log, to: stopped)
        defaults.set(becomesPrevious, forKey: "runEndStoppedIsPrevious")
        return message ? "the game stopped" : "the app ended while the game was running (iOS closed it, most often for memory, or it crashed)"
    }

    /// The logs a report carries, oldest first, each with its section title. The stopped run comes first and only
    /// when it isn't the previous run already; the current run stays last (log-sweep reads the last section as the
    /// run the player sent the log from).
    static func reportLogs() -> [(title: String, url: URL)] {
        var logs: [(String, URL)] = []
        let diagnostics = documents.appendingPathComponent(diagnosticsName)
        if FileManager.default.fileExists(atPath: diagnostics.path) { logs.append(("IOS DIAGNOSTICS", diagnostics)) }
        let stopped = documents.appendingPathComponent(stoppedName)
        if FileManager.default.fileExists(atPath: stopped.path), !defaults.bool(forKey: "runEndStoppedIsPrevious") {
            logs.append(("LAST STOPPED RUN", stopped))
        }
        logs.append(("PREVIOUS RUN", documents.appendingPathComponent("native-port-previous.log")))
        logs.append(("THIS RUN", documents.appendingPathComponent("native-port.log")))
        return logs.filter { FileManager.default.fileExists(atPath: $0.1.path) }
    }

    /// Test: PG_TEST_CRASH=1 (an environment variable, e.g. devicectl's --environment-variables) crashes the app 10 s
    /// into the world, for the stopped-run log and iOS's crash report at the next launch; PG_TEST_CRASH=launch 5 s after
    /// the app opens, without the game (iOS's report only).
    static func testCrashIfAsked(atLaunch: Bool = false) {
        guard ProcessInfo.processInfo.environment["PG_TEST_CRASH"] == (atLaunch ? "launch" : "1") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (atLaunch ? 5 : 10)) { abort() }
    }

    /// After a log reached the developer: the stop and the iOS reports in it needn't go again.
    static func sent() {
        try? FileManager.default.removeItem(at: documents.appendingPathComponent(stoppedName))
        try? FileManager.default.removeItem(at: documents.appendingPathComponent(diagnosticsName))
    }

    /// Appends lines to ios-diagnostics.log (kept to its last 64 KB), which reports carry until sent.
    fileprivate static func keep(_ lines: [String]) {
        let url = documents.appendingPathComponent(diagnosticsName)
        var data = (try? Data(contentsOf: url)) ?? Data()
        data.append((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
        if data.count > 65_536 { data = data.suffix(65_536) }
        try? data.write(to: url, options: .atomic)
    }
}

#if !targetEnvironment(macCatalyst)
/// What iOS itself recorded about how the app ended (MetricKit, GTA-159): crashes with the signal and the stack, hangs,
/// and per day how many exits were normal, memory limit kills, crashes or watchdog kills. iOS hands crash reports over
/// at the next launch and the exit counts about once a day. Each report goes into the log and ios-diagnostics.log.
final class IOSDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = IOSDiagnostics()
    var log: (String) -> Void = { _ in }

    func start() {
        MXMetricManager.shared.add(self)
        log("iOS diagnostics: listening (\(MXMetricManager.shared.pastDiagnosticPayloads.count) crash reports and \(MXMetricManager.shared.pastPayloads.count) daily reports from before).")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let f = exits.foregroundExitData, b = exits.backgroundExitData
            let line = "iOS diagnostics: exits \(Self.day(payload.timeStampBegin))-\(Self.day(payload.timeStampEnd)), app \(payload.latestApplicationVersion): "
                + "while playing \(f.cumulativeNormalAppExitCount) normal, \(f.cumulativeMemoryResourceLimitExitCount) memory limit, "
                + "\(f.cumulativeBadAccessExitCount) bad access, \(f.cumulativeIllegalInstructionExitCount) illegal instruction, "
                + "\(f.cumulativeAbnormalExitCount) other crash, \(f.cumulativeAppWatchdogExitCount) watchdog; "
                + "in the background \(b.cumulativeNormalAppExitCount) normal, \(b.cumulativeMemoryResourceLimitExitCount) memory limit, "
                + "\(b.cumulativeMemoryPressureExitCount) memory pressure, \(b.cumulativeBadAccessExitCount + b.cumulativeIllegalInstructionExitCount + b.cumulativeAbnormalExitCount) crash, "
                + "\(b.cumulativeAppWatchdogExitCount) watchdog."
            report([line])
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            var lines: [String] = []
            for crash in payload.crashDiagnostics ?? [] {
                let meta = crash.metaData
                lines.append("iOS diagnostics: crash on \(Self.time(payload.timeStampEnd)), app \(meta.applicationBuildVersion), \(meta.osVersion), \(meta.deviceType): "
                    + "exception \(crash.exceptionType.map { "\($0)" } ?? "?") code \(crash.exceptionCode.map { "\($0)" } ?? "?"), signal \(crash.signal.map { "\($0)" } ?? "?")"
                    + (crash.terminationReason.map { ", \($0)" } ?? "") + (crash.virtualMemoryRegionInfo.map { ", memory: \($0)" } ?? ""))
                lines.append("iOS diagnostics: crash stack " + Self.frames(crash.callStackTree.jsonRepresentation()))
            }
            for hang in payload.hangDiagnostics ?? [] {
                lines.append("iOS diagnostics: hang of \(hang.hangDuration) on \(Self.time(payload.timeStampEnd)): " + Self.frames(hang.callStackTree.jsonRepresentation()))
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                lines.append("iOS diagnostics: CPU limit on \(Self.time(payload.timeStampEnd)), \(cpu.totalCPUTime) over \(cpu.totalSampledTime)")
            }
            if !lines.isEmpty { report(lines) }
        }
    }

    private func report(_ lines: [String]) {
        DispatchQueue.main.async { lines.forEach(self.log) }
        RunEnd.keep(lines)
    }

    /// The crashed (or first) thread's frames, innermost first: binary + offset, which the developer symbolicates.
    private static func frames(_ json: Data) -> String {
        guard let tree = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]] else { return "(unreadable)" }
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        var out: [String] = []
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        while let f = frame, out.count < 24 {
            out.append("\(f["binaryName"] as? String ?? "?")+\(f["offsetIntoBinaryTextSegment"] as? Int ?? 0)")
            frame = (f["subFrames"] as? [[String: Any]])?.first
        }
        return out.joined(separator: " < ")
    }
    private static func day(_ date: Date) -> String { date.formatted(.iso8601.year().month().day()) }
    private static func time(_ date: Date) -> String { date.formatted(.iso8601) }
}
#endif
