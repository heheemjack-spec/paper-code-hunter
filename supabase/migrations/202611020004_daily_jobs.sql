-- Replace the old instant-claim job RPC with server-checked activity requirements.
create or replace function public.pch_job_claim(p_job text)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
 v_uid uuid:=auth.uid();
 v_state jsonb;
 v_claims jsonb;
 v_last timestamptz;
 v_coins integer;
 v_reward integer;
 v_title text;
 v_progress integer:=0;
 v_required integer:=1;
 v_codes integer:=0;
begin
 if v_uid is null then
  return jsonb_build_object('success',false,'message','กรุณาเข้าสู่ระบบ');
 end if;
 select state into v_state from public.player_state where user_id=v_uid for update;
 if not found then
  return jsonb_build_object('success',false,'message','ไม่พบข้อมูลผู้เล่น');
 end if;
 v_state:=coalesce(v_state,'{}'::jsonb);

 case p_job
  when 'cipher' then
   v_title:='นักถอดรหัส'; v_reward:=20; v_required:=1;
   select count(*)::integer into v_codes
   from jsonb_array_elements_text(coalesce(v_state->'used','[]'::jsonb)) x
   where x like '%→ +%';
   v_progress:=v_codes;
  when 'news' then
   v_title:='ผู้ตรวจข่าว'; v_reward:=15; v_required:=1;
   v_progress:=coalesce((v_state->'st'->>'cm')::integer,0);
  when 'explore' then
   v_title:='นักสำรวจ'; v_reward:=25; v_required:=1;
   v_progress:=jsonb_array_length(coalesce(v_state->'found','[]'::jsonb));
  when 'chat' then
   v_title:='ผู้ช่วยชุมชน'; v_reward:=25; v_required:=3;
   v_progress:=coalesce((v_state->'st'->>'cm')::integer,0);
  when 'archive' then
   v_title:='ผู้จัดคลังเอกสาร'; v_reward:=30; v_required:=3;
   select count(*)::integer into v_codes
   from jsonb_array_elements_text(coalesce(v_state->'used','[]'::jsonb)) x
   where x like '%→ +%';
   v_progress:=v_codes;
  when 'tester' then
   v_title:='ผู้ทดสอบเกม'; v_reward:=30; v_required:=2;
   v_progress:=coalesce((v_state->'st'->>'games')::integer,0);
  when 'hint' then
   v_title:='นักเขียนคำใบ้'; v_reward:=25; v_required:=4;
   v_progress:=coalesce((v_state->'st'->>'word')::integer,0);
  else
   return jsonb_build_object('success',false,'message','ไม่พบงานนี้');
 end case;

 if v_progress < v_required then
  return jsonb_build_object('success',false,'message','ยังทำภารกิจไม่ครบ ('||least(v_progress,v_required)||'/'||v_required||')');
 end if;

 v_claims:=coalesce(v_state->'job_claims','{}'::jsonb);
 if v_claims ? p_job then
  v_last:=(v_claims->>p_job)::timestamptz;
  if now()<v_last+interval '24 hours' then
   return jsonb_build_object('success',false,'message','งานนี้ยังพักงานอยู่ กรุณากลับมาเมื่อครบ 24 ชั่วโมง');
  end if;
 end if;

 v_coins:=coalesce((v_state->>'coins')::integer,100);
 perform set_config('pch.secure_economy','on',true);
 v_claims:=jsonb_set(v_claims,array[p_job],to_jsonb(now()),true);
 v_state:=jsonb_set(v_state,'{coins}',to_jsonb(v_coins+v_reward),true);
 v_state:=jsonb_set(v_state,'{job_claims}',v_claims,true);
 update public.player_state set state=v_state,updated_at=now() where user_id=v_uid;

 return jsonb_build_object('success',true,'coins',v_coins+v_reward,'job_claims',v_claims,
  'message','ส่งงานสำเร็จ: '||v_title||' · ได้รับค่าจ้าง '||v_reward||' เหรียญ');
end;
$$;
revoke all on function public.pch_job_claim(text) from public,anon;
grant execute on function public.pch_job_claim(text) to authenticated;
