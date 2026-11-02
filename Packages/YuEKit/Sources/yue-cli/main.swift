import Foundation
import YuEKit

/// Developer CLI for exercising the YuE2 port.
///   yue-cli tokenize <rank-file> <text>
///   yue-cli generate <model-dir> <style> <lyrics-file> <out.wav> [steps] [planning] [max-tokens] [seed]

func writeWAV(_ samples: [Float], to url: URL) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 2)
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + bytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(2))
    append(UInt32(sampleRate)); append(UInt32(sampleRate * 4)); append(UInt16(4)); append(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); append(bytes)
    for s in samples { append(Int16(max(-1, min(1, s)) * 32767)) }
    try data.write(to: url)
}

let args = CommandLine.arguments
switch args.dropFirst().first {
case "tokenize":
    let tok = try Tokenizer(rankFile: URL(fileURLWithPath: args[2]))
    print(tok.encode(args[3]))
case "parity":
    let pipeline = try Yue2Pipeline(directory: URL(fileURLWithPath: args[2]))
    for (k, v) in pipeline.parityProbe(text: args[3]).sorted(by: { $0.key < $1.key }) { print(k, v.map { String(format: "%.4f", $0) }.joined(separator: " ")) }
case "bench":
    let pipeline = try Yue2Pipeline(directory: URL(fileURLWithPath: args[2]))
    print(pipeline.benchmark())
case "generate":
    let start = Date()
    let pipeline = try Yue2Pipeline(directory: URL(fileURLWithPath: args[2]))
    FileHandle.standardError.write("loaded in \(Int(Date().timeIntervalSince(start)))s\n".data(using: .utf8)!)
    let lyrics = try String(contentsOfFile: args[4], encoding: .utf8)
    let request = SongRequest(
        style: args[3], lyrics: lyrics,
        planning: args.count > 7 ? ScorePlanning(rawValue: args[7]) ?? .full : .full,
        seed: args.count > 9 ? UInt64(args[9]) ?? 831001 : 831001,
        steps: args.count > 6 ? Int(args[6]) ?? 32 : 32,
        maxSemanticTokens: args.count > 8 ? Int(args[8]) : nil,
        voice: ProcessInfo.processInfo.environment["YUE_VOICE_IN"].flatMap { try? JSONDecoder().decode(VoiceReference.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) })
    var lastStage = ""
    var stageStart = Date()
    let t0 = Date()
    let song = try pipeline.generate(request, progress: { p in
        if p.stage.rawValue != lastStage {
            if !lastStage.isEmpty {
                FileHandle.standardError.write("\n[\(lastStage)] \(String(format: "%.1f", Date().timeIntervalSince(stageStart)))s\n".data(using: .utf8)!)
            }
            lastStage = p.stage.rawValue
            stageStart = Date()
        }
        FileHandle.standardError.write(String(format: "\r%@ %.0f%% overall %.0f%% est %.0fs", p.stage.rawValue, p.stageFraction * 100, p.overall * 100, p.estimatedSongSeconds ?? 0).data(using: .utf8)!)
    }, isCancelled: { false })
    FileHandle.standardError.write("\n[\(lastStage)] \(String(format: "%.1f", Date().timeIntervalSince(stageStart)))s\n".data(using: .utf8)!)
    try writeWAV(song.samples, to: URL(fileURLWithPath: args[5]))
    if let abc = song.abc { try abc.write(toFile: args[5] + ".abc", atomically: true, encoding: .utf8) }
    if let out = ProcessInfo.processInfo.environment["YUE_VOICE_OUT"], let voice = song.voice {
        try JSONEncoder().encode(voice).write(to: URL(fileURLWithPath: out))
    }
    print("done: \(String(format: "%.1f", song.duration))s audio in \(Int(Date().timeIntervalSince(t0)))s, truncated=\(song.truncated)")
default:
    print("usage: yue-cli tokenize|generate ...")
}
