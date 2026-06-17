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
    // Caller-supplied token identifying the scan session that owns the current browser. Unlike
    // browserGeneration it is NOT changed by an automatic restart, so the facade can stop exactly
    // the session it means to — and never a newer one that raced in — via stop(ifOwner:).
    private var browserOwner = 0
    // Monotonic per-results-callback sequence (assigned on the serial browser queue) so
    // out-of-order delivery via independent Tasks can be detected and dropped.
    private let resultsSequence = OSAllocatedUnfairLock(initialState: 0)
    private var lastHandledResultsSequence = 0
    // Monotonic per-state-callback sequence (assigned on the serial browser queue) so a state
    // update delivered out of order via independent Tasks can be detected and dropped.
    private let stateSequence = OSAllocatedUnfairLock(initialState: 0)
    private var lastHandledStateSequence = 0
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

    /// Starts the browser, tagging it with a caller-supplied `owner` token that identifies the
    /// scan session. The token survives automatic restarts (so the session can always be stopped)
    /// and lets the caller tear down *only* this session via `stop(ifOwner:)` without affecting a
    /// newer scan that may have replaced it.
    public func start(owner: Int) throws {
        guard browser == nil else {
            diagnostics.debug("start() ignored because the browser is already running")
            throw BonjourDiscoveryError.alreadyRunning
        }
        browserOwner = owner
        startBrowser()
    }

    public func stop() {
        guard let browser else { return }
        diagnostics.debug("Stopping browser")
        // Invalidate in-flight callbacks from this browser before tearing it down.
        browserGeneration += 1
        browser.cancel()
        self.browser = nil
        browserOwner = 0
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

    /// Stops the browser only if the current scan session is still owned by `owner` (i.e. it has
    /// not already been stopped or replaced by a newer scan). The facade uses this both to reap a
    /// browser started by a superseded `startScanning()`, and to ensure a `stopScanning()` whose
    /// `discovery.stop()` was delayed can't tear down a newer scan that started in the meantime.
    public func stop(ifOwner owner: Int) {
        guard browserOwner == owner else { return }
        stop()
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
        // Reset to a fresh starting state so a subscriber to a new scan doesn't first
        // observe the previous scan's lingering .cancelled/.failed state.
        browserState = .setup
        broadcastState()
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: configuration.serviceType, domain: configuration.domain)
        let browser = NWBrowser(for: descriptor, using: configuration.parameters)
        browser.stateUpdateHandler = { [weak self] state in
            // Assign a monotonic sequence on the serial browser queue so the actor can drop
            // state updates that arrive out of order through independent Tasks.
            let sequence = self?.stateSequence.withLock { value -> Int in
                value += 1
                return value
            } ?? 0
            Task { await self?.handleStateUpdate(state, generation: generation, sequence: sequence) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            // Assign a monotonic sequence on the serial browser queue so the actor can
            // drop snapshots that arrive out of order through independent Tasks.
            let sequence = self?.resultsSequence.withLock { value -> Int in
                value += 1
                return value
            } ?? 0
            Task { await self?.handleResults(results, generation: generation, sequence: sequence) }
        }
        self.browser = browser
        browser.start(queue: browserQueue)
    }

    private func handleResults(_ results: Set<NWBrowser.Result>, generation: Int, sequence: Int) {
        // Ignore callbacks from a previous browser (after stop() or a restart) so a stale
        // result can't resurrect endpoints or replace a fresh scan's snapshot.
        guard generation == browserGeneration else { return }
        // Ignore snapshots delivered out of order so an older one can't overwrite newer data.
        guard sequence > lastHandledResultsSequence else { return }
        lastHandledResultsSequence = sequence
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

    private func handleStateUpdate(_ state: NWBrowser.State, generation: Int, sequence: Int) {
        // Ignore callbacks from a previous browser so a stale state (e.g. an old
        // .cancelled/.failed) can't overwrite the current scan's state.
        guard generation == browserGeneration else { return }
        // Ignore state updates delivered out of order through independent Tasks so an older
        // state (e.g. a late .ready arriving after a newer .failed) can't hide the newer one.
        guard sequence > lastHandledStateSequence else { return }
        lastHandledStateSequence = sequence
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
        let generation = browserGeneration
        restartTask = Task { [weak self] in
            // Bail out if the sleep is interrupted by cancellation (stop()/deinit),
            // so a cancelled restart never falls through to restarting the browser.
            guard (try? await Task.sleep(until: .now + delay, clock: .continuous)) != nil else { return }
            await self?.performRestartIfNeeded(generation: generation)
        }
    }

    private func performRestartIfNeeded(generation: Int) {
        // Ignore a stale retry whose browser was already stopped or replaced (the awakened
        // task can outlive a cancel), so it can't tear down a newer scan.
        guard generation == browserGeneration, browser != nil else { return }
        diagnostics.debug("Restarting browser after failure")
        // Restart-specific teardown: cancel the failed browser and clear its results, but
        // do NOT finish subscriber streams (unlike stop()), so the observable facade and
        // direct endpointStream() consumers keep their subscription across the restart.
        browserGeneration += 1
        browser?.cancel()
        browser = nil
        endpointsByID.removeAll(keepingCapacity: false)
        broadcastEndpoints()
        startBrowser()
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
        // Only replay the current state if a browser is actually running. After stop(),
        // browserState lingers as .cancelled; replaying that to a brand-new scan's subscriber
        // would surface the previous scan's terminal state before startBrowser() broadcasts
        // .setup. When no browser is running yet, the imminent startBrowser() broadcast delivers
        // the first state, so a fresh subscriber never observes a stale one.
        if browser != nil {
            continuation.yield(browserState)
        }
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
