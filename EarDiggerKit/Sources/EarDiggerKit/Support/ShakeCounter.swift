/// Counts a burst of hard shakes (the "rage shake" that reveals the debug log). Six
/// accelerometer peaks above [thresholdG] within [windowMs] count; a gentle wobble, a bump
/// or a couple of swings do not. Feed it every accelerometer sample; the iOS side wires it
/// to Core Motion.
public struct ShakeCounter {
    public static let thresholdG = 2.7
    public static let peaksNeeded = 6
    public static let windowMs: Int64 = 3000
    public static let debounceMs: Int64 = 120
    public static let cooldownMs: Int64 = 2000

    private static let longAgo = Int64.min / 4

    private var peaks = 0
    private var firstPeakAtMs = longAgo
    private var lastPeakAtMs = longAgo
    private var firedAtMs = longAgo

    public init() {}

    public mutating func reset() {
        peaks = 0
    }

    /// One sample in units of g (gravity included). True when it completes a rage shake.
    public mutating func sample(x: Double, y: Double, z: Double, atMs now: Int64) -> Bool {
        let g = (x * x + y * y + z * z).squareRoot()
        if g < Self.thresholdG { return false }
        // One peak per swing: the sensor reports many samples above the threshold per shake.
        if now - lastPeakAtMs < Self.debounceMs { return false }
        lastPeakAtMs = now
        if now - firstPeakAtMs > Self.windowMs {
            peaks = 0
            firstPeakAtMs = now
        }
        peaks += 1
        if peaks >= Self.peaksNeeded && now - firedAtMs > Self.cooldownMs {
            peaks = 0
            firedAtMs = now
            return true
        }
        return false
    }
}
