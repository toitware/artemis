// Copyright (C) 2023 Toitware ApS.

import ar show ArWriter
import artemis.cli.pod show *
import expect show *
import io
import .utils

main args:
  with-tmp-directory: | tmp-dir |
    test-pod-file tmp-dir
    test-old-pod-file tmp-dir
    test-manifest tmp-dir

test-pod-file tmp-dir/string:
  id := random-uuid
  pod := Pod
      --id=id
      --name="name"
      --artemis-version="v1.0.0-alpha.1"
      --envelope="envelope".to-byte-array
      --partition-table=null
      --tmp-directory=tmp-dir

  out := "$tmp-dir/$(id).pod"
  cli := TestCli
  pod.write out --cli=cli
  pod2 := Pod.parse out --cli=cli --tmp-directory=tmp-dir
  expect-equals id pod2.id
  expect-equals "name" pod2.name
  expect-equals "v1.0.0-alpha.1" pod2.artemis-version
  expect-equals "envelope".to-byte-array pod2.envelope

test-old-pod-file tmp-dir/string:
  id := random-uuid
  pod := Pod
      --id=id
      --name="old"
      --envelope="old envelope".to-byte-array
      --partition-table=null
      --tmp-directory=tmp-dir

  out := "$tmp-dir/$(id).pod"
  cli := TestCli
  pod.write out --cli=cli
  parsed := Pod.parse out --cli=cli --tmp-directory=tmp-dir
  expect-null parsed.artemis-version

test-manifest tmp-dir/string:
  envelope-buffer := io.Buffer
  envelope-writer := ArWriter envelope-buffer
  envelope-writer.add "part" "contents"
  envelope-buffer.close

  pod := Pod
      --id=random-uuid
      --name="manifest"
      --artemis-version="v1.0.0-beta.2"
      --envelope=envelope-buffer.bytes
      --partition-table=null
      --tmp-directory=tmp-dir

  pod.split: | manifest/Map parts/Map |
    expect-equals "v1.0.0-beta.2" manifest["artemis-version"]
    restored := Pod.from-manifest manifest
        --tmp-directory=tmp-dir
        --download=: parts[it]
    expect-equals pod.id restored.id
    expect-equals pod.name restored.name
    expect-equals pod.artemis-version restored.artemis-version
    expect-equals pod.envelope restored.envelope

    old-manifest := manifest.copy
    old-manifest.remove "artemis-version"
    old-restored := Pod.from-manifest old-manifest
        --tmp-directory=tmp-dir
        --download=: parts[it]
    expect-null old-restored.artemis-version
