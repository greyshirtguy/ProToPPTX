// PlayOrder: a presentation's slides in the order ProPresenter shows them.
//
// KNOWN (the protos, and every ProPresenter 7 file looked at): a presentation keeps its
// slides ("cues") in one list, in no particular order, and says the order in its
// groups: each group lists its cues by UUID, and the groups are listed in order. An
// arrangement, if one is chosen, is a list of groups (a group may come more than once,
// as a chorus does); without one, every group comes once, in the order listed. A
// playlist's item can choose an arrangement of its own (PlaylistItem.arrangement),
// which is then the one followed (A GUESS that ProPresenter plays it so when the item
// is clicked in the playlist: it is what the item keeps the choice for). KNOWN (the
// maintainer's playlist, 2026-10): 7 of 19 items choose one, and 5 of those 7
// presentations have none chosen of their own. One the presentation does not have is
// passed over for the presentation's own.
//
// A cue that no group lists is not shown by ProPresenter, and is left out here too.

import Foundation
import ProFormat

struct PlayedCue {
    let cue: RVData_Cue
    let groupName: String
    /// Counts the groups as they come in the order, from 0; the same group coming twice
    /// in an arrangement counts twice.
    let groupOccurrence: Int
    let indexInGroup: Int
}

enum PlayOrder {
    /// The cues in order, and the name of the arrangement followed, if one was.
    static func cues(of presentation: RVData_Presentation, followArrangement: Bool, chosen: String? = nil) -> (cues: [PlayedCue], arrangement: String?) {
        var cuesByID: [String: RVData_Cue] = [:]
        for cue in presentation.cues { cuesByID[cue.uuid.string.uppercased()] = cue }

        var groupsByID: [String: RVData_Presentation.CueGroup] = [:]
        for group in presentation.cueGroups { groupsByID[group.group.uuid.string.uppercased()] = group }

        var groups = presentation.cueGroups
        var arrangementName: String?
        // The playlist's choice, if it is one the presentation has; else its own.
        let wanted = [chosen, presentation.hasSelectedArrangement ? presentation.selectedArrangement.string : nil].compactMap { $0 }
        if followArrangement,
           let arrangement = wanted.lazy.compactMap({ id in presentation.arrangements.first { $0.uuid.string.uppercased() == id.uppercased() } }).first {
            let arranged = arrangement.groupIdentifiers.compactMap { groupsByID[$0.string.uppercased()] }
            if !arranged.isEmpty {
                groups = arranged
                arrangementName = arrangement.name
            }
        }

        var result: [PlayedCue] = []
        for (occurrence, group) in groups.enumerated() {
            for (index, id) in group.cueIdentifiers.enumerated() {
                guard let cue = cuesByID[id.string.uppercased()] else { continue }
                result.append(PlayedCue(cue: cue, groupName: group.group.name, groupOccurrence: occurrence, indexInGroup: index))
            }
        }
        return (result, arrangementName)
    }
}
