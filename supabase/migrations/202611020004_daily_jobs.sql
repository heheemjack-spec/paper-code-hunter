-- Secure daily job rewards for Paper Code Hunter.
-- Run once in Supabase SQL Editor.
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
begin
 if v_uid is null then
  return jsonb_build_object('success',false,'message','กรุณาเข้าสู่ระบบ');
 end if;

 select state into v_state
 from public.player_state
 where user_id=v_uid
 for update;

 if not found then
  return jsonb_build_object('success',false,'message','ไม่พบข้อมูลผู้เล่น');
 end if;

 case p_job
  when 'cipher' then v_reward:=80; v_title:='นักถอดรหัส';
  when 'news' then v_reward:=60; v_title:='ผู้ตรวจข่าว';
  when 'explore' then v_reward:=100; v_title:='นักสำรวจ';
  when 'chat' then v_reward:=50; v_title:='ผู้ช่วยชุมชน';
  when 'archive' then v_reward:=70; v_title:='ผู้จัดคลังเอกสาร';
  when 'tester' then v_reward:=120; v_title:='ผู้ทดสอบเกม';
  when 'hint' then v_reward:=90; v_title:='นักเขียนคำใบ้';
  else return jsonb_build_object('success',false,'message','ไม่พบงานนี้');
 end case;

 v_state:=coalesce(v_state,'{}'::jsonb);
 v_claims:=coalesce(v_state->'job_claims','{}'::jsonb);
 if v_claims ? p_job then
  v_last:=(v_claims->>p_job)::timestamptz;
  if now()<v_last+interval '24 hours' then
   return jsonb_build_object('success',false,'message','งานนี้ยังพักงานอยู่ กรุณากลับมาอีกครั้งเมื่อครบ 24 ชั่วโมง');
  end if;
 end if;

 v_coins:=coalesce((v_state->>'coins')::integer,100);
 perform set_config('pch.secure_economy','on',true);
 v_claims:=jsonb_set(v_claims,array[p_job],to_jsonb(now()),true);
 v_state:=jsonb_set(v_state,'{coins}',to_jsonb(v_coins+v_reward),true);
 v_state:=jsonb_set(v_state,'{job_claims}',v_claims,true);

 update public.player_state
 set state=v_state,updated_at=now()
 where user_id=v_uid;

 return jsonb_build_object(
  'success',true,
  'coins',v_coins+v_reward,
  'job_claims',v_claims,
  'message','ส่งงานสำเร็จ: '..v_title||' · ได้รับค่าจ้าง '||v_reward||' เหรียญ'
 );
end;
$$;

revoke all on function public.pch_job_claim(text) from public,anon;
grant execute on function public.pch_job_claim(text) to authenticated;
