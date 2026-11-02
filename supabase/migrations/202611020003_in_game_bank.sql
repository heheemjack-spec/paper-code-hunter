-- Secure in-game bank loans for Paper Code Hunter.
-- Run once in Supabase SQL Editor.
create or replace function public.pch_bank_borrow(p_amount integer)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare
 v_uid uuid:=auth.uid(); v_state jsonb; v_loan jsonb; v_coins integer; v_balance integer;
begin
 if v_uid is null then return jsonb_build_object('success',false,'message','กรุณาเข้าสู่ระบบ'); end if;
 if p_amount is null or p_amount<100 or p_amount>1000 or mod(p_amount,100)<>0 then
  return jsonb_build_object('success',false,'message','จำนวนเงินกู้ต้องอยู่ระหว่าง 100–1,000 เหรียญ และเพิ่มครั้งละ 100');
 end if;
 select state into v_state from public.player_state where user_id=v_uid for update;
 if not found then return jsonb_build_object('success',false,'message','ไม่พบข้อมูลผู้เล่น'); end if;
 v_state:=coalesce(v_state,'{}'::jsonb); v_loan:=v_state->'loan';
 if v_loan is not null and v_loan<>'null'::jsonb and coalesce((v_loan->>'balance')::integer,0)>0 then
  return jsonb_build_object('success',false,'message','กรุณาชำระหนี้เดิมให้หมดก่อนกู้ใหม่');
 end if;
 v_coins:=coalesce((v_state->>'coins')::integer,100); v_balance:=ceil(p_amount*1.10)::integer;
 v_loan:=jsonb_build_object('principal',p_amount,'balance',v_balance,'interest_rate',10,'borrowed_at',now(),'due_at',now()+interval '7 days');
 perform set_config('pch.secure_economy','on',true);
 v_state:=jsonb_set(v_state,'{coins}',to_jsonb(v_coins+p_amount),true);
 v_state:=jsonb_set(v_state,'{loan}',v_loan,true);
 update public.player_state set state=v_state,updated_at=now() where user_id=v_uid;
 return jsonb_build_object('success',true,'coins',v_coins+p_amount,'loan',v_loan);
end; $$;

create or replace function public.pch_bank_repay(p_amount integer)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare
 v_uid uuid:=auth.uid(); v_state jsonb; v_loan jsonb; v_coins integer; v_balance integer; v_remaining integer;
begin
 if v_uid is null then return jsonb_build_object('success',false,'message','กรุณาเข้าสู่ระบบ'); end if;
 if p_amount is null or p_amount<1 then return jsonb_build_object('success',false,'message','จำนวนชำระไม่ถูกต้อง'); end if;
 select state into v_state from public.player_state where user_id=v_uid for update;
 if not found then return jsonb_build_object('success',false,'message','ไม่พบข้อมูลผู้เล่น'); end if;
 v_state:=coalesce(v_state,'{}'::jsonb); v_loan:=v_state->'loan';
 if v_loan is null or v_loan='null'::jsonb then return jsonb_build_object('success',false,'message','ไม่มีหนี้ที่ต้องชำระ'); end if;
 v_balance:=coalesce((v_loan->>'balance')::integer,0); v_coins:=coalesce((v_state->>'coins')::integer,100);
 if v_balance<1 then return jsonb_build_object('success',false,'message','ไม่มีหนี้ที่ต้องชำระ'); end if;
 if p_amount>v_balance then return jsonb_build_object('success',false,'message','จำนวนชำระเกินยอดหนี้คงเหลือ'); end if;
 if p_amount>v_coins then return jsonb_build_object('success',false,'message','เหรียญของคุณไม่เพียงพอ'); end if;
 v_remaining:=v_balance-p_amount;
 perform set_config('pch.secure_economy','on',true);
 v_state:=jsonb_set(v_state,'{coins}',to_jsonb(v_coins-p_amount),true);
 if v_remaining=0 then v_state:=jsonb_set(v_state,'{loan}','null'::jsonb,true);
 else v_loan:=jsonb_set(v_loan,'{balance}',to_jsonb(v_remaining),true); v_state:=jsonb_set(v_state,'{loan}',v_loan,true); end if;
 update public.player_state set state=v_state,updated_at=now() where user_id=v_uid;
 return jsonb_build_object('success',true,'coins',v_coins-p_amount,'loan',case when v_remaining=0 then null else v_loan end,
  'message',case when v_remaining=0 then 'ชำระหนี้ครบแล้ว สามารถกู้ใหม่ได้' else 'ชำระบางส่วนแล้ว · เหลือหนี้ '||v_remaining||' เหรียญ' end);
end; $$;

revoke all on function public.pch_bank_borrow(integer) from public,anon;
revoke all on function public.pch_bank_repay(integer) from public,anon;
grant execute on function public.pch_bank_borrow(integer) to authenticated;
grant execute on function public.pch_bank_repay(integer) to authenticated;
