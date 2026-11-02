-- Creator Mode upgrades: configurable rewards and a hard per-code redemption cap.
alter table public.pch_redeem_codes
  add column if not exists max_redemptions integer not null default 5555
    check (max_redemptions between 1 and 5555),
  add column if not exists active boolean not null default true,
  add column if not exists reward_type text not null default 'none'
    check (reward_type in ('none','avatar','frame','title','card')),
  add column if not exists reward_value text,
  add column if not exists reward_qty integer not null default 1
    check (reward_qty between 1 and 5555);

drop function if exists public.admin_create_redeem_code(text,integer,integer,integer,boolean,text,timestamptz,boolean);
create or replace function public.admin_create_redeem_code(
  p_code text, p_coins integer default 0, p_keys integer default 0,
  p_certs integer default 0, p_is_trap boolean default false,
  p_category text default null, p_expires_at timestamptz default null,
  p_mini boolean default false, p_max_redemptions integer default 5555,
  p_reward_type text default 'none', p_reward_value text default null,
  p_reward_qty integer default 1
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
     or coalesce(p_certs,0) not between 0 and 1000000
     or coalesce(p_max_redemptions,5555) not between 1 and 5555
     or coalesce(p_reward_qty,1) not between 1 and 5555
     or coalesce(p_reward_type,'none') not in ('none','avatar','frame','title','card') then
    return jsonb_build_object('success',false,'message','ข้อมูลโค้ดไม่ถูกต้อง');
  end if;
  if coalesce(p_reward_type,'none') <> 'none' and nullif(trim(p_reward_value),'') is null then
    return jsonb_build_object('success',false,'message','กรุณาเลือกไอเทมรางวัล');
  end if;
  insert into public.pch_redeem_codes(
    code,coins,keys,certs,is_trap,category,expires_at,mini,created_by,
    max_redemptions,reward_type,reward_value,reward_qty
  ) values(
    v_code,coalesce(p_coins,0),coalesce(p_keys,0),
    case when p_is_trap then 0 else coalesce(p_certs,0) end,
    coalesce(p_is_trap,false),nullif(trim(p_category),''),p_expires_at,
    coalesce(p_mini,false) and not coalesce(p_is_trap,false),auth.uid(),
    coalesce(p_max_redemptions,5555),
    case when p_is_trap then 'none' else coalesce(p_reward_type,'none') end,
    case when p_is_trap then null else nullif(trim(p_reward_value),'') end,
    case when p_is_trap then 1 else coalesce(p_reward_qty,1) end
  );
  return jsonb_build_object('success',true);
exception when unique_violation then
  return jsonb_build_object('success',false,'message','มีโค้ดนี้อยู่แล้ว');
end $$;

create or replace function public.admin_list_redeem_codes()
returns jsonb language plpgsql security definer set search_path=public,auth
as $$
begin
  if auth.uid() is null or not public.is_admin() then
    return jsonb_build_object('success',false,'message','ไม่มีสิทธิ์');
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'code',c.code,'coins',c.coins,'keys',c.keys,'certs',c.certs,
    'is_trap',c.is_trap,'category',c.category,'expires_at',c.expires_at,
    'mini',c.mini,'max_redemptions',c.max_redemptions,'active',c.active,
    'reward_type',c.reward_type,'reward_value',c.reward_value,'reward_qty',c.reward_qty,
    'redeemed_count',(select count(*) from public.pch_code_redemptions r where r.code=c.code)
  ) order by c.created_at desc) from public.pch_redeem_codes c),'[]'::jsonb);
end $$;

create or replace function public.admin_delete_redeem_code(p_code text)
returns jsonb language plpgsql security definer set search_path=public,auth
as $$
begin
  if auth.uid() is null or not public.is_admin() then
    return jsonb_build_object('success',false,'message','ไม่มีสิทธิ์');
  end if;
  delete from public.pch_redeem_codes where code=upper(trim(p_code));
  return jsonb_build_object('success',true);
end $$;

create or replace function public.admin_set_redeem_code_active(p_code text,p_active boolean)
returns jsonb language plpgsql security definer set search_path=public,auth
as $$
begin
  if auth.uid() is null or not public.is_admin() then
    return jsonb_build_object('success',false,'message','ไม่มีสิทธิ์');
  end if;
  update public.pch_redeem_codes set active=coalesce(p_active,false)
   where code=upper(trim(p_code));
  if not found then return jsonb_build_object('success',false,'message','ไม่พบโค้ด'); end if;
  return jsonb_build_object('success',true);
end $$;

create or replace function public.redeem_player_code(p_code text)
returns jsonb language plpgsql security definer set search_path=public,auth
as $$
declare
  v_uid uuid := auth.uid();
  v_code public.pch_redeem_codes%rowtype;
  v_state jsonb;
  v_coins numeric; v_keys numeric; v_certs numeric;
  v_multiplier numeric := 1;
  v_shielded boolean := false;
  v_history text;
  v_message text;
  v_count integer;
  v_reward jsonb;
  v_i integer;
begin
  if v_uid is null then return jsonb_build_object('success',false,'message','กรุณาเข้าสู่ระบบ'); end if;
  select * into v_code from public.pch_redeem_codes
   where code=upper(trim(p_code)) for update;
  if not found then return jsonb_build_object('success',false,'message','ไม่พบรหัสนี้'); end if;
  if not v_code.active then return jsonb_build_object('success',false,'message','โค้ดนี้ถูกปิดใช้งาน'); end if;
  if v_code.expires_at is not null and now()>v_code.expires_at then
    return jsonb_build_object('success',false,'message','โค้ดนี้หมดอายุแล้ว');
  end if;
  select count(*) into v_count from public.pch_code_redemptions where code=v_code.code;
  if v_count >= v_code.max_redemptions then
    return jsonb_build_object('success',false,'message','โค้ดนี้ถูกใช้ครบจำนวนแล้ว');
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
  v_coins:=coalesce((v_state->>'coins')::numeric,100);
  v_keys:=coalesce((v_state->>'keys')::numeric,3);
  v_certs:=coalesce((v_state->>'certs')::numeric,0);
  if v_code.is_trap and not v_shielded then
    v_coins:=v_coins-v_code.coins::numeric;
    v_keys:=v_keys-v_code.keys::numeric;
    v_history:=v_code.code||' → กับดัก -'||v_code.coins||' เหรียญ -'||v_code.keys||' กุญแจ';
    v_message:='เป็นรหัสกับดัก คุณเสีย '||v_code.coins||' เหรียญ และ '||v_code.keys||' กุญแจ';
  elsif v_shielded then
    v_history:=v_code.code||' → กันกับดักสำเร็จ';
    v_message:='บัตรกันกับดักช่วยไว้ได้!';
  else
    v_coins:=v_coins+(v_code.coins::numeric*v_multiplier);
    v_keys:=v_keys+(v_code.keys::numeric*v_multiplier);
    v_certs:=v_certs+v_code.certs::numeric;
    v_history:=v_code.code||' → +'||(v_code.coins::numeric*v_multiplier)||' เหรียญ +'||(v_code.keys::numeric*v_multiplier)||' กุญแจ';
    v_message:='แลกรหัสสำเร็จ';
    if v_code.reward_type <> 'none' and v_code.reward_value is not null then
      v_reward:=jsonb_build_object('type',v_code.reward_type,'value',v_code.reward_value,'qty',v_code.reward_qty);
      if v_code.reward_type='avatar' then
        for v_i in 1..v_code.reward_qty loop
          v_state:=jsonb_set(v_state,'{avs}',coalesce(v_state->'avs','[]'::jsonb)||jsonb_build_array(v_code.reward_value),true);
        end loop;
      elsif v_code.reward_type='frame' then
        for v_i in 1..v_code.reward_qty loop
          v_state:=jsonb_set(v_state,'{frs}',coalesce(v_state->'frs','["none"]'::jsonb)||jsonb_build_array(v_code.reward_value),true);
        end loop;
      elsif v_code.reward_type='title' then
        for v_i in 1..v_code.reward_qty loop
          v_state:=jsonb_set(v_state,'{tts}',coalesce(v_state->'tts','["มือใหม่ถอดรหัส"]'::jsonb)||jsonb_build_array(v_code.reward_value),true);
        end loop;
      elsif v_code.reward_type='card' then
        v_state:=jsonb_set(v_state,'{cards}',jsonb_set(coalesce(v_state->'cards','{}'::jsonb),array[v_code.reward_value],to_jsonb(coalesce((v_state->'cards'->>v_code.reward_value)::integer,0)+v_code.reward_qty),true),true);
      end if;
      v_history:=v_history||' +'||v_code.reward_qty||' '||v_code.reward_type||':'||v_code.reward_value;
    end if;
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
    'shielded',v_shielded,'message',v_message,'reward',v_reward);
exception when unique_violation then
  return jsonb_build_object('success',false,'message','คุณใช้รหัสนี้หรือโค้ดในหมวดนี้ไปแล้ว');
end $$;

revoke all on function public.admin_create_redeem_code(text,integer,integer,integer,boolean,text,timestamptz,boolean,integer,text,text,integer) from public,anon;
revoke all on function public.admin_list_redeem_codes() from public,anon;
revoke all on function public.admin_delete_redeem_code(text) from public,anon;
revoke all on function public.admin_set_redeem_code_active(text,boolean) from public,anon;
revoke all on function public.redeem_player_code(text) from public,anon;
grant execute on function public.admin_create_redeem_code(text,integer,integer,integer,boolean,text,timestamptz,boolean,integer,text,text,integer) to authenticated;
grant execute on function public.admin_list_redeem_codes() to authenticated;
grant execute on function public.admin_delete_redeem_code(text) to authenticated;
grant execute on function public.admin_set_redeem_code_active(text,boolean) to authenticated;
grant execute on function public.redeem_player_code(text) to authenticated;

notify pgrst, 'reload schema';
