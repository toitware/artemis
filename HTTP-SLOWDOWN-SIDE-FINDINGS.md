# HTTP slowdown: Linux TCP receive-buffer regression

## Current conclusion

The intermittent slowdown is a Linux TCP regression, not an HTTP-library bug,
ordinary CPU starvation, slow request handling, or a Toit GC failure.

The failing GitHub runner uses Linux `6.17.0-1022-azure`. Its behavior matches
upstream regression `1d2fbaad7cd8` (`tcp: stronger sk_rcvbuf checks`) and the
later upstream fix `026dfef287c0` (`tcp: give up on stronger sk_rcvbuf checks
(for now)`). The fix describes the same conditions: loopback traffic, a
connection that has already transferred more than 1 MB, a receive buffer near
128 KiB, data already queued, and an incoming skb larger than 64 KiB.

The observed initiating sequence is:

1. Earlier requests leave the persistent loopback connection with an
   autotuned receive buffer around 184 KiB.
2. The client begins the final 23.4 MB request. Before the HTTP server logs
   that it has started reading the body, the kernel queues a large skb.
3. The regressed `tcp_can_ingest` check rejects the skb because the queued
   memory plus the incoming skb exceeds `sk_rcvbuf`.
4. `tcp_prune_queue` calls `tcp_clamp_window`, which replaces `sk_rcvbuf` with
   the momentary queued-memory value.
5. Repeated arrivals ratchet the receive buffer down from `184190` to `65472`,
   `30656`, and finally `18368` bytes while the socket drop counter rises.
6. The sender becomes receive-window limited. Progress then follows the roughly
   200 ms retransmission timer and the connection cannot autotune back up.

Allocation failures and GC retries occur during both healthy and failed runs,
but they do not initiate the collapse. A 200-attempt cross-process control
produced 6,842 allocation failures and occasional socket drops while every
23.4 MB transfer still completed in 97--118 ms; its receive buffer never fell
below 131,072 bytes.

Upstream removed the stronger incoming-skb check in February 2026. The fix is
in Linux 7.0 and was backported to 6.18.17 and 6.19.7, but it is absent from the
6.17 GitHub-hosted runner used by the failing job.

## Reproduction evidence

The problem reproduced in GitHub Actions run `33272595646`, attempt 1, Linux
job `99153662198`, inside isolated repetition 3/10 of:

```text
/tests/cmd-pod-list-test-slow.toit --http-server --http-toit-broker
```

The test timed out after approximately 300 seconds.

It also reproduced earlier in `qemu-hello-test` during the concurrent suite.
That establishes that it is not specific to the original cmd-pod-list test.

### HTTP-level pattern

For the stalled 23.4 MB body, each 1 MiB interval showed:

- Approximately 106.5 seconds per MiB.
- 1,024 application reads per MiB.
- Exactly 512 reads waiting at least 100 ms.
- Average read wait approximately 104 ms.
- Maximum read wait approximately 208--209 ms.
- Read sizes ranging from 528 to 1,520 bytes.

The 1,024 reads and 512 slow reads are explained by each 2 KiB TCP window
being consumed in two application reads, approximately `1520 + 528`, followed
by a roughly 200 ms wait for the next window update.

### Kernel socket pattern

The 100 ms `ss -Htinmp state established` trace showed the receiver's reported
receive-buffer size changing approximately as follows during the preceding
1.39 MB upload:

```text
131072 -> 155275 -> 65472 -> 1074 bytes
```

At the same time:

- The receiver socket drop counter increased from 0 to 3.
- The sender reported `rwnd_limited: 100%`.
- The sender reported `snd_wnd:2048`.
- The sender retained a large `notsent` queue.
- About 1,083,392 bytes were reported retransmitted.
- The sender's retransmission timeout was approximately 201 ms.

This is direct evidence of TCP flow-control starvation. The approximately
201 ms retransmission timeout also matches the first approximately 202--205 ms
body-read pause.

Linux did not primarily reduce the negotiated MSS or "packet size." It
collapsed the receive buffer and advertised receive window. The small reads
were a consequence of that 2 KiB window.

## What the sibling Toit SDK source says

Relevant sibling checkout: `/home/flo/work/toit`.

### Linux TCP reads do not intentionally discard the packet

In `src/resources/tcp_linux.cc`, `PRIMITIVE(read)` does the following:

1. Calls `ioctl(fd, FIONREAD, ...)`.
2. Clamps the allocation to `ByteArray::PREFERRED_IO_BUFFER_SIZE`.
3. Allocates a forced-external Toit byte array.
4. Calls `recv` only after allocation succeeds.

Relevant code starts around:

```text
/home/flo/work/toit/src/resources/tcp_linux.cc:279
```

If allocation fails, it returns `ALLOCATION_FAILED` before `recv`. Therefore,
the pending TCP data remains in the Linux kernel; Toit does not consume and
discard it.

The interpreter handles `ALLOCATION_FAILED` by running GC and retrying the
same primitive:

```text
/home/flo/work/toit/src/interpreter_run.cc:1106
```

The byte-array allocation path is here:

```text
/home/flo/work/toit/src/process.cc:253
```

Forced-external allocations are still charged against the Toit process's heap
limit. Reaching that limit can therefore fail the TCP read allocation and
cause a GC before `recv` runs. The enhanced traces show that these retries take
well under a millisecond and also occur frequently in healthy controls; they
are not the source of the persistent slowdown.

### Host TCP reads are capped at 1,520 bytes

`ByteArray::PREFERRED_IO_BUFFER_SIZE` is `1536 - HEADER_SIZE`, currently 1,520
bytes:

```text
/home/flo/work/toit/src/objects.h:743
```

That exactly matches the maximum body-read chunk observed in the HTTP log.
The small host read size is probably a contributing condition: Linux local
TCP can deliver highly coalesced segments around 64 KiB while Toit drains only
1,520 bytes per primitive invocation and allocates a new external byte array
for every read.

### The remembered explicit drop/retry behavior is different

In the ESP32/lwIP implementation, the comment about triggering GC and relying
on retransmission applies to failure while accepting a SYN:

```text
/home/flo/work/toit/src/resources/tcp_esp32.cc:92
```

For established TCP data, the lwIP read path also allocates before advancing
or freeing the queued `pbuf`, and calls `tcp_recved` only after copying data:

```text
/home/flo/work/toit/src/resources/tcp_esp32.cc:379
```

Thus the established-data read paths do not deliberately consume and discard
data on a Toit heap allocation failure. The observed Linux collapse starts
before the server begins the final body read and does not require a long GC
pause.

## SDK and HTTP package status

- Artemis CI uses Toit SDK `v2.0.0-alpha.190`.
- The local installed SDK is alpha.198.
- Comparing alpha.190 through alpha.198 found no relevant Linux TCP change.
- The Linux TCP read implementation is effectively unchanged.
- Artemis is locked to `pkg-http` 2.15.0.
- 2.15.0 is the latest pkg-http release and repository head.
- Its recent change protects `TCP_NODELAY` restoration after peer disconnect;
  it does not change body streaming or socket receive-buffer behavior.

Therefore there is currently no evidence that a newer SDK or HTTP package has
already fixed this failure.

## Completed native diagnostic

The custom SDK diagnostic records `FIONREAD`, allocation and GC state,
`SO_RCVBUF`, `SO_MEMINFO`, `TCP_INFO`, `TCP_WINDOW_CLAMP`, readiness delay,
ports, and socket drops. It established that:

- allocation retries are sub-millisecond;
- there is no global TCP memory pressure;
- the socket's configured window clamp remains high while `SO_RCVBUF` falls;
- the first catastrophic buffer reduction is visible before the HTTP server
  starts reading the final body;
- every reduction coincides with another socket drop; and
- the exact `sk_rcvbuf` feedback behavior is the one removed by upstream Linux
  commit `026dfef287c0`.

## Mitigation experiments

Two custom-SDK controls are available only on the SDK debug branch:

1. `TOIT_TCP_READ_CHUNK_SIZE=65536` lets Linux TCP reads drain up to 64 KiB at
   once. All 100 exact Artemis repetitions passed on the affected 6.17 runner;
   every 23.4 MB request completed in 15--26 ms. This reduces exposure to the
   race but does not repair the kernel logic.
2. `TOIT_TCP_ACCEPT_RCVBUF=131072` locks accepted sockets at an actual Linux
   buffer of 262,144 bytes. The option works locally and prevents autotuning
   from ratcheting the buffer downward, but globally disabling receive-buffer
   autotuning would be a broad SDK workaround.

The preferred CI mitigation is to run on a kernel from before the regression
or one containing `026dfef287c0`. With the unmodified 1,520-byte SDK read path,
all 100 exact repetitions passed on `ubuntu-22.04` and its Linux 6.8 kernel.
The 23.4 MB requests completed in 112--149 ms, there were no socket drops, and
the receive buffer never fell below 131,072 bytes despite 3,020 ordinary
allocation retries. Pinning Linux jobs to that image is therefore a suitable
temporary measure until GitHub's current runner moves to a fixed kernel.
Smaller client writes or explicit yielding would also avoid the burst, but
would hide a kernel bug in higher-level HTTP code.

## Artifact location used during analysis

The downloaded reproduction artifact was placed at:

```text
/tmp/artemis-run-33272595646/http-upload-diagnostic.log
/tmp/artemis-run-33272595646/http-upload-sockets.log
/tmp/toit-http-run-33317237738/http-slowdown-33317237738-1
/tmp/toit-tcp-run-33329859807/tcp-clamp-33329859807-1
/tmp/toit-http-run-33330075618/http-slowdown-33330075618-1
/tmp/toit-http-run-33330876173/http-slowdown-33330876173-1
```

Those `/tmp` paths may not persist across sessions; the canonical evidence is
the GitHub Actions artifact `http-upload-diagnostics-Linux` from run
`33272595646`, attempt 1.
