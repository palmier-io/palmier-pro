import Foundation

extension EditorViewModel {
    func setColorGrade(_ lut: LUTRef?) {
        let prev = timeline.lut
        guard prev != lut else { return }
        timeline.lut = lut
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.setColorGrade(prev)
        }
        undoManager?.setActionName(lut == nil ? "Clear Color Grade (Agent)" : "Apply Color Grade (Agent)")
        // Grade renders via CALayer.filters, not the composition; rebuilding would only cause a black flash.
        videoEngine?.refreshGrade()
    }

    func setColorPrimaries(_ primaries: PrimaryGrade?) {
        let next = (primaries?.isIdentity ?? true) ? nil : primaries
        let prev = timeline.primaries
        guard prev != next else { return }
        timeline.primaries = next
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.setColorPrimaries(prev)
        }
        undoManager?.setActionName("Adjust Color")
        videoEngine?.refreshGrade()
    }
}
