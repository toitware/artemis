# Technology Stack

**Analysis Date:** 2026-03-15

## Languages

**Primary:**
- Toit v2.0.0-alpha.190 (development SDK version) - Core application logic, CLI, service, brokers, and tests
- TypeScript - Supabase Edge Functions for broker API endpoints

**Secondary:**
- SQL - Database schemas and migrations for Supabase PostgreSQL
- CMake - Build system configuration
- Bash - Build scripts and development tooling

## Runtime

**Environment:**
- Toit Runtime (custom managed runtime for IoT/embedded systems)
- Deno - Runtime for Supabase Edge Functions (TypeScript)
- PostgreSQL 15 - Database backend

**Package Manager:**
- Toit Package Manager (toit pkg)
- Lockfile: `package.lock` (present in root)

## Frameworks

**Core:**
- Toit Artemis Framework ^0.1.1 - Device and broker management system
- Toit CLI Framework ^2.6.0 - Command-line interface building
- Toit Supabase ^0.3.1 - Supabase client and authentication

**Build/Dev:**
- CMake 3.23+ - Build orchestration
- Ninja - Build executor (used by CMake)
- Supabase CLI - Local development database and edge function management

**Protocols & Networking:**
- Toit HTTP ^2.11.0 - HTTP client and server
- Toit NTP ^1.1.0 - Network Time Protocol for time synchronization
- TLS/HTTPS - Secure communication with root certificate support

## Key Dependencies

**Critical:**
- toit-supabase ^0.3.1 - Supabase client library with authentication and database access
- toit-artemis ^0.1.1 - Core Artemis device management library
- pkg-http ^2.11.0 - HTTP transport layer for broker communication
- toit-cert-roots ^1.11.0 - Root certificates for TLS/HTTPS connections

**Infrastructure:**
- pkg-cli ^2.6.0 - CLI framework for command-line tools
- pkg-fs ^2.3.1 - Filesystem access
- pkg-host ^1.16.2 - Host system integration
- toit-watchdog ^1.4.1 - Watchdog timer functionality
- toit-partition-table-esp32 ^1.4.0 - ESP32 partition table management
- toit-semver ^1.1.0 - Semantic versioning utilities
- pkg-ar ^1.4.1 - Archive handling
- artemis-pkg-copy (local path) - Local artemis package copy

**Development/Tooling:**
- snapshot (local path: tools/snapshot) - Snapshot building utility

## Configuration

**Environment:**
- Toit configuration stored in `~/.config/artemis-dev/config` (configurable via `ARTEMIS_CONFIG`)
- Broker credentials and configuration stored in local config files
- Support for both HTTP and Supabase broker configurations

**Build:**
- `CMakeLists.txt` - Main build configuration
- `package.yaml` - Root package manifest with dependencies
- `Makefile` - Development workflow automation
- `supabase_artemis/supabase/config.toml` - Local Supabase configuration
- `public/supabase_broker/supabase/config.toml` - Broker Supabase configuration

**Build Configuration Files:**
- PostgreSQL version pinned to 15 in `supabase_artemis/supabase/config.toml`
- API schemas: `public`, `storage`, `graphql_public`, `toit_artemis`
- Storage limit: 50MiB per file
- JWT expiry: 3600 seconds (1 hour)

## Platform Requirements

**Development:**
- Toit executable (toit CLI)
- CMake 3.23+
- Ninja build system
- Supabase CLI (for local database development)
- Docker (for Supabase local development)
- GNU Make
- Git

**Supported Hardware:**
- ESP32 (primary embedded target)
- ESP32-QEMU (for testing)
- Host systems (x86_64, ARM)

**Production:**
- Supabase hosting infrastructure (cloud or self-hosted)
- PostgreSQL 15+ database
- Deno runtime (for Edge Functions)

---

*Stack analysis: 2026-03-15*
