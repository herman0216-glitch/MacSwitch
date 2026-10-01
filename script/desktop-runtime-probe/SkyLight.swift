import AppKit
import Darwin

// Candidate ABI declarations: yabai dd845723416f5fe92af49fad5ebab00369e07edd,
// src/misc/extern.h. Private APIs have no Apple ABI contract. The probe first
// exercises these declarations on a window owned by its own helper process.
final class SkyLight {
    typealias MainConnection = @convention(c) () -> Int32
    typealias GetFloat = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFloat = @convention(c) (Int32, UInt32, Float) -> Int32
    typealias Order = @convention(c) (Int32, UInt32, Int32, UInt32) -> Int32
    typealias GetOrdered = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt8>) -> Int32
    typealias GetOwner = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
    typealias GetPID = @convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Int32

    static let names = ["SLSMainConnectionID", "SLSGetWindowAlpha", "SLSSetWindowAlpha",
                        "SLSOrderWindow", "SLSWindowIsOrderedIn", "SLSGetWindowOwner", "SLSConnectionGetPID"]
    private let handle: UnsafeMutableRawPointer
    let mainConnection: MainConnection
    let getAlpha: GetFloat
    let setAlpha: SetFloat
    let order: Order
    let getOrdered: GetOrdered
    let getOwner: GetOwner
    let getPID: GetPID

    init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL) else {
            throw ProbeError.failure("SkyLight could not be loaded")
        }
        self.handle = handle
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else { throw ProbeError.failure("Missing symbol: \(name)") }
            return unsafeBitCast(address, to: T.self)
        }
        mainConnection = try symbol(Self.names[0], MainConnection.self)
        getAlpha = try symbol(Self.names[1], GetFloat.self)
        setAlpha = try symbol(Self.names[2], SetFloat.self)
        order = try symbol(Self.names[3], Order.self)
        getOrdered = try symbol(Self.names[4], GetOrdered.self)
        getOwner = try symbol(Self.names[5], GetOwner.self)
        getPID = try symbol(Self.names[6], GetPID.self)
    }

    deinit { dlclose(handle) }

    func state(connection: Int32, window: UInt32) -> WindowState {
        var alpha: Float = -1
        var ordered: UInt8 = 255
        let alphaError = getAlpha(connection, window, &alpha)
        let orderError = getOrdered(connection, window, &ordered)
        return WindowState(alpha: alpha, ordered: ordered, alphaError: alphaError, orderError: orderError)
    }
}
