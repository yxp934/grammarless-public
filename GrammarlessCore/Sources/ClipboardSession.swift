import Foundation

public protocol ClipboardClient {
    func snapshot() -> ClipboardSnapshot
    func write(string: String)
    func restore(snapshot: ClipboardSnapshot)
}

public struct ClipboardSnapshot: Equatable {
    public var string: String?

    public init(string: String?) {
        self.string = string
    }
}

public struct ClipboardSession {
    private let client: ClipboardClient
    private let snapshot: ClipboardSnapshot

    public init(client: ClipboardClient) {
        self.client = client
        self.snapshot = client.snapshot()
    }

    public func writeTemporary(_ string: String) {
        client.write(string: string)
    }

    public func restore() {
        client.restore(snapshot: snapshot)
    }
}
