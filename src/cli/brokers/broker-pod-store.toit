// Copyright (C) 2026 Toit contributors.

import cli show Cli FileStore
import encoding.ubjson
import uuid show Uuid

import .broker show BrokerCli
import ..cache
import ..firmware-patches show FirmwarePatchUploader
import ..pod show Pod
import ..pod-registry
import ..pod-store show PodInfo PodStore UploadResult
import ...shared.server-config

/**
$PodStore implementation backed by a $BrokerCli.

Stores descriptions/entries/tags in the broker's pod registry tables
  and parts/manifests in the broker's pod blob storage. Local cache
  keys mirror the broker identity and organization id so multiple
  brokers can coexist without collisions.

Side effect of $upload: trivial firmware patches in the pod's envelope
  are pre-uploaded to the broker's firmware bucket via
  $FirmwarePatchUploader, so devices can later pull upgrade patches
  efficiently.
*/
class BrokerPodStore implements PodStore:
  fleet-id_/Uuid
  organization-id_/Uuid
  server-config_/ServerConfig
  broker-connection_/BrokerCli
  patch-uploader_/FirmwarePatchUploader
  cli_/Cli
  tmp-directory_/string

  constructor
      --fleet-id/Uuid
      --organization-id/Uuid
      --server-config/ServerConfig
      --broker-connection/BrokerCli
      --patch-uploader/FirmwarePatchUploader
      --cli/Cli
      --tmp-directory/string:
    fleet-id_ = fleet-id
    organization-id_ = organization-id
    server-config_ = server-config
    broker-connection_ = broker-connection
    patch-uploader_ = patch-uploader
    cli_ = cli
    tmp-directory_ = tmp-directory

  static is-existing-tag-error_ error -> bool:
    if error is not string: return false
    return error.contains "duplicate key value" or error.contains "already exists"

  upload --pod/Pod --tags/List --force-tags/bool -> UploadResult:
    patch-uploader_.upload-trivial-patches --pod=pod

    pod.split: | manifest/Map parts/Map |
      parts.do: | id/string contents/ByteArray |
        // Only upload if we don't have it in our cache.
        key := cache-key-pod-parts
            --broker-config=server-config_
            --organization-id=organization-id_
            --part-id=id
        cli_.cache.get-file-path key: | store/FileStore |
          broker-connection_.pod-registry-upload-pod-part contents --part-id=id
              --organization-id=organization-id_
          store.save contents
      key := cache-key-pod-manifest
          --broker-config=server-config_
          --organization-id=organization-id_
          --pod-id=pod.id
      cli_.cache.get-file-path key: | store/FileStore |
        encoded := ubjson.encode manifest
        broker-connection_.pod-registry-upload-pod-manifest encoded --pod-id=pod.id
            --organization-id=organization-id_
        store.save encoded

    description-ids := broker-connection_.pod-registry-descriptions
        --fleet-id=fleet-id_
        --organization-id=organization-id_
        --names=[pod.name]
        --create-if-absent

    description-id := (description-ids[0] as PodRegistryDescription).id

    broker-connection_.pod-registry-add
        --pod-description-id=description-id
        --pod-id=pod.id

    tag-errors := []
    tags.do: | tag/string |
      force := force-tags or (tag == "latest")
      exception := catch --unwind=(: not is-existing-tag-error_ it):
        broker-connection_.pod-registry-tag-set
            --pod-description-id=description-id
            --pod-id=pod.id
            --tag=tag
            --force=force
      if exception:
        tag-errors.add "Tag '$tag' already exists for pod $pod.name."

    registered-pods := broker-connection_.pod-registry-pods --fleet-id=fleet-id_ --pod-ids=[pod.id]
    pod-entry/PodRegistryEntry := registered-pods[0]

    sorted-uploaded-tags := pod-entry.tags.sort
    return UploadResult
        --fleet-id=fleet-id_
        --id=pod.id
        --name=pod.name
        --revision=pod-entry.revision
        --tags=sorted-uploaded-tags
        --tag-errors=tag-errors

  is-cached --pod-id/Uuid -> bool:
    manifest-key := cache-key-pod-manifest
        --broker-config=server-config_
        --organization-id=organization-id_
        --pod-id=pod-id
    return cli_.cache.contains manifest-key

  download --pod-id/Uuid -> Pod:
    manifest-key := cache-key-pod-manifest
        --broker-config=server-config_
        --organization-id=organization-id_
        --pod-id=pod-id
    encoded-manifest := cli_.cache.get manifest-key: | store/FileStore |
      bytes := broker-connection_.pod-registry-download-pod-manifest
        --pod-id=pod-id
        --organization-id=organization-id_
      store.save bytes
    manifest := ubjson.decode encoded-manifest
    return Pod.from-manifest
        manifest
        --tmp-directory=tmp-directory_
        --download=: | part-id/string |
          key := cache-key-pod-parts
              --broker-config=server-config_
              --organization-id=organization-id_
              --part-id=part-id
          cli_.cache.get key: | store/FileStore |
            bytes := broker-connection_.pod-registry-download-pod-part
                part-id
                --organization-id=organization-id_
            store.save bytes

  list-pods --names/List -> Map:
    descriptions := ?
    if names.is-empty:
      descriptions = broker-connection_.pod-registry-descriptions --fleet-id=fleet-id_
    else:
      descriptions = broker-connection_.pod-registry-descriptions
          --fleet-id=fleet-id_
          --organization-id=organization-id_
          --names=names
          --no-create-if-absent
    result := {:}
    descriptions.do: | description/PodRegistryDescription |
      pods := broker-connection_.pod-registry-pods --pod-description-id=description.id
      result[description] = pods
    return result

  delete --description-names/List -> none:
    descriptions := broker-connection_.pod-registry-descriptions
        --fleet-id=fleet-id_
        --organization-id=organization-id_
        --names=description-names
        --no-create-if-absent
    unknown-pod-descriptions := []
    description-names.do: | name/string |
      was-found := descriptions.any: | description/PodRegistryDescription |
        description.name == name
      if not was-found: unknown-pod-descriptions.add name
    if not unknown-pod-descriptions.is-empty:
      if unknown-pod-descriptions.size == 1:
        cli_.ui.abort "Unknown pod '$unknown-pod-descriptions[0]'."
      else:
        quoted := unknown-pod-descriptions.map: "'$it'"
        joined := quoted.join ", "
        cli_.ui.abort "Unknown pods $joined."
    broker-connection_.pod-registry-descriptions-delete
        --fleet-id=fleet-id_
        --description-ids=descriptions.map: it.id

  delete --pod-references/List -> none:
    pod-ids := get-pod-ids pod-references
    delete --pod-ids=pod-ids

  delete --pod-ids/List -> none:
    broker-connection_.pod-registry-delete
        --fleet-id=fleet-id_
        --pod-ids=pod-ids

  add-tags --tags/List --force/bool --references/List -> none:
    references = references.map: | reference/PodReference |
      reference.is-name-only
          ? reference.with --tag="latest"
          : reference

    pod-ids := get-pod-ids references
    pod-entries := broker-connection_.pod-registry-pods
        --fleet-id=fleet-id_
        --pod-ids=pod-ids

    mapping := {:}
    for i := 0; i < pod-ids.size; i++:
      mapping[pod-ids[i]] = references[i]

    tag-errors := []
    tags.do: | tag/string |
      pod-entries.do: | pod-entry/PodRegistryEntry |
        exception := catch --unwind=(: not is-existing-tag-error_ it):
          broker-connection_.pod-registry-tag-set
              --pod-description-id=pod-entry.pod-description-id
              --pod-id=pod-entry.id
              --tag=tag
              --force=force
        if exception:
          ref/PodReference := mapping[pod-entry.id]
          tag-errors.add "Tag '$tag' already exists for pod $ref.name."

    if not tag-errors.is-empty:
      tag-errors.do: cli_.ui.emit --error it
      cli_.ui.abort

  remove-tags --tags/List --references/List -> none:
    names := {}
    references.do: | reference/PodReference |
      assert: reference.is-name-only
      names.add reference.name

    descriptions := broker-connection_.pod-registry-descriptions
        --fleet-id=fleet-id_
        --organization-id=organization-id_
        --names=names.to-list
        --no-create-if-absent

    descriptions.do: | description/PodRegistryDescription |
      description-id := description.id
      tags.do: | tag/string |
        broker-connection_.pod-registry-tag-remove
            --pod-description-id=description-id
            --tag=tag

  get-pod-ids references/List -> List:
    references.do: | reference/PodReference |
      if not reference.id:
        if not reference.name:
          throw "Either id or name must be specified: $reference"
        if not reference.tag and not reference.revision:
          throw "Either tag or revision must be specified: $reference"

    missing-ids := references.filter: | reference/PodReference |
      not reference.id
    pod-ids-response := broker-connection_.pod-registry-pod-ids
        --fleet-id=fleet-id_
        --references=missing-ids

    has-errors := false
    result := references.map: | reference/PodReference |
      if reference.id: continue.map reference.id
      resolved := pod-ids-response.get reference
      if not resolved:
        has-errors = true
        if reference.tag:
          cli_.ui.emit --error "No pod with name '$reference.name' and tag '$reference.tag' in the fleet."
        else:
          cli_.ui.emit --error "No pod with name '$reference.name' and revision $reference.revision in the fleet."
      resolved
    if has-errors: cli_.ui.abort
    return result

  pod pod-id/Uuid -> PodInfo:
    pod-entry := broker-connection_.pod-registry-pods
        --fleet-id=fleet-id_
        --pod-ids=[pod-id]
    if not pod-entry.is-empty:
      description-id := pod-entry[0].pod-description-id
      description := broker-connection_.pod-registry-descriptions --ids=[description-id]
      if not description.is-empty:
        return PodInfo --id=pod-id --name=description[0].name --revision=pod-entry[0].revision --tags=pod-entry[0].tags

    return PodInfo --id=pod-id --name=null --revision=null --tags=null

  get-pod-id reference/PodReference -> Uuid:
    return (get-pod-ids [reference])[0]

  get-pod-id --name/string --tag/string? --revision/int? -> Uuid:
    return get-pod-id (PodReference --name=name --tag=tag --revision=revision)

  pod-exists reference/PodReference -> bool:
    pod-id := get-pod-id reference
    pod-entry := broker-connection_.pod-registry-pods
        --fleet-id=fleet-id_
        --pod-ids=[pod-id]
    return not pod-entry.is-empty

  get-pod-registry-entry-map --pod-ids/List -> Map:
    pod-id-entries := broker-connection_.pod-registry-pods
        --fleet-id=fleet-id_
        --pod-ids=pod-ids
    pod-entry-map := {:}
    pod-id-entries.do: | entry/PodRegistryEntry |
      pod-entry-map[entry.id] = entry
    return pod-entry-map

  get-pod-descriptions --pod-registry-entries/List -> Map:
    description-set := {}
    description-set.add-all
        (pod-registry-entries.map: | entry/PodRegistryEntry | entry.pod-description-id)
    description-ids := []
    description-ids.add-all description-set
    descriptions := broker-connection_.pod-registry-descriptions --ids=description-ids
    description-map := {:}
    descriptions.do: | description/PodRegistryDescription |
      description-map[description.id] = description
    return description-map
