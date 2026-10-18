-- =====================================================================
-- whatsapp_messages — starter schema for "WA Meta Direct — Inbound Starter"
--
-- Where to run : Supabase → SQL Editor → New query → paste → Run
-- Safe to re-run: yes (IF NOT EXISTS everywhere, FK added only if possible)
-- Environments  : run once per environment (dev / demo / production)
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1) Table
--    One row per WhatsApp message, incoming AND outgoing.
--    n8n writes incoming rows in "Log Incoming Message".
--    You write outgoing rows yourself after every send (HTTP Request node)
--    and "Update WhatsApp Status" updates their status later.
-- ---------------------------------------------------------------------
create table if not exists public.whatsapp_messages (
  id               bigint generated always as identity not null,
  registration_id  bigint null,                -- optional link to your own table (see step 2)
  wa_message_id    text null,                  -- wamid from Meta (unique)
  phone            text null,                  -- NULL when the user hides their number
  user_id          text null,                  -- BSUID, e.g. EG.1139... (always present)
  direction        text not null,              -- incoming | outgoing
  message_type     text null,                  -- text | image | audio | document | interactive | button | template ...
  content          text null,                  -- message text or media caption
  message_label    text null,                  -- outgoing only: your reply type (e.g. WELCOME_REPLY)
  button_reply     text null,                  -- incoming only: id of the button the user tapped
  button_title     text null,                  -- incoming only: title of the button the user tapped
  raw              jsonb null,                 -- full webhook body (incoming) or API response (outgoing)
  created_at       timestamptz not null default now(),
  status           text null,                  -- outgoing only: sent | delivered | read | failed
  status_at        timestamptz null,
  error            text null,                  -- failure reason from status webhook

  constraint whatsapp_messages_pkey primary key (id),
  constraint whatsapp_messages_wa_message_id_key unique (wa_message_id),

  constraint whatsapp_messages_direction_check
    check (direction = any (array['incoming', 'outgoing'])),

  constraint whatsapp_messages_status_check
    check (status is null or status = any (array['sent', 'delivered', 'read', 'failed'])),

  constraint whatsapp_messages_status_outgoing_only
    check (status is null or direction = 'outgoing'),

  constraint whatsapp_messages_phone_or_user
    check (phone is not null or user_id is not null)
);

-- ---------------------------------------------------------------------
-- 2) Optional FK → event_registrations
--    Added ONLY if that table exists in your project. Otherwise skipped
--    with a notice, and registration_id stays a plain column.
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.event_registrations') is not null
     and not exists (
       select 1 from pg_constraint
       where conname = 'whatsapp_messages_registration_id_fkey'
         and conrelid = 'public.whatsapp_messages'::regclass
     )
  then
    alter table public.whatsapp_messages
      add constraint whatsapp_messages_registration_id_fkey
      foreign key (registration_id) references public.event_registrations (id)
      on delete set null;
  elsif to_regclass('public.event_registrations') is null then
    raise notice 'event_registrations not found - FK skipped (this is fine).';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3) Indexes (wa_message_id is already indexed by its UNIQUE constraint)
-- ---------------------------------------------------------------------
create index if not exists whatsapp_messages_phone_idx
  on public.whatsapp_messages (phone);

create index if not exists whatsapp_messages_user_id_idx
  on public.whatsapp_messages (user_id);

create index if not exists whatsapp_messages_registration_idx
  on public.whatsapp_messages (registration_id);

create index if not exists whatsapp_messages_created_idx
  on public.whatsapp_messages (created_at desc);

create index if not exists whatsapp_messages_label_idx
  on public.whatsapp_messages (message_label)
  where message_label is not null;

-- ---------------------------------------------------------------------
-- 4) Security: RLS ON with no policies
--    → the public anon / authenticated keys can NOT read or write this table.
--    → n8n "Postgres node" (direct DB connection as postgres) still works.
-- ---------------------------------------------------------------------
alter table public.whatsapp_messages enable row level security;

-- ---------------------------------------------------------------------
-- 5) Column descriptions (visible in Supabase Table Editor)
-- ---------------------------------------------------------------------
comment on table  public.whatsapp_messages is
  'Every WhatsApp message in/out. One row per wamid (insert uses on conflict do nothing).';
comment on column public.whatsapp_messages.direction is
  'incoming = from user (webhook) | outgoing = sent by us (logged after HTTP Request node)';
comment on column public.whatsapp_messages.content is
  'Message text or media caption. NULL for button taps (see button_title).';
comment on column public.whatsapp_messages.message_label is
  'Outgoing only. Your reply type, e.g. WELCOME_REPLY, CONFIRMED_REPLY.';
comment on column public.whatsapp_messages.button_reply is
  'Incoming only. Button / list reply id (e.g. CONFIRM).';
comment on column public.whatsapp_messages.button_title is
  'Incoming only. Button / list text the user tapped (e.g. تأكيد الحجز).';
comment on column public.whatsapp_messages.status is
  'Outgoing only. sent → delivered → read (never goes back). failed overrides.';
comment on column public.whatsapp_messages.wa_message_id is
  'wamid from Meta. NULL when the send call failed and returned no id.';
comment on column public.whatsapp_messages.user_id is
  'BSUID (e.g. EG.1139...). phone may be NULL for users with hidden numbers.';

commit;

-- ---------------------------------------------------------------------
-- Quick check (optional): should return 16 columns
-- ---------------------------------------------------------------------
-- select column_name, data_type
-- from information_schema.columns
-- where table_schema = 'public' and table_name = 'whatsapp_messages'
-- order by ordinal_position;
