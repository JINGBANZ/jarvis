import Foundation

public extension ReferenceAdmissionResult {
    var admitted: Admitted? {
        guard case .admitted(let result) = self else { return nil }
        return result
    }

    func capabilities(disabledTools: Set<String>, disabledSkills: Set<String> = [], skills: [Skill] = []) -> CoachCapabilities {
        let names: Set<String> = [listReferencesTool.name, readReferenceTool.name, searchReferencesTool.name]
        let effective = disabledTools.subtracting(names)
            .union(admitted?.accessPolicy.disabledTools.intersection(names) ?? [])
        return .compose(disabledTools: effective, disabledSkills: disabledSkills,
                        referencesAdmitted: admitted != nil, skills: skills)
    }
}
