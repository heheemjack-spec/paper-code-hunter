-- Prevent overflow when a player's JSONB balance exceeds PostgreSQL INTEGER range.
-- Apply in Supabase SQL Editor after the earlier secure redeem RPC migration.

create or replace function public.redeem_player_code(p_code text)
returns jsonb
language plpgsql security definer set search_path=public,auth
as $$
declare
  v_uid uuid := auth.uid();
  v_code public.pch_redeem_codes%rowtype;
  v_state jsonb;
  v_coins numeric;
  v_keys numeric;
  v_certs numeric;
  v_multiplier numeric := 1;
  v_shielded boolean := false;
  v_history text;
  v_message text;
begin
  if v_uid is null then
    return jsonb_build_object('success',false,'message','กรุณาเข้าสู่ระบบ');
  end if;

  select * into v_code
  from public.pch_redeem_codes
  where code=upper(trim(p_code))
  for update;

  if not found then
    return jsonb_build_object('success',false,'message','ไม่พบรหัสนี้');
  end if;
  if v_code.expires_at is not null and now()>v_code.expires_at then
    return jsonb_build_object('success',false,'message','โค้ดนี้หมดอายุแล้ว');
  end if;
  if exists(select 1 from public.pch_code_redemptions where code=v_code.code and user_id=v_uid) then
    return jsonb_build_object('success',false,'message','คุณใช้รหัสนี้ไปแล้ว');
  end if;
  if v_code.category is not null and exists(
    select 1 from public.pch_code_redemptions where user_id=v_uid and category=v_code.category
  ) then
    return jsonb_build_object('success',false,'message','คุณใช้โค้ดในหมวดนี้ไปแล้ว');
  end if;

  select state into v_state
  from public.player_state
  where user_id=v_uid
  for update;

  v_state:=coalesce(v_state,'{}'::jsonb);
  if coalesce(v_state->'fx'->>'x2','false')='true' and not v_code.is_trap then
    v_multiplier:=2;
    v_state:=jsonb_set(v_state,'{fx}',coalesce(v_state->'fx','{}'::jsonb)-'x2',true);
  end if;
  if v_code.is_trap and coalesce(v_state->'fx'->>'shield','false')='true' then
    v_shielded:=true;
    v_state:=jsonb_set(v_state,'{fx}',coalesce(v_state->'fx','{}'::jsonb)-'shield',true);
  end if;

  -- JSONB numeric values are read as NUMERIC, not INTEGER, to avoid 32-bit overflow.
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
  end if;

  perform set_config('pch.secure_economy','on',true);
  v_state:=jsonb_set(v_state,'{coins}',to_jsonb(v_coins),true);
  v_state:=jsonb_set(v_state,'{keys}',to_jsonb(v_keys),true);
  v_state:=jsonb_set(v_state,'{certs}',to_jsonb(v_certs),true);
  v_state:=jsonb_set(v_state,'{used}',coalesce(v_state->'used','[]'::jsonb)||jsonb_build_array(v_history),true);

  if v_code.category is not null then
    v_state:=jsonb_set(v_state,'{cu}',coalesce(v_state->'cu','{}'::jsonb)||jsonb_build_object(v_code.category,v_code.code),true);
  end if;

  insert into public.player_state(user_id,state)
  values(v_uid,v_state)
  on conflict(user_id) do update set state=excluded.state;

  insert into public.pch_code_redemptions(code,user_id,category)
  values(v_code.code,v_uid,v_code.category);

  return jsonb_build_object(
    'success',true,'coins',v_coins,'keys',v_keys,'certs',v_certs,
    'history',v_history,'category',v_code.category,'trap',v_code.is_trap,
    'shielded',v_shielded,'message',v_message
  );
exception when unique_violation then
  return jsonb_build_object('success',false,'message','คุณใช้รหัสนี้หรือโค้ดในหมวดนี้ไปแล้ว');
end
$$;

revoke all on function public.redeem_player_code(text) from public,anon;
grant execute on function public.redeem_player_code(text) to authenticated;
