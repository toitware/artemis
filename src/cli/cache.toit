// Copyright (C) 2022 Toitware ApS. All rights reserved.

import crypto.sha256
import encoding.base64
import encoding.json
import fs
import fs.xdg
import host.os
import host.file
import host.directory
import system
import uuid
import writer
import .server-config
import .utils

/**
Handles cached files.

Typically, caches are stored in the user's home: \$(HOME)/.cache, but users can
  overwrite this by setting the \$XDG_CACHE_HOME environment variable.

To simplify testing, the environment variable '<app-name>_CACHE_DIR' can be used to
  override the cache directory.
*/

SDK-PATH ::= "sdks"
ENVELOPE-PATH ::= "envelopes"
GIT-APP-PATH ::= "git_app"
POD-MANIFEST-PATH ::= "pod/manifest"
POD-PARTS-PATH ::= "pod/parts"
service-image-cache-key --service-version/string --sdk-version/string --artemis-config/ServerConfig -> string:
  return "$artemis-config.name/service/$service-version/$(sdk-version).image"
application-image-cache-key id/uuid.Uuid --broker-config/ServerConfig -> string:
  return "$broker-config.name/application/images/$(id).image"

/**
A class to manage objects that can be downloaded or generated, but should
  be kept alive if possible.
*/
class Cache:
  app-name/string
  path/string

  /**
  Creates a new cache.

  If the \$XDG_CACHE_HOME environment variable is set, the cache is located
    at \$XDG_CACHE_HOME/$app-name. Otherwise, the cache will is stored
    in \$(HOME)/.cache/$app-name.
  */
  constructor --app-name/string:
    app-name-upper := app-name.to-ascii-upper
    cache-home := xdg.cache-home
    return Cache --app-name=app-name --path="$cache-home/$(app-name)"

  /**
  Creates a new cache using the given $path as the cache directory.
  */
  constructor --.app-name --.path:

  /**
  Removes the cache entry with the given $key.
  */
  remove key/string -> none:
    key-path := key-path_ key
    if file.is-file key-path:
      file.delete key-path
    else if file.is-directory key-path:
      directory.rmdir --recursive key-path

  /**
  Whether the cache contains the given $key.

  The key can point to a file or a directory.
  */
  contains key/string -> bool:
    key-path := key-path_ key
    return file.is-file key-path or file.is-directory key-path

  /**
  Variant of $(get key [block]).

  Returns a path to the cache entry, instead of the content.
  */
  get-file-path key/string [block] -> string:
    key-path := key-path_ key
    if file.is-directory key-path:
      throw "Cache entry '$(key)' is a directory."

    if not file.is-file key-path:
      file-store := FileStore_ this key
      try:
        block.call file-store
        if not file-store.has-stored_:
          throw "Generator callback didn't store anything."
      finally:
        file-store.close_

    return key-path

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
    key-path := get-file-path key block
    return file.read-content key-path

  /**
  Returns the path to the cached directory item with the given $key.

  If the cache entry doesn't exist yet, calls the $block callback
    to generate it. The block is called with an instance of
    $DirectoryStore, which must be used to store the value that
    should be in the cache.

  Throws, if there already exists a cache entry with the given $key, but
    that entry is a file.
  */
  get-directory-path key/string [block] -> string:
    key-path := key-path_ key
    if file.is-file key-path:
      throw "Cache entry '$(key)' is a file."

    if not file.is-directory key-path:
      directory-store := DirectoryStore_ this key
      try:
        block.call directory-store
        if not directory-store.has-stored_:
          throw "Generator callback didn't store anything."
      finally:
        directory-store.close_

    return key-path

  // TODO(florian): add a `delete` method.

  ensure-cache-directory_:
    directory.mkdir --recursive path

  /**
  Escapes the given $path so it's valid.
  Escapes '\' even if the platform is Windows, where it's a valid
    path separator.
  If two given paths are equal, then the escaped paths are also equal.
  If they are different, then the escaped paths are also different.
  */
  escape-path_ path/string -> string:
    if system.platform != system.PLATFORM-WINDOWS:
      return path
    // On Windows, we need to escape some characters.
    // We use '#' as escape character.
    // We will treat '/' as the folder separator, and escape '\'.
    escaped-path := path.replace --all "#" "##"
    // The following characters are not allowed:
    //  <, >, :, ", |, ?, *
    // '\' and '/' would both become folder separators, so
    // we escape '\' to stay unique.
    // We escape them as #<hex value>.
    [ '<', '>', ':', '"', '|', '?', '*', '\\' ].do:
      escaped-path = escaped-path.replace --all
          string.from-rune it
          "#$(%02X it)"
    if escaped-path.ends-with " " or escaped-path.ends-with ".":
      // Windows doesn't allow files to end with a space or a dot.
      // Add a suffix to make it valid.
      // Note that this still guarantees uniqueness, because
      // a space would normally not be escaped.
      escaped-path = "$escaped-path#20"
    return escaped-path

  key-path_ key/string -> string:
    if system.platform == system.PLATFORM-WINDOWS and key.size > 100:
      // On Windows we shorten the path so it doesn't run into the 260 character limit.
      sha := sha256.Sha256
      sha.add key
      key = "$(base64.encode --url-mode sha.get)"

    return "$(path)/$(escape-path_ key)"

  with-tmp-directory_ key/string?=null [block]:
    ensure-cache-directory_
    prefix := ?
    if key and system.platform != system.PLATFORM-WINDOWS:
      // On Windows don't try to create long prefixes as paths are limited to 260 characters.
      escaped-key := escape-path_ key
      escaped-key = escaped-key.replace --all "/" "_"
      prefix = "$(path)/$(escaped-key)-"
    else:
      prefix = "$(path)/tmp-"

    tmp-dir := directory.mkdtemp prefix
    try:
      block.call tmp-dir
    finally:
      // It's legal for the block to (re)move the directory.
      if file.is-directory tmp-dir:
        directory.rmdir --recursive tmp-dir

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
  with-tmp-directory [block]

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
  save-via-writer [block]

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
  with-tmp-directory [block]

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
  has-stored_/bool := false
  is-closed_/bool := false

  constructor .cache_ .key:

  close_: is-closed_ = true

  /**
  Creates a temporary directory that is on the same file system as the cache.
  As such, it is suitable for a $move call.

  Calls the given $block with the path as argument.
  The temporary directory is deleted after the block returns.
  */
  with-tmp-directory [block]:
    cache_.with-tmp-directory_ block

  /**
  Saves the given $bytes as the content of $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  save bytes/ByteArray:
    store_: | file-path/string |
      file.write-content bytes --path=file-path

  /**
  Calls the given $block with a $writer.Writer.

  The $block must write its chunks to the writer.
  The writer is closed after the block returns.
  */
  save-via-writer [block]:
    store_: | file-path/string |
      stream := file.Stream.for-write file-path
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
    store_: | file-path/string |
      copy-file_ --source=path --target=file-path

  /**
  Moves the file at $path to the cache under $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  move path/string:
    if has-stored_: throw "Already saved content for key: $key"
    if is-closed_: throw "FileStore is closed"

    store_: | file-path/string |
      // TODO(florian): we should be able to test whether the rename should succeed.
      exception := catch: file.rename path file-path
      if not exception: continue.store_
      // We assume that the files weren't on the same file system.
      copy-file_ --source=path --target=file-path

  store_ [block] -> none:
    if has-stored_: throw "Already saved content for key: $key"
    if is-closed_: throw "FileStore is closed"

    // Save files into a temporary file first, then rename it to the final
    // location.
    cache_.with-tmp-directory_ key: | tmp-dir |
      tmp-path := "$tmp-dir/content"
      block.call tmp-path
      key-path := cache_.key-path_ key
      key-dir := fs.dirname key-path
      directory.mkdir --recursive key-dir
      atomic-move-file_ tmp-path key-path

    has-stored_ = true

class DirectoryStore_ implements DirectoryStore:
  cache_/Cache
  key/string
  has-stored_/bool := false
  is-closed_/bool := false

  constructor .cache_ .key:

  close_: is-closed_ = true

  /**
  Creates a temporary directory that is on the same file system as the cache.
  As such, it is suitable for a $move call.

  Calls the given $block with the path as argument.
  The temporary directory is deleted after the block returns.
  */
  with-tmp-directory [block]:
    cache_.with-tmp-directory_ block

  /**
  Copies the content of the directory $path to the cache under $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  copy path/string:
    store_: | dir-path/string |
      copy-directory --source=path --target=dir-path

  /**
  Moves the directory at $path to the cache under $key.

  If the key already exists, the generated content is dropped.
  This can happen if two processes try to access the cache at the same time.
  */
  move path/string:
    store_: | dir-path/string |
      // TODO(florian): we should be able to test whether the rename should succeed.
      exception := catch: file.rename path dir-path
      if not exception: continue.store_
      // We assume that the files weren't on the same file system.
      copy-directory --source=path --target=dir-path

  // TODO(florian): add "download" method.
  // Must be a tar, tar.gz, tgz, or zip.
  // download url/string --path/string="":

  store_ [block] -> none:
    if has-stored_: throw "Already saved content for key: $key"
    if is-closed_: throw "DirectoryStore is closed"

    // Save files into a temporary directory first, then rename it to the final
    // location.
    cache_.with-tmp-directory_ key: | tmp-dir |
      block.call tmp-dir
      key-path := cache_.key-path_ key
      key-dir := fs.dirname key-path
      directory.mkdir --recursive key-dir
      atomic-move-directory_ tmp-dir key-path

    has-stored_ = true



atomic-move-file_ source-path/string target-path/string -> none:
  // There is a race condition here, but not much we can do about it.
  if file.is-file target-path: return
  file.rename source-path target-path

atomic-move-directory_ source-path/string target-path/string -> none:
  // There is a race condition here, but not much we can do about it.
  if file.is-directory target-path: return
  file.rename source-path target-path

copy-file_ --source/string --target/string -> none:
  // TODO(florian): we want to keep the permissions of the original file,
  // except that we want to make the file read-only.
  in := file.Stream.for-read source
  out := file.Stream.for-write target
  w := writer.Writer out
  w.write-from in
  in.close
  out.close
