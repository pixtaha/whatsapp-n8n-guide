-- =====================================================================
-- WhatsApp Inbox — full Supabase setup                     schema v1.1.0
--   Tables : configurations, dashboard_agents, whatsapp_contacts, whatsapp_messages
--   Storage: private bucket "whatsapp-media" + access policies
--   Extras : auto contact list (triggers), status timestamps, Realtime, RLS
--
-- How to run:
--   1) Set the schema name ONCE at the top (v_schema). Default: whatsapp
--   2) Supabase → SQL Editor → New query → paste this whole file → Run
--   3) Expose the schema for the dashboard (supabase-js), or it can't see the tables.
--      n8n (Postgres node) does not need this.
--        Supabase Cloud : Project Settings → Data API → Exposed schemas → add it
--        Self-hosted    : in .env add it to PGRST_DB_SCHEMAS
--                         (e.g. PGRST_DB_SCHEMAS=public,storage,graphql_public,whatsapp)
--                         then: docker compose up -d rest
--   Run it once per environment (dev / demo / production = separate projects).
--
-- Safe to re-run: everything uses IF NOT EXISTS / CREATE OR REPLACE /
-- DROP POLICY IF EXISTS. Running it on an older whatsapp_messages table
-- adds the missing columns and links old messages to contacts.
--
-- What changed in v1.1.0:
--   - status "played" (voice note played by the user) + played_at column
--   - statuses never go back (a late "delivered" can't overwrite "read");
--     "failed" always wins; "read" without "delivered" fills delivered_at
--   - reactions and system messages no longer change the chat list
--     (unread count, preview, 24h window); they are still logged
--   - whatsapp_schema_version() → the dashboard checks compatibility
--   - message index includes id (stable "load older messages" paging)
--
-- Who can do what:
--   n8n (Postgres node, user "postgres")     → everything (owner, bypasses RLS)
--   n8n upload to Storage (service_role key) → everything in Storage
--   Dashboard user in dashboard_agents       → read chats + media, mark read,
--                                               assign/archive, upload to outgoing/
--   Anyone else (anon key, random sign-up)   → nothing
-- =====================================================================

begin;

-- =====================================================================
-- ⬇️⬇️  اسم الـ schema: غيّره هنا بس (حروف صغيرة، من غير مسافات)  ⬇️⬇️
-- =====================================================================
do $$
declare
  v_schema text := 'whatsapp';   -- ← مثال: 'whatsapp' أو 'public'
begin
  execute format('create schema if not exists %I', v_schema);
  -- only for this transaction: every unqualified name below lands in v_schema
  perform set_config('search_path', format('%I', v_schema), true);
end $$;

-- =====================================================================
-- 0) App configuration (settings + secrets read by n8n "Load Config")
--    Server-only: RLS on, no policies, no grants → anon / authenticated
--    can't read it. Only the Postgres connection (n8n) can.
--    ⚠️ Anyone with the Postgres password, and every database backup,
--    can read these secrets. Treat backups as secret.
-- =====================================================================
create table if not exists configurations (
  id            serial primary key,
  environment   text not null default 'production',
  config_key    text not null,
  config_value  text not null,
  is_secret     boolean not null default false,
  description   text null,
  updated_at    timestamptz not null default now(),
  constraint configurations_environment_check
    check (environment in ('dev', 'demo', 'production')),
  constraint configurations_env_key_unique unique (environment, config_key)
);

create or replace function set_updated_at()
returns trigger
language plpgsql
set search_path from current
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_configurations_updated_at on configurations;
create trigger trg_configurations_updated_at
  before update on configurations
  for each row execute function set_updated_at();

-- defaults: "do nothing" so a re-run never overwrites real values
insert into configurations
  (environment, config_key, config_value, is_secret, description)
values
  ('production', 'graph_version',    'v26.0',                   false, 'إصدار Meta Graph API'),
  ('production', 'supabase_url',     'CHANGE_ME',               false, 'رابط مشروع Supabase (من غير / في الآخر)'),
  ('production', 'media_bucket',     'whatsapp-media',          false, 'اسم الـ bucket لملفات الواتساب'),
  ('production', 'ai_model',         'google/gemini-2.5-flash', false, 'موديل الرد'),
  ('production', 'transcribe_model', 'openai/whisper-1',        false, 'موديل تحويل الصوت لنص'),
  ('production', 'system_prompt',    'انت مساعد واتساب للنشاط ده. رد بالعامية المصرية، بشكل ودود ومختصر (من سطر لـ 4 سطور). لو مش عارف حاجة قول كده بصراحة ومتألّفش معلومات، واعرض تحويل العميل لموظف.', false, 'تعليمات البوت — غيّرها لاسم ونشاط العميل'),
  ('production', 'whatsapp_access_token',     'CHANGE_ME', true, 'Meta System User permanent token'),
  ('production', 'whatsapp_app_secret',       'CHANGE_ME', true, 'للتحقق من x-hub-signature-256'),
  ('production', 'whatsapp_verify_token',     'CHANGE_ME', true, 'لتأكيد الـ Webhook مع Meta'),
  ('production', 'openrouter_api_key',        'CHANGE_ME', true, 'مفتاح الـ AI provider'),
  ('production', 'supabase_service_role_key', 'CHANGE_ME', true, 'لرفع الملفات على Storage (SERVICE_KEY بتاع supabase-storage)')
on conflict (environment, config_key) do nothing;

-- =====================================================================
-- 1) Dashboard agents (who may open the inbox)
-- =====================================================================
create table if not exists dashboard_agents (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  text not null,
  role          text not null default 'agent',
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  constraint dashboard_agents_role_check check (role in ('admin', 'agent'))
);

-- true when the logged-in user is an active agent
create or replace function is_dashboard_agent()
returns boolean
language sql
stable
security definer
set search_path from current
as $$
  select exists (
    select 1
    from dashboard_agents a
    where a.id = (select auth.uid())
      and a.is_active
  );
$$;

-- =====================================================================
-- 2) Contacts (one row per WhatsApp user = the chat list)
-- =====================================================================
create table if not exists whatsapp_contacts (
  id                      bigint generated always as identity primary key,
  user_id                 text null,          -- BSUID (e.g. EG.1139...)
  phone                   text null,          -- null when the user hides it
  username                text null,
  name                    text null,          -- WhatsApp profile name
  registration_id         bigint null,
  last_message_at         timestamptz null,
  last_message_preview    text null,
  last_message_direction  text null,
  last_inbound_at         timestamptz null,   -- 24h customer service window starts here
  unread_count            integer not null default 0,
  assigned_to             uuid null references dashboard_agents (id) on delete set null,
  is_archived             boolean not null default false,
  tags                    text[] not null default '{}',
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),

  constraint whatsapp_contacts_user_id_key unique (user_id),
  constraint whatsapp_contacts_phone_key   unique (phone),
  constraint whatsapp_contacts_phone_or_user check (phone is not null or user_id is not null),
  constraint whatsapp_contacts_unread_check  check (unread_count >= 0),
  constraint whatsapp_contacts_direction_check
    check (last_message_direction is null or last_message_direction in ('incoming', 'outgoing'))
);

-- =====================================================================
-- 3) Messages (every message in / out)
-- =====================================================================
create table if not exists whatsapp_messages (
  id                bigint generated always as identity primary key,
  wa_message_id     text null,
  direction         text not null,
  created_at        timestamptz not null default now(),

  constraint whatsapp_messages_wa_message_id_key unique (wa_message_id)
);

-- every column is added separately, so an older table gets upgraded too
alter table whatsapp_messages
  -- identity & routing
  add column if not exists wa_message_id          text null,            -- wamid from Meta
  add column if not exists contact_id             bigint null,
  add column if not exists registration_id        bigint null,
  add column if not exists phone                  text null,
  add column if not exists user_id                text null,            -- BSUID
  -- content
  add column if not exists message_type           text null,            -- text, image, audio, video, document, sticker, location, interactive, button, reaction, template, unsupported, system...
  add column if not exists content                text null,            -- real text / caption
  add column if not exists message_label          text null,            -- outgoing: our reply type
  add column if not exists button_reply           text null,            -- incoming: button id
  add column if not exists button_title           text null,            -- incoming: button text
  add column if not exists context_wa_message_id  text null,            -- the message this one replies to
  add column if not exists template_name          text null,            -- outgoing template name
  add column if not exists sent_by                text null,            -- 'bot', 'system' or an agent uuid
  add column if not exists payload                jsonb null,           -- location / contacts / reaction / buttons we sent
  add column if not exists raw                    jsonb null,           -- full webhook or API response
  -- time
  add column if not exists wa_timestamp           timestamptz null,     -- time at Meta (incoming)
  -- delivery status (outgoing)
  add column if not exists status                 text null,
  add column if not exists status_at              timestamptz null,
  add column if not exists sent_at                timestamptz null,
  add column if not exists delivered_at           timestamptz null,
  add column if not exists read_at                timestamptz null,
  add column if not exists played_at              timestamptz null,     -- voice note played (v1.1.0)
  add column if not exists failed_at              timestamptz null,
  add column if not exists error                  text null,
  -- media
  add column if not exists media_id               text null,            -- Meta media id (incoming: valid 7 days)
  add column if not exists media_mime_type        text null,
  add column if not exists media_filename         text null,
  add column if not exists media_size_bytes       bigint null,
  add column if not exists media_sha256           text null,
  add column if not exists storage_path           text null,            -- path inside bucket whatsapp-media (NOT a URL)
  add column if not exists media_status           text null,            -- pending | stored | failed | expired
  add column if not exists media_error            text null;

-- constraints (added only if missing)
do $$
declare
  c record;
  v_reg regclass;
begin
  -- v1.1.0: the status list changed (+ played) → drop the old check so the loop re-adds it
  alter table whatsapp_messages drop constraint if exists whatsapp_messages_status_check;

  for c in
    select * from (values
      ('whatsapp_messages_direction_check',
       'check (direction in (''incoming'', ''outgoing''))'),
      ('whatsapp_messages_status_check',
       'check (status is null or status in (''sent'', ''delivered'', ''read'', ''played'', ''failed''))'),
      ('whatsapp_messages_status_outgoing_only',
       'check (status is null or direction = ''outgoing'')'),
      ('whatsapp_messages_phone_or_user',
       'check (phone is not null or user_id is not null)'),
      ('whatsapp_messages_media_status_check',
       'check (media_status is null or media_status in (''pending'', ''stored'', ''failed'', ''expired''))'),
      ('whatsapp_messages_contact_id_fkey',
       'foreign key (contact_id) references whatsapp_contacts (id) on delete set null')
    ) as t(conname, def)
  loop
    if not exists (
      select 1 from pg_constraint
      where conname = c.conname
        and conrelid = 'whatsapp_messages'::regclass
    ) then
      execute format('alter table whatsapp_messages add constraint %I %s', c.conname, c.def);
    end if;
  end loop;

  -- links to event_registrations, only in projects that have it
  -- (looked up in this schema first, then in public)
  v_reg := coalesce(to_regclass(format('%I.event_registrations', current_schema())),
                    to_regclass('public' || '.event_registrations'));
  if v_reg is not null then
    if not exists (select 1 from pg_constraint
                   where conname = 'whatsapp_messages_registration_id_fkey'
                     and conrelid = 'whatsapp_messages'::regclass) then
      execute format('alter table whatsapp_messages
        add constraint whatsapp_messages_registration_id_fkey
        foreign key (registration_id) references %s (id) on delete set null', v_reg);
    end if;
    if not exists (select 1 from pg_constraint
                   where conname = 'whatsapp_contacts_registration_id_fkey'
                     and conrelid = 'whatsapp_contacts'::regclass) then
      execute format('alter table whatsapp_contacts
        add constraint whatsapp_contacts_registration_id_fkey
        foreign key (registration_id) references %s (id) on delete set null', v_reg);
    end if;
  else
    raise notice 'event_registrations not found: registration_id foreign keys skipped.';
  end if;

  -- older tables were created without the unique → "on conflict (wa_message_id)" fails
  if to_regclass('whatsapp_messages_wa_message_id_key') is null then
    alter table whatsapp_messages
      add constraint whatsapp_messages_wa_message_id_key unique (wa_message_id);
  end if;
end $$;

-- =====================================================================
-- 4) Indexes
-- =====================================================================
-- v1.1.0: chat history paging uses (created_at, id) so two messages with the
-- same time are never skipped or shown twice → replaces the old index
drop index if exists whatsapp_messages_contact_created_idx;
create index if not exists whatsapp_messages_contact_created_id_idx
  on whatsapp_messages (contact_id, created_at desc, id desc);
create index if not exists whatsapp_messages_phone_idx
  on whatsapp_messages (phone);
create index if not exists whatsapp_messages_user_id_idx
  on whatsapp_messages (user_id);
create index if not exists whatsapp_messages_registration_idx
  on whatsapp_messages (registration_id);
create index if not exists whatsapp_messages_created_idx
  on whatsapp_messages (created_at desc);
create index if not exists whatsapp_messages_label_idx
  on whatsapp_messages (message_label) where message_label is not null;
create index if not exists whatsapp_messages_context_idx
  on whatsapp_messages (context_wa_message_id) where context_wa_message_id is not null;
create index if not exists whatsapp_messages_media_pending_idx
  on whatsapp_messages (created_at) where media_status = 'pending';

create index if not exists whatsapp_contacts_last_message_idx
  on whatsapp_contacts (last_message_at desc nulls last) where not is_archived;
create index if not exists whatsapp_contacts_assigned_idx
  on whatsapp_contacts (assigned_to) where assigned_to is not null;

-- =====================================================================
-- 5) Helper functions
-- =====================================================================

-- schema version: the dashboard calls it after login to check compatibility
create or replace function whatsapp_schema_version()
returns text
language sql
immutable
set search_path from current
as $$
  select '1.1.0'::text;
$$;

-- file extension from a MIME type ("audio/ogg; codecs=opus" → ogg)
create or replace function whatsapp_media_extension(p_mime text)
returns text
language sql
immutable
set search_path from current
as $$
  select case lower(trim(split_part(coalesce(p_mime, ''), ';', 1)))
    when 'image/jpeg'  then 'jpg'
    when 'image/png'   then 'png'
    when 'image/webp'  then 'webp'
    when 'video/mp4'   then 'mp4'
    when 'video/3gpp'  then '3gp'
    when 'audio/ogg'   then 'ogg'
    when 'audio/mpeg'  then 'mp3'
    when 'audio/mp4'   then 'm4a'
    when 'audio/aac'   then 'aac'
    when 'audio/amr'   then 'amr'
    when 'application/pdf' then 'pdf'
    when 'text/plain'      then 'txt'
    when 'application/msword' then 'doc'
    when 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' then 'docx'
    when 'application/vnd.ms-excel' then 'xls'
    when 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' then 'xlsx'
    when 'application/vnd.ms-powerpoint' then 'ppt'
    when 'application/vnd.openxmlformats-officedocument.presentationml.presentation' then 'pptx'
    else 'bin'
  end;
$$;

-- one place that decides where a file goes in the bucket:
--   incoming/2026/10/wamid.HBgM....ogg
-- Only ONE version may exist: a 4-arg and a 5-arg version together make
-- every call ambiguous. n8n calls it with 5 args (… created_at, media_filename);
-- the defaults keep 3-arg calls working.
drop function if exists whatsapp_media_path(text, text, text, timestamptz);

create or replace function whatsapp_media_path(
  p_direction     text,
  p_wa_message_id text,
  p_mime          text,
  p_at            timestamptz default now(),
  p_filename      text default null
)
returns text
language sql
stable
set search_path from current
as $$
  select p_direction
      || '/' || to_char(coalesce(p_at, now()) at time zone 'UTC', 'YYYY/MM')
      || '/' || regexp_replace(p_wa_message_id, '[^A-Za-z0-9._-]', '_', 'g')
      || '.' || case
                  -- unknown MIME (e.g. a .zip document) → use the file's own extension
                  when whatsapp_media_extension(p_mime) = 'bin'
                   and lower(substring(coalesce(p_filename, '') from '\.([A-Za-z0-9]{1,8})$')) is not null
                  then lower(substring(p_filename from '\.([A-Za-z0-9]{1,8})$'))
                  else whatsapp_media_extension(p_mime)
                end;
$$;

-- short text for the chat list
create or replace function whatsapp_message_preview(
  p_content       text,
  p_message_type  text,
  p_button_title  text,
  p_filename      text,
  p_payload       jsonb
)
returns text
language sql
immutable
set search_path from current
as $$
  select left(coalesce(
    nullif(trim(p_content), ''),
    nullif(trim(p_button_title), ''),
    case p_message_type
      when 'image'       then '📷 صورة'
      when 'video'       then '🎥 فيديو'
      when 'audio'       then '🎤 رسالة صوتية'
      when 'document'    then '📄 ' || coalesce(p_filename, 'مستند')
      when 'sticker'     then '🏷️ ملصق'
      when 'location'    then '📍 موقع'
      when 'contacts'    then '👤 جهة اتصال'
      when 'reaction'    then 'تفاعل ' || coalesce(p_payload ->> 'emoji', '')
      when 'unsupported' then '⚠️ رسالة غير مدعومة'
      else p_message_type
    end
  ), 120);
$$;

-- find the contact for (user_id, phone) or create it; returns contact id
create or replace function whatsapp_upsert_contact(
  p_user_id          text,
  p_phone            text,
  p_name             text default null,
  p_username         text default null,
  p_registration_id  bigint default null
)
returns bigint
language plpgsql
security definer
set search_path from current
as $$
declare
  v_id bigint;
begin
  if p_user_id is null and p_phone is null then
    return null;
  end if;

  -- match order: user_id (BSUID) → phone
  if p_user_id is not null then
    select id into v_id from whatsapp_contacts where user_id = p_user_id;
  end if;
  if v_id is null and p_phone is not null then
    select id into v_id from whatsapp_contacts where phone = p_phone;
  end if;

  if v_id is null then
    begin
      insert into whatsapp_contacts (user_id, phone, name, username, registration_id)
      values (p_user_id, p_phone, p_name, p_username, p_registration_id)
      returning id into v_id;
      return v_id;
    exception when unique_violation then
      -- another message created it at the same moment
      select id into v_id from whatsapp_contacts
      where (p_user_id is not null and user_id = p_user_id)
         or (p_phone   is not null and phone   = p_phone)
      order by (user_id = p_user_id) desc nulls last
      limit 1;
    end;
  end if;

  -- fill missing identity fields (only if no other contact already owns them)
  update whatsapp_contacts c
  set user_id = case
        when c.user_id is null and p_user_id is not null
         and not exists (select 1 from whatsapp_contacts x where x.user_id = p_user_id)
        then p_user_id else c.user_id end,
      phone = case
        when c.phone is null and p_phone is not null
         and not exists (select 1 from whatsapp_contacts x where x.phone = p_phone)
        then p_phone else c.phone end,
      name            = coalesce(p_name, c.name),
      username        = coalesce(p_username, c.username),
      registration_id = coalesce(c.registration_id, p_registration_id)
  where c.id = v_id;

  return v_id;
end;
$$;

-- move a contact to a new BSUID (use on "user_changed_number" / "user_changed_user_id" system webhooks)
create or replace function whatsapp_change_user_id(
  p_previous_user_id text,
  p_new_user_id      text,
  p_new_phone        text default null
)
returns bigint
language plpgsql
security definer
set search_path from current
as $$
declare
  v_id bigint;
begin
  update whatsapp_contacts
  set user_id = p_new_user_id,
      phone   = coalesce(p_new_phone, phone)
  where user_id = p_previous_user_id
    and not exists (select 1 from whatsapp_contacts x where x.user_id = p_new_user_id)
  returning id into v_id;
  return v_id;
end;
$$;

-- =====================================================================
-- 6) Triggers
-- =====================================================================

-- BEFORE INSERT: link the message to its contact (creates the contact if new).
-- Never blocks logging: any problem here only leaves contact_id empty.
-- Name / username are read from raw → entry[0].changes[0].value.contacts.
-- If one webhook carries several messages, store per message a raw that has
-- the same shape but only that message and its contact (done in n8n Code node).
create or replace function whatsapp_messages_before_insert()
returns trigger
language plpgsql
security definer
set search_path from current
as $$
declare
  v_profile jsonb;
begin
  if new.contact_id is null then
    begin
      -- profile name / username from the webhook (incoming only)
      if new.direction = 'incoming'
         and jsonb_typeof(new.raw #> '{entry,0,changes,0,value,contacts}') = 'array' then
        select e.value into v_profile
        from jsonb_array_elements(new.raw #> '{entry,0,changes,0,value,contacts}') as e
        where e.value ->> 'user_id' = new.user_id
           or e.value ->> 'wa_id'   = new.phone
        limit 1;
      end if;

      new.contact_id := whatsapp_upsert_contact(
        new.user_id,
        new.phone,
        v_profile #>> '{profile,name}',
        v_profile #>> '{profile,username}',
        new.registration_id
      );
    exception when others then
      raise warning 'whatsapp contact link skipped for %: %', new.wa_message_id, sqlerrm;
    end;
  end if;
  return new;
end;
$$;

-- AFTER INSERT: update the chat list (runs only for real inserts,
-- so "on conflict do nothing" duplicates don't add unread messages).
-- v1.1.0: reactions and system messages are logged but do NOT touch the
-- chat list: no unread +1, no preview change, no 24h window change.
-- (The dashboard shows a reaction on the message in context_wa_message_id.)
create or replace function whatsapp_messages_after_insert()
returns trigger
language plpgsql
security definer
set search_path from current
as $$
declare
  v_at timestamptz := coalesce(new.wa_timestamp, new.created_at, now());
begin
  if new.contact_id is null
     or new.message_type in ('reaction', 'system') then
    return null;
  end if;

  begin
    update whatsapp_contacts c
    set last_message_preview = case
          when c.last_message_at is null or v_at >= c.last_message_at
          then whatsapp_message_preview(new.content, new.message_type, new.button_title, new.media_filename, new.payload)
          else c.last_message_preview end,
        last_message_direction = case
          when c.last_message_at is null or v_at >= c.last_message_at
          then new.direction else c.last_message_direction end,
        last_message_at = greatest(c.last_message_at, v_at),
        last_inbound_at = case
          when new.direction = 'incoming' then greatest(c.last_inbound_at, v_at)
          else c.last_inbound_at end,
        unread_count = c.unread_count + case when new.direction = 'incoming' then 1 else 0 end,
        is_archived  = case when new.direction = 'incoming' then false else c.is_archived end
    where c.id = new.contact_id;
  exception when others then
    raise warning 'whatsapp chat list update skipped for %: %', new.wa_message_id, sqlerrm;
  end;
  return null;
end;
$$;

-- BEFORE UPDATE OF status: statuses only move forward and keep one
-- timestamp each (for ✓ ✓✓ blue ✓✓ and played).
--   order: sent(1) → delivered(2) → read(3) → played(4); failed(9) always wins
--   Meta does not promise order: a late "delivered" after "read" is ignored.
--   "read" / "played" without the earlier steps fill those timestamps too.
create or replace function whatsapp_messages_status_times()
returns trigger
language plpgsql
set search_path from current
as $$
declare
  v_at  timestamptz := coalesce(new.status_at, now());
  v_old int := case old.status when 'sent' then 1 when 'delivered' then 2
                 when 'read' then 3 when 'played' then 4 when 'failed' then 9 else 0 end;
  v_new int := case new.status when 'sent' then 1 when 'delivered' then 2
                 when 'read' then 3 when 'played' then 4 when 'failed' then 9 else 0 end;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  -- an older status arrived late → keep the current one
  if v_new < v_old then
    new.status    := old.status;
    new.status_at := old.status_at;
    return new;
  end if;

  case new.status
    when 'sent' then
      new.sent_at      := coalesce(new.sent_at, v_at);
    when 'delivered' then
      new.delivered_at := coalesce(new.delivered_at, v_at);
    when 'read' then
      new.read_at      := coalesce(new.read_at, v_at);
      new.delivered_at := coalesce(new.delivered_at, v_at);
    when 'played' then
      new.played_at    := coalesce(new.played_at, v_at);
      new.read_at      := coalesce(new.read_at, v_at);
      new.delivered_at := coalesce(new.delivered_at, v_at);
    when 'failed' then
      new.failed_at    := coalesce(new.failed_at, v_at);
    else
      null;
  end case;
  return new;
end;
$$;

create or replace function whatsapp_contacts_touch()
returns trigger
language plpgsql
set search_path from current
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists whatsapp_messages_before_insert on whatsapp_messages;
create trigger whatsapp_messages_before_insert
  before insert on whatsapp_messages
  for each row execute function whatsapp_messages_before_insert();

drop trigger if exists whatsapp_messages_after_insert on whatsapp_messages;
create trigger whatsapp_messages_after_insert
  after insert on whatsapp_messages
  for each row execute function whatsapp_messages_after_insert();

-- leftovers from an older quick fix (same job as whatsapp_messages_status_times)
drop trigger if exists trg_whatsapp_status_times on whatsapp_messages;
drop function if exists whatsapp_set_status_times();

drop trigger if exists whatsapp_messages_status_times on whatsapp_messages;
create trigger whatsapp_messages_status_times
  before update of status on whatsapp_messages
  for each row execute function whatsapp_messages_status_times();

drop trigger if exists whatsapp_contacts_touch on whatsapp_contacts;
create trigger whatsapp_contacts_touch
  before update on whatsapp_contacts
  for each row execute function whatsapp_contacts_touch();

-- =====================================================================
-- 7) Backfill: link existing messages to contacts (only rows not linked yet)
--    Old messages count as read (unread_count stays 0).
--    Reactions / system messages are linked but don't change the chat list.
-- =====================================================================
do $$
declare
  r record;
  v_contact_id bigint;
  v_profile jsonb;
begin
  for r in
    select * from whatsapp_messages
    where contact_id is null
      and (user_id is not null or phone is not null)
    order by created_at, id
  loop
    v_profile := null;
    if r.direction = 'incoming'
       and jsonb_typeof(r.raw #> '{entry,0,changes,0,value,contacts}') = 'array' then
      select e.value into v_profile
      from jsonb_array_elements(r.raw #> '{entry,0,changes,0,value,contacts}') as e
      where e.value ->> 'user_id' = r.user_id or e.value ->> 'wa_id' = r.phone
      limit 1;
    end if;

    v_contact_id := whatsapp_upsert_contact(
      r.user_id, r.phone,
      v_profile #>> '{profile,name}', v_profile #>> '{profile,username}',
      r.registration_id);

    update whatsapp_messages set contact_id = v_contact_id where id = r.id;

    continue when r.message_type in ('reaction', 'system');

    update whatsapp_contacts c
    set last_message_at        = coalesce(r.wa_timestamp, r.created_at),
        last_message_preview   = whatsapp_message_preview(r.content, r.message_type, r.button_title, r.media_filename, r.payload),
        last_message_direction = r.direction,
        last_inbound_at        = case when r.direction = 'incoming'
                                      then coalesce(r.wa_timestamp, r.created_at)
                                      else c.last_inbound_at end
    where c.id = v_contact_id;
  end loop;
end $$;

-- =====================================================================
-- 8) Security: RLS + grants
-- =====================================================================
alter table configurations    enable row level security;
alter table dashboard_agents  enable row level security;
alter table whatsapp_contacts enable row level security;
alter table whatsapp_messages enable row level security;

-- public API keys get nothing by default
revoke all on configurations, dashboard_agents, whatsapp_contacts, whatsapp_messages
  from anon, authenticated;
revoke all on sequence configurations_id_seq from anon, authenticated;
-- configurations: no grants and no policies on purpose (secrets live here)

-- schema access: nobody may create objects here; dashboard users may enter it
do $$
begin
  execute format('revoke create on schema %I from public', current_schema());
  execute format('grant usage on schema %I to authenticated, service_role', current_schema());
end $$;

-- agents: read everything they need, change only inbox fields on contacts
grant select on dashboard_agents  to authenticated;
grant select on whatsapp_messages to authenticated;
grant select on whatsapp_contacts to authenticated;
grant update (unread_count, assigned_to, is_archived, tags) on whatsapp_contacts to authenticated;

drop policy if exists "agents read agents" on dashboard_agents;
create policy "agents read agents" on dashboard_agents
  for select to authenticated
  using ((select is_dashboard_agent()));

drop policy if exists "agents read contacts" on whatsapp_contacts;
create policy "agents read contacts" on whatsapp_contacts
  for select to authenticated
  using ((select is_dashboard_agent()));

drop policy if exists "agents update contacts" on whatsapp_contacts;
create policy "agents update contacts" on whatsapp_contacts
  for update to authenticated
  using ((select is_dashboard_agent()))
  with check ((select is_dashboard_agent()));

drop policy if exists "agents read messages" on whatsapp_messages;
create policy "agents read messages" on whatsapp_messages
  for select to authenticated
  using ((select is_dashboard_agent()));

-- functions: only the server (n8n / postgres) may call the helpers
revoke execute on function
  whatsapp_upsert_contact(text, text, text, text, bigint),
  whatsapp_change_user_id(text, text, text),
  whatsapp_media_path(text, text, text, timestamptz, text),
  whatsapp_media_extension(text),
  whatsapp_message_preview(text, text, text, text, jsonb),
  whatsapp_messages_before_insert(),
  whatsapp_messages_after_insert(),
  whatsapp_messages_status_times(),
  whatsapp_contacts_touch(),
  set_updated_at()
  from public, anon, authenticated;

revoke execute on function is_dashboard_agent(), whatsapp_schema_version() from public, anon;
grant  execute on function is_dashboard_agent(), whatsapp_schema_version() to authenticated;

-- =====================================================================
-- 9) Realtime (new messages / chat list update live in the dashboard)
-- =====================================================================
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['whatsapp_messages', 'whatsapp_contacts'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime'
                       and schemaname = current_schema() and tablename = t) then
        execute format('alter publication supabase_realtime add table %I.%I', current_schema(), t);
      end if;
    end loop;
  else
    raise notice 'supabase_realtime publication not found: Realtime skipped.';
  end if;
end $$;

-- =====================================================================
-- 10) Storage: private bucket for all WhatsApp media
--   - public = false → direct links return an error; the dashboard uses
--     short signed URLs (createSignedUrl).
--   - file_size_limit = NULL → no bucket limit; the project's global limit
--     applies (Supabase Cloud Free: 50 MB; self-hosted: FILE_SIZE_LIMIT of the
--     storage service in docker-compose.yml — set it to 104857600 = 100 MB).
--     WhatsApp's largest file is 100 MB (documents).
--   - allowed_mime_types = NULL on purpose: users can send any document type,
--     and voice notes arrive as "audio/ogg; codecs=opus".
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('whatsapp-media', 'whatsapp-media', false, null, null)
on conflict (id) do update
  set public          = false,
      file_size_limit = excluded.file_size_limit;

-- agents can read (needed to create signed URLs)
drop policy if exists "whatsapp media: agents read" on storage.objects;
create policy "whatsapp media: agents read" on storage.objects
  for select to authenticated
  using (bucket_id = 'whatsapp-media' and (select is_dashboard_agent()));

-- agents can upload only into outgoing/ (sending a file from the dashboard)
drop policy if exists "whatsapp media: agents upload outgoing" on storage.objects;
create policy "whatsapp media: agents upload outgoing" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'whatsapp-media'
    and (storage.foldername(name))[1] = 'outgoing'
    and (select is_dashboard_agent())
  );
-- no update / delete policies: files are never changed from the dashboard

-- =====================================================================
-- 11) Documentation (visible in Supabase Table Editor)
-- =====================================================================
comment on table dashboard_agents  is 'People allowed to open the WhatsApp inbox. Add rows manually (see end of file).';
comment on table whatsapp_contacts is 'One row per WhatsApp user. Filled automatically by triggers on whatsapp_messages.';
comment on table whatsapp_messages is 'Every WhatsApp message in/out. One row per wamid. n8n inserts with on conflict do update (no-op) + returning (xmax = 0) as is_new, so retries still get storage_path.';
comment on table configurations    is 'Settings + secrets for n8n. Server-only (RLS, no policies). Values CHANGE_ME must be replaced. Backups contain these secrets.';

comment on function whatsapp_schema_version() is 'Schema version for the dashboard compatibility check. Bump it whenever this file changes.';

comment on column whatsapp_contacts.last_inbound_at is 'Last message FROM the user (reactions / system not counted). Free-form replies allowed for 24h after this; after that, templates only.';
comment on column whatsapp_contacts.unread_count    is 'Incoming messages (not reactions) since the agent last opened the chat. Dashboard sets it to 0.';

comment on column whatsapp_messages.message_type   is 'text, image, audio, video, document, sticker, location, contacts, interactive, button, reaction, template, unsupported, system. reaction / system never change the chat list.';
comment on column whatsapp_messages.content        is 'Real message text. incoming: user text. outgoing: body/caption we sent. NULL for button taps (see button_title).';
comment on column whatsapp_messages.message_label  is 'Outgoing only. Our reply type, e.g. CONFIRMED_REPLY, UNREGISTERED_REPLY.';
comment on column whatsapp_messages.button_reply   is 'Incoming only. Button / list reply id (e.g. CONFIRM).';
comment on column whatsapp_messages.button_title   is 'Incoming only. Button / list text the user tapped.';
comment on column whatsapp_messages.context_wa_message_id is 'wamid of the message this one replies to (context.id). For reactions: the message that was reacted to.';
comment on column whatsapp_messages.sent_by        is 'Outgoing only. bot | system | agent uuid.';
comment on column whatsapp_messages.payload        is 'Type-specific data: location, contacts, reaction ({"emoji": ...}; no emoji = reaction removed), buttons we sent.';
comment on column whatsapp_messages.wa_timestamp   is 'Message time at Meta (webhook timestamp). created_at = time we saved it.';
comment on column whatsapp_messages.status         is 'Outgoing only: sent → delivered → read → played (never goes back, enforced by trigger). failed overrides.';
comment on column whatsapp_messages.played_at      is 'First time the user played a voice note we sent (status played).';
comment on column whatsapp_messages.wa_message_id  is 'wamid from Meta. NULL when the send call failed and returned no id.';
comment on column whatsapp_messages.user_id        is 'BSUID. Always present on incoming; phone may be NULL for hidden numbers.';
comment on column whatsapp_messages.media_id       is 'Meta media id. Incoming ids expire after 7 days; download before that.';
comment on column whatsapp_messages.storage_path   is 'Path in bucket whatsapp-media. Build with whatsapp_media_path(). Never store a URL here.';
comment on column whatsapp_messages.media_status   is 'pending (not downloaded yet) | stored | failed | expired';

commit;

-- =====================================================================
-- After running
-- =====================================================================
-- Run these in a NEW query. Start it with the schema you chose, e.g.:
--
-- set search_path = whatsapp;
--
-- 0) Expose the schema for the dashboard:
--    Cloud      : Project Settings → Data API → Exposed schemas → add "whatsapp" → Save
--    Self-hosted: .env → PGRST_DB_SCHEMAS=...,whatsapp → docker compose up -d rest
--
-- 1) Add yourself as an agent (create the user first: Authentication → Users → Add user):
--
-- insert into dashboard_agents (id, display_name, role)
-- select id, 'Taha', 'admin' from auth.users where email = 'you@example.com';
--
-- 2) Fill the configuration (every CHANGE_ME). n8n stops with a clear error until you do:
--
-- update configurations set config_value = '...'
-- where environment = 'production' and config_key = 'whatsapp_access_token';
--
-- select config_key from configurations
-- where config_value in ('CHANGE_ME', '');            -- must return 0 rows
--
-- Self-hosted: supabase_service_role_key = SERVICE_KEY of the supabase-storage
-- container (docker inspect supabase-storage …). A key from another project
-- fails with "signature verification failed".
--
-- 3) Quick check:
--
-- select
--   whatsapp_schema_version()                                         as schema_version,   -- 1.1.0
--   (select count(*) from whatsapp_messages)                          as messages,
--   (select count(*) from whatsapp_messages where contact_id is null) as messages_without_contact,
--   (select count(*) from whatsapp_contacts)                          as contacts,
--   (select public from storage.buckets where id = 'whatsapp-media')  as bucket_is_public;   -- must be false
--
-- 4) Path for a new media file (use in a Postgres node):
--
-- select whatsapp_media_path('incoming', $1, $2, $3, $4) as storage_path;
--   -- $1 = wamid, $2 = mime type, $3 = created_at, $4 = original filename
--
-- 5) Mark media that can no longer be downloaded (incoming ids expire after 7 days):
--
-- update whatsapp_messages
-- set media_status = 'expired'
-- where media_status = 'pending' and direction = 'incoming'
--   and created_at < now() - interval '7 days';
