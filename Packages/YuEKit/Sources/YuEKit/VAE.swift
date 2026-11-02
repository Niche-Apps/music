import Foundation
import MLX
import MLXNN

/// Samples per latent frame at 48 kHz.
public let samplesPerFrame = 1920

final class Snake: Module, UnaryLayer {
    var alpha: MLXArray
    var beta: MLXArray

    init(_ channels: Int) {
        alpha = MLXArray.zeros([channels])
        beta = MLXArray.zeros([channels])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let a = exp(alpha)
        let b = exp(beta)
        return x + (1.0 / (b + 1e-9)) * pow(sin(x * a), 2)
    }
}

final class ResidualUnit: Module, UnaryLayer {
    let layers: [UnaryLayer]

    init(_ channels: Int, dilation: Int) {
        layers = [
            Snake(channels),
            Conv1d(
                inputChannels: channels, outputChannels: channels, kernelSize: 7, padding: 3 * dilation,
                dilation: dilation),
            Snake(channels),
            Conv1d(inputChannels: channels, outputChannels: channels, kernelSize: 1),
        ]
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var y = x
        for layer in layers { y = layer(y) }
        return x + y
    }
}

final class DecoderBlock: Module, UnaryLayer {
    let layers: [UnaryLayer]

    init(_ cin: Int, _ cout: Int, stride: Int) {
        layers = [
            Snake(cin),
            ConvTransposed1d(
                inputChannels: cin, outputChannels: cout, kernelSize: 2 * stride, stride: stride,
                padding: (stride + 1) / 2),
            ResidualUnit(cout, dilation: 1),
            ResidualUnit(cout, dilation: 3),
            ResidualUnit(cout, dilation: 9),
        ]
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = x
        for layer in layers { x = layer(x) }
        return x
    }
}

struct VAEConfig: Codable {
    struct Decoder: Codable {
        var channels: Int
        var cMults: [Int]
        var strides: [Int]
        var latentDim: Int
        var outChannels: Int

        enum CodingKeys: String, CodingKey {
            case channels, cMults = "c_mults", strides, latentDim = "latent_dim", outChannels = "out_channels"
        }
    }

    var decoderConfig: Decoder

    enum CodingKeys: String, CodingKey { case decoderConfig = "decoder_config" }
}

/// YuE2 Oobleck VAE decoder (channels-last; weight norm already folded).
public final class OobleckDecoder: Module, UnaryLayer {
    let layers: [UnaryLayer]

    init(_ cfg: VAEConfig.Decoder) {
        let c = cfg.channels
        let mults = [1] + cfg.cMults
        var layers: [UnaryLayer] = [
            Conv1d(inputChannels: cfg.latentDim, outputChannels: mults.last! * c, kernelSize: 7, padding: 3)
        ]
        for i in stride(from: mults.count - 1, to: 0, by: -1) {
            layers.append(DecoderBlock(mults[i] * c, mults[i - 1] * c, stride: cfg.strides[i - 1]))
        }
        layers.append(Snake(mults[0] * c))
        layers.append(
            Conv1d(inputChannels: mults[0] * c, outputChannels: cfg.outChannels, kernelSize: 7, padding: 3, bias: false))
        self.layers = layers
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = x
        for layer in layers { x = layer(x) }
        return x
    }

    /// z [T,64] float32 → audio [1920*T-64, 2] float32 via exact tile cores (no crossfade). Unclipped.
    /// `onTile` receives (completed, total) after each tile.
    func decodeTiled(_ z: MLXArray, core: Int = 256, halo: Int = 16, onTile: ((Int, Int) -> Void)? = nil)
        -> MLXArray
    {
        let frames = z.dim(0)
        let total = samplesPerFrame * frames - 64
        var out: [MLXArray] = []
        let tiles = (frames + core - 1) / core
        for (index, start) in stride(from: 0, to: frames, by: core).enumerated() {
            let end = min(frames, start + core)
            let left = max(0, start - halo)
            let right = min(frames, end + halo)
            let tile = self(z[left ..< right][.newAxis])[0]
            let crop = (start - left) * samplesPerFrame
            let length = min(end * samplesPerFrame, total) - start * samplesPerFrame
            let piece = tile[crop ..< (crop + length)]
            eval(piece)
            out.append(piece)
            GPU.clearCache()
            onTile?(index + 1, tiles)
        }
        return concatenated(out)
    }

    static func load(directory: URL) throws -> OobleckDecoder {
        let cfg = try JSONDecoder().decode(
            VAEConfig.self, from: Data(contentsOf: directory.appending(path: "vae_config.json")))
        let decoder = OobleckDecoder(cfg.decoderConfig)
        let weights = try loadArrays(url: directory.appending(path: "vae.safetensors"))
        try decoder.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(decoder)
        return decoder
    }
}
