import CoreMotion
import EarDiggerKit
import Foundation

/// Fires [onShake] after a burst of hard shakes (see [ShakeCounter]). Only listens between
/// [start] and [stop]. Used from the main thread; Core Motion delivers on the main queue.
final class ShakeDetector {
    private let motion = CMMotionManager()
    private var counter = ShakeCounter()

    var onShake: (() -> Void)?

    /// False when the device has no accelerometer (the simulator).
    var available: Bool { motion.isAccelerometerAvailable }

    func start() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        counter.reset()
        motion.accelerometerUpdateInterval = 1.0 / 50 // like Android's SENSOR_DELAY_GAME
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let a = data.acceleration // in g, gravity included
            if self.counter.sample(x: a.x, y: a.y, z: a.z, atMs: Int64(data.timestamp * 1000)) {
                self.onShake?()
            }
        }
    }

    func stop() {
        if motion.isAccelerometerActive { motion.stopAccelerometerUpdates() }
    }
}
