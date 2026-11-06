// Supabase Edge Function: manage-employee
// Deploy with: supabase functions deploy manage-employee
// Requires SUPABASE_SERVICE_ROLE_KEY as a Supabase secret.
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
    const validEmail = (value: string) => !value || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);

    if (action === "create") {
      const displayName = String(body.display_name || "").trim();
      const contactEmail = String(body.email || "").trim().toLowerCase();
      if (displayName.length < 1 || displayName.length > 100) return json({ error: "Enter an employee display name." }, 400);
      if (contactEmail.length > 254 || !validEmail(contactEmail)) return json({ error: "Enter a valid employee email address." }, 400);
      let passcode = "";
      let createdUser: { id: string } | null = null;
      for (let attempt = 0; attempt < 20; attempt++) {
        const random = new Uint32Array(1);
        crypto.getRandomValues(random);
        passcode = String(random[0] % 1_000_000).padStart(6, "0");
        const authEmail = passcode + "@employees.apexcomputers.internal";
        const { data: created, error: createError } = await admin.auth.admin.createUser({
          email: authEmail, password: passcode, email_confirm: true,
          user_metadata: { account_type: "employee", display_name: displayName }
        });
        if (!createError && created.user) { createdUser = created.user; break; }
        const message = createError?.message || "Could not create employee login.";
        if (!/already|registered|duplicate|exists/i.test(message)) return json({ error: message }, 400);
      }
      if (!createdUser) return json({ error: "Could not generate an unused passcode. Please try again." }, 503);
      const { error: profileError } = await admin.from("employee_profiles").insert({
        user_id: createdUser.id, username: passcode, display_name: displayName,
        email: contactEmail || null, active: true
      });
      if (profileError) {
        await admin.auth.admin.deleteUser(createdUser.id);
        return json({ error: profileError.message }, 500);
      }
      return json({ success: true, passcode, employee: { user_id: createdUser.id, display_name: displayName, email: contactEmail || null, active: true } });
    }

    if (action === "update") {
      const userId = String(body.user_id || "");
      const displayName = String(body.display_name || "").trim();
      const contactEmail = String(body.email || "").trim().toLowerCase();
      if (!userId) return json({ error: "Employee user ID is required." }, 400);
      if (displayName.length < 1 || displayName.length > 100) return json({ error: "Enter an employee display name." }, 400);
      if (contactEmail.length > 254 || !validEmail(contactEmail)) return json({ error: "Enter a valid employee email address." }, 400);
      const { data: target, error: lookupError } = await admin.from("employee_profiles").select("user_id").eq("user_id", userId).maybeSingle();
      if (lookupError) return json({ error: lookupError.message }, 400);
      if (!target) return json({ error: "Employee account was not found." }, 404);
      const { error } = await admin.from("employee_profiles").update({ display_name: displayName, email: contactEmail || null }).eq("user_id", userId);
      if (error) return json({ error: error.message }, 400);
      const { error: metadataError } = await admin.auth.admin.updateUserById(userId, {
        user_metadata: { display_name: displayName, account_type: "employee" }
      });
      if (metadataError) return json({ error: metadataError.message }, 400);
      return json({ success: true });
    }

    if (action === "reset_passcode") {
      const userId = String(body.user_id || "");
      const { data: target, error: lookupError } = await admin.from("employee_profiles").select("user_id").eq("user_id", userId).maybeSingle();
      if (lookupError) return json({ error: lookupError.message }, 400);
      if (!target) return json({ error: "Employee account was not found." }, 404);
      let passcode = "";
      let updated = false;
      for (let attempt = 0; attempt < 20; attempt++) {
        const random = new Uint32Array(1);
        crypto.getRandomValues(random);
        passcode = String(random[0] % 1_000_000).padStart(6, "0");
        const authEmail = passcode + "@employees.apexcomputers.internal";
        const { error } = await admin.auth.admin.updateUserById(userId, {
          email: authEmail, password: passcode, email_confirm: true
        });
        if (!error) { updated = true; break; }
        if (!/already|registered|duplicate|exists/i.test(error.message || "")) return json({ error: error.message }, 400);
      }
      if (!updated) return json({ error: "Could not generate an unused passcode. Please try again." }, 503);
      const { error: profileError } = await admin.from("employee_profiles").update({ username: passcode }).eq("user_id", userId);
      if (profileError) return json({ error: "The new code was set, but the profile could not be updated: " + profileError.message }, 500);
      return json({ success: true, passcode });
    }

    if (action === "set_active") {
      const userId = String(body.user_id || "");
      const active = body.active === true;
      const { data: target, error: lookupError } = await admin.from("employee_profiles").select("user_id").eq("user_id", userId).maybeSingle();
      if (lookupError) return json({ error: lookupError.message }, 400);
      if (!target) return json({ error: "Employee account was not found." }, 404);
      const { error } = await admin.from("employee_profiles").update({ active }).eq("user_id", userId);
      if (error) return json({ error: error.message }, 400);
      const { error: banError } = await admin.auth.admin.updateUserById(userId, { ban_duration: active ? "none" : "876000h" });
      if (banError) return json({ error: banError.message }, 400);
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
