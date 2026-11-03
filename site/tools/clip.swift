// Cuts a preview clip from a recording and measures its waveform.
//   clip <in.m4a> <out.m4a> <startSeconds> <lengthSeconds>  → prints JSON peaks (120 values, 0...1)
import AVFoundation

let a = CommandLine.arguments
let input = URL(fileURLWithPath: a[1]), output = URL(fileURLWithPath: a[2])
let start = Double(a[3])!, length = Double(a[4])!
let asset = AVURLAsset(url: input)
let duration = try await asset.load(.duration).seconds
let s = min(start, max(0, duration - length))
let range = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600), duration: CMTime(seconds: min(length, duration), preferredTimescale: 600))

try? FileManager.default.removeItem(at: output)
guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { fatalError("no export") }
export.timeRange = range
// Fade in and out so clips don't start or stop abruptly.
let track = try await asset.loadTracks(withMediaType: .audio)[0]
let params = AVMutableAudioMixInputParameters(track: track)
params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: range.start, duration: CMTime(seconds: 1.5, preferredTimescale: 600)))
params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: range.end - CMTime(seconds: 3, preferredTimescale: 600), duration: CMTime(seconds: 3, preferredTimescale: 600)))
let mix = AVMutableAudioMix(); mix.inputParameters = [params]
export.audioMix = mix
try await export.export(to: output, as: .m4a)

// Peaks of the clip.
let reader = try AVAssetReader(asset: asset)
reader.timeRange = range
let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 11025,
])
reader.add(out); reader.startReading()
var samples: [Int16] = []
while let buf = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buf) {
    var len = 0; var ptr: UnsafeMutablePointer<Int8>?
    CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
    ptr!.withMemoryRebound(to: Int16.self, capacity: len / 2) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: len / 2)) }
}
let bins = 120, per = max(1, samples.count / bins)
var peaks: [Double] = (0..<bins).map { i in
    let slice = samples[min(i * per, samples.count) ..< min((i + 1) * per, samples.count)]
    let rms = sqrt(slice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(slice.count, 1)))
    return rms / 32768
}
let top = peaks.max() ?? 1
peaks = peaks.map { (($0 / max(top, 0.0001)) * 1000).rounded() / 1000 }
print("[" + peaks.map { String($0) }.joined(separator: ",") + "]")
