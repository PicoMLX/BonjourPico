import Foundation
import Network
import BonjourDiscoveryCore

@MainActor
public final class BonjourPico {
    private let discovery: BonjourDiscoveryActor

    public init(configuration: BonjourDiscoveryActor.Configuration = .init()) {
        self.discovery = BonjourDiscoveryActor(configuration: configuration)
    }

    init(actor: BonjourDiscoveryActor) {
        self.discovery = actor
    }

    public var endpoints: [BonjourEndpoint] {
        get async {
            await discovery.currentEndpoints()
        }
    }

    public var state: NWBrowser.State {
        get async {
            await discovery.currentState()
        }
    }

    public var isScanning: Bool {
        get async {
            let currentState = await discovery.currentState()
            switch currentState {
            case .ready, .waiting: return true
            default: return false
            }
        }
    }

    public func startScanning() async throws {
        do {
            try await discovery.start()
        } catch {
            throw BonjourPicoError(from: error)
        }
    }

    public func stopScanning() async {
        await discovery.stop()
    }

    public func streamEndpoints() async -> AsyncThrowingStream<[BonjourEndpoint], Error> {
        await discovery.serviceStream()
    }

    public func streamState() async -> AsyncStream<NWBrowser.State> {
        await discovery.stateStream()
    }
}
