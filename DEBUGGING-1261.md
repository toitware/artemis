# PR #1261 CI Investigation

## Current state

- The temporary runtime and HTTP instrumentation has been removed.
- The canceled-subprocess-wait/QEMU teardown fix remains committed.
- The HTTP slowdown is a Linux 6.17 TCP receive-buffer regression, fixed
  upstream by `026dfef287c0`, rather than an Artemis, pkg-http, or Toit GC bug.
- Linux CI is temporarily pinned to `ubuntu-22.04` (Linux 6.8) until the
  `ubuntu-latest` hosted runner moves to a kernel containing the upstream fix.
- `pkg-http` is updated to the latest 2.15.0 release; its recent
  stale-connection retry change is unrelated to the receive-buffer failure.
- `ROADMAP.md` remains untouched.

## Serial tests

The serial rerun passed all six hardware tests after approximately 24 minutes. There is no observed serial regression in PR #90 or PR #91.

## Intermittent HTTP upload stall

The large-upload stall was traced to Linux regression `1d2fbaad7cd8` (`tcp:
stronger sk_rcvbuf checks`). On the GitHub-hosted Linux 6.17 runner, the final
23.4 MB loopback request could arrive as a large skb before the server task
started reading it. The regressed receive-memory check called
`tcp_clamp_window`, and repeated arrivals ratcheted `SO_RCVBUF` down:

```text
184190 -> 65472 -> 30656 -> 18368 bytes
```

The socket drop counter rose at each transition. The sender then became
receive-window limited and advanced on the roughly 200 ms retransmission
timer. The configured TCP window clamp stayed high, but the socket memory
budget could no longer autotune upward.

GC is not the cause. Allocation retries are sub-millisecond and occur in large
numbers in healthy runs. A raw cross-process control completed 200/200 uploads
despite 6,842 retries, and the Ubuntu 22.04 exact control completed 100/100
despite 3,020 retries.

Upstream commit `026dfef287c0` removed the faulty stronger check after reporting
the same loopback, persistent-connection, 128 KiB receive-buffer, and >64 KiB
skb conditions. It is present in Linux 7.0 and stable 6.18.17/6.19.7, but not
in the runner's 6.17 kernel.

Two independent controls passed all 100 exact test repetitions:

- custom SDK reads of up to 64 KiB on Linux 6.17: 15--26 ms per 23.4 MB request;
- the stock 1,520-byte SDK reads on Linux 6.8: 112--149 ms per request and zero
  socket drops.

The latter is the chosen temporary CI mitigation. Full evidence and artifact
locations are in `HTTP-SLOWDOWN-SIDE-FINDINGS.md`.

## Native `toit.run` crash

macOS produced a genuine native `toit.run` crash:

- signal: `SIGSEGV` / `EXC_BAD_ACCESS`;
- fault: invalid write while unlinking a resource-list node;
- faulting stack:
  - `ResourceGroup::tear_down`;
  - `Process::~Process`;
  - `Scheduler::run_process`;
- another thread was concurrently processing kqueue resource closure.

Linux later reproduced the same host-process segmentation fault in `qemu-trigger-test`.

### Likely cause

Before the local fix, `TestDevicePipe.kill-subprocess_` did the following:

1. Sends `SIGTERM`.
2. Calls `child-process.wait` with a 250 ms timeout.
3. If that wait times out, cancellation interrupts it.
4. Sends `SIGKILL`.
5. Calls `wait` again on the same subprocess.

`pkg-host` registers the subprocess resource when `wait` begins. A canceled wait leaves that resource registered. Calling `wait` again registers the same linked-list node a second time, corrupting the list. Process teardown later crashes while unlinking that node.

Current upstream `pkg-host` caches a successfully completed wait, but it still does not make a canceled wait safe to retry.

### Minimal reproducer

A host-only reproducer independently confirmed the mechanism. It repeatedly:

1. started a subprocess;
2. canceled its first `wait` with `with-timeout`;
3. killed the subprocess;
4. called `wait` again.

All 100 iterations appeared to complete, after which `toit.run` segfaulted
during process teardown. Replacing the two waits with one background waiter and
waiting on its latch twice completed the same 100 iterations without a crash.

### Implemented fix

Use one persistent waiter task per child process:

1. Start a task that calls `child-process.wait` exactly once.
2. Have it signal a completion latch.
3. Send `SIGTERM` and wait up to 250 ms on that latch.
4. If necessary, send `SIGKILL`.
5. Continue waiting on the same waiter task/latch.

This fix is implemented in `TestDevicePipe`. Both variants of
`host-hello-test` and both variants of the formerly crashing
`qemu-trigger-test` pass with it. The exact SIGTERM-timeout/SIGKILL fallback was
also exercised 20 times with a child that deliberately ignored SIGTERM.

Serializing QEMU tests would reduce host load and probably lower the trigger rate, but it would only mask this bug.

## QEMU Ethernet failure

A separate device/QEMU problem occurred on both Windows and Linux.

The affected sequence was:

1. The `eth-qemu` container started but its service provider disappeared before discovery.
2. The network client reported `ethernet unavailable`.
3. Synchronization failed with `CONNECT_FAILED: no available networks`.
4. The device entered deep sleep.
5. QEMU repeatedly panicked with `LoadStorePIFAddrError` during reboot.
6. The test waited for a synchronization line that could never appear and eventually hit its 300-second timeout.

The apparent 300-second hang was therefore not an HTTP request taking 300 seconds.

The `eth-qemu` entrypoint revealed two lifecycle bugs:

- it reported itself as background before constructing and installing the
  provider, allowing synchronization to race provider registration;
- it defined an `OpenEthProvider` that marks the container foreground while
  Ethernet is open, but instantiated the base provider instead, leaving the
  subclass as dead code.

The implemented fix installs `OpenEthProvider` before transitioning to
background and guards the transition against an immediately opened module. One
paired `qemu-hello-test` round passed with the change. A longer stress attempt
was cut short when the local host lost its network route before QEMU startup;
those later failures occurred during pod upload or LAN-IP discovery and did not
exercise the device Ethernet path.

## Cross-platform stress results

### Supabase

- The latest Supabase job passed 37 of 38 tests.
- Its only failure was `qemu-trigger-test` using the local Artemis broker.
- QEMU completed the expected boot and interval-trigger output, then received
  `SIGTERM` from `toit.run`.
- `toit.run` immediately segfaulted from `pkg-host/pipe.toit`, matching the
  canceled/retried subprocess-wait teardown failure.

### macOS

- The native teardown crash reproduced once at approximately attempt 11.
- A subsequent 20-round paired run passed.
- This is consistent with an intermittent timing-sensitive resource corruption.

### Windows

- The original failure was a missing `eth-qemu` Ethernet provider followed by a timeout.
- Early stress selectors accidentally selected zero tests because of platform-specific CTest matching behavior.
- `--no-tests=error` was added so this could not silently pass again.
- The selectors were replaced with stable CTest indices.
- The latest corrected 10-round Windows stress passed.

### Linux

- Linux reproduced the native subprocess teardown segmentation fault.
- Linux also reproduced the missing Ethernet provider and QEMU panic loop.
- The latest instrumented Linux run passed.

## Removed diagnostic changes

The following temporary diagnostics were removed after identifying the HTTP
root cause and validating the QEMU fixes:

- SDK tool duration logging;
- sanitized HTTP client timing;
- HTTP server request-body progress, chunk, heap, and GC logging;
- Linux socket, process, and cgroup CPU sampling;
- macOS core-dump configuration and native backtraces;
- Windows and macOS paired QEMU stress runs;
- `fail-fast: false` so platform failures do not hide one another;
- sanitized workflow artifacts rather than complete logs that may contain credentials.

## Remaining work

1. Stress the single-waiter `TestDevicePipe` fix on CI platforms with QEMU.
2. Decide whether `pkg-host` or the SDK should defensively reject or support repeated waits after cancellation.
3. Stress the `eth-qemu` provider lifecycle fix on CI platforms.
4. Remove the Ubuntu 22.04 pin after GitHub's hosted kernel contains
   `026dfef287c0` or an equivalent stable backport.
