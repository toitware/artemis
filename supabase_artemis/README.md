# Supabase configuration of Artemis

If your checkout is up to date, your migrations folder should have
all DB schemas in it. That is, the DB layout on the server should match the
one that is created by the migration sql files.

You can start a local supabase instance with `supabase start` in this folder.
This uses the migrations to generate a local version of our Artemis server.
It also uses the seed.sql file to populate the database with some test data.
This test data is not used in production. Feel free to modify the seed.sql
file.

## Modifying the DB

If you don't change the DB you can work locally, but if you need to
modify the DB you need to connect to the server.

Use the supabase client (AUR: supabase-bin) to connect to the project:
```
supabase login
# For the next command:
# - create a token (it's for your account), and
# - use the database password from our bitwarden vault.
supabase link --project-ref uelhwhbsyumuqhbukich
```

There are two options to modify the DB:
- write migration scripts (SQL), or
- modify the DB using the studio. The studio URL is given by
  `supabase start` or `supabase status`.

Newly created migrations should be checked in, and should be reviewed.

### Migration scripts
Run `supabase migration new <name>` to create a new migration script.

This adds a new file to the migrations folder. You can apply the new
migration locally with `supabase db reset`.

The advantage of writing migration scripts by hand is that you can add
comments. However, it requires more understanding of SQL.

### Studio
Just modify the DB with the app. Once you are ready, run:
```
supabase db diff -f <name>
```

An SQL differ will automatically generate a migration script for you.
The scripts might be more verbose than necessary. You can edit them to
make them more readable.

### Synchronizing with the server
Once you are happy with your changes, you can commit them to the server.

The cleanest way would be to wait the review to finish, and let the buildbot
push the migrations. However, you can also push the migrations yourself using

```
supabase db push
```

You can see your and server's last migration timestamp with:
```
supabase migration list
```

The server stores its timestamp in `supabase_migrations.schema_migrations`. It
is possible to modify the value there (although not recommended).

#### Getting changes from the server
If the server was modified (instead of the local DB), you should be able to get
the latest changes with:
```
supabase db remote commit
```
This didn't work for me, though. I got an "error creating shadow database" error.

However, it looks like `supabase db diff --linked --use-migra` does a diff. The
resulting diff seems to include all functions. It might be necessary to manually
remove them.

It is probably necessary to update the `supabase_migrations.schema_migrations`
entry when doing a diff without the `commit` command.

In summary, if `supabase db remote commit` doesn't work, try the following:
```
supabase db diff --linked --use-migra -f <name>  # a simple name like "feature_x"
```
That generates a new file in the migrations folder. Then go to
https://app.supabase.com/project/uelhwhbsyumuqhbukich/editor/18031 and
update the version there.

Note: I haven't tested this. If you did, please update this file.

## References
https://supabase.com/docs/guides/cli/managing-environments
