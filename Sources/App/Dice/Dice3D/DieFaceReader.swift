import SceneKit
import simd

/// Turns a settled die's physical orientation back into a game face.
/// The GAME RESULT rides on this, so it stays deliberately dumb: take the
/// die's six local axes in world space (straight off the presentation
/// transform — the physics-animated pose, not the model pose), dot each
/// with world-up, and the axis pointing most upward names the face.
enum DieFaceReader {
    /// The face currently pointing up. Valid any time, but only meaningful
    /// once the die has settled (a mid-tumble read returns whichever face
    /// happens to be up at that instant).
    static func upFace(of die: DieNode) -> LcrFace {
        axisFaceIndexUp(of: die).face
    }

    /// Index (into DieNode.axisFaces order: +X, −X, +Y, −Y, +Z, −Z) and
    /// face of the most-upward axis. Exposed for tests/diagnostics.
    static func axisFaceIndexUp(of die: DieNode) -> (index: Int, face: LcrFace) {
        let transform = die.presentation.simdWorldTransform
        // Columns 0/1/2 are the local X/Y/Z axes expressed in world space;
        // their .y components ARE the dot products with world-up (0,1,0).
        let x = transform.columns.0.y
        let y = transform.columns.1.y
        let z = transform.columns.2.y
        let ups: [Float] = [x, -x, y, -y, z, -z]
        var best = 0
        for index in 1..<6 where ups[index] > ups[best] { best = index }
        return (best, die.axisFaces[best])
    }

    /// How decisively the die is lying flat: 1.0 = a face is perfectly
    /// level, ~0.58 = balanced on a corner. Used to decide whether a
    /// timed-out die needs a settling nudge before its face is trusted.
    static func flatness(of die: DieNode) -> Float {
        let transform = die.presentation.simdWorldTransform
        let x = abs(transform.columns.0.y)
        let y = abs(transform.columns.1.y)
        let z = abs(transform.columns.2.y)
        return max(x, max(y, z))
    }
}
