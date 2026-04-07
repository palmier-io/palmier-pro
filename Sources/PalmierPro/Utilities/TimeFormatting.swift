/// Converts a frame number to timecode string "HH:MM:SS:FF"
func formatTimecode(frame: Int, fps: Int) -> String {
    guard fps > 0 else { return "00:00:00:00" }
    let totalSeconds = frame / fps
    let ff = frame % fps
    let ss = totalSeconds % 60
    let mm = (totalSeconds / 60) % 60
    let hh = totalSeconds / 3600
    return String(format: "%02d:%02d:%02d:%02d", hh, mm, ss, ff)
}

func frameToSeconds(frame: Int, fps: Int) -> Double {
    guard fps > 0 else { return 0 }
    return Double(frame) / Double(fps)
}

func secondsToFrame(seconds: Double, fps: Int) -> Int {
    Int(seconds * Double(fps))
}
