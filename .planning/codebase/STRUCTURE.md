# Codebase Structure

**Analysis Date:** 2026-03-15

## Directory Layout

```
artemis/
├── src/                           # Main source code (Toit)
│   ├── cli/                       # CLI tool
│   │   ├── artemis.toit          # Main entry point
│   │   ├── cli.toit              # CLI root command setup
│   │   ├── cmds/                 # Command implementations
│   │   ├── artemis_servers/      # Artemis server API client
│   │   ├── brokers/              # Broker client implementations
│   │   ├── utils/                # CLI utilities
│   │   └── *.toit                # Core CLI modules (config, device, fleet, pod, etc.)
│   ├── service/                  # Device-side runtime service
│   │   ├── service.toit          # Main service entry point
│   │   ├── scheduler.toit        # Job scheduler
│   │   ├── containers.toit       # Container management
│   │   ├── brokers/              # Broker connection implementations
│   │   ├── jobs.toit             # Base job abstraction
│   │   ├── synchronize.toit      # State synchronization job
│   │   ├── firmware-update.toit  # Firmware update logic
│   │   ├── device.toit           # Device state representation
│   │   ├── storage.toit          # Persistent storage
│   │   └── *.toit                # Supporting modules
│   └── shared/                   # Shared code (CLI and service)
│       ├── version.toit          # Version constants
│       ├── constants.toit        # Global constants (commands)
│       ├── server-config.toit    # Broker configuration
│       ├── json-diff.toit        # JSON difference computation
│       └── utils/                # Shared utilities
├── tests/                         # Test files
│   ├── *-test.toit              # Individual test files
│   ├── gold/                    # Expected output files for tests
│   └── spec_extends_tests/      # Test extensions
├── supabase_artemis/             # Supabase edge functions and migrations
│   └── supabase/
│       ├── functions/           # Edge function code
│       ├── migrations/          # Database migrations
│       └── snippets/            # Code snippets
├── public/                        # Public documentation and schemas
│   ├── docs/                    # Documentation
│   ├── examples/                # Example configurations
│   └── schemas/                 # JSON schemas for pod specs
├── tools/                         # Utility tools
│   ├── http_servers/            # Test HTTP servers
│   ├── service_image_uploader/  # Upload service images
│   ├── snapshot/                # Snapshot tool
│   ├── lan_ip/                  # LAN IP discovery
│   └── windows_installer/       # Windows installer
├── auth/                          # Authentication utilities
├── benchmarks/                    # Performance benchmarks
├── recovery/                      # Recovery tools
├── artemis-pkg-copy/             # Temporary copy of artemis package
├── build/                         # CMake build directory (generated)
├── .github/                       # GitHub workflows and configuration
└── .planning/                     # GSD planning documents
```

## Directory Purposes

**src/cli:**
- Purpose: Command-line interface for managing devices, fleets, pods, and organizations
- Contains: Entry point, command handlers, broker clients, configuration management
- Key files: `artemis.toit` (CLI orchestrator), `cli.toit` (command structure), `cmds/` (individual commands)

**src/service:**
- Purpose: Device-side runtime that manages containers and synchronization
- Contains: Scheduler, job implementations, container/firmware management, broker connections
- Key files: `service.toit` (entry point), `scheduler.toit` (job orchestration), `containers.toit` (app management), `synchronize.toit` (state sync)

**src/shared:**
- Purpose: Code shared between CLI and service layers
- Contains: Version strings, command constants, server configuration, utilities
- Key files: `version.toit` (versioning), `constants.toit` (command codes), `server-config.toit` (broker config)

**src/cli/brokers:**
- Purpose: CLI-side broker implementations for communicating with servers
- Contains: HTTP broker, Supabase broker, request/response handling
- Key files: `broker.toit` (interface), `http/base.toit` (HTTP implementation), `supabase/supabase.toit` (Supabase implementation)

**src/service/brokers:**
- Purpose: Device-side broker implementations for communicating with management servers
- Contains: Connection handling, goal state fetching, state reporting
- Key files: `broker.toit` (interface), `http/http.toit` (HTTP implementation)

**tests:**
- Purpose: Test suite for CLI commands and core functionality
- Contains: Command output tests, synchronization tests, JSON diff tests
- Key files: `*-test.toit` (individual tests), `gold/` (expected outputs for verification)

**supabase_artemis:**
- Purpose: Supabase backend infrastructure (database and edge functions)
- Contains: Database schema migrations, serverless functions for API endpoints
- Key files: `migrations/` (database schema), `functions/` (API endpoints)

## Key File Locations

**Entry Points:**
- `src/cli/artemis.toit`: CLI main entry point and version handling
- `src/service/service.toit`: Device service entry point, exports `run-artemis` function
- `src/cli/cli.toit`: CLI command structure and routing

**Configuration:**
- `src/shared/server-config.toit`: Broker connection configuration (HTTP/Supabase)
- `src/cli/config.toit`: User configuration management (profiles, brokers, cache)
- `package.yaml`: Toit package dependencies

**Core Logic:**
- `src/service/scheduler.toit`: Job scheduler that drives device operation
- `src/service/containers.toit`: Container lifecycle management
- `src/service/synchronize.toit`: State synchronization with broker
- `src/cli/artemis.toit`: Device manager from CLI perspective
- `src/cli/fleet.toit`: Fleet management operations

**Testing:**
- `tests/cmd-fleet-status-test.toit`: Fleet command test
- `tests/synchronizer.toit`: Synchronization logic test
- `tests/gold/`: Expected command output files

## Naming Conventions

**Files:**
- Toit source files: `lowercase-with-hyphens.toit`
- Executable or tool files: `lowercase-with-hyphens` (no extension)
- Test files: `*-test.toit` or `*_test.toit` (ending in -test or _test)
- Generated files: `*.generated.toit` or `version.toit.in` (template)

**Directories:**
- Module directories: `lowercase-with-hyphens/` (e.g., `artemis_servers`, `brokers`)
- Command implementations: Inside `cmds/` with command name (e.g., `device.toit`, `fleet.toit`)
- Test support: `gold/` for expected outputs, `spec_extends_tests/` for test utilities

**Classes:**
- PascalCase for classes: `ContainerManager`, `SynchronizeJob`, `ArtemisServerCli`
- Abstract base classes: `Job`, `TaskJob`, `BrokerConnection`, `BrokerService`

**Functions/Methods:**
- snake-case with hyphens: `run-artemis`, `connect-network_`, `ensure-authenticated`
- Private methods: trailing underscore `_` before method name (e.g., `connected-artemis-server_`)
- Getter methods: simple names (e.g., `runlevel`, `is-running`)

**Constants:**
- ALL-CAPS with hyphens: `RUNLEVEL-NORMAL`, `STATE-SYNCHRONIZED`, `COMMAND-UPDATE-GOALS_`
- Maps of constants: `ARTEMIS-COMMAND-TO-STRING`, `BROKER-COMMAND-TO-STRING`

**Variables:**
- snake-case with hyphens: `max-offline-time`, `job-states`, `images_`
- Field names: lowercase: `name`, `id`, `tasks_`

## Where to Add New Code

**New CLI Command:**
1. Create handler in `src/cli/cmds/` (e.g., `src/cli/cmds/new-command.toit`)
2. Implement `create-new-command-commands() -> List` function
3. Import and call from `src/cli/cli.toit` in main function
4. Add command tests to `tests/` with corresponding gold output in `tests/gold/`

**New Service Job:**
1. Create in `src/service/` (e.g., `src/service/new-job.toit`)
2. Extend `Job` or `TaskJob` abstract class from `src/service/jobs.toit`
3. Implement required methods: `is-running`, `schedule`, `start`, `stop`
4. Import and add to scheduler via `scheduler.add-job` in `src/service/service.toit`
5. Store/restore state via `scheduler-state` property if needed

**New Broker Implementation:**
- CLI side: Create in `src/cli/brokers/` (e.g., `src/cli/brokers/custom/custom.toit`)
- Service side: Create in `src/service/brokers/` (e.g., `src/service/brokers/custom/custom.toit`)
- Implement `BrokerConnection` interface
- Add factory method in broker constructor in respective layer
- Update configuration to support new broker type

**Shared Utilities:**
- General utilities: `src/shared/utils/utils.toit` or `src/shared/utils/specific-util.toit`
- Constants: Add to `src/shared/constants.toit`
- Protocols: Define interfaces in appropriate module or new dedicated file

**Tests:**
- New test file: `tests/my-feature-test.toit`
- Expected output: `tests/gold/cmd-my-feature-test/` (directory with output files)
- Import test utilities from existing test files as reference

## Special Directories

**build/**
- Purpose: CMake build output directory (generated at build time)
- Generated: Yes
- Committed: No (in .gitignore)
- Contains: Compiled binaries, build artifacts, test executables

**tests/gold/**
- Purpose: Expected output files for command tests (golden files)
- Generated: No (manually curated)
- Committed: Yes
- Usage: Tests compare actual output against files in this directory

**supabase_artemis/supabase/**
- Purpose: Supabase infrastructure as code
- Generated: No
- Committed: Yes
- Structure: `migrations/` (numbered SQL files), `functions/` (edge functions)

**.packages/**
- Purpose: Cached package dependencies (managed by Toit package manager)
- Generated: Yes (via `toit pkg` commands)
- Committed: No (in .gitignore)

**artemis-pkg-copy/**
- Purpose: Temporary copy of the Artemis package API from public repository
- Generated: No (static copy)
- Committed: Yes
- Status: Marked for deletion when public package API stabilizes

---

*Structure analysis: 2026-03-15*
