-- Copyright (C) 2023 Toitware ApS. All rights reserved.

CREATE TABLE test_table (
  id serial PRIMARY KEY,
  name text NOT NULL,
  value int NOT NULL
);

CREATE TABLE test_table2 (
  id serial PRIMARY KEY,
  name text NOT NULL,
  -- Use a foreign key with cascade.
  -- This is the easiest way to clean out this table, since we only
  -- have write access to it (see below).
  other_id int REFERENCES test_table(id) ON DELETE CASCADE
);

ALTER TABLE test_table2 ENABLE ROW LEVEL SECURITY;

-- A policy that only allows inserting into test_table, but not select.
CREATE POLICY test_table_no_read_insert_policy ON test_table2
  FOR INSERT
  WITH CHECK (true);

-- A view into the table so we can check that the table was modified.
-- The view runs with the same permissions as the definer, which
-- gives us full access.
CREATE VIEW test_table2_view AS
  SELECT * FROM test_table2;

-- A simple function to test RPC calls.
CREATE OR REPLACE FUNCTION rpc_add_test_table_42()
RETURNS void
AS $$
  INSERT INTO test_table (name, value) VALUES ('rpc', 42);
$$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION rpc_sum(a int, b int)
RETURNS int
AS $$
  SELECT a + b;
$$ LANGUAGE SQL;

-- For testing that the authentication works.

CREATE TABLE test_table3 (
  id uuid PRIMARY KEY REFERENCES auth.users(id),
  value int NOT NULL
);

ALTER TABLE test_table3 ENABLE ROW LEVEL SECURITY;

-- Users can access their own row.
CREATE POLICY test_table3_self_access ON test_table3
  FOR ALL
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());
