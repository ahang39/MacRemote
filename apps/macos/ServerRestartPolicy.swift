enum ServerRestartPolicy {
    // Retry a crashed helper with exponential backoff; keep the menu app alive.
    // A process that runs for 60s resets this count in MacRemoteController.
    static func delay(forAttempt attempt: Int) -> Double {
        let exponent = min(max(0, attempt - 1), 6)
        return min(60, Double(1 << exponent))
    }
}
