import Foundation
import NaturalLanguage

public protocol EmbeddingProvider: Sendable {
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// Embeddings locaux avec le framework NaturalLanguage d'Apple : gratuits, hors
/// ligne, rien ne quitte le Mac. Modèle contextuel multilingue (macOS 14) si ses
/// ressources sont disponibles, sinon embedding de phrase français.
///
/// Leur qualité est modeste ; ils servent seulement à présélectionner des fiches
/// candidates à la fusion, que le modèle de langue confirme ensuite.
public final class NaturalLanguageEmbedder: EmbeddingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var contextual: NLContextualEmbedding?
    private var contextualTried = false

    public init() {}

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        await prepareContextual()
        return texts.map { vector(for: $0) }
    }

    private func prepareContextual() async {
        let shouldTry: Bool = lock.withLock {
            defer { contextualTried = true }
            return !contextualTried
        }
        guard shouldTry, let model = NLContextualEmbedding(language: .french) else { return }
        if !model.hasAvailableAssets {
            _ = try? await model.requestAssets()
        }
        guard model.hasAvailableAssets, (try? model.load()) != nil else { return }
        lock.withLock { contextual = model }
    }

    func vector(for text: String) -> [Float] {
        let model = lock.withLock { contextual }
        if let model, let result = try? model.embeddingResult(for: text, language: .french) {
            var sum = [Double](repeating: 0, count: model.dimension)
            var n = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
                for i in 0..<min(vec.count, sum.count) { sum[i] += vec[i] }
                n += 1
                return true
            }
            if n > 0 { return Self.normalize(sum.map { Float($0 / Double(n)) }) }
        }
        if let sentence = NLEmbedding.sentenceEmbedding(for: .french), let v = sentence.vector(for: text) {
            return Self.normalize(v.map(Float.init))
        }
        return Self.hashed(text)
    }

    static func normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    /// Dernier recours : sac de mots haché (reste déterministe et local).
    static func hashed(_ text: String, dimension: Int = 256) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 2 }
        for w in words {
            var h: UInt64 = 1469598103934665603
            for b in w.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            v[Int(h % UInt64(dimension))] += 1
        }
        return normalize(v)
    }
}

public enum VectorMath {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    public static func encode(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    public static func decode(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
