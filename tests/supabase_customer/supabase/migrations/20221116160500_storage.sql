insert into storage.buckets (id, name, public)
values
  ('assets', 'assets', true)
  ;

create policy "Public Access"
on storage.objects for all
using (bucket_id = 'assets');
