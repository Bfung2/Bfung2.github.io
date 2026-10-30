import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "https://bfung2.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

function base64UrlUtf8(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const clientId = Deno.env.get("GOOGLE_CLIENT_ID");
    const clientSecret = Deno.env.get("GOOGLE_CLIENT_SECRET");
    const refreshToken = Deno.env.get("GOOGLE_REFRESH_TOKEN");
    if (!supabaseUrl || !anonKey || !clientId || !clientSecret || !refreshToken) {
      return json({ error: "Email service is not fully configured in Supabase Secrets." }, 500);
    }

    const authorization = req.headers.get("Authorization") || "";
    const supabase = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user || (user.email || "").toLowerCase() !== "apexcomputers039@gmail.com") {
      return json({ error: "Only the Apex Computers owner can send customer emails." }, 401);
    }

    const input = await req.json();
    const to = String(input.to || "").trim();
    const subject = String(input.subject || "").trim();
    const body = String(input.body || "");
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to) || to.length > 254) {
      return json({ error: "A valid recipient email is required." }, 400);
    }
    if (!subject || subject.length > 180 || /[\r\n]/.test(subject)) {
      return json({ error: "A valid subject is required." }, 400);
    }
    if (!body.trim() || body.length > 20000) {
      return json({ error: "Email body is empty or too long." }, 400);
    }

    const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        refresh_token: refreshToken,
        grant_type: "refresh_token",
      }),
    });
    const tokenData = await tokenResponse.json();
    if (!tokenResponse.ok || !tokenData.access_token) {
      console.error("Google token refresh failed:", tokenData.error || tokenResponse.status);
      return json({ error: "Google authorization failed. Reconnect the Gmail account." }, 502);
    }

    const encodedSubject = "=?UTF-8?B?" + btoa(String.fromCharCode(...new TextEncoder().encode(subject))) + "?=";
    const mime = [
      "To: " + to,
      "From: Apex Computers <apexcomputers039@gmail.com>",
      "Subject: " + encodedSubject,
      "MIME-Version: 1.0",
      'Content-Type: text/plain; charset="UTF-8"',
      "Content-Transfer-Encoding: base64",
      "",
      btoa(String.fromCharCode(...new TextEncoder().encode(body))).replace(/.{1,76}/g, "$&\r\n"),
    ].join("\r\n");

    const gmailResponse = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
      method: "POST",
      headers: {
        Authorization: "Bearer " + tokenData.access_token,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ raw: base64UrlUtf8(mime) }),
    });
    const gmailData = await gmailResponse.json();
    if (!gmailResponse.ok) {
      console.error("Gmail send failed:", gmailData.error?.status || gmailResponse.status);
      return json({ error: "Gmail could not send the message. Please try again." }, 502);
    }
    return json({ success: true, messageId: gmailData.id });
  } catch (error) {
    console.error("send-gmail:", error instanceof Error ? error.message : "Unexpected error");
    return json({ error: "Unexpected email service error." }, 500);
  }
});
