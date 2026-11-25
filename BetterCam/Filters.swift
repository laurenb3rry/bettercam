/// The looks offered in the camera and editor. Soleil first: the default for new captures.
struct Filter: Identifiable, Equatable {
    let id: String
    let name: String

    static let all = Grade.Look.active.map { Filter(id: $0.id, name: $0.name) }

    static func named(_ id: String) -> Filter {
        all.first { $0.id == id } ?? all[0]
    }

    /// A saved camera choice from revision 4 ("v1.<look>") or 5 ("v1r5.<look>") carries over to its revision-6
    /// successor. Recipes are not migrated: a photo saved with a revision-5 look keeps rendering with it.
    static func migrated(_ id: String) -> String {
        let name = id.hasPrefix("v1r5.") ? String(id.dropFirst(5)) : id.hasPrefix("v1.") ? String(id.dropFirst(3)) : nil
        switch name {
        case "signature": return Grade.Look.soleil.id
        case "editorial": return Grade.Look.editorial.id
        case "fineArt": return Grade.Look.terra.id
        case "silver": return Grade.Look.silver.id
        default: return id
        }
    }
}

// V0 Editorial, Leica M6 and Chroma (exact source, commented) live in research/v1/legacy/Filters-v0.swift;
// the revision-5 look sources in research/v1/archive/rev5/ (they still render archived recipes via Grade.Look.*R5).
