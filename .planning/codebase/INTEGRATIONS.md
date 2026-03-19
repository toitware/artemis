# External Integrations

**Analysis Date:** 2026-03-15

## APIs & External Services

**Supabase (Primary Backend):**
- Service: Supabase Backend-as-a-Service (PostgREST API, Auth, Storage)
  - SDK/Client: toit-supabase ^0.3.1 (`github.com/toitware/toit-supabase`)
  - Authentication: JWT tokens with anon key
  - Environment variables: `SUPABASE_URL`, `SUPABASE_ANON_KEY`
  - Configuration: `ServerConfigSupabase` class in `src/shared/server-config.toit`
  - Usage locations:
    - `src/cli/brokers/supabase/supabase.toit` - CLI broker implementation
    - `src/cli/artemis_servers/supabase/supabase.toit` - Artemis server API client
    - `src/cli/utils/supabase.toit` - Utility functions

**HTTP Brokers (Alternative Backend):**
- Service: Custom Toit HTTP broker protocol
  - SDK/Client: pkg-http ^2.11.0 (`github.com/toitlang/pkg-http`)
  - Configuration: `ServerConfigHttp` class in `src/shared/server-config.toit`
  - Usage locations:
    - `src/cli/brokers/http/base.toit` - HTTP broker implementation
    - `src/cli/artemis_servers/http/base.toit` - HTTP server client
    - `src/service/brokers/http` - Device-side HTTP broker

**NTP Time Service:**
- Service: Network Time Protocol for system time synchronization
  - SDK/Client: pkg-ntp ^1.1.0 (`github.com/toitlang/pkg-ntp`)
  - Purpose: Ensuring accurate time on devices
  - Usage: Time-critical device operations

## Data Storage

**Databases:**
- Provider: Supabase (PostgreSQL 15)
  - Connection: Supabase REST API over HTTP/HTTPS
  - Client: toit-supabase ^0.3.1
  - Schemas exposed:
    - `public` - Main public schema
    - `storage` - File storage metadata
    - `graphql_public` - GraphQL API schema
    - `toit_artemis` - Artemis-specific schema
  - Configuration file: `supabase_artemis/supabase/config.toml`
  - Migrations: Located in `supabase_artemis/supabase/migrations/`
  - Seed data: `supabase_artemis/supabase/seed.sql`

**File Storage:**
- Supabase Storage buckets
  - Access: Through Supabase REST API
  - Size limit: 50 MiB per file
  - Support for public and private buckets
  - Referenced in Edge Function `b/index.ts` for firmware and image uploads/downloads

**Caching:**
- Configuration caching: Local filesystem in `~/.cache/artemis/` (device-specific)
- Server connection caching uses cache keys based on host/port/path hashing

## Authentication & Identity

**Auth Provider:**
- Supabase Auth (Email/Password and OAuth providers)
  - Implementation: Supabase authentication service
  - Methods supported:
    - Email/password signup and sign-in (`sign-up`, `sign-in` with credentials)
    - OAuth provider sign-in (Google, GitHub, etc.) - via Supabase OAuth providers
  - JWT token-based authentication with 1-hour expiry (configurable)
  - Session management: Browser-based with redirect URL handling
  - OAuth Redirect URL: `https://toit.io/auth` for production

**Authorization:**
- Row-Level Security (RLS) policies in PostgreSQL
- Organization-based access control
- Device ownership verification through organization membership
- Role-based access: User, Member, and organization-specific roles

## Monitoring & Observability

**Error Tracking:**
- Not detected as a dedicated service integration
- Error handling through application logging

**Logs:**
- Console logging via `import log` in Toit code
- Supabase Edge Function logs available through Supabase dashboard
- Local development logs directed to console

## CI/CD & Deployment

**Hosting:**
- Supabase Cloud (primary) - API and database hosting
- Self-hosted option supported for local development and testing
- Public broker instance: `supabase.co` domain (e.g., `ezxwpyeoypvnnldpdotx.supabase.co`)
- Private Artemis instance: `artemis-api.toit.io`

**Deployment:**
- Edge Functions deployed via Supabase CLI: `supabase functions deploy`
- Database migrations via Supabase CLI: `supabase db push`
- Service images managed through `tools/service_image_uploader/uploader.toit`

**Build/Test Infrastructure:**
- Local Supabase instances: `make start-supabase` / `make start-supabase-no-config`
- Test targets:
  - Unit tests: `make test`
  - Serial tests: `make test-serial`
  - Supabase integration tests: `make test-supabase`

## Environment Configuration

**Required env vars:**
- `SUPABASE_URL` - Supabase project URL (from config)
- `SUPABASE_ANON_KEY` - Supabase anonymous key for public access
- `ARTEMIS_CONFIG` - Path to local artemis configuration (default: `~/.config/artemis-dev/config`)
- `TOIT_PKG_AUTO_SYNC` - Whether to auto-sync packages (CMake option, ON by default)
- `DEFAULT_SDK_VERSION` - SDK version for compilation
- `ARTEMIS_GIT_VERSION` - Version string for builds (auto-computed from git)

**Test Environment Vars:**
- `ARTEMIS_HOST` - Artemis server host (production: `artemis-api.toit.io`)
- `ARTEMIS_ANON` - Anonymous JWT token for Artemis server
- `ARTEMIS_TEST_HOST` - Test Supabase instance host
- `ARTEMIS_TEST_ANON` - Test Supabase instance anonymous key

**Secrets location:**
- `.env` files (not committed) - Development secrets
- Supabase project settings - Production secrets
- Makefile JWT tokens (test credentials only, not for production)

## Webhooks & Callbacks

**Incoming:**
- Supabase Edge Function endpoint: `/functions/v1/b`
  - POST endpoint receiving binary-encoded commands
  - Commands handled:
    - Device goal updates (`COMMAND_UPDATE_GOAL_`)
    - Device state reporting (`COMMAND_REPORT_STATE_`)
    - Event reporting (`COMMAND_REPORT_EVENT_`)
    - Firmware/image downloads (`COMMAND_DOWNLOAD_`, `COMMAND_DOWNLOAD_PRIVATE_`)
    - Pod registry operations (10+ commands for pod management)
  - Authentication: JWT Bearer token in Authorization header or anon key

**Outgoing:**
- Device -> Broker API calls for:
  - State synchronization
  - Event reporting
  - Goal fetching
  - Firmware/image downloading
- No webhook-style callbacks to external systems detected

## Data Formats

**Communication Protocols:**
- Binary protocol for device-broker communication (command-based)
  - Command byte followed by JSON or binary payload
  - Handled in Edge Function: `supabase_artemis/supabase/functions/b/index.ts`
  - HTTP request body contains binary command + payload

**REST API:**
- PostgREST API for database table operations
- supabase.rpc() for stored procedure calls
- Supabase Storage API for file operations

**Serialization:**
- JSON for REST API payloads
- Binary/ArrayBuffer for firmware and image data
- Base64 encoding for certificate storage and transmission

---

*Integration audit: 2026-03-15*
