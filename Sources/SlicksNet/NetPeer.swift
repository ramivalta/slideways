import Foundation
import SlicksCore
import SlicksLink

/// Game messages to and from one peer over an encrypted UDP link. Inputs and race state go
/// unreliable (newest wins); everything else is reliable and ordered. Callbacks run on main.
public final class NetPeer {
    public let link: Link
    public var onMessage: ((NetMessage) -> Void)?
    /// The other side left, timed out, or broke the protocol. Not called for `close(reason:)`.
    public var onClose: ((String) -> Void)?

    public var rtt: Double? { link.rtt }
    public var route: Route { link.route }
    public var isClosed: Bool { link.isClosed }

    private var pingTimer: DispatchSourceTimer?

    init(link: Link) {
        self.link = link
        link.onMessage = { [weak self] _, bytes in self?.deliver(bytes) }
        link.onClose = { [weak self] reason in self?.closed(reason) }
        // Regular pings keep the round-trip estimate fresh even when nothing else is sent.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 1)
        t.setEventHandler { [weak self] in self?.send(.ping(DispatchTime.now().uptimeNanoseconds)) }
        t.resume()
        pingTimer = t
    }

    deinit { pingTimer?.cancel() }

    public func send(_ message: NetMessage) {
        link.send(message.encoded(), reliable: message.isReliable)
    }

    public func close(reason: String) {
        pingTimer?.cancel()
        link.close(reason: reason)
    }

    private func deliver(_ bytes: [UInt8]) {
        guard let message = try? NetMessage(decoding: bytes) else {
            close(reason: "sent a message this version can't read")
            return closed("the other side sent a message this version can't read")
        }
        switch message {
        case let .ping(t): send(.pong(t))
        case .pong: break
        default: onMessage?(message)
        }
    }

    private func closed(_ reason: String) {
        pingTimer?.cancel()
        let handler = onClose
        onClose = nil
        handler?(reason)
    }
}

extension NetMessage {
    /// Inputs, race state and pings are superseded by the next one; resending them is pointless.
    var isReliable: Bool {
        switch self {
        case .input, .snapshot, .ping, .pong: false
        default: true
        }
    }
}
