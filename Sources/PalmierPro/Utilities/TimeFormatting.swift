import Foundation

func formatTimecode(frame: Int, fps: Int) -> String {
    guard fps > 0 else { return "00:00:00:00" }
    let absFrame = abs(frame)
    let totalSeconds = absFrame / fps
    let ff = absFrame % fps
    let ss = totalSeconds % 60
    let mm = (totalSeconds / 60) % 60
    let hh = totalSeconds / 3600
    let sign = frame < 0 ? "-" : ""
    return "\(sign)\(twoDigit(hh)):\(twoDigit(mm)):\(twoDigit(ss)):\(twoDigit(ff))"
}

private func twoDigit(_ value: Int) -> String {
    guard value >= 0 && value < 10 else { return "\(value)" }
    return "0\(value)"
}

func frameToSeconds(frame: Int, fps: Int) -> Double {
    guard fps > 0 else { return 0 }
    return Double(frame) / Double(fps)
}

func secondsToFrame(seconds: Double, fps: Int) -> Int {
    Int(seconds * Double(fps))
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = Foundation.pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
