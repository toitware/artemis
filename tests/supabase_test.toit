// Copyright (C) 2022 Toitware ApS.

import supabase
import .supabase_local_server

import expect show *

expect_throws --contains/string [block]:
  exception := catch: block.call
  expect_not_null exception
  expect (exception.contains contains)

main:
  // TODO(florian): this test and the corresponding supabase server should be
  // moved to the supabase package.
  config := get_supabase_config --sub_directory="supabase_test"

  client := supabase.Client --server_config=config
      --certificate_provider=: unreachable

  try:
    test_rest client
    // TODO(florian): write tests for storage and auth.
  finally:
    client.close

TEST_TABLE ::= "test_table"
// This table is write-only.
TEST_TABLE2 ::= "test_table2"
// This view gives full access to the test_table
TEST_TABLE2_VIEW ::= "test_table2_view"
RPC_ADD_42 ::= "rpc_add_test_table_42"
RPC_SUM ::= "rpc_sum"

test_rest client/supabase.Client:
  // Clear the test table in case we have leftovers from a previous run.
  client.rest.delete TEST_TABLE --filters=[]

  // The table should be empty now.
  rows := client.rest.select TEST_TABLE
  expect rows.is_empty

  // Insert a row.
  row := client.rest.insert TEST_TABLE {
    "name": "test",
    "value": 11,
  }
  expect row["name"] == "test"
  expect row["value"] == 11
  valid_id := row["id"]

  // Check that select sees the new row.
  rows = client.rest.select TEST_TABLE
  expect_equals 1 rows.size
  expect rows[0]["name"] == "test"
  expect rows[0]["value"] == 11

  // Update the row.
  client.rest.update TEST_TABLE --filters=[
    "id=eq.$rows[0]["id"]"
  ] {
    "value": 12,
  }
  // Check that the update succeeded.
  rows = client.rest.select TEST_TABLE
  expect_equals 1 rows.size
  expect rows[0]["name"] == "test"
  expect rows[0]["value"] == 12

  // We can also use 'upsert' to update the row.
  client.rest.upsert TEST_TABLE {
    "id": rows[0]["id"],
    "name": "test",
    "value": 13,
  }
  // Check that the update succeeded.
  rows = client.rest.select TEST_TABLE
  expect_equals 1 rows.size
  expect rows[0]["name"] == "test"
  expect rows[0]["value"] == 13

  // Alternatively, we can also ignore duplicates.
  client.rest.upsert TEST_TABLE --ignore_duplicates {
    "id": rows[0]["id"],
    "name": "test",
    "value": 14,
  }
  // Check that the update didn't do anything (ignoring the duplicate).
  rows = client.rest.select TEST_TABLE
  expect_equals 1 rows.size
  expect rows[0]["name"] == "test"
  expect rows[0]["value"] == 13

  // Upsert also works for inserting new rows.
  client.rest.upsert TEST_TABLE {
    "name": "test2",
    "value": 14,
  }
  // Check that the insert succeeded.
  rows = client.rest.select TEST_TABLE
  expect_equals 2 rows.size
  if rows[0]["name"] == "test":
    expect rows[0]["value"] == 13
    expect rows[1]["name"] == "test2"
    expect rows[1]["value"] == 14
  else:
    expect rows[0]["name"] == "test2"
    expect rows[0]["value"] == 14
    expect rows[1]["name"] == "test"
    expect rows[1]["value"] == 13

  // Use select with filters.
  rows = client.rest.select TEST_TABLE --filters=[
    "value=eq.14",
  ]
  expect_equals 1 rows.size
  expect rows[0]["name"] == "test2"
  expect rows[0]["value"] == 14

  // Check insert without returning the result.
  inserted := client.rest.insert TEST_TABLE --no-return_inserted {
    "name": "test3",
    "value": 15,
  }
  expect_null inserted
  // Check that the insert succeeded.
  rows = client.rest.select TEST_TABLE --filters=[
    "name=eq.test3",
  ]
  expect_equals 1 rows.size
  expect rows[0]["name"] == "test3"
  expect rows[0]["value"] == 15

  // We can't use the default 'insert' for writing into a table we can't read.
  expect_throws --contains="policy":
    client.rest.insert TEST_TABLE2 {
      "name": "test",
      "other_id": valid_id,
    }

  // Check that the table is still empty.
  rows = client.rest.select TEST_TABLE2_VIEW
  expect rows.is_empty

  // Run the same insert again, but this time with '--no-return_inserted'.
  // This time it should work.
  inserted = client.rest.insert TEST_TABLE2 --no-return_inserted {
    "name": "test 99",
    "other_id": valid_id,
  }
  expect_null inserted

  // Check that the insert succeeded.
  rows = client.rest.select TEST_TABLE2_VIEW
  expect_equals 1 rows.size
  expect rows[0]["name"] == "test 99"
  expect rows[0]["other_id"] == valid_id

  /*
  Reminder: test_table now has the following entries:
  [
    {id: 1, name: test, value: 13},
    {id: 2, name: test2, value: 14},
    {id: 3, name: test3, value: 15}
  ]
  */

  // Test update.
  client.rest.update TEST_TABLE --filters=[
    "name=eq.test",
  ] {
    "value": 100,
  }
  // Check that the update succeeded.
  rows = client.rest.select TEST_TABLE --filters=[
    "value=eq.100",
  ]
  expect_equals 1 rows.size
  expect rows[0]["name"] == "test"
  expect rows[0]["value"] == 100

  // Test update of multiple rows.
  client.rest.update TEST_TABLE --filters=[
    "value=lt.99",
  ] {
    "value": 200,
  }
  // Check that the update succeeded.
  rows = client.rest.select TEST_TABLE --filters=[
    "value=eq.200",
  ]
  expect_equals 2 rows.size
  if rows[0]["name"] == "test2":
    expect rows[0]["value"] == 200
    expect rows[1]["name"] == "test3"
    expect rows[1]["value"] == 200
  else:
    expect rows[0]["name"] == "test3"
    expect rows[0]["value"] == 200
    expect rows[1]["name"] == "test2"
    expect rows[1]["value"] == 200

  // Test delete.
  client.rest.delete TEST_TABLE --filters=[
    "name=eq.test",
  ]
  // Check that the delete succeeded.
  rows = client.rest.select TEST_TABLE --filters=[
    "name=eq.test",
  ]
  expect rows.is_empty

  rows = client.rest.select TEST_TABLE
  expect_equals 2 rows.size
  if rows[0]["name"] == "test2":
    expect rows[0]["value"] == 200
    expect rows[1]["name"] == "test3"
    expect rows[1]["value"] == 200
  else:
    expect rows[0]["name"] == "test3"
    expect rows[0]["value"] == 200
    expect rows[1]["name"] == "test2"
    expect rows[1]["value"] == 200

  // Put one more row into the table.
  client.rest.insert TEST_TABLE {
    "name": "test4",
    "value": 300,
  }

  // Test delete of multiple rows.
  client.rest.delete TEST_TABLE --filters=[
    "value=lt.250",
  ]
  // Check that the delete succeeded.
  rows = client.rest.select TEST_TABLE
  expect_equals 1 rows.size
  expect rows[0]["name"] == "test4"
  expect rows[0]["value"] == 300

  // Test rpc calls.
  result := client.rest.rpc RPC_ADD_42 {:}
  expect_null result
  // Check that the table now has the 42 entry.
  rows = client.rest.select TEST_TABLE --filters=[
    "value=eq.42",
  ]
  expect_equals 1 rows.size
  expect rows[0]["name"] == "rpc"


  result = client.rest.rpc RPC_SUM {
    "a": 1,
    "b": 2,
  }
  expect_equals 3 result
