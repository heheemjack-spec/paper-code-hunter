import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (status: number, body: Record<string, unknown>) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  try {
    const { username, display_name, password } = await req.json();
    const normalized = String(username ?? "").trim().toLowerCase();
    const display = String(display_name ?? normalized).trim().slice(0, 14);
    const pass = String(password ?? "");

    if (!/^[a-z0-9_]{3,14}$/.test(normalized) || normalized === "la") {
      return json(400, { error: "ชื่อผู้เล่นไม่ถูกต้องหรือสงวนไว้" });
    }
    if (pass.length < 8 || pass.length > 72) {
      return json(400, { error: "รหัสผ่านต้องมี 8-72 ตัวอักษร" });
    }
    if (!display) return json(400, { error: "กรุณาระบุชื่อที่แสดง" });

    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) return json(500, { error: "ระบบสมัครสมาชิกยังตั้งค่าไม่ครบ" });

    const admin = createClient(url, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const email = `${normalized}@players.papercodehunter.com`;
    const { data, error } = await admin.auth.admin.createUser({
      email,
      password: pass,
      email_confirm: true,
      user_metadata: { display_name: display, username: normalized },
    });

    if (error) {
      if (/already|exists|registered/i.test(error.message)) {
        return json(409, { error: "ชื่อนี้ถูกใช้แล้ว" });
      }
      console.error("Player registration failed:", error.message);
      return json(400, { error: "สมัครสมาชิกไม่สำเร็จ กรุณาตรวจสอบข้อมูล" });
    }
    return json(200, { success: true, user_id: data.user.id });
  } catch {
    return json(400, { error: "คำขอสมัครสมาชิกไม่ถูกต้อง" });
  }
});
