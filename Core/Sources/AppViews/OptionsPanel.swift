// OptionsPanel: the options, and what could not be carried over of the chosen
// presentation.
//
// Every control here is one field of ConversionOptions, and each has a flag of the same
// meaning on the command line (docs/OPTIONS.md). The words under each say what it does
// in a sentence; they are the place to explain, not a help page.
//
// Each section's heading has a small picture on a square of colour, as System Settings
// has before each of its panes, so that the sections can be found at a glance; and a
// choice of a few is a row of cards, each with a picture of what it does and its whole
// name, where a menu had cut the name short. (A first try, 2026-10-24: the maintainer
// would like the options to look less like a list of words, and has not yet settled
// how.)

import DeckModel
import SwiftUI

struct OptionsPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Keep background media on following slides", isOn: $model.options.carryBackgroundForward)
                Caption("In ProPresenter a background stays up while later slides with no media of their own are clicked. When this is on, each of those slides gets the background that would be showing.")
                ChoiceCards("Put background pictures", selection: $model.options.backgroundPlacement, choices: [
                    .init(.slideBackground, "As the slide’s background", symbol: "rectangle.inset.filled"),
                    .init(.pictureAtBack, "As a picture at the back", symbol: "square.3.layers.3d.bottom.filled"),
                ])
                Caption(model.options.backgroundPlacement == .slideBackground
                    ? "Set in Format Background: it cannot be clicked or moved by mistake while the words are edited."
                    : "A picture behind everything else, which can be selected, moved and replaced.")
            } header: {
                Heading("Background media", symbol: "photo.on.rectangle", colour: .blue)
            }

            Section {
                Toggle("Leave out slides turned off in ProPresenter", isOn: $model.options.skipDisabledSlides)
                Toggle("Follow the chosen arrangement", isOn: $model.options.followArrangement)
                Caption("For songs: slides in the order of the arrangement chosen in ProPresenter, repeats included. Off, or with none chosen: each group once, in order.")
            } header: {
                Heading("Slides", symbol: "rectangle.stack", colour: .orange)
            }

            Section {
                ChoiceCards("Video cues", selection: $model.options.videos, choices: [
                    .init(.embed, "Put the video in", symbol: "play.rectangle"),
                    .init(.stillOnly, "A still from it only", symbol: "photo"),
                    .init(.leaveOut, "Leave them out", symbol: "eye.slash"),
                ])
            } header: {
                Heading("Videos", symbol: "film", colour: .purple)
            }

            Section {
                Toggle("Slide notes become speaker notes", isOn: $model.options.includeNotes)
                Toggle("Groups become PowerPoint sections", isOn: $model.options.groupsAsSections)
                Button("Set All Options Back") { model.options = .defaults }
                    .disabled(model.options == .defaults)
            } header: {
                Heading("Also", symbol: "text.bubble", colour: .green)
            }

            if let item = model.selected {
                Section {
                    if case .ready = item.state, item.notes.isEmpty {
                        Label("Everything was carried over.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                    ForEach(item.notes) { note in
                        NoteRow(note: note)
                    }
                } header: {
                    Heading("Notes on \(item.name)", symbol: item.notes.isEmpty ? "checkmark" : "exclamationmark", colour: item.notes.isEmpty ? .green : .gray)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A section's heading: its name, after a small white picture on a square of colour.
struct Heading: View {
    let title: String
    let symbol: String
    let colour: SwiftUI.Color

    init(_ title: String, symbol: String, colour: SwiftUI.Color) {
        self.title = title
        self.symbol = symbol
        self.colour = colour
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(colour.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)
            Text(title).lineLimit(1)
        }
    }
}

/// A choice of a few, as cards side by side under its name: each a picture and words,
/// the one chosen in the accent colour.
struct ChoiceCards<Value: Hashable>: View {
    struct Choice {
        let value: Value
        let title: String
        let symbol: String

        init(_ value: Value, _ title: String, symbol: String) {
            self.value = value
            self.title = title
            self.symbol = symbol
        }
    }

    let title: String
    @Binding var selection: Value
    let choices: [Choice]

    init(_ title: String, selection: Binding<Value>, choices: [Choice]) {
        self.title = title
        self._selection = selection
        self.choices = choices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            HStack(alignment: .top, spacing: 8) {
                ForEach(choices, id: \.value) { choice in
                    card(choice)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func card(_ choice: Choice) -> some View {
        let chosen = choice.value == selection
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button { selection = choice.value } label: {
            VStack(spacing: 6) {
                Image(systemName: choice.symbol)
                    .font(.system(size: 18))
                    .frame(height: 22)
                Text(choice.title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(shape.fill(chosen ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.5))))
            .overlay(shape.strokeBorder(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), lineWidth: chosen ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct NoteRow: View {
    let note: ConversionNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.message).fixedSize(horizontal: false, vertical: true)
                if !note.slides.isEmpty {
                    Text(note.slidesText.prefix(1).uppercased() + note.slidesText.dropFirst())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var icon: String {
        switch note.kind {
        case .missingMedia: return "photo.badge.exclamationmark"
        case .missingFont: return "textformat"
        case .macro: return "gearshape.2"
        case .audio: return "speaker.wave.2"
        case .simplified: return "info.circle"
        }
    }

    private var color: SwiftUI.Color {
        switch note.kind {
        case .missingMedia, .missingFont: return .orange
        default: return .secondary
        }
    }
}
