import EngineProtocol
import Foundation
import Testing
@testable import StandardKit

/// Drives EngineClient against a stand-in engine written in Python, the way a listener's own
/// engine would be: launched from Settings, spoken to over JSON lines.
@Suite(.serialized) struct CustomEngineTests {
    static let fakeEngine = #"""
        #!/usr/bin/python3
        import json, sys
        def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
        for line in sys.stdin:
            c = json.loads(line)
            if "load" in c:
                if c["load"]["modelPath"].endswith("broken"):
                    print("Traceback: weights not found", file=sys.stderr, flush=True)
                    sys.exit(3)
                send({"ready": {"loadSeconds": 0.25}})
            elif "generate" in c:
                job = c["generate"]["_0"]
                send({"progress": {"id": job["id"], "_1": {"stage": "rendering", "stageFraction": 0.5, "overall": 0.5, "elapsed": 1}}})
                open(job["outputPath"], "w").write(job["title"] + "|" + job["artist"] + "|" + str(job["maxSeconds"]))
                send({"finished": {"_0": {"id": job["id"], "duration": 12.5, "loudness": -14, "seconds": 1, "truncated": False}}})
            elif "shutdown" in c:
                sys.exit(0)
        """#

    func makeEngine() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "engine-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appending(path: "engine.py")
        try Self.fakeEngine.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, dir)
    }

    @Test func probesAndRecordsWithACustomEngine() async throws {
        let (script, dir) = try makeEngine()
        let client = EngineClient(executableURL: URL(fileURLWithPath: "/nonexistent"))
        await client.configure(executable: script)
        let loadSeconds = try await client.probe(modelDirectory: dir)
        #expect(loadSeconds == 0.25)

        let output = dir.appending(path: "song.m4a")
        let job = EngineJob(
            id: "job1", style: "indie rock", lyrics: "[Verse]\nla", planning: "full", seed: 7, steps: 16,
            maxSemanticTokens: nil, outputPath: output.path, title: "Turn It Up", artist: "The Halts", voice: "alto",
            isInstrumental: false, maxSeconds: 240)
        let progress = ProgressBox()
        let result = try await client.render(job, modelDirectory: dir) { progress.record($0.overall) }
        #expect(result.duration == 12.5)
        #expect(try String(contentsOf: output, encoding: .utf8) == "Turn It Up|The Halts|240")
        #expect(progress.values == [0.5])
        await client.shutdown()
    }

    @Test func reportsTheEnginesLastErrorLineWhenItCrashes() async throws {
        let (script, dir) = try makeEngine()
        let client = EngineClient(executableURL: script)
        do {
            _ = try await client.probe(modelDirectory: dir.appending(path: "broken"))
            Issue.record("probe should fail")
        } catch {
            #expect(error.localizedDescription.contains("Traceback: weights not found"))
        }
    }

    @Test func missingProgramIsReportedClearly() async throws {
        let client = EngineClient(executableURL: URL(fileURLWithPath: "/nope/engine"))
        await #expect(throws: EngineError.self) { try await client.probe(modelDirectory: URL(fileURLWithPath: "/tmp")) }
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func record(_ v: Double) { lock.withLock { stored.append(v) } }
    var values: [Double] { lock.withLock { stored } }
}
