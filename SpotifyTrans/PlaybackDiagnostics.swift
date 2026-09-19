import Foundation

// Opt-in for a supervised device session. Never pass credentials, callback URLs,
// HTTP headers, arbitrary response bodies, or lyrics to this logger.
enum PlaybackDiagnostics {
    static func response(_ data: Data, kind: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--playback-diagnostics"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        // Only allow known protocol fields; never log arbitrary response text.
        func code(_ value: Any?) -> String {
            guard let value = value as? String, value.count <= 80,
                  value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else { return "unknown" }
            return value
        }
        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String)?.lowercased() ?? ""
            let category = message.contains("premium") ? "premium"
                : message.contains("scope") ? "scope"
                : message.contains("restriction") ? "restriction"
                : message.contains("no active device") ? "no_active_device" : "other"
            record("\(kind) error reason=\(code(error["reason"])) category=\(category)")
        } else if kind == "poll" {
            let actions = object["actions"] as? [String: Any]
            let disallows = actions?["disallows"] as? [String: Bool] ?? [:]
            let knownActions = ["resuming", "pausing", "skipping_next", "skipping_prev", "interrupting_playback", "transferring_playback"]
            let blocked = knownActions.filter { disallows[$0] == true }.joined(separator: ",")
            record("poll payload type=\(code(object["currently_playing_type"])) itemPresent=\(object["item"] is [String: Any]) playing=\(object["is_playing"] as? Bool ?? false) disallowed=\(blocked)")
        }
        #endif
    }

    static func record(_ event: @autoclosure () -> String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--playback-diagnostics") else { return }
        let message = event().replacingOccurrences(of: "\n", with: " ")
        let line = "[LyrivaPlayback] \(Date().ISO8601Format()) \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        #endif
    }
}
