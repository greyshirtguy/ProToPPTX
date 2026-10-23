// PresentationTree: a presentation as a database workspace keeps it, put back into the
// shape of ProPresenter 21.4's message before LoroMessage makes the message of it.
//
// KNOWN (the maintainer's workspace, ProPresenter 22.7 beta, 2026-10): two parts of a
// presentation are kept otherwise than as the message has them.
//
//   - The groups, and which slides are in each, are a Loro tree,
//     "cue_group_placements", in place of the message's list `cue_groups`: each node
//     at the top a group (its "meta" holds the group's id, and its name, colour and the
//     rest under Kind/group), and each node under one a slide of the group, in order
//     (its "meta" holds the slide's id, under Kind "cue").
//   - The slides themselves ("cues") are a map of each slide's id to the slide. Their
//     order in the message's list never mattered (PlayOrder goes by the groups); they
//     are put in the order the groups give, then any no group names, by id.
//
// NOT KNOWN: whether a slide can be at the top of the tree with no group, or a group
// in a group. A slide outside every group is left out, as ProPresenter 21 leaves out a
// slide that no group lists; a group in a group is taken as one more group, after its
// parent's own slides.

import Foundation
import LoroKit

enum PresentationTree {
    /// The presentation's root, with its groups and slides as 21.4's message has them.
    static func asMessageTree(_ root: LoroValue) -> LoroValue {
        guard var parts = root.map else { return root }
        var order: [String] = []
        if let placements = parts["cue_group_placements"]?.list {
            var groups: [LoroValue] = []
            func visit(_ node: LoroValue) {
                guard let meta = node["meta"], meta["Kind"]?["__tag"]?.string == "group" else { return }
                var group = meta["Kind"]?["group"]?.map ?? [:]
                group["uuid"] = meta["uuid"] ?? .null
                var ids: [LoroValue] = []
                var inner: [LoroValue] = []
                for child in node["children"]?.list ?? [] {
                    if child["meta"]?["Kind"]?["__tag"]?.string == "cue", let id = child["meta"]?["uuid"] {
                        ids.append(id)
                        if let s = id.string { order.append(s) }
                    } else {
                        inner.append(child)
                    }
                }
                groups.append(.map(["group": .map(group), "cue_identifiers": .list(ids)]))
                for child in inner { visit(child) }
            }
            for node in placements { visit(node) }
            if parts["cue_groups"] == nil || parts["cue_groups"]?.list?.isEmpty == true {
                parts["cue_groups"] = .list(groups)
            }
            parts["cue_group_placements"] = nil
        }
        if let cues = parts["cues"]?.map {
            var listed: [LoroValue] = []
            var seen = Set<String>()
            for id in order where cues[id] != nil && !seen.contains(id) {
                listed.append(cues[id]!)
                seen.insert(id)
            }
            for id in cues.keys.sorted() where !seen.contains(id) { listed.append(cues[id]!) }
            parts["cues"] = .list(listed)
        }
        return .map(parts)
    }
}
