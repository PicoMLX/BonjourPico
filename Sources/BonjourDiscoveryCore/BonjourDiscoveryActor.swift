import Foundation
import Network
import os

/// Owns the `NWBrowser` on its own queue and exposes discovery results as async streams.
/// All mutable state is actor-isolated, so callers never touch the browser directly.
public actor BonjourDiscoveryActor {
    public struct Configuration: Sendable {
        public var serviceType: String
        public var domain: String
        public var parameters: NWParameters
        public var retryDelay: Duration

        public init(
            serviceType: String = "_pico._tcp",
            domain: String = "local.",
            parameters: NWParameters = .tcp,
            retryDelay: Duration = .seconds(2)
        ) {
            self.serviceType = serviceType
            self.domain = domain
            self.parameters = parameters
            self.retryDelay = retryDelay
        }
    }

    public struct Diagnostics: Sendable {
        private let logger: Logger?

        public init(subsystem: String = "BonjourPico", category: String = "Discovery", isEnabled: Bool = true) {
            self.logger = isEnabled ? Logger(subsystem: subsystem, category: category) : nil
        }

        public func debug(_ message: @autoclosure () -> String) {
            guard let logger else { return }
            let text = message()
            logger.debug("\(text, privacy: .public)")
        }

        public func error(_ message: @autoclosure () -> String) {
            guard let logger else { return }
            let text = message()
            logger.error("\(text, privacy: .public)")
        }
    }

    public nonisolated let configuration: Configuration

    private let decoder: BonjourTXTDecoder
    private let diagnostics: Diagnostics
    private let browserQueue: DispatchQueue

    private var browser: NWBrowser?
    // Bumped on every start/stop so callbacks queued by a previous NWBrowser can be
    // identified and ignored (a stale callback must not pollute a newer scan).
    private var browserGeneration = 0
    private var browserState: NWBrowser.State = .setup
    private var endpointsByID: [String: BonjourEndpoint] = [:]
    private var endpointContinuations: [UUID: AsyncThrowingStream<[BonjourEndpoint], Error>.Continuation] = [:]
    private var stateContinuations: [UUID: AsyncStream<NWBrowser.State>.Continuation] = [:]
    private var restartTask: Task<Void, Never>?

    public init(
        configuration: Configuration = .init(),
        decoder: BonjourTXTDecoder = .shared,
        diagnostics: Diagnostics = .init(),
        queue: DispatchQueue = DispatchQueue(label: "BonjourDiscoveryActor.browser")
    ) {
        self.configuration = configuration
        self.decoder = decoder
        self.diagnostics = diagnostics
        self.browserQueue = queue
    }

    deinit {
        browser?.cancel()
        restartTask?.cancel()
    }

    public func start() throws {
        guard browser == nil else {
            diagnostics.debug("start() ignored because the browser is already running")
            throw BonjourDiscoveryError.alreadyRunning
        }
        startBrowser()
    }

    public func stop() {
        guard let browser else { return }
        diagnostics.debug("Stopping browser")
        // Invalidate in-flight callbacks from this browser before tearing it down.
        browserGeneration += 1
        browser.cancel()
        self.browser = nil
        restartTask?.cancel()
        restartTask = nil
        browserState = .cancelled
        endpointsByID.removeAll(keepingCapacity: false)
        broadcastState()
        broadcastEndpoints()
        // Terminate subscribers' streams now that scanning has stopped (terminal),
        // so their `for await` loops end cleanly.
        finishEndpointStreams()
        finishStateStreams()
    }

    public func currentEndpoints() -> [BonjourEndpoint] {
        endpointsByID.values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    public func currentState() -> NWBrowser.State {
        browserState
    }

    public func serviceStream() -> AsyncThrowingStream<[BonjourEndpoint], Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<[BonjourEndpoint], Error>.makeStream()
        addEndpointContinuation(continuation, id: id)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeEndpointContinuation(id: id) }
        }
        return stream
    }

    public func stateStream() -> AsyncStream<NWBrowser.State> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<NWBrowser.State>.makeStream()
        addStateContinuation(continuation, id: id)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeStateContinuation(id: id) }
        }
        return stream
    }

    private func startBrowser() {
        diagnostics.debug("Starting browser for service: \(configuration.serviceType)")
        browserGeneration += 1
        let generation = browserGeneration
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: configuration.serviceType, domain: configuration.domain)
        let browser = NWBrowser(for: descriptor, using: configuration.parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleStateUpdate(state, generation: generation) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.handleResults(results, generation: generation) }
        }
        self.browser = browser
        browser.start(queue: browserQueue)
    }

    private func handleResults(_ results: Set<NWBrowser.Result>, generation: Int) {
        // Ignore callbacks from a previous browser (after stop() or a restart) so a stale
        // result can't resurrect endpoints or replace a fresh scan's snapshot.
        guard generation == browserGeneration else { return }
        var next: [String: BonjourEndpoint] = [:]
        for result in results {
            do {
                let endpoint = try BonjourEndpoint(result: result, decoder: decoder)
                next[endpoint.id] = endpoint
            } catch {
                diagnostics.error("Failed to decode endpoint: \(error.localizedDescription)")
            }
        }
        endpointsByID = next
        broadcastEndpoints()
    }

    private func handleStateUpdate(_ state: NWBrowser.State, generation: Int) {
        // Ignore callbacks from a previous browser so a stale state (e.g. an old
        // .cancelled/.failed) can't overwrite the current scan's state.
        guard generation == browserGeneration else { return }
        browserState = state
        broadcastState()
        switch state {
        case .failed(let error):
            // Transient failure: keep subscriber streams open and auto-restart, so both
            // the observable facade and direct endpointStream() consumers recover. The
            // failure is surfaced via the state stream.
            diagnostics.error("Browser failed: \(error.localizedDescription)")
            scheduleRestart()
        case .cancelled:
            diagnostics.debug("Browser cancelled")
        default:
            break
        }
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        guard browser != nil else { return }
        let delay = configuration.retryDelay
        restartTask = Task { [weak self] in
            // Bail out if the sleep is interrupted by cancellation (stop()/deinit),
            // so a cancelled restart never falls through to restarting the browser.
            guard (try? await Task.sleep(until: .now + delay, clock: .continuous)) != nil else { return }
            await self?.performRestartIfNeeded()
        }
    }

    private func performRestartIfNeeded() {
        guard browser != nil else { return }
        stop()
        do {
            try start()
        } catch {
            diagnostics.error("Automatic restart failed: \(error.localizedDescription)")
        }
    }

    private func addEndpointContinuation(_ continuation: AsyncThrowingStream<[BonjourEndpoint], Error>.Continuation, id: UUID) {
        endpointContinuations[id] = continuation
        continuation.yield(currentEndpoints())
    }

    private func removeEndpointContinuation(id: UUID) {
        endpointContinuations.removeValue(forKey: id)
    }

    private func addStateContinuation(_ continuation: AsyncStream<NWBrowser.State>.Continuation, id: UUID) {
        stateContinuations[id] = continuation
        continuation.yield(browserState)
    }

    private func removeStateContinuation(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func broadcastEndpoints() {
        let snapshot = currentEndpoints()
        for continuation in endpointContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func broadcastState() {
        let state = browserState
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

    private func finishEndpointStreams() {
        for continuation in endpointContinuations.values {
            continuation.finish()
        }
        endpointContinuations.removeAll(keepingCapacity: false)
    }

    private func finishStateStreams() {
        for continuation in stateContinuations.values {
            continuation.finish()
        }
        stateContinuations.removeAll(keepingCapacity: false)
    }
}
