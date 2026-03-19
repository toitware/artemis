# Testing Patterns

**Analysis Date:** 2026-03-15

## Test Framework

**Runner:**
- CMake-based test runner using ctest
- Toit language runtime executes tests via `toit run`
- Config: `/home/flo/work/artemis/tests/CMakeLists.txt`

**Assertion Library:**
- `expect` standard library module for assertions
- Provides functions like `expect-equals`, `expect-null`, `expect-throw`, `expect-bytes-equal`, `expect-identical`

**Run Commands:**
```bash
make test              # Run all tests
make test-serial       # Run serial tests only
make test-supabase     # Run Supabase-specific tests
```

CMake test execution:
```bash
cd build && ninja check              # Run all tests
cd build && ninja check_serial       # Serial tests
cd build && ninja check_supabase     # Supabase tests
```

## Test File Organization

**Location:**
- Tests located in `/home/flo/work/artemis/tests/` directory
- Co-located with main source but in separate `tests` directory
- Test files live at same hierarchy level as source modules

**Naming:**
- Pattern: `*-test.toit` for regular tests
- Pattern: `*-test-slow.toit` for slow/long-running tests
- Pattern: `serial-*` for tests that must run sequentially
- Examples: `channel-test.toit`, `cmd-pod-delete-test.toit`, `supabase-artemis-broker-policies-test.toit`

**Structure:**
```
tests/
├── *-test.toit           # Standard unit/integration tests
├── *-test-slow.toit      # Slow tests with longer timeouts
├── serial-*.toit         # Serial tests (resource locks)
├── gold/                 # Gold files for CLI output comparison
├── utils.toit            # Test utilities and fixtures
├── CMakeLists.txt        # Test configuration
└── .packages/            # Vendored dependencies
```

## Test Structure

**Suite Organization:**

Tests use a `main` entry point that spawns task(s) and may install/uninstall service providers:

```toit
// File: tests/channel-test.toit
main:
  provider := TestServiceProvider
  provider.install
  spawn:: test
  provider.uninstall --wait

test:
  test-open "small" 32 * 1024
  test-open "medium" 64 * 1024
  3.repeat: test-simple "fisk"
  test-neutering "hest"
  test-full "fisk"
```

**Patterns:**

1. **Setup/Teardown:**
   - `main` function handles initialization
   - `spawn::` for concurrent test tasks
   - Service provider `install`/`uninstall` for resource management
   - Try-finally blocks for cleanup:
     ```toit
     try:
       // test code
       list.do: channel.send it
     finally:
       channel.close
     ```

2. **Assertion Pattern:**
   ```toit
   expect-equals expected actual
   expect-null value
   expect-bytes-equal expected-bytes actual-bytes
   expect-throw "ERROR_MESSAGE": function-call
   expect-identical obj1 obj2
   ```

3. **CLI Test Pattern (from utils.toit):**
   ```toit
   run-gold test-name description args --ignore-spacing=false --expect-exit-1=false
   ```
   Compares CLI output against gold files stored in `gold/` directory.

4. **Test Helpers:**
   ```toit
   with-tmp-directory [block]           // Create temp directory for test
   with-tmp-config-cli [block]          // Create test CLI with config
   with-fleet [block]                   // Fleet testing context
   with-server [block]                  // Server testing context
   ```

## Mocking

**Framework:** Manual mocking using test doubles and custom implementations

**Patterns:**

1. **Test Doubles:**
   ```toit
   // From tests/utils.toit
   class TestExit:

   class TestPrinter extends cli-pkg.Printer:
     print_ str/string:
       test-ui_.stdout += "$str\n"

   class TestUi extends cli-pkg.Ui:
     stdout/string := ""
     stderr/string := ""
     quiet_/bool
   ```

2. **Service Provider Mocking:**
   ```toit
   provider := TestServiceProvider
   provider.install
   spawn:: test
   provider.uninstall --wait
   ```

3. **Capturing Output:**
   ```toit
   ui := TestUi --quiet=quiet --json=json
   run-cli := cli.with --ui=ui
   // Run code that uses ui
   output := ui.stdout
   ```

**What to Mock:**
- CLI output and printing (use TestUi)
- Service providers for isolated component testing
- File system operations (use temporary directories)
- External HTTP/Supabase servers (pre-configured with test fixtures)

**What NOT to Mock:**
- Core language features
- Standard library functions
- Data structures (ByteArray, List, Map)
- File I/O when actual files needed for integration tests

## Fixtures and Factories

**Test Data:**

Constants and fixture creation in `tests/utils.toit`:

```toit
/** test@example.com is an admin of the $TEST-ORGANIZATION-UUID. */
TEST-EXAMPLE-COM-EMAIL ::= "test@example.com"
TEST-EXAMPLE-COM-PASSWORD ::= "password"
TEST-EXAMPLE-COM-UUID ::= Uuid.parse "f76629c5-a070-4bbc-9918-64beaea48848"
TEST-EXAMPLE-COM-NAME ::= "Test User"

TEST-ORGANIZATION-NAME ::= "Test Organization"
TEST-ORGANIZATION-UUID ::= Uuid.parse "4b6d9e35-cae9-44c0-8da0-6b0e485987e2"

TEST-DEVICE-UUID ::= Uuid.parse "eb45c662-356c-4bea-ad8c-ede37688fddf"
TEST-POD-UUID ::= Uuid.parse "0e29c450-f802-49cc-b695-c5add71fdac3"
```

**Factory Functions:**

```toit
// Create test CLI with temporary config
with-tmp-config-cli [block]:
  with-tmp-directory: | directory |
    config-path := "$directory/config"
    app-name := "artemis-test"
    config := cli-pkg.Config --app-name=app-name --path=config-path --data={:}
    cli := cli-pkg.Cli app-name --config=config
    block.call cli

// Create pods for testing
create-pods name/string fleet/TestFleet --count/int -> List:
  spec := """
    { "$schema": "https://toit.io/...", "name": "$name", ... }
    """
  spec-path := "$fleet.fleet-dir/$(name).json"
  write-blob-to-file spec-path spec
  count.repeat:
    fleet.run ["pod", "upload", spec-path]
  return [description-id, spec-ids]
```

**Location:**
- Test utilities and fixtures in `tests/utils.toit`
- Test data constants defined at module level
- Fleet testing utilities in TestFleet class

## Coverage

**Requirements:** Not detected; no coverage enforcement found in configuration

**View Coverage:** Not applicable; Toit test framework does not expose coverage metrics

## Test Types

**Unit Tests:**
- Scope: Individual functions and small modules
- Approach: Direct function calls with assertions
- Example: `test-open`, `test-send` in `channel-test.toit`
- Pattern: Parameterized helpers that run multiple scenarios

**Integration Tests:**
- Scope: Multiple components interacting (CLI + server + broker)
- Approach: Full command execution with temporary servers
- Example: `cmd-pod-delete-test.toit`, broker policy tests
- Pattern: Use `with-fleet`, `with-server` context managers
- Configuration via `// ARTEMIS_TEST_FLAGS:` comments in test file

**E2E Tests:**
- Framework: CMake-based with test flags for different server configurations
- Patterns:
  - `// ARTEMIS_TEST_FLAGS: ARTEMIS` - requires Artemis server
  - `// ARTEMIS_TEST_FLAGS: BROKER` - requires broker
  - Multiple test variants per file with different flags
- Execution: Tests run with different server/broker combinations via CMake

**Resource Locks:**
- Tests that need exclusive resources use CMake resource locks
- Lock names: `artemis_server`, `broker`, `artemis_broker`, `serial`
- Supabase tests automatically get locks when they use supabase flags

## Common Patterns

**Async Testing:**

Concurrency via `spawn::` for parallel task execution:

```toit
main:
  provider.install
  spawn:: test          // Spawn test as concurrent task
  provider.uninstall --wait
```

**Error Testing:**

```toit
// Test that error is thrown with specific message
expect-throw "OUT_OF_RANGE: 209 > 200":
  channel.acknowledge 209

// Test that specific exception type is thrown
expect-throw "ALREADY_IN_USE":
  // code that throws
```

**Parameterized Tests:**

Test helper functions called with different parameters:

```toit
test-open "small" 32 * 1024
test-open "medium" 64 * 1024
test-open "large" 512 * 1024

test-neutering "hest"
[1, 2, 5, 127, 128, 129, 512, 1024, 3000].do:
  test-neutering topic it
```

**Gold File Tests:**

CLI output comparison against golden files:

```toit
run-gold "BAA-delete-pod-revision"
    "Delete a pod by revision"
    [
      "pod", "delete", "$pod1-name#2"
    ]

// Compares output to gold/gold-dir-name/BAA-delete-pod-revision.txt
// Updates gold files if UPDATE_GOLD=1 environment variable set
```

**Test Timeouts:**

Set via CMake based on test pattern:
- Default: `200` seconds
- Slow tests (`*-test-slow.toit`): `300` seconds
- Serial tests (`serial-*`): `1000` seconds
- QEMU tests (`qemu-*`): `300` seconds

---

*Testing analysis: 2026-03-15*
