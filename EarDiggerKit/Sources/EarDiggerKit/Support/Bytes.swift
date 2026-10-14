/// Fixed-width integer access on byte arrays. Every wire format here is little-endian
/// except the tube battery reply and sensor packets, which are big-endian.
enum Bytes {
    static func u16le(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | Int(b[o + 1]) << 8
    }

    static func u32le(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    /// A signed 32-bit little-endian value, widened to `Int`.
    static func i32le(_ b: [UInt8], _ o: Int) -> Int {
        Int(Int32(bitPattern: u32le(b, o)))
    }

    static func u32be(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    static func i16be(_ b: [UInt8], _ o: Int) -> Int {
        Int(Int16(bitPattern: UInt16(b[o]) << 8 | UInt16(b[o + 1])))
    }

    static func putU16le(_ b: inout [UInt8], _ o: Int, _ v: UInt16) {
        b[o] = UInt8(truncatingIfNeeded: v)
        b[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }

    static func putU32le(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
    }
}
