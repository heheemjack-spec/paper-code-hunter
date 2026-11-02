-- Secure cloud redeem codes for Paper Code Hunter.
-- Run once in Supabase SQL Editor. Never expose service-role credentials in the client.

create table if not exists public.pch_redeem_codes (
  code text primary key check (code ~ '^[A-Z0-9_-]{3,32}$'),
  coins integer not null default 0 check (coins between 0 and 1000000),
  keys integer not null default 0 check (keys between 0 and 1000000),
  certs integer not null default 0 check (certs between 0 and 1000000),
  is_trap boolean not null default false,
  category text,
  expires_at timestamptz,
  mini boolean not null default false,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.pch_code_redemptions (
  id bigint generated always as identity primary key,
  code text not null references public.pch_redeem_codes(code) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  category text,
  redeemed_at timestamptz not null default now(),
  unique(code,user_id)
);
create unique index if not exists pch_one_code_per_category
  on public.pch_code_redemptions(user_id,category) where category is not null;

alter table public.pch_redeem_codes enable row level security;
alter table public.pch_code_redemptions enable row level security;
revoke all on public.pch_redeem_codes, public.pch_code_redemptions from anon, authenticated;
grant select,insert,update,delete on public.player_state to authenticated;

-- Client-side state saves cannot alter economy or redemption history.
create or replace function public.pch_guard_player_economy()
returns trigger language plpgsql set search_path=public
as $$
begin
  if current_setting('pch.secure_economy', true) = 'on' then
    return new;
  end if;
  if auth.uid() is not null then
    if tg_op = 'UPDATE' then
      new.state := coalesce(new.state,'{}'::jsonb)
        || jsonb_build_object(
          'coins', coalesce(old.state->'coins','100'::jsonb),
          'keys', coalesce(old.state->'keys','3'::jsonb),
          'certs', coalesce(old.state->'certs','0'::jsonb),
          'used', coalesce(old.state->'used','[]'::jsonb),
          'cu', coalesce(old.state->'cu','{}'::jsonb),
          'fx', coalesce(old.state->'fx','{}'::jsonb)
        );
    else
      new.state := coalesce(new.state,'{}'::jsonb)
        || jsonb_build_object('coins',100,'keys',3,'certs',0,'used','[]'::jsonb,'cu','{}'::jsonb,'fx','{}'::jsonb);
    end if;
  end if;
  return new;
end $$;

drop trigger if exists pch_guard_player_economy on public.player_state;
create trigger pch_guard_player_economy
before insert or update on public.player_state
for each row execute function public.pch_guard_player_economy();

create or replace function public.admin_create_redeem_code(
  p_code text, p_coins integer default 0, p_keys integer default 0,
  p_certs integer default 0, p_is_trap boolean default false,
  p_category text default null, p_expires_at timestamptz default null,
  p_mini boolean default false
) returns jsonb
language plpgsql security definer set search_path=public,auth
as $$
declare v_code text := upper(trim(p_code));
begin
  if auth.uid() is null or not public.is_admin() then
    return jsonb_build_object('success',false,'message','ไม่มีสิทธิ์สร้างโค้ด');
  end if;
  if v_code !~ '^[A-Z0-9_-]{3,32}$'
     or coalesce(p_coins,0) not between 0 and 1000000
     or coalesce(p_keys,0) not between 0 and 1000000
     or coalesce(p_certs,0) not between 0 and 1000000 then
    return jsonb_build_object('success',false,'message','ข้อมูลโค้ดไม่ถูกต้อง');
  end if;
  insert into public.pch_redeem_codes(code,coins,keys,certs,is_trap,category,expires_at,mini,created_by)
  values(v_code,coalesce(p_coins,0),coalesce(p_keys,0),case when p_is_trap then 0 else coalesce(p_certs,0) end,
         coalesce(p_is_trap,false),nullif(trim(p_category),''),p_expires_at,coalesce(p_mini,false) and not coalesce(p_is_trap,false),auth.uid());
  return jsonb_build_object('success',true);
exception when unique_violation then
  return jsonb_build_object('success',false,'message','มีโค้ดนี้อยู่แล้ว');
end $$;

create or replace function public.redeem_player_code(p_code text)
returns jsonb
language plpgsql security definer set search_path=public,auth
as $$
declare
  v_uid uuid := auth.uid();
  v_code public.pch_redeem_codes%rowtype;
  v_state jsonb;
  v_coins integer; v_keys integer; v_certs integer;
  v_multiplier integer := 1;
  v_shielded boolean := false;
  v_history text;
  v_message text;
begin
  if v_uid is null then return jsonb_build_object('success',false,'message','กรุณาเข้าสู่ระบบ'); end if;
  select * into v_code from public.pch_redeem_codes
   where code=upper(trim(p_code)) for update;
  if not found then return jsonb_build_object('success',false,'message','ไม่พบรหัสนี้'); end if;
  if v_code.expires_at is not null and now()>v_code.expires_at then
    return jsonb_build_object('success',false,'message','โค้ดนี้หมดอายุแล้ว');
  end if;
  if exists(select 1 from public.pch_code_redemptions where code=v_code.code and user_id=v_uid) then
    return jsonb_build_object('success',false,'message','คุณใช้รหัสนี้ไปแล้ว');
  end if;
  if v_code.category is not null and exists(
    select 1 from public.pch_code_redemptions where user_id=v_uid and category=v_code.category
  ) then return jsonb_build_object('success',false,'message','คุณใช้โค้ดในหมวดนี้ไปแล้ว'); end if;

  select state into v_state from public.player_state where user_id=v_uid for update;
  v_state:=coalesce(v_state,'{}'::jsonb);
  if coalesce(v_state->'fx'->>'x2','false')='true' and not v_code.is_trap then
    v_multiplier:=2;
    v_state:=jsonb_set(v_state,'{fx}',coalesce(v_state->'fx','{}'::jsonb)-'x2',true);
  end if;
  if v_code.is_trap and coalesce(v_state->'fx'->>'shield','false')='true' then
    v_shielded:=true;
    v_state:=jsonb_set(v_state,'{fx}',coalesce(v_state->'fx','{}'::jsonb)-'shield',true);
  end if;

  v_coins:=coalesce((v_state->>'coins')::integer,100);
  v_keys:=coalesce((v_state->>'keys')::integer,3);
  v_certs:=coalesce((v_state->>'certs')::integer,0);
  if v_code.is_trap and not v_shielded then
    v_coins:=v_coins-v_code.coins;
    v_keys:=v_keys-v_code.keys;
    v_history:=v_code.code||' → กับดัก -'||v_code.coins||' เหรียญ -'||v_code.keys||' กุญแจ';
    v_message:='เป็นรหัสกับดัก คุณเสีย '||v_code.coins||' เหรียญ และ '||v_code.keys||' กุญแจ';
  elsif v_shielded then
    v_history:=v_code.code||' → กันกับดักสำเร็จ';
    v_message:='บัตรกันกับดักช่วยไว้ได้!';
  else
    v_coins:=v_coins+(v_code.coins*v_multiplier);
    v_keys:=v_keys+(v_code.keys*v_multiplier);
    v_certs:=v_certs+v_code.certs;
    v_history:=v_code.code||' → +'||(v_code.coins*v_multiplier)||' เหรียญ +'||(v_code.keys*v_multiplier)||' กุญแจ';
    v_message:='แลกรหัสสำเร็จ';
  end if;

  perform set_config('pch.secure_economy','on',true);
  v_state:=jsonb_set(v_state,'{coins}',to_jsonb(v_coins),true);
  v_state:=jsonb_set(v_state,'{keys}',to_jsonb(v_keys),true);
  v_state:=jsonb_set(v_state,'{certs}',to_jsonb(v_certs),true);
  v_state:=jsonb_set(v_state,'{used}',coalesce(v_state->'used','[]'::jsonb)||jsonb_build_array(v_history),true);
  if v_code.category is not null then
    v_state:=jsonb_set(v_state,'{cu}',coalesce(v_state->'cu','{}'::jsonb)||jsonb_build_object(v_code.category,v_code.code),true);
  end if;
  insert into public.player_state(user_id,state) values(v_uid,v_state)
  on conflict(user_id) do update set state=excluded.state;
  insert into public.pch_code_redemptions(code,user_id,category) values(v_code.code,v_uid,v_code.category);

  return jsonb_build_object('success',true,'coins',v_coins,'keys',v_keys,'certs',v_certs,
    'history',v_history,'category',v_code.category,'trap',v_code.is_trap,
    'shielded',v_shielded,'message',v_message);
exception when unique_violation then
  return jsonb_build_object('success',false,'message','คุณใช้รหัสนี้หรือโค้ดในหมวดนี้ไปแล้ว');
end $$;

revoke all on function public.admin_create_redeem_code(text,integer,integer,integer,boolean,text,timestamptz,boolean) from public,anon;
revoke all on function public.redeem_player_code(text) from public,anon;
grant execute on function public.admin_create_redeem_code(text,integer,integer,integer,boolean,text,timestamptz,boolean) to authenticated;
grant execute on function public.redeem_player_code(text) to authenticated;
