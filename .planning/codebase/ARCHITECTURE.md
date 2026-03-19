# Architecture

**Analysis Date:** 2026-03-15

## Pattern Overview

**Overall:** Layered client-server architecture with a separation between CLI management layer and device-side service layer. The device runs a scheduler-based job execution model that synchronizes state with a broker.

**Key Characteristics:**
- CLI and service are separate binaries communicating through brokers (HTTP/Supabase)
- Device-side uses event-driven scheduler for responsive job execution
- State synchronization model where goal state is fetched from broker and containers/firmware are updated to match
- Pluggable broker architecture supporting multiple backend implementations
- Job-based execution model with priorities and runlevels for clean shutdown and state management

## Layers

**CLI Layer:**
- Purpose: Command-line interface for managing devices, fleets, pods, and configurations
- Location: `src/cli/`
- Contains: Command handlers, user-facing UI, broker clients, authentication
- Depends on: Broker implementations, shared constants and utilities
- Used by: End users via command-line invocation

**Service Layer:**
- Purpose: Runs on devices to manage containers, firmware updates, and state synchronization
- Location: `src/service/`
- Contains: Job scheduler, container manager, broker connections, device state
- Depends on: Broker implementations, shared utilities, system services
- Used by: Device runtime environment

**Shared Layer:**
- Purpose: Common utilities and constants used by both CLI and service
- Location: `src/shared/`
- Contains: Version info, server configuration, utilities, JSON diffing logic, patch tools
- Depends on: Third-party packages only
- Used by: Both CLI and service layers

**Broker Layer:**
- Purpose: Communication abstraction between devices and management servers
- Location: `src/cli/brokers/` (CLI side) and `src/service/brokers/` (service side)
- Contains: HTTP broker implementation, Supabase broker implementation, broker interfaces
- Depends on: HTTP client libraries, encryption libraries
- Used by: CLI and service for device-broker communication

## Data Flow

**Device Synchronization Flow (Primary):**

1. **Initialization**: Service starts on device via `run-artemis()` in `src/service/service.toit`
2. **Scheduler Setup**: `Scheduler` created with `Device`, `ContainerManager`, and `BrokerService`
3. **Synchronization Job**: `SynchronizeJob` connects to broker to fetch goal state
4. **Goal Processing**: Compares current device state with goal state from broker
5. **Updates Applied**:
   - Container images downloaded and installed via `ContainerManager`
   - Firmware updates applied via `FirmwareUpdateJob`
   - Device state persisted to storage
6. **Report Back**: Device state and events reported back to broker
7. **Idle/Wait**: Scheduler waits until next job or state change

**CLI Command Flow (Secondary):**

1. User invokes command (e.g., `artemis device update`)
2. CLI command in `src/cli/cmds/` constructs request
3. Request routed through `Artemis` class or `BrokerCli` wrapper
4. API call made through configured broker (HTTP or Supabase)
5. Response returned and formatted for user output

**State Management:**

- Device state stored in `Device` class: current applications, firmware version, configuration
- Goal state received from broker as JSON map comparing containers and firmware
- State reconciliation via `json-diff` logic to compute minimal required changes
- State persistence: Job states serialized before deep sleep, restored on wake

## Key Abstractions

**Job System:**
- Purpose: Abstraction for schedulable, cancellable work units on device
- Examples: `src/service/jobs.toit` (base), `src/service/containers.toit` (container jobs), `src/service/synchronize.toit` (sync job)
- Pattern: Abstract `Job` class with lifecycle (`start`, `stop`, `schedule`). Subclasses implement scheduling logic. Scheduler tracks and runs jobs.

**BrokerConnection Interface:**
- Purpose: Protocol abstraction for device-to-broker communication
- Examples: `src/service/brokers/http/http.toit` (HTTP implementation)
- Pattern: Interface defines methods for fetching goals, downloading images/firmware, reporting state and events. Implementations handle transport specifics.

**ArtemisService Provider:**
- Purpose: Runtime API service for containers to access Artemis capabilities
- Location: `src/service/service.toit` (class `ArtemisServiceProvider`)
- Pattern: Implements Toit service protocol to expose device ID, reboot, container control methods at runtime

**Pod:**
- Purpose: Container image with metadata and specification
- Location: `src/cli/pod.toit` and `src/cli/pod-specification.toit`
- Pattern: Contains container definition, triggers, environment variables, serialized as JSON

**Firmware:**
- Purpose: Device firmware image with versioning and update capability
- Location: `src/cli/firmware.toit` and `src/service/firmware-update.toit`
- Pattern: Firmware identified by version string, downloaded in chunks, verified by SHA256

## Entry Points

**CLI Entry Point:**
- Location: `src/cli/artemis.toit` (main function)
- Triggers: Command-line invocation with arguments
- Responsibilities: Sets up certificate roots, parses root command structure, routes to subcommands

**Service Entry Point:**
- Location: `src/service/service.toit` (function `run-artemis`)
- Triggers: Device boots with Artemis service configured
- Responsibilities: Initializes scheduler, broker, container manager; runs main event loop

**Artemis Server CLI (Device Management):**
- Location: `src/cli/artemis_servers/artemis-server.toit`
- Triggers: CLI needs to communicate with Artemis server API
- Responsibilities: Authenticates user, creates devices, lists SDK/service versions, downloads service images

**Synchronizer Job (Device-side):**
- Location: `src/service/synchronize.toit`
- Triggers: Scheduled by the scheduler based on synchronization intervals
- Responsibilities: Connects to broker, fetches goal state, applies container/firmware updates, reports state

## Error Handling

**Strategy:** Try-catch blocks with graceful degradation. Critical errors trigger reboot or state reset. Network errors retry with backoff.

**Patterns:**
- Broker connection failures: Retried with exponential backoff via synchronization job states (state machine with DISCONNECTED → CONNECTING → CONNECTED states)
- Container download failures: Logged with tags, container marked failed, synchronization continues
- Firmware update failures: Error reported back to broker, device remains in current state
- CLI errors: User-friendly messages via `cli.ui.abort()` or `cli.ui.error()`
- Service errors: Logged with context tags (device ID, version, job name)

## Cross-Cutting Concerns

**Logging:** Uses Toit `log` package. Loggers created with context via `.with-name` to track component (e.g., "scheduler", "containers", "synchronize"). Tags added to log entries for structured context.

**Validation:** Pod specifications validated against schema in `src/cli/pod-specification.toit`. Device names and references validated in CLI command handlers. Configuration validated when loaded.

**Authentication:** User authentication handled by `ArtemisServerCli` class. Credentials cached in local config. Tokens refreshed on demand via `ensure-authenticated` method.

---

*Architecture analysis: 2026-03-15*
