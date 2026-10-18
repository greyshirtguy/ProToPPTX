// OptionsPanel: the options, and what could not be carried over of the chosen
// presentation.
//
// Every control here is one field of ConversionOptions, and each has a flag of the same
// meaning on the command line (docs/OPTIONS.md). The words under each say what it does
// in a sentence; they are the place to explain, not a help page.

import DeckModel
import SwiftUI

struct OptionsPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Background media") {
                Toggle("Keep background media on following slides", isOn: $model.options.carryBackgroundForward)
                Caption("In ProPresenter a background stays up while later slides with no media of their own are clicked. When this is on, each of those slides gets the background that would be showing.")
                Picker("Put background pictures", selection: $model.options.backgroundPlacement) {
                    Text("As the slide’s background").tag(ConversionOptions.BackgroundPlacement.slideBackground)
                    Text("As a picture at the back").tag(ConversionOptions.BackgroundPlacement.pictureAtBack)
                }
                Caption(model.options.backgroundPlacement == .slideBackground
                    ? "Set in Format Background: it cannot be clicked or moved by mistake while the words are edited."
                    : "A picture behind everything else, which can be selected, moved and replaced.")
            }

            Section("Slides") {
                Toggle("Leave out slides turned off in ProPresenter", isOn: $model.options.skipDisabledSlides)
                Toggle("Follow the chosen arrangement", isOn: $model.options.followArrangement)
                Caption("For songs: slides in the order of the arrangement chosen in ProPresenter, repeats included. Off, or with none chosen: each group once, in order.")
            }

            Section("Videos") {
                Picker("Video cues", selection: $model.options.videos) {
                    Text("Put the video in").tag(ConversionOptions.VideoHandling.embed)
                    Text("A still from it only").tag(ConversionOptions.VideoHandling.stillOnly)
                    Text("Leave them out").tag(ConversionOptions.VideoHandling.leaveOut)
                }
            }

            Section("Also") {
                Toggle("Slide notes become speaker notes", isOn: $model.options.includeNotes)
                Toggle("Groups become PowerPoint sections", isOn: $model.options.groupsAsSections)
                Button("Set All Options Back") { model.options = .defaults }
                    .disabled(model.options == .defaults)
            }

            if let item = model.selected {
                Section("Notes on \(item.name)") {
                    if case .ready = item.state, item.notes.isEmpty {
                        Label("Everything was carried over.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                    ForEach(item.notes) { note in
                        NoteRow(note: note)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
