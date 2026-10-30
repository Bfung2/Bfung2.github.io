// Supabase Edge Function: manage-employee
// Deploy with: supabase functions deploy manage-employee
// Set secret: supabase secrets set SUPABASE_SERVICE_ROLE_KEY=... 
// The public anon key is not a substitute for the service-role secret.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

  try {
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!serviceKey) return json({ error: "Server is missing SUPABASE_SERVICE_ROLE_KEY." }, 500);

    const authHeader = req.headers.get("Authorization") || "";
    const caller = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
    const { data: { user }, error: authError } = await caller.auth.getUser();
    if (authError || !user || (user.email || "").toLowerCase() !== "apexcomputers039@gmail.com") {
      return json({ error: "Owner authentication required." }, 401);
    }

    const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
    const body = await req.json();
    const action = String(body.action || "");

    if (action === "create") {
      const displayName = String(body.display_name || "").trim();
      if (displayName.length < 1 || displayName.length > 100) return json({ error: "Enter an employee display name." }, 400);
      // Generate a unique six-digit numeric passcode. Retry if another employee
      // already has the same code, since each code maps to a unique Auth email.
      let passcode = "";
      let createdUser: { id: string } | null = null;
      for (let attempt = 0; attempt < 20; attempt++) {
        const random = new Uint32Array(1);
        crypto.getRandomValues(random);
        passcode = String(random[0] % 1_000_000).padStart(6, "0");
        const email = passcode + "@employees.apexcomputers.internal";
        const { data: created, error: createError } = await admin.auth.admin.createUser({
          email, password: passcode, email_confirm: true,
          user_metadata: { account_type: "employee" }
        });
        if (!createError && created.user) {
          createdUser = created.user;
          break;
        }
        const message = createError?.message || "Could not create employee login.";
        if (!/already|registered|duplicate|exists/i.test(message)) return json({ error: message }, 400);
      }
      if (!createdUser) return json({ error: "Could not generate an unused passcode. Please try again." }, 503);
      const username = passcode;
      const created = { user: createdUser };
      const { error: profileError } = await admin.from("employee_profiles").insert({
        user_id: created.user.id, username, display_name: displayName, active: true
      });
      if (profileError) {
        await admin.auth.admin.deleteUser(createdUser.id);
        return json({ error: profileError.message }, 500);
      }
      return json({ success: true, passcode, employee: { user_id: createdUser.id, display_name: displayName, active: true } });
    }

    if (action === "set_active") {
      const userId = String(body.user_id || "");
      const active = body.active === true;
      const { data: target, error: lookupError } = await admin.from("employee_profiles").select("user_id").eq("user_id", userId).maybeSingle();
      if (lookupError) return json({ error: lookupError.message }, 400);
      if (!target) return json({ error: "Employee account was not found." }, 404);
      const { error } = await admin.from("employee_profiles").update({ active }).eq("user_id", userId);
      if (error) return json({ error: error.message }, 400);
      if (!active) {
        const { error: banError } = await admin.auth.admin.updateUserById(userId, { ban_duration: "876000h" });
        if (banError) return json({ error: banError.message }, 400);
      } else {
        const { error: unbanError } = await admin.auth.admin.updateUserById(userId, { ban_duration: "none" });
        if (unbanError) return json({ error: unbanError.message }, 400);
      }
      return json({ success: true });
    }

    if (action === "delete") {
      const userId = String(body.user_id || "");
      const { data: target, error: lookupError } = await admin.from("employee_profiles").select("user_id").eq("user_id", userId).maybeSingle();
      if (lookupError) return json({ error: lookupError.message }, 400);
      if (!target) return json({ error: "Employee account was not found." }, 404);
      const { error: deleteError } = await admin.auth.admin.deleteUser(userId);
      if (deleteError) return json({ error: deleteError.message }, 400);
      return json({ success: true });
    }

    return json({ error: "Unknown action." }, 400);
  } catch (error) {
    console.error("manage-employee:", error);
    return json({ error: error instanceof Error ? error.message : "Unexpected server error." }, 500);
  }
});
