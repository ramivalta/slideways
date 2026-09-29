import Foundation
import GameController
import SlicksCore

/// Logical keys the game cares about, independent of platform key codes.
public enum Key: Hashable, Sendable {
    case up, down, left, right
    case w, a, s, d
    case i, j, k, l
    case pad8, pad4, pad5, pad6, pad2
    case space, enter, escape, tab
    case q, r, p

    #if os(macOS)
    /// Maps macOS virtual key codes (kVK_*) to logical keys.
    public init?(macKeyCode code: UInt16) {
        switch code {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 13: self = .w
        case 0: self = .a
        case 1: self = .s
        case 2: self = .d
        case 34: self = .i
        case 38: self = .j
        case 40: self = .k
        case 37: self = .l
        case 91: self = .pad8
        case 86: self = .pad4
        case 87: self = .pad5
        case 88: self = .pad6
        case 84: self = .pad2
        case 49: self = .space
        case 36, 76: self = .enter
        case 53: self = .escape
        case 48: self = .tab
        case 12: self = .q
        case 15: self = .r
        case 35: self = .p
        default: return nil
        }
    }
    #endif
}

/// Keyboard layout for one local player.
public struct KeyBindings: Sendable {
    public var accelerate: [Key]
    public var brake: [Key]
    public var left: [Key]
    public var right: [Key]
    public var label: String

    public static let players: [KeyBindings] = [
        KeyBindings(accelerate: [.up], brake: [.down], left: [.left], right: [.right], label: "Arrow keys"),
        KeyBindings(accelerate: [.w], brake: [.s], left: [.a], right: [.d], label: "W A S D"),
        KeyBindings(accelerate: [.i], brake: [.k], left: [.j], right: [.l], label: "I J K L"),
        KeyBindings(accelerate: [.pad8], brake: [.pad5, .pad2], left: [.pad4], right: [.pad6], label: "Numpad 8 4 5 6"),
    ]
}

/// Tracks held keys and connected game controllers.
public final class Input {
    public static let shared = Input()

    private(set) var held: Set<Key> = []

    public func press(_ key: Key) { held.insert(key) }
    public func release(_ key: Key) { held.remove(key) }
    /// Call when the window loses focus so keys don't stay stuck down.
    public func releaseAll() { held.removeAll() }

    public func isHeld(_ key: Key) -> Bool { held.contains(key) }

    private func any(_ keys: [Key]) -> Bool { keys.contains { held.contains($0) } }

    /// Controllers in connection order. Controller N drives local player N.
    public var controllers: [GCController] {
        GCController.controllers().filter { $0.extendedGamepad != nil }
    }

    /// Combined keyboard and gamepad input for a local player.
    public func carInput(forPlayer p: Int) -> CarInput {
        var input = CarInput()
        if p < KeyBindings.players.count {
            let b = KeyBindings.players[p]
            input.throttle = any(b.accelerate) ? 1 : 0
            input.brake = any(b.brake) ? 1 : 0
            input.steer = (any(b.left) ? 1 : 0) - (any(b.right) ? 1 : 0)
        }
        let pads = controllers
        if p < pads.count, let pad = pads[p].extendedGamepad {
            let stick = pad.leftThumbstick.xAxis.value
            let dpad = pad.dpad.xAxis.value
            let x = abs(stick) > abs(dpad) ? stick : dpad
            if abs(x) > 0.15 { input.steer = -Double(x) }
            input.throttle = max(input.throttle, Double(max(pad.rightTrigger.value, pad.buttonA.value)))
            input.brake = max(input.brake, Double(max(pad.leftTrigger.value, pad.buttonB.value, pad.buttonX.value)))
        }
        return input
    }
}
