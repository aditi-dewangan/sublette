import SwiftUI

/// A stack of cards where the top one can be dragged right to like and left
/// to pass. Used by both decks.
@MainActor
struct SwipeCardStack<Item: Identifiable, Card: View>: View {
    let items: [Item]
    let onLike: () -> Void
    let onPass: () -> Void
    @ViewBuilder let card: (Item) -> Card

    @State private var offset: CGSize = .zero

    /// How far a card must travel to count as a swipe.
    static var threshold: CGFloat { 110 }

    var body: some View {
        ZStack {
            ForEach(Array(items.prefix(3).enumerated().reversed()), id: \.element.id) { index, item in
                card(item)
                    .overlay(alignment: .top) {
                        if index == 0 {
                            stamp
                        }
                    }
                    .scaleEffect(index == 0 ? 1 : 1 - CGFloat(index) * 0.04)
                    .offset(y: CGFloat(index) * 10)
                    .offset(index == 0 ? offset : .zero)
                    .rotationEffect(.degrees(index == 0 ? Double(offset.width / 22) : 0))
                    .gesture(drag, including: index == 0 ? .all : .subviews)
                    .allowsHitTesting(index == 0)
                    .accessibilityHidden(index != 0)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: items.map(\.id))
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { offset = $0.translation }
            .onEnded { value in
                let width = value.translation.width
                if width > Self.threshold {
                    finish(towards: 600, then: onLike)
                } else if width < -Self.threshold {
                    finish(towards: -600, then: onPass)
                } else {
                    withAnimation(.spring()) { offset = .zero }
                }
            }
    }

    private func finish(towards x: CGFloat, then action: @escaping () -> Void) {
        withAnimation(.easeOut(duration: 0.2)) {
            offset = CGSize(width: x, height: offset.height)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            offset = .zero
            action()
        }
    }

    @ViewBuilder
    private var stamp: some View {
        let progress = min(abs(offset.width) / Self.threshold, 1)
        if offset.width > 10 {
            StampLabel(text: "LIKE", color: Brand.magenta)
                .opacity(progress)
                .rotationEffect(.degrees(-12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        } else if offset.width < -10 {
            StampLabel(text: "PASS", color: Brand.ink)
                .opacity(progress)
                .rotationEffect(.degrees(12))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(24)
        }
    }
}

private struct StampLabel: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(.title, design: .rounded).weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 4))
            .accessibilityHidden(true)
    }
}

/// Round buttons under a deck: undo, pass, save, like.
struct DeckButton: View {
    let systemImage: String
    let label: String
    var color: Color = Brand.ink
    var size: CGFloat = 60
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(Color.white, in: Circle())
                .overlay(Circle().stroke(Brand.ink.opacity(0.12), lineWidth: 1))
                .shadow(color: Brand.ink.opacity(0.08), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A photo from a URL that shows a quiet placeholder while loading or when
/// storage can't be reached.
struct RemotePhoto: View {
    let urlString: String?

    var body: some View {
        ZStack {
            Brand.cream
            Image(systemName: "photo")
                .font(.system(size: 34))
                .foregroundStyle(Brand.ink.opacity(0.25))
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
