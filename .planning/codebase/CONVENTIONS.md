# Coding Conventions

**Analysis Date:** 2026-03-15

## Naming Patterns

**Files:**
- Kebab-case for file names: `json-diff.toit`, `pod-registry.toit`, `server-config.toit`
- Test files use suffix `-test.toit` or `-test-slow.toit`: `channel-test.toit`, `cmd-pod-delete-test.toit`
- No file extension variations; all source files are `.toit`

**Functions:**
- Kebab-case for function names: `read-all`, `test-open`, `create-pods`, `ensure-authenticated`
- Helper/private functions use underscore suffix: `compute-cache-key_`, `install-root-certificates_`, `generate-envelope-path_`
- Test functions use `test-` prefix: `test-open`, `test-send`, `test-simple`, `test-neutering`
- Command handler functions use verb prefix: `sign-up`, `sign-in`, `create-auth-commands`, `ensure-available-artemis-service`

**Variables:**
- Kebab-case for local variables and parameters: `tmp-dir`, `spec-ids`, `fleet-root`, `organization-id`
- Private instance fields use underscore suffix: `tmp-dir_`, `cache-key_`, `test-ui_`, `ders-already-installed_`
- Constants use SCREAMING-KEBAB-CASE: `DEFAULT-CAPACITY`, `MAGIC-NAME_`, `TEST-ORGANIZATION-UUID`
- UUID variables use `-id` or `-uuid` suffix: `organization-id`, `device-id`, `TEST-ORGANIZATION-UUID`

**Types:**
- PascalCase for class names: `TestExit`, `TestPrinter`, `TestHumanPrinter`, `TestJsonPrinter`, `TestUi`, `TestCli`
- PascalCase for interface names: `Authenticatable`, `BrokerCli`, `ServerConfig`
- Private class fields use underscore suffix: `test-ui_`, `json_`, `quiet_`, `name_`

## Code Style

**Formatting:**
- No explicit formatter detected (no .prettierrc file)
- Consistent indentation of 2 spaces observed throughout codebase
- Line continuations use natural indentation
- Method/function definitions on single line with parameters indented on next lines

**Linting:**
- No explicit linter configuration files detected (no eslint or similar)
- Code follows conventional Toit patterns with consistent style

## Import Organization

**Order:**
1. Standard library imports (system, core)
2. External package imports (cli, encoding, crypto, http, etc.)
3. Relative imports from parent packages (`..` imports)
4. Relative imports from sibling packages (`.` imports)
5. Export declarations

**Examples from codebase:**
```toit
// File: src/cli/cli.toit
import certificate-roots
import cli show *
import core as core
import host.pipe show stderr
import io

import .cmds.auth
import .cmds.config
import .cmds.device

import ..shared.version
```

```toit
// File: src/cli/brokers/broker.toit
import cli show Cli
import host.file
import encoding.json
import net
import uuid show Uuid

import ..auth
import ..config
import .supabase
import .http.base
```

**Path Aliases:**
- Direct imports of modules by name without aliases typically
- Aliasing used when name conflicts or for clarity: `import encoding.json as json-encoding`
- Re-exports using `show *` when module provides public API

## Error Handling

**Patterns:**
- Throw string literals with error descriptions: `throw "Unknown broker type"`
- Use assert for invariant checks: `assert: root-cmd.check; true`
- Try-finally blocks for cleanup operations:
  ```toit
  try:
    block.call tmp-dir
  finally:
    directory.rmdir --recursive tmp-dir
  ```
- Try blocks with exception unwinding for control flow:
  ```toit
  exception = catch --unwind=(: not expect-exit-1 or (not allow-exception and it is not TestExit)):
    artemis-pkg.main args --cli=run-cli
  ```
- Null checks using `if not var_:` pattern

## Logging

**Framework:** `log` standard library module used for structured logging

**Patterns:**
- Logging is sparse in source code, mainly used in service/device code
- No universal logging pattern enforced across codebase
- Print statements used for CLI output via `cli.ui.emit` or `core.print`
- Test output via stdout/stderr captured in TestUi class

## Comments

**When to Comment:**
- Comments document non-obvious behavior and design decisions
- Interfaces and public functions have documentation comments
- Complex logic has inline comments explaining intent
- TODOs marked with `// TODO(author):` pattern

**JSDoc/TSDoc:**
- Not applicable to Toit language
- Block comments using `/**` and `*/` for documentation:
  ```toit
  /**
  Responsible for allowing the Artemis CLI to talk to Artemis services on devices.
  */
  interface BrokerCli implements Authenticatable:
  ```
- Parameter documentation in comments:
  ```toit
  /**
  The block is called with a $DeviceDetailed as argument:
  The block must return a new goal state which replaces the actual goal state.
  */
  update-goal --device-id/Uuid [block] -> none
  ```

## Function Design

**Size:** Functions are typically 5-50 lines, with test functions often longer due to test setup and assertions

**Parameters:**
- Named parameters using `--parameter-name/type` syntax
- Block parameters with `[block]` or `[block/block-type]` syntax
- Required parameters without defaults
- Optional parameters with `?` type modifier: `--email/string?`

**Return Values:**
- Explicit return types in function signatures: `-> string`, `-> List`, `-> none`, `-> bool`
- Functions return values implicitly (last expression)
- Null returns for operations that complete without producing values

**Example patterns:**
```toit
// Function with named parameters and block
update-goal --device-id/Uuid [block] -> none

// Function with optional parameters
constructor --quiet/bool=true --json/bool=false

// Function with list parameters
update-goals --device-ids/List --goals/List -> none

// Helper function returning computed value
cache-key -> string:
  if not cache-key_:
    cache-key_ = base64-lib.encode --url-mode (sha1.sha1 compute-cache-key_)
  return cache-key_
```

## Module Design

**Exports:**
- Explicit export statements: `export Device`
- Modules export types, interfaces, and top-level functions
- Private implementation details use underscore suffix convention

**Barrel Files:**
- Not commonly used; imports are specific and direct
- Relative imports reference exact modules needed

---

*Convention analysis: 2026-03-15*
