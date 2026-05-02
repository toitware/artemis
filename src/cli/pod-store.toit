// Copyright (C) 2026 Toit contributors.

import uuid show Uuid

import .pod show Pod
import .pod-registry show PodReference

/**
A store of pods, scoped to a single (fleet, organization) pair.

Today the only implementation is broker-backed. Future implementations
  could store pods on a filesystem (for `git`-managed fleets) or fetch
  them from an HTTP-only source (for example a public release page).
*/
interface PodStore:
  /**
  Uploads $pod and registers it under its embedded name.

  Applies the given $tags after upload. If $force-tags is true, tags
    that already point to a different pod are moved; otherwise such tags
    are reported as errors in the result. The "latest" tag is always
    moved.

  Implementations may also upload trivial firmware patches as a side
    effect, so devices can later download upgrade patches without
    needing the original envelope.
  */
  upload --pod/Pod --tags/List --force-tags/bool -> UploadResult

  /**
  Downloads the pod with the given $pod-id, materialising it on disk.
  */
  download --pod-id/Uuid -> Pod

  /** Whether the pod with the given $pod-id is in the local cache. */
  is-cached --pod-id/Uuid -> bool

  /**
  Returns the pods of the given $names.

  If $names is empty, returns all pod descriptions in the fleet.

  Returns a map from $PodRegistryDescription to a List of
    $PodRegistryEntry instances.
  */
  list-pods --names/List -> Map

  /**
  Deletes pod descriptions (and all their entries) by name.

  Aborts via the CLI UI if any of the names do not exist.
  */
  delete --description-names/List -> none

  /**
  Deletes individual pods identified by reference.

  References are resolved to pod ids first; missing references abort.
  */
  delete --pod-references/List -> none

  /** Deletes individual pods by id. */
  delete --pod-ids/List -> none

  /**
  Sets $tags on the pods identified by $references.

  Name-only references are resolved against the "latest" tag. If
    $force is false, attempting to set an existing tag aborts via the
    CLI UI.
  */
  add-tags --tags/List --force/bool --references/List -> none

  /**
  Removes $tags from the pod descriptions named in $references.

  All references must be name-only.
  */
  remove-tags --tags/List --references/List -> none

  /**
  Resolves a list of $PodReference instances to their pod ids.

  Aborts via the CLI UI if any reference does not resolve.
  */
  get-pod-ids references/List -> List

  /** Resolves a single $reference to its pod id. */
  get-pod-id reference/PodReference -> Uuid

  /** Convenience for resolving by name + tag/revision. */
  get-pod-id --name/string --tag/string? --revision/int? -> Uuid

  /** Whether the given $reference resolves to an existing pod. */
  pod-exists reference/PodReference -> bool

  /**
  Returns metadata ($PodInfo) for the pod with the given $pod-id.

  If the pod does not exist, returns a $PodInfo with null fields.
  */
  pod pod-id/Uuid -> PodInfo

  /**
  Fetches pod entries for the given ids.

  Returns a map from pod id to $PodRegistryEntry.
  */
  get-pod-registry-entry-map --pod-ids/List -> Map

  /**
  Resolves the descriptions referenced by the given pod entries.

  Returns a map from description id to $PodRegistryDescription.
  */
  get-pod-descriptions --pod-registry-entries/List -> Map

/**
Result of $PodStore.upload.
*/
class UploadResult:
  fleet-id/Uuid
  id/Uuid
  name/string
  revision/int
  tags/List
  tag-errors/List

  constructor --.fleet-id --.id --.name --.revision --.tags --.tag-errors:

  to-json -> Map:
    result := {
      "fleet-id": "$fleet-id",
      "id": "$id",
      "name": name,
      "revision": revision,
      "tags": tags,
    }
    if not tag-errors.is-empty:
      result["tag-errors"] = tag-errors
    return result

/**
Lightweight metadata for a pod resolved by id.

Fields are null when the pod does not exist in the store.
*/
class PodInfo:
  id/Uuid
  name/string?
  revision/int?
  tags/List?

  constructor --.id --.name --.revision --.tags:
