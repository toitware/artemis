// Copyright (C) 2023 Toitware ApS.

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
    test_auth client
    // TODO(florian): write tests for storage.
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
  expect_equals "test" row["name"]
  expect_equals 11 row["value"]
  valid_id := row["id"]

  // Check that select sees the new row.
  rows = client.rest.select TEST_TABLE
  expect_equals 1 rows.size
  expect_equals "test" rows[0]["name"]
  expect_equals 11 rows[0]["value"]

  // Update the row.
  client.rest.update TEST_TABLE --filters=[
    "id=eq.$rows[0]["id"]"
  ] {
    "value": 12,
  }
  // Check that the update succeeded.
  rows = client.rest.select TEST_TABLE
  expect_equals 1 rows.size
  expect_equals "test" rows[0]["name"]
  expect_equals 12 rows[0]["value"]

  // We can also use 'upsert' to update the row.
  client.rest.upsert TEST_TABLE {
    "id": rows[0]["id"],
    "name": "test",
    "value": 13,
  }
  // Check that the update succeeded.
  rows = client.rest.select TEST_TABLE
  expect_equals 1 rows.size
  expect_equals "test" rows[0]["name"]
  expect_equals 13 rows[0]["value"]

  // Alternatively, we can also ignore duplicates.
  client.rest.upsert TEST_TABLE --ignore_duplicates {
    "id": rows[0]["id"],
    "name": "test",
    "value": 14,
  }
  // Check that the update didn't do anything (ignoring the duplicate).
  rows = client.rest.select TEST_TABLE
  expect_equals 1 rows.size
  expect_equals "test" rows[0]["name"]
  expect_equals 13 rows[0]["value"]

  // Upsert also works for inserting new rows.
  client.rest.upsert TEST_TABLE {
    "name": "test2",
    "value": 14,
  }
  // Check that the insert succeeded.
  rows = client.rest.select TEST_TABLE
  expect_equals 2 rows.size
  if rows[0]["name"] == "test":
    expect_equals 13 rows[0]["value"]
    expect_equals "test2" rows[1]["name"]
    expect_equals 14 rows[1]["value"]
  else:
    expect_equals "test2" rows[0]["name"]
    expect_equals 14 rows[0]["value"]
    expect_equals "test" rows[1]["name"]
    expect_equals 13 rows[1]["value"]

  // Use select with filters.
  rows = client.rest.select TEST_TABLE --filters=[
    "value=eq.14",
  ]
  expect_equals 1 rows.size
  expect_equals "test2" rows[0]["name"]
  expect_equals 14 rows[0]["value"]

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
  expect_equals "test3" rows[0]["name"]
  expect_equals 15 rows[0]["value"]

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
  expect_equals "test 99" rows[0]["name"]
  expect_equals valid_id rows[0]["other_id"]

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
  expect_equals "test" rows[0]["name"]
  expect_equals 100 rows[0]["value"]

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
    expect_equals 200 rows[0]["value"]
    expect_equals "test3" rows[1]["name"]
    expect_equals 200 rows[1]["value"]
  else:
    expect_equals "test3" rows[0]["name"]
    expect_equals 200 rows[0]["value"]
    expect_equals "test2" rows[1]["name"]
    expect_equals 200 rows[1]["value"]

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
    expect_equals 200 rows[0]["value"]
    expect_equals "test3" rows[1]["name"]
    expect_equals 200 rows[1]["value"]
  else:
    expect_equals "test3" rows[0]["name"]
    expect_equals 200 rows[0]["value"]
    expect_equals "test2" rows[1]["name"]
    expect_equals 200 rows[1]["value"]

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
  expect_equals "test4" rows[0]["name"]
  expect_equals 300 rows[0]["value"]

  // Test RPCs.
  result := client.rest.rpc RPC_ADD_42 {:}
  expect_null result
  // Check that the table now has the 42 entry.
  rows = client.rest.select TEST_TABLE --filters=[
    "value=eq.42",
  ]
  expect_equals 1 rows.size
  expect_equals "rpc" rows[0]["name"]


  result = client.rest.rpc RPC_SUM {
    "a": 1,
    "b": 2,
  }
  expect_equals 3 result

AUTH_PASSWORD ::= "123456"

AUTH_TABLE := "test_table3"

test_auth client/supabase.Client:
  email := "test-$random@toit.io"
  // The testing supabase server has 'enable_confirmations = false',
  // which means that we can sign up without worrying that emails
  // are sent.
  client.auth.sign_up --email=email --password=AUTH_PASSWORD

  // Log in.
  client.auth.sign_in --email=email --password=AUTH_PASSWORD

  // Check that we are logged in.
  current_user := client.auth.get_current_user
  expect_equals email current_user["email"]
  user_id := current_user["id"]

  // Verify that we send the user id with rest requests.
  rows := client.rest.select AUTH_TABLE
  expect rows.is_empty

  // Insert a row.
  inserted := client.rest.insert AUTH_TABLE {
    "id": user_id,
    "value": 13,
  }
  expect_equals user_id inserted["id"]
  expect_equals 13 inserted["value"]

  // Check that the insert succeeded.
  rows = client.rest.select AUTH_TABLE
  expect_equals 1 rows.size
  expect_equals user_id rows[0]["id"]
  expect_equals 13 rows[0]["value"]

  // TODO(florian): there doesn't seem to be a way to change the email
  // without triggering a confirmation email.
  // Even with the confirmation mail, I didn't get it to work.
  /*
  email2 := "test-$random@toit.io"
  client.auth.update_current_user {
    "email": email2,
  }
  */

  // TODO(florian): add log out and test it here.
  // For now just hackishly remove the session.
  client.session_ = null

  // Check that we are now anonymous and can see the entry in the test table.
  rows = client.rest.select AUTH_TABLE
  expect rows.is_empty
