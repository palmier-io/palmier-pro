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

func parseTimecode(_ value: String, fps: Int) -> Int? {
    let fields = value.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...1_000).contains(fps), fields.count == 4,
          let hours = Int(fields[0]), let minutes = Int(fields[1]),
          let seconds = Int(fields[2]), let frames = Int(fields[3]),
          (0..<1_000).contains(hours), (0..<60).contains(minutes), (0..<60).contains(seconds),
          (0..<fps).contains(frames) else { return nil }
    return (hours * 3_600 + minutes * 60 + seconds) * fps + frames
}

private func twoDigit(_ value: Int) -> String {
    guard value >= 0 && value < 10 else { return "\(value)" }
    return "0\(value)"
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
