CREATE POLICY "Enable read access for anon"
  ON "public"."events"
  AS PERMISSIVE FOR SELECT
  TO anon
  USING (true);
