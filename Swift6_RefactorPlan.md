# BonjourPico Swift 6.2 Redesign Plan

## Suggestions and Considerations
- Document minimum supported platforms and toolchain (e.g., Xcode 16+, Swift 6.2, iOS 17.4 / macOS 14.4 or newer) so adopters understand compatibility and migration expectations.
- Clarify optional tooling scope: call out that CI is intentionally deferred while still noting recommended local commands (swift build/test, SwiftFormat/SwiftLint) when they are introduced.
- Flesh out the SwiftUI integration contract, including lifecycle semantics (auto-start/stop, preview support via simulated endpoints) and the property-wrapper/environment story so consumers can wire it in confidently.
- Provide an upgrade checklist mapping existing BonjourPico APIs to the new actor-based layers, highlighting async/await adoption and any namespace changes for smoother migrations.

## Original Proposal

### Reimagining BonjourPico for Swift 6.2

Below is how I would architect a fresh Swift 6.2 version of BonjourPico so that it is idiomatic, concurrency-safe, and delightful to consume from SwiftUI.

---

#### 1. Goals & Principles

1. **Explicit concurrency** – no unsafe shared mutable state; everything goes through actors or `@MainActor`.
2. **SwiftUI-first ergonomics** – ship a view-model style wrapper and supported modifiers so users can drop it into a `SwiftUI` app with minimal boilerplate.
3. **Modern Network framework usage** – continue to use `NWBrowser` and friends but wrap them in async abstractions.
4. **Composable API layers** – separate the low-level discovery logic from the presentation layer.
5. **Robust testability** – abstract dependencies to inject mock browsers.
6. **Documentation & samples** – give developers a cookbook of patterns (imperative, async stream, SwiftUI).

---

#### 2. Package Layout

```
Sources/
 ├── BonjourDiscoveryCore   (internal target)
 │    ├── BonjourDiscoveryActor.swift
 │    ├── BonjourEndpoint.swift
 │    └── BonjourTXTDecoder.swift
 ├── BonjourPico            (public target)
 │    ├── BonjourPico.swift
 │    ├── BonjourPicoViewModel.swift
 │    ├── BonjourPicoError.swift
 │    └── Localization/
 │         └── Localizable.xcstrings
 └── Support/
      └── Diagnostics.swift (logging/helpers)
```

- **`BonjourDiscoveryCore`** encapsulates the raw `Network` framework usage.
- **`BonjourPico`** exposes the high-level public API, SwiftUI helpers, and domain models.
- **Support** holds shared utilities.

---

#### 3. Core Discovery Layer

##### `BonjourDiscoveryActor`
```swift
public actor BonjourDiscoveryActor {
    public struct Configuration {
        public var serviceType: String = "_pico._tcp"
        public var domain: String = "local."
        public var parameters: NWParameters = .tcp
    }

    public nonisolated let configuration: Configuration

    public init(configuration: Configuration = .init(), logger: Logger = .default)

    public func start() async throws
    public func stop()
    public func serviceStream() -> AsyncThrowingStream<[BonjourEndpoint], Error>
}
```

*Responsibilities*:
- Own the `NWBrowser`.
- Emit deduplicated, sorted `BonjourEndpoint` arrays through an `AsyncThrowingStream`.
- Maintain TXT record cache in actor-isolated dictionaries.
- Apply automatic retry/backoff on transient `.failed` states.
- Optionally expose diagnostics via a structured logging API.

##### `BonjourEndpoint` model
- Immutable, `Sendable`, with typed fields: `id`, `name`, `hostName`, `ipAddresses: [String]`, `port: UInt16`, `txtRecord: [String: Data]`.
- Provide computed helpers (e.g., `.displayName`, `.resolvedInterface`).

##### `BonjourTXTDecoder`
- Utility to decode `NWBrowser.Result.Metadata.bonjour` records and map them into typed keys.
- Allows mocking for tests.

---

#### 4. Public Facing Layer

##### `BonjourPico` façade (async API)
```swift
@MainActor
public final class BonjourPico {
    public var endpoints: [BonjourEndpoint] { get async }
    public var isScanning: Bool { get async }
    public var state: ScanState { get async }

    public func startScanning() async throws
    public func stopScanning()
    public func streamEndpoints() -> AsyncThrowingStream<[BonjourEndpoint], Error>
}
```

- Wraps the actor, handles bridging onto the main actor.
- Maintains a `Task` that listens to `serviceStream()` and updates `@Published` / `Observation` state.

##### SwiftUI Integration

1. **`BonjourPicoViewModel`**
   ```swift
   @MainActor @Observable
   public final class BonjourPicoViewModel {
       public var endpoints: [BonjourEndpoint] = []
       public var isScanning = false
       public var error: BonjourPicoError?
       public func startScanning()
       public func stopScanning()
   }
   ```

2. **Property Wrapper / Environment Key**
   - `@Environment(\.bonjourPico)` to provide a shared view model.
   - `View.bonjourPico()` modifier to inject and auto-start scanning when a view appears.

3. **Sample SwiftUI View**
   - Provided in an updated example app showing best practices (`@StateObject var browser = BonjourPicoViewModel()` etc.).

---

#### 5. Errors & Diagnostics

- **`BonjourPicoError`** public enum with cases such as `.missingTXTKey(String)`, `.browserFailed(NWError)`, `.authorizationDenied`.
- Conform to `LocalizedError` with localizable strings.
- Provide a structured logging sink to integrate with OSLog.

---

#### 6. Concurrency Strategy

- Strict Swift 6.2 concurrency checking.
- All mutable states (endpoint cache, NWBrowser state) live inside `BonjourDiscoveryActor`.
- `BonjourPico` and `BonjourPicoViewModel` are `@MainActor` classes, bridging actor outputs to the UI.
- `AsyncStream` surfaces asynchronous sequences; SwiftUI view model subscribes using `Task(priority:)` inside `init()` and cancels in `deinit`.

---

#### 7. Testing Approach

1. **Core Tests** – Inject a mock `BrowserClient` protocol into `BonjourDiscoveryActor` to simulate added/removed endpoints.
2. **Model Tests** – Validate TXT record decoding, equality, `Sendable`.
3. **SwiftUI Snapshot Tests** – Use `ViewInspector` (if desired) or concurrency tests verifying updates happen on `@MainActor`.
4. **Concurrency Tests** – Build with `-strict-concurrency=complete` to guarantee actor isolation.

---

#### 8. Toolchain & Build

- `Package.swift` header: `// swift-tools-version: 6.2`
- Platforms: `.iOS(.v17_4)`, `.macOS(.v14_4)`, `.tvOS(.v17_4)`, `.visionOS(.v1_2)` (adjust based on final Xcode requirements).
- Compiler flags:
  ```swift
  swiftSettings: [
      .enableExperimentalFeature("StrictConcurrency"),
      .unsafeFlags(["-warn-concurrency"])
  ]
  ```
- CI pipeline runs: `swift build`, `swift test`, documentation generation (`swift package generate-documentation`), SwiftFormat/SwiftLint if adopted.

---

#### 9. Documentation & Examples

- Expanded README with:
  - Quick-start using async/await.
  - SwiftUI integration snippet.
  - Info.plist configuration table.
  - Troubleshooting section (permissions, local network prompts).
- DocC catalog describing discovery lifecycle, error cases, concurrency expectations.

---

#### 10. Extensibility

- Support configuration for custom service types.
- Allow plugging custom TXT record decoders (e.g., `BonjourEndpoint.Metadata` generics).
- Optional feature flag target for simulated endpoints (useful in SwiftUI previews).

---

**In short:** isolate Bonjour networking in a dedicated actor, expose async-first APIs, ship a SwiftUI-focused view model, and enforce Swift 6 concurrency habits throughout. This structure keeps the low-level network details testable and separate from UI concerns, while providing a frictionless experience for app developers adopting Swift 6.2 and the Observation framework.
