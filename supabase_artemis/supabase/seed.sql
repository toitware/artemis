insert into public.organizations(id, name)
values('4b6d9e35-cae9-44c0-8da0-6b0e485987e2', 'Test Organization');

insert into public.devices(id, alias, organization_id)
values('eb45c662-356c-4bea-ad8c-ede37688fddf',
       '191149e5-a95b-47b1-80dd-b149f953d272',
       '4b6d9e35-cae9-44c0-8da0-6b0e485987e2');

-- Add users:
--  * "test@example.com" with password "password"
--  * "demo@example.com" with password "password"
INSERT INTO auth.users (instance_id,id,aud,"role",email,encrypted_password,email_confirmed_at,last_sign_in_at,raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at,phone,phone_confirmed_at,confirmation_token,email_change,email_change_token_new,recovery_token) VALUES
	('00000000-0000-0000-0000-000000000000'::uuid,'f76629c5-a070-4bbc-9918-64beaea48848'::uuid,'authenticated','authenticated','test@example.com','$2a$10$PznXR5VSgzjnAp7T/X7PCu6vtlgzdFt1zIr41IqP0CmVHQtShiXxS','2022-02-11 21:02:04.547','2022-02-11 22:53:12.520','{"provider": "email", "providers": ["email"]}','{}',FALSE,'2022-02-11 21:02:04.542','2022-02-11 21:02:04.542',NULL,NULL,'','','',''),
	('00000000-0000-0000-0000-000000000000'::uuid,'d9064bb5-1501-4ec9-bfee-21ab74d645b8'::uuid,'authenticated','authenticated','demo@example.com','$2a$10$mOJUAphJbZR4CdM38.bgOeyySurPeFHoH/T1s7HuGdpRb7JgatF7K','2022-02-12 07:40:23.616','2022-02-12 07:40:23.621','{"provider": "email", "providers": ["email"]}','{}',FALSE,'2022-02-12 07:40:23.612','2022-02-12 07:40:23.613',NULL,NULL,'','','',''),
	('00000000-0000-0000-0000-000000000000'::uuid,'6ac69de5-7b56-4153-a31c-7b4e29bbcbcf'::uuid,'authenticated','authenticated','test-admin@toit.io','$2a$10$BzysDkdyOfTA40JOja2SFeFOh9MDU1MeMD9DjOrLSUiRDKJ6VgIR.','2023-01-10 16:58:19.57372+00','2023-01-10 16:58:19.57372+00','{"provider": "email", "providers": ["email"]}','{}',FALSE,'2023-01-10 16:58:19.57372+00','2023-01-10 16:58:19.57372+00',NULL,NULL,'','','','')
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.identities (id,user_id,identity_data,provider,last_sign_in_at,created_at,updated_at) VALUES
	('f76629c5-a070-4bbc-9918-64beaea48848','f76629c5-a070-4bbc-9918-64beaea48848'::uuid,'{"sub": "f76629c5-a070-4bbc-9918-64beaea48848"}','email','2022-02-11 21:02:04.545','2022-02-11 21:02:04.545','2022-02-11 21:02:04.545'),
	('d9064bb5-1501-4ec9-bfee-21ab74d645b8','d9064bb5-1501-4ec9-bfee-21ab74d645b8'::uuid,'{"sub": "d9064bb5-1501-4ec9-bfee-21ab74d645b8"}','email','2022-02-12 07:40:23.615','2022-02-12 07:40:23.615','2022-02-12 07:40:23.615'),
	('6ac69de5-7b56-4153-a31c-7b4e29bbcbcf','6ac69de5-7b56-4153-a31c-7b4e29bbcbcf'::uuid,'{"sub": "6ac69de5-7b56-4153-a31c-7b4e29bbcbcf"}','email','2023-01-10 16:58:19.57372+00','2023-01-10 16:58:19.57372+00','2023-01-10 16:58:19.57372+00')
ON CONFLICT (id, provider) DO NOTHING;

INSERT INTO public.roles(user_id, organization_id, role)
VALUES
  ('f76629c5-a070-4bbc-9918-64beaea48848', '4b6d9e35-cae9-44c0-8da0-6b0e485987e2', 'admin'),
  ('d9064bb5-1501-4ec9-bfee-21ab74d645b8', '4b6d9e35-cae9-44c0-8da0-6b0e485987e2', 'member');

UPDATE public.profiles
  SET name = 'Test User'
  WHERE id = 'f76629c5-a070-4bbc-9918-64beaea48848';

UPDATE public.profiles
  SET name = 'Demo User'
  WHERE id = 'd9064bb5-1501-4ec9-bfee-21ab74d645b8';

UPDATE public.profiles
  SET name = 'Admin User'
  WHERE id = '6ac69de5-7b56-4153-a31c-7b4e29bbcbcf';

INSERT INTO public.admins (id) VALUES ('6ac69de5-7b56-4153-a31c-7b4e29bbcbcf');
