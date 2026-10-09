import SwiftUI

/// Bidding on the phone: private, tactile, one decision presented honestly.
/// A horizontal wheel of big numbers; the coach whispers underneath.
///
/// Spades additions: 0 on the wheel IS nil (labelled so), and with
/// `rules.spadesBlindNil` on the hand starts face-down behind a "Blind Nil
/// / Peek" choice: declaring blind nil never shows the cards; peeking
/// flips them and forfeits the blind bet for this round. Partnership
/// tables show the partner's bid as soon as it lands ("Team bid 7");
/// cutthroat tables show no partner line at all.
struct BidEntryView: View {
    @Bindable var client: GameClientController
    @Environment(\.accessibilityReduceMotion) private var motionReduced
    @State private var bid: Int = 0
    /// Spades blind nil: the player chose to look. Reset every round.
    @State private var hasPeeked = false
    /// Drives the face-down -> face-up flip of the preview fan on peek.
    @State private var peekFlip: Double = 0

    private var snap: ClientSnapshot? { client.snapshot }
    private var isSpades: Bool { snap?.gameKind == .spades }
    private var maxBid: Int { snap?.round?.cardsPerPlayer ?? 0 }
    private var isMyBidTurn: Bool {
        guard let snap, let seat = client.mySeat else { return false }
        return snap.phase == .bidding && snap.round?.turnSeat == seat
    }
    private var myBid: Int? {
        guard let snap, let seat = client.mySeat else { return nil }
        return snap.round?.bids[seat]
    }
    /// Blind nil is on the table for this seat right now: rule on, spades,
    /// this seat hasn't bid yet, and hasn't looked.
    private var blindNilAvailable: Bool {
        guard let snap, isSpades, snap.rules.spadesBlindNil, myBid == nil else { return false }
        return !hasPeeked
    }
    /// The hand stays hidden only while blind nil is still a live option.
    private var handHidden: Bool { blindNilAvailable }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(titleText)
                .font(.system(.title2, design: .serif).weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)

            if let teamLine {
                TeamBidLine(text: teamLine)
            }

            if isMyBidTurn, myBid == nil {
                if blindNilAvailable {
                    blindNilChoice
                } else {
                    bidWheel
                    if let hint = coachHint {
                        CoachWhisper(text: hint)
                    }
                    if isSpades {
                        GhostHintTipView(tip: SpadesNilTip())
                            .padding(.horizontal, 24)
                    }
                    Button {
                        Haptics.play()
                        client.placeBid(bid)
                    } label: {
                        Text(bidButtonText)
                            .font(.title3.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CardStyle.gold)
                    .foregroundStyle(CardStyle.ink)
                    .padding(.horizontal, 40)
                    .accessibilityLabel(bidButtonText)
                }
            } else {
                waitingRow
                if blindNilAvailable {
                    // Not your turn yet, but you can already decide to look
                    // (and give up blind nil) or keep the cards hidden.
                    peekButton
                }
            }
            Spacer()
            if isSpades {
                handPreview
                    .padding(.bottom, 18)
            }
        }
        .animation(motionReduced ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: handHidden)
        .animation(motionReduced ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: isMyBidTurn)
        .onAppear {
            SpadesNilTip.isEligible = isSpades && isMyBidTurn && !blindNilAvailable
        }
        .onChange(of: isMyBidTurn) { _, newValue in
            SpadesNilTip.isEligible = isSpades && newValue && !blindNilAvailable
        }
        .onChange(of: hasPeeked) { _, _ in
            SpadesNilTip.isEligible = isSpades && isMyBidTurn && !blindNilAvailable
        }
        .onChange(of: snap?.round?.roundNumber) { _, _ in
            // A fresh deal: the cards are unseen again.
            hasPeeked = false
            peekFlip = 0
            bid = 0
        }
    }

    // MARK: copy

    private var titleText: String {
        if isMyBidTurn, myBid == nil {
            return blindNilAvailable ? "Blind nil, or a look first?" : "How many tricks will you take?"
        }
        return "Bidding…"
    }

    private var bidButtonText: String {
        if isSpades, bid == 0 { return "Bid Nil" }
        return "Bid \(bid)"
    }

    /// Spades partnership: the partner's bid once it's in, folded into a
    /// team total once ours is too. Nil for cutthroat / individual play and
    /// for every other game.
    private var teamLine: String? {
        guard let snap, isSpades, let seat = client.mySeat,
              SpadesRules.isPartnership(seatCount: snap.seats.count, cutthroat: snap.rules.spadesCutthroat)
        else { return nil }
        let teams = SpadesRules.teams(seatIDs: snap.seats.map(\.id), cutthroat: snap.rules.spadesCutthroat)
        guard let partner = teams.first(where: { $0.contains(seat) })?.first(where: { $0 != seat }),
              let partnerBid = snap.round?.bids[partner] else { return nil }
        let partnerName = snap.seats.first { $0.id == partner }?.playerName ?? "Partner"
        let partnerBlind = snap.round?.blindNilSeats.contains(partner) ?? false
        let partnerWord = partnerBid == 0 ? (partnerBlind ? "blind nil" : "nil") : "\(partnerBid)"
        if let mine = myBid {
            let team = mine + partnerBid // nil bids are 0, so they add nothing
            return "Team bid \(team) · \(partnerName) \(partnerWord)"
        }
        return "\(partnerName) (partner) bid \(partnerWord)"
    }

    // MARK: wheel

    private var bidWheel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(0...max(maxBid, 0), id: \.self) { value in
                    let isNil = isSpades && value == 0
                    Button {
                        Haptics.tick()
                        withAnimation(motionReduced ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                            bid = value
                        }
                    } label: {
                        Text(isNil ? "Nil" : "\(value)")
                            .font(.system(isNil ? .title2 : .title, design: .serif).weight(.bold).monospacedDigit())
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .foregroundStyle(bid == value ? CardStyle.ink : .white.opacity(0.75))
                            .frame(width: 64, height: 64)
                            .background(
                                Circle().fill(bid == value ? CardStyle.gold : .white.opacity(0.10))
                            )
                            .scaleEffect(bid == value ? 1.15 : 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isNil ? "Bid nil, no tricks" : "Bid \(value)")
                    .accessibilityAddTraits(bid == value ? .isSelected : [])
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 12)
        }
    }

    private var waitingRow: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.white.opacity(0.6))
            Text(myBid == nil ? "Waiting for other bids" : "Bid in — waiting for the rest")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: spades blind nil

    /// Two honest buttons: the bet, and the look that forfeits it.
    private var blindNilChoice: some View {
        VStack(spacing: 14) {
            Button {
                Haptics.play()
                client.bidBlindNil()
            } label: {
                VStack(spacing: 2) {
                    Text("Blind Nil")
                        .font(.title3.weight(.bold))
                    Text("No tricks, cards unseen · ±\(SpadesRules.blindNilBonus)")
                        .font(.caption)
                        .opacity(0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(CardStyle.gold)
            .foregroundStyle(CardStyle.ink)
            .padding(.horizontal, 40)
            .accessibilityLabel("Bid blind nil")
            .accessibilityHint("Bets on taking no tricks without looking at your cards")

            peekButton
        }
    }

    private var peekButton: some View {
        Button {
            Haptics.arm()
            peek()
        } label: {
            Label("Peek at my cards", systemImage: "eye")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CardStyle.gold)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(.white.opacity(0.10)))
                .overlay(Capsule().strokeBorder(CardStyle.gold.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Peek at my cards")
        .accessibilityHint("Shows your hand and gives up blind nil for this round")
    }

    /// Turns the fan over in two sweeps (0 -> 90 edge-on, then -90 -> 0)
    /// with the face swap at the midpoint, so the revealed faces land
    /// upright instead of mirrored — same trick as the table's trump flip.
    private func peek() {
        if motionReduced {
            hasPeeked = true
            peekFlip = 0
            return
        }
        withAnimation(.easeIn(duration: 0.2)) {
            peekFlip = 90
        } completion: {
            hasPeeked = true
            peekFlip = -90
            withAnimation(.easeOut(duration: 0.25)) { peekFlip = 0 }
        }
    }

    /// A compact, overlapping fan of the hand under the bid controls: card
    /// backs while blind nil is still open, faces once peeked (or when the
    /// rule is off). The fan flips as one piece so the reveal reads as the
    /// hand being turned over, not thirteen separate pops.
    private var handPreview: some View {
        let cards = snap?.myHand ?? []
        let count = max(cards.count, 1)
        return GeometryReader { geo in
            let cardWidth = min(geo.size.width * 0.19, 72)
            let step: CGFloat = cards.count > 1
                ? min(cardWidth * 0.62, (geo.size.width - cardWidth - 32) / CGFloat(count - 1))
                : 0
            let total = cardWidth + step * CGFloat(count - 1)
            ZStack {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    CardView(card: card, faceUp: !handHidden)
                        .frame(width: cardWidth)
                        .offset(x: -total / 2 + cardWidth / 2 + CGFloat(index) * step)
                        .zIndex(Double(index))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .rotation3DEffect(.degrees(peekFlip), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
        }
        .frame(height: 118)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(handHidden
            ? "Your \(cards.count) cards, face down"
            : "Your hand: " + cards.map(\.accessibleName).joined(separator: ", "))
    }

    // MARK: coach

    /// v1 heuristic: count near-certain winners. The full coach engine
    /// (teach mode, per-play hints) grows from this seam.
    private var coachHint: String? {
        guard let hand = snap?.myHand, !hand.isEmpty else { return nil }
        var strong = 0
        for card in hand {
            switch card.kind {
            case .wizard: strong += 1
            case .standard(let suit, let rank):
                if rank == 14 { strong += 1 }
                else if let trump = snap?.round?.trumpSuit, suit == trump, rank >= 12 { strong += 1 }
            case .jester: break
            case .uno: break // this coach only runs for trick-taking games
            }
        }
        return "Coach: \(strong) likely \(strong == 1 ? "winner" : "winners") in this hand."
    }
}

/// The partner's bid, quietly: gold on a soft capsule, same family as
/// `CoachWhisper` so the two read as the same voice.
struct TeamBidLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.caption)
            Text(text)
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(CardStyle.gold.opacity(0.95))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.08)))
        .accessibilityLabel(text)
    }
}

struct CoachWhisper: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "graduationcap.fill")
                .font(.caption)
            Text(text)
                .font(.footnote)
        }
        .foregroundStyle(CardStyle.gold.opacity(0.9))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.08)))
    }
}
