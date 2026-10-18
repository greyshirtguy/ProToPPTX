// SlideGrid: a presentation's slides, drawn as they will be written, in a grid.
//
// Each slide says its number and where it came from in ProPresenter (its group and
// name). A slide whose background was carried on from an earlier one says so, and from
// which, so that the person can see what the "keep background media" option did. A slide
// opens larger with a double click, or Return; the arrow keys go through them there.

import AppKit
import DeckModel
import SwiftUI

struct SlideGrid: View {
    let item: PresentationItem
    @State private var viewing: Int?
    @State private var selected: Int?

    var body: some View {
        Group {
            switch item.state {
            case .reading where item.deck == nil:
                ProgressView("Reading \(item.name)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let why):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text("This presentation could not be read.").font(.title3)
                    Text(why).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                if let deck = item.deck {
                    grid(deck)
                }
            }
        }
        .sheet(item: Binding(get: { viewing.map(SlideIndex.init) }, set: { viewing = $0?.value })) { index in
            SlideViewer(item: item, index: index.value) { viewing = nil }
        }
    }

    private func grid(_ deck: Deck) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 420), spacing: 18)], spacing: 22) {
                ForEach(deck.slides.indices, id: \.self) { k in
                    SlideCell(number: k + 1, slide: deck.slides[k], image: item.thumbnails[k], aspect: deck.size.width / deck.size.height, isSelected: selected == k)
                        .onTapGesture(count: 2) { viewing = k }
                        .onTapGesture { selected = k }
                }
            }
            .padding(20)
        }
        .onKeyPress(.return) {
            if let selected { viewing = selected }
            return .handled
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct SlideIndex: Identifiable {
    let value: Int
    var id: Int { value }
}

struct SlideCell: View {
    let number: Int
    let slide: Slide
    let image: CGImage?
    let aspect: Double
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Color.black)
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isSelected ? 3 : 1))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number)").font(.callout.monospacedDigit().weight(.semibold))
                Text(slide.caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            if let bg = slide.background, bg.isCarriedOver {
                Label("Background from slide \(bg.fromSlide ?? 0)", systemImage: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.teal)
                    .help("This slide has no media cue of its own; in ProPresenter the background from slide \(bg.fromSlide ?? 0) would still be showing, so it is put on this slide too.")
            }
        }
    }
}

/// One slide, large, with the arrow keys to go through the rest.
struct SlideViewer: View {
    let item: PresentationItem
    @State var index: Int
    let close: () -> Void
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Rectangle().fill(Color.black)
                if let image { Image(decorative: image, scale: 1).resizable().interpolation(.high) }
            }
            .aspectRatio((item.deck?.size.width ?? 16) / (item.deck?.size.height ?? 9), contentMode: .fit)
            .frame(minWidth: 800, minHeight: 450)

            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index == 0)
                Text("Slide \(index + 1) of \(item.deck?.slides.count ?? 0)").monospacedDigit()
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index + 1 >= (item.deck?.slides.count ?? 0))
                if let slide = item.deck?.slides[safe: index] {
                    Text(slide.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let bg = slide.background, bg.isCarriedOver {
                        Label("Background from slide \(bg.fromSlide ?? 0)", systemImage: "arrow.turn.down.right").foregroundStyle(.teal)
                    }
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .task(id: index) { image = await item.picture(of: index, width: 1920) }
    }

    private func step(_ d: Int) {
        let n = item.deck?.slides.count ?? 0
        index = min(max(index + d, 0), max(n - 1, 0))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
