// Copyright (C) 2022 Toitware ApS. All rights reserved.

import artemis.cli.cache
import host.directory
import host.file
import monitor
import expect show *
import writer

main:
  test_file_cache
  test_dir_cache

test_file_cache:
  cache_dir := directory.mkdtemp "/tmp/cache_test-"
  try:
    c := cache.Cache --app_name="test" --path=cache_dir

    key := "key"
    expect_not (c.contains key)
    value := c.get key: | store/cache.FileStore |
      store.save #[1, 2, 3]
    expect_equals value #[1, 2, 3]

    value = c.get key: | store |
      throw "Should not be called"
    expect_equals value #[1, 2, 3]

    path := c.get_file_path key: | store |
      throw "Should not be called"
    expect_equals path "$cache_dir/key"
    content := file.read_content path
    expect_equals content #[1, 2, 3]

    key2 := "dir/nested/many/levels/key2"
    expect_not (c.contains key2)
    value2 := c.get key2: | store/cache.FileStore |
      store.save #[4, 5, 6]
    expect_equals value2 #[4, 5, 6]

    value2 = c.get key2: | store |
      throw "Should not be called"
    expect_equals value2 #[4, 5, 6]

    path2 := c.get_file_path key2: | store |
      throw "Should not be called"
    expect_equals path2 "$cache_dir/$key2"
    content2 := file.read_content path2
    expect_equals content2 #[4, 5, 6]

    // Make sure we didn't leave any temporary directories behind.
    dir_streamer := directory.DirectoryStream cache_dir
    dir_entries := {}
    while entry := dir_streamer.next:
      dir_entries.add entry

    key3 := "dir/key3"
    expect_not (c.contains key3)
    value3 := c.get key3: | store/cache.FileStore |
      store.with_tmp_directory: | tmp_dir |
        tmp_file := "$tmp_dir/file"
        write_content --path=tmp_file --content=#[7, 8, 9]
        store.move tmp_file
    expect_equals value3 #[7, 8, 9]

    value3 = c.get key3: | store |
      throw "Should not be called"
    expect_equals value3 #[7, 8, 9]

    key4 := "dir/key4"
    expect_not (c.contains key4)
    value4 := c.get key4: | store/cache.FileStore |
      store.with_tmp_directory: | tmp_dir |
        tmp_file := "$tmp_dir/file"
        write_content --path=tmp_file --content=#[10, 11, 12]
        store.copy tmp_file
    expect_equals value4 #[10, 11, 12]

    value4 = c.get key4: | store |
      throw "Should not be called"
    expect_equals value4 #[10, 11, 12]

    // Note that key5 will not get any value, and there should not be
    // any directory for it.
    key5 := "dir2/key5"
    expect_not (c.contains key5)
    expect_throw "fail": c.get key5: | store/cache.FileStore |
      throw "fail"
    expect_not (c.contains key5)

    // If a move/copy fails, the key doesn't get a value.
    exception := catch: c.get key5: | store/cache.FileStore |
      store.with_tmp_directory: | tmp_dir |
        tmp_file := "$tmp_dir/file"
        // Doesn't exist.
        store.move tmp_file
    expect_not_null exception
    expect_not (c.contains key5)

    exception = catch: c.get key5: | store/cache.FileStore |
      store.with_tmp_directory: | tmp_dir |
        tmp_file := "$tmp_dir/file"
        // Doesn't exist.
        store.copy tmp_file
    expect_not_null exception
    expect_not (c.contains key5)

    // However, as soon as a `store` is successful, the first value
    // sticks.
    key6 := "dir/key6"
    expect_not (c.contains key6)
    exception = catch: c.get key6: | store/cache.FileStore |
      store.save #[13, 14, 15]
      store.save #[16, 17, 18]
    expect (exception.starts_with "Already saved")
    value6 := c.get key6: | store/cache.FileStore |
      throw "Should not be called"
    expect_equals value6 #[13, 14, 15]

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
    expect_equals value7 #[19, 20, 21]

    // Test concurrent access with copy.
    key9 := "dir/key9"
    task::
      semaphore1.down
      c.get key9: | store/cache.FileStore |
        store.with_tmp_directory: | tmp_dir |
          tmp_file := "$tmp_dir/file"
          write_content --path=tmp_file --content=#[31, 32, 33]
          store.copy tmp_file
          semaphore2.up

    value9 := c.get key9: | store/cache.FileStore |
      semaphore1.up
      semaphore2.down
      store.with_tmp_directory: | tmp_dir |
        tmp_file := "$tmp_dir/file"
        write_content --path=tmp_file --content=#[34, 35, 36]
        store.copy tmp_file

    // The first task wins.
    expect_equals value9 #[31, 32, 33]

    // Test concurrent access with move.
    key11 := "dir/key11"
    task::
      semaphore1.down
      c.get key11: | store/cache.FileStore |
        store.with_tmp_directory: | tmp_dir |
          tmp_file := "$tmp_dir/file"
          write_content --path=tmp_file --content=#[43, 44, 45]
          store.move tmp_file
          semaphore2.up

    value11 := c.get key11: | store/cache.FileStore |
      semaphore1.up
      semaphore2.down
      store.with_tmp_directory: | tmp_dir |
        tmp_file := "$tmp_dir/file"
        write_content --path=tmp_file --content=#[46, 47, 48]
        store.move tmp_file

    // The first task wins.
    expect_equals value11 #[43, 44, 45]

    expect_equals 2 dir_entries.size
    expect (dir_entries.contains "key")
    expect (dir_entries.contains "dir")

  finally:
    directory.rmdir --recursive cache_dir


write_content --path/string --content/ByteArray:
  stream := file.Stream.for_write path
  w := writer.Writer stream
  w.write content
  w.close

test_dir_cache:
  cache_dir := directory.mkdtemp "/tmp/cache_test-"
  try:
    c := cache.Cache --app_name="test" --path=cache_dir

    // Test 'move' of the tmp directory.
    key := "key"
    expect_not (c.contains key)
    value := c.get_directory_path key: | store/cache.DirectoryStore |
      store.with_tmp_directory: | dir |
        store.move dir
    expect_equals value "$cache_dir/$key"

    value = c.get_directory_path key: | store |
      throw "Should not be called"
    expect_equals value "$cache_dir/$key"

    // Test 'copy' of the tmp directory.
    key2 := "key2"
    expect_not (c.contains key2)
    value2 := c.get_directory_path key2: | store/cache.DirectoryStore |
      store.with_tmp_directory: | dir |
        write_content --path="$dir/file" --content=#[1, 2, 3]
        store.move dir
    expect_equals value2 "$cache_dir/$key2"
    expect_equals #[1, 2, 3] (file.read_content "$value2/file")

    // Test nested directories.
    key3 := "dir/key3"
    expect_not (c.contains key3)
    value3 := c.get_directory_path key3: | store/cache.DirectoryStore |
      store.with_tmp_directory: | dir |
        write_content --path="$dir/file" --content=#[4, 5, 6]
        store.move dir
    expect_equals value3 "$cache_dir/$key3"
    expect_equals #[4, 5, 6] (file.read_content "$value3/file")

    // Test concurrent accesses to the cache.

    // Incremented, when the task is allowed to save the cache value.
    semaphore1 := monitor.Semaphore
    // Incremented, when the task has finished writing the cache value.
    semaphore2 := monitor.Semaphore

    key4 := "dir/key4"
    task::
      semaphore1.down
      c.get_directory_path key4: | store/cache.DirectoryStore |
        store.with_tmp_directory: | dir |
          write_content --path="$dir/file" --content=#[7, 8, 9]
          store.move dir
          semaphore2.up

    value4 := c.get_directory_path key4: | store/cache.DirectoryStore |
      semaphore1.up
      semaphore2.down
      store.with_tmp_directory: | dir |
        write_content --path="$dir/file" --content=#[10, 11, 12]
        store.move dir

    expect_equals value4 "$cache_dir/$key4"
    // The first task wins.
    expect_equals #[7, 8, 9] (file.read_content "$value4/file")

    // Make sure we didn't leave any temporary directories behind.
    dir_streamer := directory.DirectoryStream cache_dir
    dir_entries := {}
    while entry := dir_streamer.next:
      dir_entries.add entry

    expect_equals 3 dir_entries.size
    expect (dir_entries.contains "key")
    expect (dir_entries.contains "key2")
    expect (dir_entries.contains "dir")

  finally:
    directory.rmdir --recursive cache_dir
