// Copyright (C) 2022 Toitware ApS. All rights reserved.

import artemis.cli.cache
import host.directory
import host.file
import monitor
import expect show *

main:
  test-file-cache
  test-dir-cache

test-file-cache:
  cache-dir := directory.mkdtemp "/tmp/cache_test-"
  try:
    c := cache.Cache --app-name="test" --path=cache-dir

    key := "key"
    expect-not (c.contains key)
    value := c.get key: | store/cache.FileStore |
      store.save #[1, 2, 3]
    expect-equals value #[1, 2, 3]

    value = c.get key: | store |
      throw "Should not be called"
    expect-equals value #[1, 2, 3]

    path := c.get-file-path key: | store |
      throw "Should not be called"
    expect-equals path "$cache-dir/key"
    content := file.read-content path
    expect-equals content #[1, 2, 3]

    key2 := "dir/nested/many/levels/key2"
    expect-not (c.contains key2)
    value2 := c.get key2: | store/cache.FileStore |
      store.save #[4, 5, 6]
    expect-equals value2 #[4, 5, 6]

    value2 = c.get key2: | store |
      throw "Should not be called"
    expect-equals value2 #[4, 5, 6]

    path2 := c.get-file-path key2: | store |
      throw "Should not be called"
    expect-equals path2 "$cache-dir/$key2"
    content2 := file.read-content path2
    expect-equals content2 #[4, 5, 6]

    // Make sure we didn't leave any temporary directories behind.
    dir-streamer := directory.DirectoryStream cache-dir
    dir-entries := {}
    while entry := dir-streamer.next:
      dir-entries.add entry

    key3 := "dir/key3"
    expect-not (c.contains key3)
    value3 := c.get key3: | store/cache.FileStore |
      store.with-tmp-directory: | tmp-dir |
        tmp-file := "$tmp-dir/file"
        write-content --path=tmp-file --content=#[7, 8, 9]
        store.move tmp-file
    expect-equals value3 #[7, 8, 9]

    value3 = c.get key3: | store |
      throw "Should not be called"
    expect-equals value3 #[7, 8, 9]

    key4 := "dir/key4"
    expect-not (c.contains key4)
    value4 := c.get key4: | store/cache.FileStore |
      store.with-tmp-directory: | tmp-dir |
        tmp-file := "$tmp-dir/file"
        write-content --path=tmp-file --content=#[10, 11, 12]
        store.copy tmp-file
    expect-equals value4 #[10, 11, 12]

    value4 = c.get key4: | store |
      throw "Should not be called"
    expect-equals value4 #[10, 11, 12]

    // Note that key5 will not get any value, and there should not be
    // any directory for it.
    key5 := "dir2/key5"
    expect-not (c.contains key5)
    expect-throw "fail": c.get key5: | store/cache.FileStore |
      throw "fail"
    expect-not (c.contains key5)

    // If a move/copy fails, the key doesn't get a value.
    exception := catch: c.get key5: | store/cache.FileStore |
      store.with-tmp-directory: | tmp-dir |
        tmp-file := "$tmp-dir/file"
        // Doesn't exist.
        store.move tmp-file
    expect-not-null exception
    expect-not (c.contains key5)

    exception = catch: c.get key5: | store/cache.FileStore |
      store.with-tmp-directory: | tmp-dir |
        tmp-file := "$tmp-dir/file"
        // Doesn't exist.
        store.copy tmp-file
    expect-not-null exception
    expect-not (c.contains key5)

    // However, as soon as a `store` is successful, the first value
    // sticks.
    key6 := "dir/key6"
    expect-not (c.contains key6)
    exception = catch: c.get key6: | store/cache.FileStore |
      store.save #[13, 14, 15]
      store.save #[16, 17, 18]
    expect (exception.starts-with "Already saved")
    value6 := c.get key6: | store/cache.FileStore |
      throw "Should not be called"
    expect-equals value6 #[13, 14, 15]

    // Test concurrent cache access.

    // Incremented, when the task is allowed to save the cache value.
    semaphore1 := monitor.Semaphore
    // Incremented, when the task has finished writing the cache value.
    semaphore2 := monitor.Semaphore

    key7 := "dir/key7"
    task::
      semaphore1.down
      c.get key7: | store/cache.FileStore |
        store.save #[19, 20, 21]
        semaphore2.up

    value7 := c.get key7: | store/cache.FileStore |
      semaphore1.up
      semaphore2.down
      store.save #[22, 23, 24]

    // The first task wins.
    expect-equals value7 #[19, 20, 21]

    // Test concurrent access with copy.
    key9 := "dir/key9"
    task::
      semaphore1.down
      c.get key9: | store/cache.FileStore |
        store.with-tmp-directory: | tmp-dir |
          tmp-file := "$tmp-dir/file"
          write-content --path=tmp-file --content=#[31, 32, 33]
          store.copy tmp-file
          semaphore2.up

    value9 := c.get key9: | store/cache.FileStore |
      semaphore1.up
      semaphore2.down
      store.with-tmp-directory: | tmp-dir |
        tmp-file := "$tmp-dir/file"
        write-content --path=tmp-file --content=#[34, 35, 36]
        store.copy tmp-file

    // The first task wins.
    expect-equals value9 #[31, 32, 33]

    // Test concurrent access with move.
    key11 := "dir/key11"
    task::
      semaphore1.down
      c.get key11: | store/cache.FileStore |
        store.with-tmp-directory: | tmp-dir |
          tmp-file := "$tmp-dir/file"
          write-content --path=tmp-file --content=#[43, 44, 45]
          store.move tmp-file
          semaphore2.up

    value11 := c.get key11: | store/cache.FileStore |
      semaphore1.up
      semaphore2.down
      store.with-tmp-directory: | tmp-dir |
        tmp-file := "$tmp-dir/file"
        write-content --path=tmp-file --content=#[46, 47, 48]
        store.move tmp-file

    // The first task wins.
    expect-equals value11 #[43, 44, 45]

    expect-equals 2 dir-entries.size
    expect (dir-entries.contains "key")
    expect (dir-entries.contains "dir")

  finally:
    directory.rmdir --recursive cache-dir


write-content --path/string --content/ByteArray:
  stream := file.Stream.for-write path
  stream.out.write content
  stream.close

test-dir-cache:
  cache-dir := directory.mkdtemp "/tmp/cache_test-"
  try:
    c := cache.Cache --app-name="test" --path=cache-dir

    // Test 'move' of the tmp directory.
    key := "key"
    expect-not (c.contains key)
    value := c.get-directory-path key: | store/cache.DirectoryStore |
      store.with-tmp-directory: | dir |
        store.move dir
    expect-equals value "$cache-dir/$key"

    value = c.get-directory-path key: | store |
      throw "Should not be called"
    expect-equals value "$cache-dir/$key"

    // Test 'copy' of the tmp directory.
    key2 := "key2"
    expect-not (c.contains key2)
    value2 := c.get-directory-path key2: | store/cache.DirectoryStore |
      store.with-tmp-directory: | dir |
        write-content --path="$dir/file" --content=#[1, 2, 3]
        store.move dir
    expect-equals value2 "$cache-dir/$key2"
    expect-equals #[1, 2, 3] (file.read-content "$value2/file")

    // Test nested directories.
    key3 := "dir/key3"
    expect-not (c.contains key3)
    value3 := c.get-directory-path key3: | store/cache.DirectoryStore |
      store.with-tmp-directory: | dir |
        write-content --path="$dir/file" --content=#[4, 5, 6]
        store.move dir
    expect-equals value3 "$cache-dir/$key3"
    expect-equals #[4, 5, 6] (file.read-content "$value3/file")

    // Test concurrent accesses to the cache.

    // Incremented, when the task is allowed to save the cache value.
    semaphore1 := monitor.Semaphore
    // Incremented, when the task has finished writing the cache value.
    semaphore2 := monitor.Semaphore

    key4 := "dir/key4"
    task::
      semaphore1.down
      c.get-directory-path key4: | store/cache.DirectoryStore |
        store.with-tmp-directory: | dir |
          write-content --path="$dir/file" --content=#[7, 8, 9]
          store.move dir
          semaphore2.up

    value4 := c.get-directory-path key4: | store/cache.DirectoryStore |
      semaphore1.up
      semaphore2.down
      store.with-tmp-directory: | dir |
        write-content --path="$dir/file" --content=#[10, 11, 12]
        store.move dir

    expect-equals value4 "$cache-dir/$key4"
    // The first task wins.
    expect-equals #[7, 8, 9] (file.read-content "$value4/file")

    // Make sure we didn't leave any temporary directories behind.
    dir-streamer := directory.DirectoryStream cache-dir
    dir-entries := {}
    while entry := dir-streamer.next:
      dir-entries.add entry

    expect-equals 3 dir-entries.size
    expect (dir-entries.contains "key")
    expect (dir-entries.contains "key2")
    expect (dir-entries.contains "dir")

  finally:
    directory.rmdir --recursive cache-dir
