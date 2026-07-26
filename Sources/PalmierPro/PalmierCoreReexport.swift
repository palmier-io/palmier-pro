import Foundation
@_exported import PalmierCore

// Bridges the concrete timeline model to the portable core. Clip reads exactly
// the fields RippleClip requires; the conformance is the only coupling point
// the engines have with the app's model layer.
extension Clip: RippleClip {}
