// Copyright (C) 2022 Toitware ApS. All rights reserved.

/**
Handles cached files.

Typically, caches are stored in the user's home: \$(HOME)/.cache, but users can
  overwrite this by setting the \$XDG_CACHE_HOME environment variable.

To simplify testing, the environment variable '<app-name>_CACHE_DIR' can be used to
  override the cache directory.
*/

import host.os
import host.file
import host.directory
import encoding.json
import writer

/**
A class to manage objects that can be downloaded or generated, but should
  be kept alive if possible.
*/
class Cache:
  app_name/string
  path/string

  /**
  Creates a new cache.

  If the \$XDG_CACHE_HOME environment variable is set, the cache is located
    at \$XDG_CACHE_HOME/$app_name. Otherwise, the cache will is stored
    in \$(HOME)/.cache/$app_name.
  */
  constructor --app_name/string:
    app_name_upper := app_name.to_ascii_upper
    env := os.env
    if env.contains "$(app_name_upper)_CACHE_DIR":
      return Cache --app_name=app_name --path=env["$(app_name_upper)_CACHE_DIR"]

    if env.contains "XDG_CACHE_HOME":
      return Cache --app_name=app_name --path="$(env["XDG_CACHE_HOME"])/$(app_name)"

    if env.contains "HOME":
      return Cache --app_name=app_name --path="$(env["HOME"])/.cache/$(app_name)"

    throw "No cache directory found. HOME not set."

  /**
  Creates a new cache using the given $path as the cache directory.
  */
  constructor --.app_name --.path:

  /**
  Whether the cache contains the given $key.

  The key can point to a file or a directory.
  */
  contains key/string -> bool:
    key_path := key_path_ key
    return file.is_file key_path or file.is_directory key_path

  /**
  Variant of $(get key [block]).

  Returns a path to the cache entry, instead of the content.
  */
  get_file_path key/string [block] -> string:
    key_path := key_path_ key
    if file.is_directory key_path:
      throw "Cache entry '$(key)' is a directory."

    if not file.is_file key_path:
      file_store := FileStore_ this key
      try:
        block.call file_store
        if not file_store.has_stored_:
          throw "Generator callback didn't store anything."
      finally:
        file_store.close_

    return key_path

  /**
  Returns the content of the cache entry with the given $key.

  If the cache entry doesn't exist yet, calls the $block callback
    to generate it. The block is called with an instance of
    $FileStore, which can be used to store the value that
    should be in the cache.

  Throws, if there already exists a cache entry with the given $key, but
    that entry is not a file.
  */
  get key/string [block] -> ByteArray:
    key_path := get_file_path key block
    return file.read_content key_path

  /**
  Returns the path to the cached directory item with the given $key.

  If the cache entry doesn't exist yet, calls the $block callback
    to generate it. The block is called with an instance of
    $DirectoryStore, which must be used to store the value that
    should be in the cache.

  Throws, if there already exists a cache entry with the given $key, but
    that entry is a file.
  */
  get_directory_path key/string [block] -> string:
    key_path := key_path_ key
    if file.is_file key_path:
      throw "Cache entry '$(key)' is a file."

    if not file.is_directory key_path:
      directory_store := DirectoryStore_ this key
      try:
        block.call directory_store
        if not directory_store.has_stored_:
          throw "Generator callback didn't store anything."
      finally:
        directory_store.close_

    return key_path

  // TODO(florian): add a `delete` method.

  ensure_cache_directory_:
    directory.mkdir --recursive path

  key_path_ key/string -> string:
    return "$(path)/$(key)"

  with_tmp_directory_ key/string?=null [block]:
    ensure_cache_directory_
    prefix := ?
    if key:
      // TODO(florian): this doesn't work on Windows.
      if platform == PLATFORM_WINDOWS: throw "UNIMPLEMENTED"
      escaped_key := key.replace --all "/" "_"
      prefix = "$(path)/$(escaped_key)-"
    else:
      prefix = "$(path)/tmp-"

    tmp_dir := directory.mkdtemp prefix
    try:
      block.call tmp_dir
    finally:
      // It's legal for the block to (re)move the directory.
      if file.is_directory tmp_dir:
        directory.rmdir --recursive tmp_dir

/**
An interface to store a file in the cache.

An instance of this class is provided to callers of the cache's get methods
  when the key doesn't exist yet. The caller must then call one of the store
  methods to fill the cache.
*/
interface FileStore:
  key -> string

  /**
  Creates a temporary directory that is on the same file system as the cache.
  As such, it is suitable for a $move call.

  Calls the given $block with the path as argument.
  The temporary directory is deleted after the block returns.
  */
  with_tmp_directory [block]

  /**
  Saves the given $bytes as the content of $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  save bytes/ByteArray

  /**
  Calls the given $block with a $writer.Writer.

  The $block must write its chunks to the writer.
  The writer is closed after the block returns.
  */
  save_to_writer [block]

  /**
  Copies the content of $path to the cache under $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  copy path/string

  /**
  Moves the file at $path to the cache under $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  move path/string

  // TODO(florian): add "download" method.
  // download url/string --compressed/bool=false --path/string="":

/**
An interface to store a directory in the cache.

An instance of this class is provided to callers of the cache's get methods
  when the key doesn't exist yet. The caller must then call one of the store
  methods to fill the cache.
*/
interface DirectoryStore:
  key -> string

  /**
  Creates a temporary directory that is on the same file system as the cache.
  As such, it is suitable for a $move call.

  Calls the given $block with the path as argument.
  The temporary directory is deleted after the block returns.
  */
  with_tmp_directory [block]

  /**
  Copies the content of the directory $path to the cache under $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  copy path/string

  /**
  Moves the directory at $path to the cache under $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  move path/string

  // TODO(florian): add "download" method.
  // Must be a tar, tar.gz, tgz, or zip.
  // download url/string --path/string="":


class FileStore_ implements FileStore:
  cache_/Cache
  key/string
  has_stored_/bool := false
  is_closed_/bool := false

  constructor .cache_ .key:

  close_: is_closed_ = true

  /**
  Creates a temporary directory that is on the same file system as the cache.
  As such, it is suitable for a $move call.

  Calls the given $block with the path as argument.
  The temporary directory is deleted after the block returns.
  */
  with_tmp_directory [block]:
    cache_.with_tmp_directory_ block

  /**
  Saves the given $bytes as the content of $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  save bytes/ByteArray:
    store_: | file_path/string |
      file.write_content bytes --path=file_path

  /**
  Calls the given $block with a $writer.Writer.

  The $block must write its chunks to the writer.
  The writer is closed after the block returns.
  */
  save_to_writer [block]:
    store_: | file_path/string |
      stream := file.Stream.for_write file_path
      w := writer.Writer stream
      try:
        block.call w
      finally:
        w.close

  /**
  Copies the content of $path to the cache under $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  copy path/string:
    store_: | file_path/string |
      copy_file_ --source=path --target=file_path

  /**
  Moves the file at $path to the cache under $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  move path/string:
    if has_stored_: throw "Already saved content for key: $key"
    if is_closed_: throw "FileStore is closed"

    store_: | file_path/string |
      // TODO(florian): we should be able to test whether the rename should succeed.
      exception := catch: file.rename path file_path
      if not exception: continue.store_
      // We assume that the files weren't on the same file system.
      copy_file_ --source=path --target=file_path

  store_ [block] -> none:
    if has_stored_: throw "Already saved content for key: $key"
    if is_closed_: throw "FileStore is closed"

    // Save files into a temporary file first, then rename it to the final
    // location.
    cache_.with_tmp_directory_ key: | tmp_dir |
      tmp_path := "$tmp_dir/content"
      block.call tmp_path
      key_path := cache_.key_path_ key
      key_dir := dirname_ key_path
      directory.mkdir --recursive key_dir
      atomic_move_file_ tmp_path key_path

    has_stored_ = true

class DirectoryStore_ implements DirectoryStore:
  cache_/Cache
  key/string
  has_stored_/bool := false
  is_closed_/bool := false

  constructor .cache_ .key:

  close_: is_closed_ = true

  /**
  Creates a temporary directory that is on the same file system as the cache.
  As such, it is suitable for a $move call.

  Calls the given $block with the path as argument.
  The temporary directory is deleted after the block returns.
  */
  with_tmp_directory [block]:
    cache_.with_tmp_directory_ block

  /**
  Copies the content of the directory $path to the cache under $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  copy path/string:
    store_: | dir_path/string |
      copy_directory_ --source=path --target=dir_path

  /**
  Moves the directory at $path to the cache under $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  move path/string:
    store_: | dir_path/string |
      // TODO(florian): we should be able to test whether the rename should succeed.
      exception := catch: file.rename path dir_path
      if not exception: continue.store_
      // We assume that the files weren't on the same file system.
      copy_directory_ --source=path --target=dir_path

  // TODO(florian): add "download" method.
  // Must be a tar, tar.gz, tgz, or zip.
  // download url/string --path/string="":

  store_ [block] -> none:
    if has_stored_: throw "Already saved content for key: $key"
    if is_closed_: throw "DirectoryStore is closed"

    // Save files into a temporary directory first, then rename it to the final
    // location.
    cache_.with_tmp_directory_ key: | tmp_dir |
      block.call tmp_dir
      key_path := cache_.key_path_ key
      key_dir := dirname_ key_path
      directory.mkdir --recursive key_dir
      atomic_move_directory_ tmp_dir key_path

    has_stored_ = true



atomic_move_file_ source_path/string target_path/string -> none:
  // There is a race condition here, but not much we can do about it.
  if file.is_file target_path: return
  file.rename source_path target_path

atomic_move_directory_ source_path/string target_path/string -> none:
  // There is a race condition here, but not much we can do about it.
  if file.is_directory target_path: return
  file.rename source_path target_path

dirname_ path/string -> string:
  // TODO(florian): this wouldn't work on Windows.
  if platform == PLATFORM_WINDOWS: throw "UNIMPLEMENTED"
  last_slash := path.index_of --last "/"
  if last_slash == -1: return "."
  return path[0..last_slash]

copy_file_ --source/string --target/string -> none:
  // TODO(florian): we want to keep the permissions of the original file,
  // except that we want to make the file read-only.
  in := file.Stream.for_read source
  out := file.Stream.for_write target
  w := writer.Writer out
  while chunk := in.read:
    w.write chunk
  in.close
  out.close

copy_directory_ --source/string --target/string -> none:
  // TODO(florian): we want to keep the permissions of the original file,
  // except that we want to make the file read-only.
  directory.mkdir --recursive target
  dir_entries := directory.DirectoryStream source
  try:
    while entry := dir_entries.next:
      source_path := "$(source)/$(entry)"
      target_path := "$(target)/$(entry)"
      if file.is_file source_path:
        copy_file_ --source=source_path --target=target_path
      else if file.is_directory source_path:
        copy_directory_ --source=source_path --target=target_path
      else:
        throw "Unknown file type: $(source_path)"
  finally:
    dir_entries.close
