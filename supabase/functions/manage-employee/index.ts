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
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });

  try {
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!serviceKey) return json({ error: "Server is missing SUPABASE_SERVICE_ROLE_KEY." }, 500);

    const securePassword = () => {
      const bytes = new Uint8Array(24); crypto.getRandomValues(bytes);
      return Array.from(bytes, value => value.toString(16).padStart(2, "0")).join("") + "Aa!9";
    };
    const digest = async (value: string) => {
      const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
      return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
    };
    const setupExpiry = () => new Date(Date.now() + 7 * 86400_000).toISOString();
    const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
    const body = await req.json();
    const action = String(body.action || "");

    if (action === "activate") {
      const setupCode = String(body.setup_code || "").trim();
      const password = typeof body.password === "string" ? body.password : "";
      const match = /^(\d{6})\.[a-f0-9]{48}Aa!9$/.exec(setupCode);
      if (!match) return json({ error: "Enter the full setup code from Apex Computers." }, 400);
      const passwordBytes = new TextEncoder().encode(password).length;
      if (password.length < 12 || passwordBytes > 72 || setupCode.endsWith("." + password)) {
        return json({ error: "Choose a new password with at least 12 characters and at most 72 UTF-8 bytes." }, 400);
      }
      const claimedAt = new Date().toISOString();
      const { data: employee, error: claimError } = await admin.from("employee_profiles")
        .update({ credential_version: -1, credentials_changed_at: claimedAt })
        .eq("username", match[1]).eq("active", true).eq("credential_version", 0)
        .eq("setup_code_hash", await digest(setupCode)).gt("setup_code_expires_at", claimedAt)
        .select("user_id").maybeSingle();
      if (claimError) return json({ error: "Employee setup is temporarily unavailable." }, 503);
      if (!employee) return json({ error: "This setup code is invalid, expired, already used, or unavailable." }, 400);

      const { error: passwordError } = await admin.auth.admin.updateUserById(employee.user_id, { password });
      if (passwordError) {
        await admin.from("employee_profiles").update({ credential_version: 0 })
          .eq("user_id", employee.user_id).eq("credential_version", -1).eq("credentials_changed_at", claimedAt);
        return json({ error: "Choose a different password and try again." }, 400);
      }
      const { data: activated, error: activationError } = await admin.from("employee_profiles").update({
        credential_version: 1, credentials_changed_at: new Date().toISOString(),
        setup_code_hash: null, setup_code_expires_at: null,
      }).eq("user_id", employee.user_id).eq("credential_version", -1)
        .eq("credentials_changed_at", claimedAt).select("user_id").maybeSingle();
      if (activationError || !activated) return json({ error: "Ask the owner to reissue your setup code." }, 503);
      return json({ success: true, passcode: match[1] });
    }

    const authHeader = req.headers.get("Authorization") || "";
    const caller = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
    const { data: { user }, error: authError } = await caller.auth.getUser();
    if (authError || !user || (user.email || "").toLowerCase() !== "apexcomputers039@gmail.com") {
      return json({ error: "Owner authentication required." }, 401);
    }
    const { data: ownerVerified, error: ownerSecurityError } = await caller.rpc("apex_is_owner");
    if (ownerSecurityError || ownerVerified !== true) return json({ error: "Verify your owner authenticator before managing employees." }, 403);

    const validEmail = (value: string) => !value || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);

    const permissionKeys = ["orders", "requests", "customer_details", "claim_jobs", "update_status"] as const;
    const defaultPermissions = { orders: false, requests: false, customer_details: false, claim_jobs: false, update_status: false };
    const readPermissions = (value: unknown) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Employee permissions are missing or invalid.");
      const input = value as Record<string, unknown>;
      const output: Record<string, boolean> = {};
      for (const key of permissionKeys) {
        if (typeof input[key] !== "boolean") throw new Error("Every employee permission must be enabled or disabled.");
        output[key] = input[key];
      }
      return output;
    };
    const logOwnerActivity = async (eventType: string, targetUserId: string, details: Record<string, unknown>) => {
      const { error } = await admin.from("employee_activity_logs").insert({
        actor_user_id: user.id, actor_name: "Owner", target_user_id: targetUserId, event_type: eventType, details
      });
      if (error) console.error("Could not write employee audit event:", error.message);
    };

    if (action === "create") {
      const displayName = String(body.display_name || "").trim();
      const contactEmail = String(body.email || "").trim().toLowerCase();
      if (displayName.length < 1 || displayName.length > 100) return json({ error: "Enter an employee display name." }, 400);
      if (contactEmail.length > 254 || !validEmail(contactEmail)) return json({ error: "Enter a valid employee email address." }, 400);
      const password = securePassword();
      let passcode = "";
      let createdUser: { id: string } | null = null;
      for (let attempt = 0; attempt < 20; attempt++) {
        const random = new Uint32Array(1);
        crypto.getRandomValues(random);
        passcode = String(random[0] % 1_000_000).padStart(6, "0");
        const authEmail = passcode + "@employees.apexcomputers.internal";
        const { data: created, error: createError } = await admin.auth.admin.createUser({
          email: authEmail, password, email_confirm: true,
          user_metadata: { account_type: "employee", display_name: displayName }
        });
        if (!createError && created.user) { createdUser = created.user; break; }
        const message = createError?.message || "Could not create employee login.";
        if (!/already|registered|duplicate|exists/i.test(message)) return json({ error: message }, 400);
      }
      if (!createdUser) return json({ error: "Could not generate an unused passcode. Please try again." }, 503);
      const setupCode = passcode + "." + securePassword();
      const { error: profileError } = await admin.from("employee_profiles").insert({
        user_id: createdUser.id, username: passcode, display_name: displayName,
        email: contactEmail || null, active: true, permissions: defaultPermissions, credential_version: 0, credentials_changed_at: new Date().toISOString(),
        setup_code_hash: await digest(setupCode), setup_code_expires_at: setupExpiry(),
      });
      if (profileError) {
        await admin.auth.admin.deleteUser(createdUser.id);
        return json({ error: profileError.message }, 500);
      }
      await logOwnerActivity("employee_created", createdUser.id, { display_name: displayName, email: contactEmail || null });
      return json({ success: true, setup_code: setupCode, employee: { user_id: createdUser.id, display_name: displayName, email: contactEmail || null, active: true, permissions: defaultPermissions } });
    }

    if (action === "update") {
      const userId = String(body.user_id || "");
      const displayName = String(body.display_name || "").trim();
      const contactEmail = String(body.email || "").trim().toLowerCase();
      if (!userId) return json({ error: "Employee user ID is required." }, 400);
      if (displayName.length < 1 || displayName.length > 100) return json({ error: "Enter an employee display name." }, 400);
      if (contactEmail.length > 254 || !validEmail(contactEmail)) return json({ error: "Enter a valid employee email address." }, 400);
      const { data: target, error: lookupError } = await admin.from("employee_profiles").select("user_id,display_name").eq("user_id", userId).maybeSingle();
      if (lookupError) return json({ error: lookupError.message }, 400);
      if (!target) return json({ error: "Employee account was not found." }, 404);
      let permissions: Record<string, boolean>;
      try { permissions = readPermissions(body.permissions); }
      catch (error) { return json({ error: error instanceof Error ? error.message : "Invalid employee permissions." }, 400); }
      const { error } = await admin.from("employee_profiles").update({ display_name: displayName, email: contactEmail || null, permissions }).eq("user_id", userId);
      if (error) return json({ error: error.message }, 400);
      const { error: metadataError } = await admin.auth.admin.updateUserById(userId, {
        user_metadata: { display_name: displayName, account_type: "employee" }
      });
      if (metadataError) return json({ error: metadataError.message }, 400);
      await logOwnerActivity("employee_updated", userId, { display_name: displayName, email: contactEmail || null, permissions });
      return json({ success: true });
    }

    if (action === "reset_passcode") {
      const userId = String(body.user_id || "");
      const { data: target, error: lookupError } = await admin.from("employee_profiles").select("user_id,username").eq("user_id", userId).maybeSingle();
      if (lookupError || !target) return json({ error: "Employee account was not found." }, 404);
      const setupCode = target.username + "." + securePassword();
      // A short-lived claim prevents reissuing credentials during an Auth password update.
      // Allow recovery after an interrupted function invocation has expired.
      const staleClaim = new Date(Date.now() - 10 * 60_000).toISOString();
      const { data: updated, error: profileError } = await admin.from("employee_profiles").update({
        credential_version: 0, credentials_changed_at: new Date().toISOString(),
        setup_code_hash: await digest(setupCode), setup_code_expires_at: setupExpiry(),
      }).eq("user_id", userId).eq("active", true)
        .or(`credential_version.neq.-1,credentials_changed_at.lt.${staleClaim}`).select("user_id").maybeSingle();
      if (profileError || !updated) return json({ error: "Enable the account and wait for any in-progress setup to finish before reissuing." }, 409);
      await logOwnerActivity("employee_setup_reissued", userId, {});
      return json({ success: true, setup_code: setupCode });
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
      await logOwnerActivity(active ? "employee_enabled" : "employee_disabled", userId, { active });
      return json({ success: true });
    }

    if (action === "delete") {
      const userId = String(body.user_id || "");
      const { data: target, error: lookupError } = await admin.from("employee_profiles").select("user_id").eq("user_id", userId).maybeSingle();
      if (lookupError) return json({ error: lookupError.message }, 400);
      if (!target) return json({ error: "Employee account was not found." }, 404);
      await logOwnerActivity("employee_deleted", userId, { user_id: userId });
      const { error: deleteError } = await admin.auth.admin.deleteUser(userId);
      if (deleteError) return json({ error: deleteError.message }, 400);
      return json({ success: true });
    }
    return json({ error: "Unknown action." }, 400);
  } catch {
    console.error("manage-employee: unexpected request failure");
    return json({ error: "Unexpected server error." }, 500);
  }
});
