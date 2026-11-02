import Foundation
import MLX
import MLXNN

/// Hyper-parameters read from the checkpoint's `config.json`.
public struct Yue2Config: Codable, Sendable {
    public struct Quantization: Codable, Sendable {
        public var groupSize: Int
        public var bits: Int
        public var narBits: Int?

        enum CodingKeys: String, CodingKey {
            case groupSize = "group_size", bits, narBits = "nar_bits"
        }
    }

    public var hiddenSize: Int
    public var numHiddenLayers: Int
    public var numAttentionHeads: Int
    public var numKeyValueHeads: Int
    public var headDim: Int
    public var intermediateSize: Int
    public var vocabSize: Int
    public var rmsNormEps: Float
    public var ropeTheta: Float
    public var latentDim: Int
    public var maxLatentFrames: Int
    public var timestepShift: Float
    public var quantization: Quantization?

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size", numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads", numKeyValueHeads = "num_key_value_heads"
        case headDim = "head_dim", intermediateSize = "intermediate_size", vocabSize = "vocab_size"
        case rmsNormEps = "rms_norm_eps", ropeTheta = "rope_theta", latentDim = "latent_dim"
        case maxLatentFrames = "max_latent_frames", timestepShift = "timestep_shift", quantization
    }
}

/// Append-only per-layer cache grown in 256-slot steps (mlx-lm pattern).
final class KVCache {
    static let step = 256
    private var keys: MLXArray?
    private var values: MLXArray?
    private(set) var offset = 0

    func update(_ k: MLXArray, _ v: MLXArray) -> (MLXArray, MLXArray) {
        let prev = offset
        let (B, H, T, D) = (k.dim(0), k.dim(1), k.dim(2), k.dim(3))
        if keys == nil || prev + T > keys!.dim(2) {
            let n = ((T + Self.step - 1) / Self.step) * Self.step
            let newK = MLXArray.zeros([B, H, n, D], dtype: k.dtype)
            let newV = MLXArray.zeros([B, H, n, D], dtype: v.dtype)
            if var keys, var values {
                if prev % Self.step != 0 {
                    keys = keys[.ellipsis, ..<prev, 0...]
                    values = values[.ellipsis, ..<prev, 0...]
                }
                self.keys = concatenated([keys, newK], axis: 2)
                self.values = concatenated([values, newV], axis: 2)
            } else {
                keys = newK
                values = newV
            }
        }
        offset += T
        keys![.ellipsis, prev ..< offset, 0...] = k
        values![.ellipsis, prev ..< offset, 0...] = v
        return (keys![.ellipsis, ..<offset, 0...], values![.ellipsis, ..<offset, 0...])
    }
}

final class Attention: Module {
    let nHeads: Int
    let nKV: Int
    let headDim: Int
    let ropeBase: Float
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    init(_ cfg: Yue2Config) {
        nHeads = cfg.numAttentionHeads
        nKV = cfg.numKeyValueHeads
        headDim = cfg.headDim
        ropeBase = cfg.ropeTheta
        scale = pow(Float(cfg.headDim), -0.5)
        let h = cfg.hiddenSize
        _qProj.wrappedValue = Linear(h, nHeads * headDim, bias: false)
        _kProj.wrappedValue = Linear(h, nKV * headDim, bias: false)
        _vProj.wrappedValue = Linear(h, nKV * headDim, bias: false)
        _oProj.wrappedValue = Linear(nHeads * headDim, h, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: cfg.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: cfg.rmsNormEps)
    }

    /// q [B,H,T,D], k/v [B,KV,T,D] after QK-norm and RoPE at `offset`.
    func projectQKV(_ x: MLXArray, offset: Int) -> (MLXArray, MLXArray, MLXArray) {
        let (B, T) = (x.dim(0), x.dim(1))
        let q = qNorm(qProj(x).reshaped(B, T, nHeads, -1)).transposed(0, 2, 1, 3)
        let k = kNorm(kProj(x).reshaped(B, T, nKV, -1)).transposed(0, 2, 1, 3)
        let v = vProj(x).reshaped(B, T, nKV, -1).transposed(0, 2, 1, 3)
        func rope(_ a: MLXArray) -> MLXArray {
            MLXFast.RoPE(a, dimensions: headDim, traditional: false, base: ropeBase, scale: 1, offset: offset)
        }
        return (rope(q), rope(k), v)
    }

    func attend(_ q: MLXArray, _ k: MLXArray, _ v: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode)
        -> MLXArray
    {
        let (B, T) = (q.dim(0), q.dim(2))
        let o = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: mask)
        return oProj(o.transposed(0, 2, 1, 3).reshaped(B, T, -1))
    }
}

final class MLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ cfg: Yue2Config) {
        _gateProj.wrappedValue = Linear(cfg.hiddenSize, cfg.intermediateSize, bias: false)
        _upProj.wrappedValue = Linear(cfg.hiddenSize, cfg.intermediateSize, bias: false)
        _downProj.wrappedValue = Linear(cfg.intermediateSize, cfg.hiddenSize, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(silu(gateProj(x)) * upProj(x))
    }
}

final class DecoderLayer: Module {
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: RMSNorm
    @ModuleInfo(key: "self_attn") var selfAttn: Attention
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayernorm: RMSNorm
    @ModuleInfo(key: "mlp") var mlp: MLP
    @ModuleInfo(key: "nar_input_layernorm") var narInputLayernorm: RMSNorm
    @ModuleInfo(key: "nar_self_attn") var narSelfAttn: Attention
    @ModuleInfo(key: "nar_pre_mlp_layernorm") var narPreMlpLayernorm: RMSNorm
    @ModuleInfo(key: "nar_mlp") var narMlp: MLP

    init(_ cfg: Yue2Config) {
        let (h, eps) = (cfg.hiddenSize, cfg.rmsNormEps)
        _inputLayernorm.wrappedValue = RMSNorm(dimensions: h, eps: eps)
        _selfAttn.wrappedValue = Attention(cfg)
        _postAttentionLayernorm.wrappedValue = RMSNorm(dimensions: h, eps: eps)
        _mlp.wrappedValue = MLP(cfg)
        _narInputLayernorm.wrappedValue = RMSNorm(dimensions: h, eps: eps)
        _narSelfAttn.wrappedValue = Attention(cfg)
        _narPreMlpLayernorm.wrappedValue = RMSNorm(dimensions: h, eps: eps)
        _narMlp.wrappedValue = MLP(cfg)
    }

    func ar(_ x: MLXArray, cache: KVCache, mask: MLXFast.ScaledDotProductAttentionMaskMode) -> MLXArray {
        let (q, k0, v0) = selfAttn.projectQKV(inputLayernorm(x), offset: cache.offset)
        let (k, v) = cache.update(k0, v0)
        let x = x + selfAttn.attend(q, k, v, mask: mask)
        return x + mlp(postAttentionLayernorm(x))
    }

    /// AR pass that also returns this layer's (k, v) for the NAR to attend over.
    func arPrefillKV(_ x: MLXArray) -> (MLXArray, (MLXArray, MLXArray)) {
        let (q, k, v) = selfAttn.projectQKV(inputLayernorm(x), offset: 0)
        let h = x + selfAttn.attend(q, k, v, mask: .causal)
        return (h + mlp(postAttentionLayernorm(h)), (k, v))
    }

    func nar(_ x: MLXArray, arK: MLXArray, arV: MLXArray, offset: Int) -> MLXArray {
        let (q, k0, v0) = narSelfAttn.projectQKV(narInputLayernorm(x), offset: offset)
        let k = concatenated([arK, k0], axis: 2)
        let v = concatenated([arV, v0], axis: 2)
        let h = x + narSelfAttn.attend(q, k, v, mask: .none)
        return h + narMlp(narPreMlpLayernorm(h))
    }
}

final class Backbone: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    let layers: [DecoderLayer]
    let norm: RMSNorm

    init(_ cfg: Yue2Config) {
        _embedTokens.wrappedValue = Embedding(embeddingCount: cfg.vocabSize, dimensions: cfg.hiddenSize)
        layers = (0 ..< cfg.numHiddenLayers).map { _ in DecoderLayer(cfg) }
        norm = RMSNorm(dimensions: cfg.hiddenSize, eps: cfg.rmsNormEps)
    }
}

final class TimestepEmbedder: Module {
    let freqSize: Int
    let fc1: Linear
    let fc2: Linear

    init(hidden: Int, freqSize: Int = 256) {
        self.freqSize = freqSize
        fc1 = Linear(freqSize, hidden)
        fc2 = Linear(hidden, hidden)
    }

    func callAsFunction(_ t: MLXArray, dtype: DType) -> MLXArray {
        let half = freqSize / 2
        let freqs = exp(-log(Float(10000)) * MLXArray(0 ..< half).asType(.float32) / Float(half))
        let args = t.asType(.float32).reshaped(-1, 1) * freqs[.newAxis]
        let emb = concatenated([cos(args), sin(args)], axis: -1).asType(dtype)
        return fc2(silu(fc1(emb)))
    }
}

final class LatentPosEmbed: Module {
    var pe: MLXArray

    init(maxFrames: Int, hidden: Int) {
        pe = MLXArray.zeros([maxFrames, hidden])
    }
}

public final class Yue2Model: Module {
    let config: Yue2Config
    @ModuleInfo(key: "model") var model: Backbone
    @ModuleInfo(key: "lm_head") var lmHead: Linear
    @ModuleInfo(key: "llm2vae") var llm2vae: Linear
    @ModuleInfo(key: "vae2llm") var vae2llm: Linear
    @ModuleInfo(key: "time_embedder") var timeEmbedder: TimestepEmbedder
    @ModuleInfo(key: "latent_pos_embed") var latentPosEmbed: LatentPosEmbed

    init(_ cfg: Yue2Config) {
        config = cfg
        _model.wrappedValue = Backbone(cfg)
        _lmHead.wrappedValue = Linear(cfg.hiddenSize, cfg.vocabSize, bias: false)
        _llm2vae.wrappedValue = Linear(cfg.hiddenSize, cfg.latentDim)
        _vae2llm.wrappedValue = Linear(cfg.latentDim, cfg.hiddenSize)
        _timeEmbedder.wrappedValue = TimestepEmbedder(hidden: cfg.hiddenSize)
        _latentPosEmbed.wrappedValue = LatentPosEmbed(maxFrames: cfg.maxLatentFrames, hidden: cfg.hiddenSize)
    }

    var layerCount: Int { model.layers.count }

    /// An output head restricted to `rows` of the vocabulary (logit i ↔ token rows.lowerBound + i).
    func head(rows: Range<Int>) -> Linear {
        if let q = lmHead as? QuantizedLinear {
            return QuantizedLinear(
                weight: q.weight[rows], bias: nil, scales: q.scales[rows], biases: q.biases?[rows],
                groupSize: q.groupSize, bits: q.bits, mode: q.mode)
        }
        return Linear(weight: lmHead.weight[rows], bias: nil)
    }

    /// tokens [B,T] → logits [B,V] of the last position.
    func arStep(_ tokens: MLXArray, caches: [KVCache], head: Linear? = nil) -> MLXArray {
        var x = model.embedTokens(tokens)
        let mask: MLXFast.ScaledDotProductAttentionMaskMode = tokens.dim(1) > 1 ? .causal : .none
        for (layer, cache) in zip(model.layers, caches) {
            x = layer.ar(x, cache: cache, mask: mask)
        }
        x = model.norm(x[0..., (-1)...])
        return (head ?? lmHead)(x)[0..., -1]
    }

    /// Runs the AR path once over a chunk prefix and returns per-layer (k, v).
    func narPrefill(_ tokens: [Int]) -> [(MLXArray, MLXArray)] {
        var x = model.embedTokens(MLXArray(tokens.map(Int32.init))[.newAxis])
        var cache: [(MLXArray, MLXArray)] = []
        for layer in model.layers {
            let (h, kv) = layer.arPrefillKV(x)
            x = h
            cache.append(kv)
            eval(kv.0, kv.1)
        }
        return cache
    }

    /// Flow-matching velocity for `state` [T,64] at logit-time `rawT`.
    func narVelocity(_ state: MLXArray, rawT: Float, arCache: [(MLXArray, MLXArray)], arLength: Int) -> MLXArray {
        let shift = config.timestepShift
        let sig = sigmoid(MLXArray(rawT).asType(state.dtype))
        let t = shift * sig / (1 + (shift - 1) * sig)
        let n = state.dim(0) + 2
        var x = vae2llm(padded(state, widths: [.init((1, 1)), .init((0, 0))])[.newAxis])
        x = x + timeEmbedder(t, dtype: state.dtype)[.newAxis]
        let pos = minimum(MLXArray(Int32(0) ..< Int32(n)), Int32(config.maxLatentFrames - 1))
        x = x + latentPosEmbed.pe[pos][.newAxis].asType(x.dtype)
        for (layer, kv) in zip(model.layers, arCache) {
            x = layer.nar(x, arK: kv.0, arV: kv.1, offset: arLength)
        }
        return llm2vae(model.norm(x))[0, 1 ..< (n - 1)]
    }

    /// Floating point type used for activations and unquantised weights.
    public private(set) var computeType: DType = .bfloat16

    static func load(directory: URL, computeType: DType = .bfloat16) throws -> Yue2Model {
        let cfg = try JSONDecoder().decode(
            Yue2Config.self, from: Data(contentsOf: directory.appending(path: "config.json")))
        let model = Yue2Model(cfg)
        let weights = try loadArrays(url: directory.appending(path: "model.safetensors"))
        if let q = cfg.quantization {
            quantize(model: model) { path, module in
                guard module is Linear, weights["\(path).scales"] != nil else { return nil }
                let bits = path.contains(".nar_") ? (q.narBits ?? q.bits) : q.bits
                return (q.groupSize, bits, .affine)
            }
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        if computeType != .bfloat16 {
            let converted = model.parameters().flattened().map { key, value in
                (key, value.dtype == .bfloat16 ? value.asType(computeType) : value)
            }
            try model.update(parameters: ModuleParameters.unflattened(converted), verify: [])
        }
        model.computeType = computeType
        eval(model)
        return model
    }
}
