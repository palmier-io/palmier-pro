func formatTimecode(frame: Int, fps: Int) -> String {
    guard fps > 0 else { return "00:00:00:00" }
    let totalSeconds = frame / fps
    let ff = frame % fps
    let ss = totalSeconds % 60
    let mm = (totalSeconds / 60) % 60
    let hh = totalSeconds / 3600
    return "\(twoDigit(hh)):\(twoDigit(mm)):\(twoDigit(ss)):\(twoDigit(ff))"
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
