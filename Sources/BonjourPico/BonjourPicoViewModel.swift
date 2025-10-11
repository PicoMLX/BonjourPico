import BonjourDiscoveryCore
import Network
import Observation

@MainActor
@Observable
public final class BonjourPicoViewModel {
    public private(set) var endpoints: [BonjourEndpoint] = []
    public private(set) var state: NWBrowser.State = .setup
    public private(set) var isScanning = false
    public private(set) var error: BonjourPicoError?

    private let pico: BonjourPico
    private var endpointTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    public init(configuration: BonjourDiscoveryActor.Configuration = .init()) {
        self.pico = BonjourPico(configuration: configuration)
    }

    init(pico: BonjourPico) {
        self.pico = pico
    }

    public func startScanning() {
        guard endpointTask == nil else { return }
        error = nil

        endpointTask = Task { [weak self] in
            await self?.observeEndpoints()
        }

        stateTask = Task { [weak self] in
            await self?.observeState()
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.pico.startScanning()
            } catch {
                self.error = BonjourPicoError(from: error)
                self.stopScanning()
            }
        }
    }

    public func stopScanning() {
        endpointTask?.cancel()
        endpointTask = nil
        stateTask?.cancel()
        stateTask = nil
        Task { [weak self] in
            guard let self else { return }
            await self.pico.stopScanning()
            self.isScanning = false
        }
    }

    public func refresh() {
        Task { [weak self] in
            guard let self else { return }
            self.endpoints = await self.pico.endpoints
            let currentState = await self.pico.state
            self.state = currentState
            self.isScanning = {
                switch currentState {
                case .ready, .waiting(_):
                    return true
                default:
                    return false
                }
            }()
        }
    }

    private func observeEndpoints() async {
        do {
            let stream = await pico.streamEndpoints()
            for try await endpoints in stream {
                guard !Task.isCancelled else { break }
                self.endpoints = endpoints
            }
        } catch {
            self.error = BonjourPicoError(from: error)
        }
    }

    private func observeState() async {
        let stream = await pico.streamState()
        for await state in stream {
            guard !Task.isCancelled else { break }
            self.state = state
            switch state {
            case .failed(let error):
                self.error = BonjourPicoError(from: BonjourDiscoveryError.browserFailed(error))
                self.isScanning = false
            case .ready, .waiting(_):
                self.isScanning = true
            default:
                self.isScanning = false
            }
        }
    }
}
