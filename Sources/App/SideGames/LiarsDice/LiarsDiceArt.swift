import SwiftUI

/// A flat, photoreal pip die for Liar's Dice's 2D moments (the phone's
/// peek, the table's reveal). It wears the SAME face art the 3D dice do —
/// `DieFaceTextures.standard`, ivory stock, black inked pips, the lone red
/// center pip on the 1 — clipped to a rounded die silhouette and given a
/// bevel, a top-left sheen, and a contact shadow so it reads as a die
/// sitting on felt rather than a flat sticker.
struct LiarsPipDie: View {
    let value: Int
    var size: CGFloat = 40
    /// Counted-face glow (the call's count beat).
    var glow: Bool = false
    /// Not part of the count: dimmed once the counting starts.
    var dimmed: Bool = false

    var body: some View {
        let corner = size * 0.2
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            shape.fill(Color(red: 0.93, green: 0.91, blue: 0.85))
            Image(uiImage: DieFaceTextures.standard(max(1, min(6, value))))
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .clipShape(shape)
            // Rounded-edge bevel: bright on the lit corner, dark on the far one.
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.05), .black.opacity(0.38)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: max(1, size * 0.05))
            // Soft sheen from the lamp.
            shape.fill(LinearGradient(colors: [.white.opacity(0.20), .clear],
                                      startPoint: .topLeading, endPoint: UnitPoint(x: 0.65, y: 0.65)))
                .allowsHitTesting(false)
            if glow {
                shape.strokeBorder(CardStyle.gold, lineWidth: max(2, size * 0.09))
            }
        }
        .frame(width: size, height: size)
        .saturation(dimmed ? 0.5 : 1)
        .brightness(dimmed ? -0.22 : 0)
        .shadow(color: .black.opacity(0.5), radius: size * 0.08, x: size * 0.03, y: size * 0.07)
        .shadow(color: glow ? CardStyle.gold.opacity(0.95) : .clear, radius: glow ? size * 0.35 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Die showing \(value)")
    }
}

/// The photoreal leather cup (the `TableCup` asset, brass rim, red felt
/// interior) in two poses: upright (`flip` 0 — the shaking pose, mouth up)
/// and face-down over the dice (`flip` 1 — rotated 180 degrees with a
/// stitched leather base cap drawn over the cut-off bottom, so it reads as
/// an upside-down cup standing on the felt). `flip` between the two is the
/// settle: the cup turns over onto the dice.
///
/// The asset bakes in a rightward lean; `TableCupView` counter-rotates it
/// by `assetTilt`, and so do we, so the cup stands straight.
struct LiarsDiceCupArt: View {
    var width: CGFloat
    /// 0 = upright (mouth up), 1 = face-down over the dice.
    var flip: Double = 1
    /// Extra tilt (the shake wobble / the peek lift lean).
    var wobble: Angle = .zero
    /// Soft contact shadow under the cup.
    var grounded: Bool = true

    static let assetTilt: Angle = .degrees(-13.5)
    private var height: CGFloat { width * (968.0 / 879.0) }

    var body: some View {
        ZStack {
            if grounded {
                Ellipse()
                    .fill(RadialGradient(colors: [.black.opacity(0.55), .black.opacity(0.2), .clear],
                                         center: .center, startRadius: 0, endRadius: width * 0.62))
                    .frame(width: width * 1.05, height: height * 0.42)
                    .offset(y: height * (flip > 0.5 ? 0.38 : 0.40))
                    .blur(radius: 3)
            }
            ZStack {
                Image("TableCup")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
                    .rotationEffect(Self.assetTilt)
                    .shadow(color: .black.opacity(0.5), radius: width * 0.07, y: width * 0.05)
                // Base cap: only visible once the cup is over.
                baseCap
                    .opacity(pow(flip, 3))
            }
            .rotationEffect(.degrees(180 * flip) + wobble)
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    /// A leather disc with a stitched ring — what you would see looking at
    /// the closed bottom of the cup. Drawn in the UNflipped frame, near the
    /// image's cut-off bottom, so the 180 degree rotation lands it on top.
    private var baseCap: some View {
        let w = width * 0.78
        return ZStack {
            Ellipse()
                .fill(RadialGradient(
                    colors: [Color(red: 0.60, green: 0.34, blue: 0.18),
                             Color(red: 0.43, green: 0.22, blue: 0.11),
                             Color(red: 0.25, green: 0.12, blue: 0.07)],
                    center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: w * 0.62))
            Ellipse()
                .strokeBorder(Color(red: 0.86, green: 0.70, blue: 0.46).opacity(0.8),
                              style: StrokeStyle(lineWidth: 1.6, dash: [4, 3.5]))
                .padding(w * 0.07)
            Ellipse()
                .strokeBorder(.black.opacity(0.4), lineWidth: 1.5)
            // Lamp catch-light on the leather.
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.22), .clear],
                                     startPoint: .topLeading, endPoint: .center))
                .padding(w * 0.12)
        }
        .frame(width: w, height: w * 0.50)
        .rotationEffect(Self.assetTilt)
        .offset(x: -width * 0.02, y: height * 0.405)
    }
}

/// The classic ledger/brass look shared by the phone's stepper.
struct LiarsBrassButton: View {
    let systemName: String
    var enabled: Bool = true
    var diameter: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(
                    RadialGradient(colors: [Color(red: 0.99, green: 0.92, blue: 0.72),
                                            CardStyle.gold,
                                            Color(red: 0.52, green: 0.39, blue: 0.19)],
                                   center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0,
                                   endRadius: diameter * 0.75))
                Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1)
                Image(systemName: systemName)
                    .font(.system(size: diameter * 0.40, weight: .black))
                    .foregroundStyle(CardStyle.ink.opacity(0.9))
                    .shadow(color: .white.opacity(0.35), radius: 0, y: 0.7)
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
            .opacity(enabled ? 1 : 0.32)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
