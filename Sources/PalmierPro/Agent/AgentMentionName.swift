import Foundation

func makeMentionDisplayName(from raw: String) -> String {
    var result = ""
    var lastWasDash = false
    for ch in raw {
        if ch.isWhitespace || ch == "-" {
            if !lastWasDash { result.append("-") }
            lastWasDash = true
        } else {
            result.append(ch)
            lastWasDash = false
        }
    }
    return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}
