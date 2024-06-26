// Copyright (C) 2023 Toitware ApS. All rights reserved.

/* Artemis commands. */
COMMAND-CHECK-IN_ ::= 0
COMMAND-CREATE-DEVICE-IN-ORGANIZATION_ ::= 1
COMMAND-SIGN-UP_ ::= 2
COMMAND-SIGN-IN_ ::= 3
COMMAND-GET-ORGANIZATIONS_ ::= 4
COMMAND-UPDATE-CURRENT-USER_ ::= 18
/**
Command to notify the Artemis server that a device has been created.

To avoid accidental confusion with $COMMAND-NOTIFY-BROKER-CREATED_, the
  command has the same constants.
*/
COMMAND-NOTIFY-ARTEMIS-CREATED_ ::= 5
COMMAND-GET-ORGANIZATION-DETAILS_ ::= 6
COMMAND-CREATE-ORGANIZATION_ ::= 7
COMMAND-UPDATE-ORGANIZATION_ ::= 8
COMMAND-GET-ORGANIZATION-MEMBERS_ ::= 9
COMMAND-ORGANIZATION-MEMBER-ADD_ ::= 10
COMMAND-ORGANIZATION-MEMBER-REMOVE_ ::= 11
COMMAND-ORGANIZATION-MEMBER-SET-ROLE_ ::= 12
COMMAND-GET-PROFILE_ ::= 13
COMMAND-UPDATE-PROFILE_ ::= 14
COMMAND-LIST-SDK-SERVICE-VERSIONS_ ::= 15
COMMAND-DOWNLOAD-SERVICE-IMAGE_ ::= 16
COMMAND-UPLOAD-SERVICE-IMAGE_ ::= 17

ARTEMIS-COMMAND-TO-STRING ::= {
  COMMAND-CHECK-IN_: "check-in",
  COMMAND-CREATE-DEVICE-IN-ORGANIZATION_: "create-device-in-organization",
  COMMAND-SIGN-UP_: "sign-up",
  COMMAND-SIGN-IN_: "sign-in",
  COMMAND-GET-ORGANIZATIONS_: "get-organizations",
  COMMAND-UPDATE-CURRENT-USER_: "update-current-user",
  COMMAND-NOTIFY-ARTEMIS-CREATED_: "notify-artemis-created",
  COMMAND-GET-ORGANIZATION-DETAILS_: "get-organization-details",
  COMMAND-CREATE-ORGANIZATION_: "create-organization",
  COMMAND-UPDATE-ORGANIZATION_: "update-organization",
  COMMAND-GET-ORGANIZATION-MEMBERS_: "get-organization-members",
  COMMAND-ORGANIZATION-MEMBER-ADD_: "organization-member-add",
  COMMAND-ORGANIZATION-MEMBER-REMOVE_: "organization-member-remove",
  COMMAND-ORGANIZATION-MEMBER-SET-ROLE_: "organization-member-set-role",
  COMMAND-GET-PROFILE_: "get-profile",
  COMMAND-UPDATE-PROFILE_: "update-profile",
  COMMAND-LIST-SDK-SERVICE-VERSIONS_: "list-sdk-service-versions",
  COMMAND-DOWNLOAD-SERVICE-IMAGE_: "download-service-image",
  COMMAND-UPLOAD-SERVICE-IMAGE_: "upload-service-image"
}

/* Broker commands */
// When updating this list, also update the tools/http_servers/public/broker/constants.toit which
// contains a copy of this list.
COMMAND-UPLOAD_ ::= 1
COMMAND-DOWNLOAD_ ::= 2
COMMAND-DOWNLOAD-PRIVATE_ ::= 3
// As of 2024-03-22 unused. Newer CLIs use $COMMAND-UPDATE-GOALS_ instead.
COMMAND-UPDATE-GOAL_ ::= 4
COMMAND-GET-DEVICES_ ::= 5
/**
Command to notify the Artemis server that a broker has been created.

To avoid accidental confusion with $COMMAND-NOTIFY-ARTEMIS-CREATED_, the
  command has the same constants.
*/
COMMAND-NOTIFY-BROKER-CREATED_ ::= 6
COMMAND-GET-EVENTS_ ::= 7
COMMAND-UPDATE-GOALS_ ::= 8

COMMAND-GET-GOAL_ ::= 10
COMMAND-REPORT-STATE_ ::= 11
COMMAND-REPORT-EVENT_ ::= 12

COMMAND-POD-REGISTRY-DESCRIPTION-UPSERT_ ::= 100
COMMAND-POD-REGISTRY-ADD_ ::= 101
COMMAND-POD-REGISTRY-TAG-SET_ ::= 102
COMMAND-POD-REGISTRY-TAG-REMOVE_ ::= 103
COMMAND-POD-REGISTRY-DESCRIPTIONS_ ::= 104
COMMAND-POD-REGISTRY-DESCRIPTIONS-BY-IDS_ ::= 105
COMMAND-POD-REGISTRY-DESCRIPTIONS-BY-NAMES_ ::= 106
COMMAND-POD-REGISTRY-PODS_ ::= 107
COMMAND-POD-REGISTRY-PODS-BY-IDS_ ::= 108
COMMAND-POD-REGISTRY-POD-IDS-BY-REFERENCE_ ::= 109
COMMAND-POD-REGISTRY-DELETE-DESCRIPTIONS_ ::= 110
COMMAND-POD-REGISTRY-DELETE_ ::= 111

BROKER-COMMAND-TO-STRING ::= {
  COMMAND-UPLOAD_: "upload",
  COMMAND-DOWNLOAD_: "download",
  COMMAND-DOWNLOAD-PRIVATE_: "download-private",
  COMMAND-UPDATE-GOAL_: "update-goal",
  COMMAND-UPDATE-GOALS_: "update-goals",
  COMMAND-GET-DEVICES_: "get-devices",
  COMMAND-NOTIFY-BROKER-CREATED_: "notify-broker-created",
  COMMAND-GET-EVENTS_: "get-events",
  COMMAND-GET-GOAL_: "get-goal",
  COMMAND-REPORT-STATE_: "report-state",
  COMMAND-REPORT-EVENT_: "report-event",
  COMMAND-POD-REGISTRY-DESCRIPTION-UPSERT_: "pod-registry-description-upsert",
  COMMAND-POD-REGISTRY-ADD_: "pod-registry-add",
  COMMAND-POD-REGISTRY-TAG-SET_: "pod-registry-tag-set",
  COMMAND-POD-REGISTRY-TAG-REMOVE_: "pod-registry-tag-remove",
  COMMAND-POD-REGISTRY-DESCRIPTIONS_: "pod-registry-descriptions",
  COMMAND-POD-REGISTRY-DESCRIPTIONS-BY-IDS_: "pod-registry-descriptions-by-ids",
  COMMAND-POD-REGISTRY-DESCRIPTIONS-BY-NAMES_: "pod-registry-descriptions-by-names",
  COMMAND-POD-REGISTRY-PODS_: "pod-registry-pods",
  COMMAND-POD-REGISTRY-PODS-BY-IDS_: "pod-registry-pods-by-ids",
  COMMAND-POD-REGISTRY-POD-IDS-BY-REFERENCE_: "pod-registry-pod-ids-by-reference",
  COMMAND-POD-REGISTRY-DELETE-DESCRIPTIONS_: "pod-registry-delete-descriptions",
  COMMAND-POD-REGISTRY-DELETE_: "pod-registry-delete"
}
