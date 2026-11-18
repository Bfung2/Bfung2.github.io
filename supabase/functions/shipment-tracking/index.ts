import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const site = "https://bfung2.github.io";
const cors = {
  "Access-Control-Allow-Origin": site,
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};
const json = (data: unknown) => Response.json(data, { headers: cors });
const timeout = () => AbortSignal.timeout(8000);

function carrierLink(carrier: string, number: string) {
  return (carrier === "UPS"
    ? "https://www.ups.com/track?tracknum="
    : "https://tools.usps.com/go/TrackConfirmAction?tLabels=") + encodeURIComponent(number);
}

function base64(text: string) {
  return btoa(Array.from(new TextEncoder().encode(text), (byte) => String.fromCharCode(byte)).join(""));
}

async function gmailToken() {
  const client_id = Deno.env.get("GOOGLE_CLIENT_ID");
  const client_secret = Deno.env.get("GOOGLE_CLIENT_SECRET");
  const refresh_token = Deno.env.get("GOOGLE_REFRESH_TOKEN");
  if (!client_id || !client_secret || !refresh_token) return null;
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST", signal: timeout(),
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id, client_secret, refresh_token, grant_type: "refresh_token" }),
  });
  return response.ok ? (await response.json()).access_token : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed." });

  try {
    const input = await req.json();
    const url = Deno.env.get("SUPABASE_URL")!;
    const auth = { persistSession: false, autoRefreshToken: false };
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth });
    const shipments = admin.from("apex_shipments");

    if (input.action === "status") {
      const key = Deno.env.get("EASYPOST_API_KEY");
      if (!key?.startsWith("EZAK") || typeof input.token !== "string" || !/^[a-f0-9]{64}$/.test(input.token)) {
        return json({ carrier_update: null });
      }
      const { data: order } = await admin.from("apex_orders").select(
        "id,shipping_carrier,shipment_tracking_number",
      ).eq("tracking_token", input.token).eq("is_test", false)
        .in("fulfillment_stage", ["shipped", "delivered"]).maybeSingle();
      if (!order) return json({ carrier_update: null });
      const { data: shipment } = await shipments.select("*").eq("order_id", order.id)
        .eq("carrier", order.shipping_carrier).eq("tracking_number", order.shipment_tracking_number).maybeSingle();
      if (!shipment) return json({ carrier_update: null });

      const checkedAt = new Date().toISOString();
      const cutoff = new Date(Date.now() - 5 * 60 * 1000).toISOString();
      const { data: claimed } = await shipments.update({ carrier_checked_at: checkedAt }).eq("order_id", order.id)
        .or(`carrier_checked_at.is.null,carrier_checked_at.lt.${cutoff}`).select("order_id").maybeSingle();
      if (!claimed) return json({ carrier_update: shipment.carrier_update });

      try {
        const base = "https://api.easypost.com/v2/trackers";
        const headers = { Authorization: "Basic " + btoa(key + ":"), "Content-Type": "application/json" };
        const response = await (shipment.tracker_id
          ? fetch(base + "/" + encodeURIComponent(shipment.tracker_id), { headers, signal: timeout() })
          : fetch(base, { method: "POST", headers, signal: timeout(), body: JSON.stringify({
              tracker: { carrier: shipment.carrier, tracking_code: shipment.tracking_number },
            }) }));
        if (response.ok) {
          const tracker = await response.json();
          const delivered = tracker.status === "delivered" ? (tracker.tracking_details || [])
            .filter((detail: { status: string; datetime: string }) => detail.status === "delivered" && detail.datetime)
            .map((detail: { datetime: string }) => detail.datetime).sort().at(-1) : null;
          const carrier_update = {
            status: tracker.status,
            estimated_delivery: tracker.est_delivery_date || null,
            delivered_at: delivered || null,
          };
          await shipments.update({ tracker_id: tracker.id, carrier_update })
            .eq("order_id", order.id).eq("carrier_checked_at", checkedAt);
          return json({ carrier_update });
        }
      } catch {
        // Keep the last carrier response available during service interruptions.
      }
      return json({ carrier_update: shipment.carrier_update });
    }

    if (input.action !== "ship" || typeof input.order !== "string" || !Number.isInteger(input.revision)
        || typeof input.number !== "string" || input.number.length > 34 || !["UPS", "USPS"].includes(input.carrier)) {
      return json({ error: "Enter a valid UPS or USPS tracking number." });
    }

    const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      auth, global: { headers: { Authorization: req.headers.get("Authorization") || "" } },
    });
    const { error } = await caller.rpc("apex_confirm_shipment", {
      p_order: input.order, p_revision: input.revision, p_carrier: input.carrier, p_number: input.number,
    });
    if (error) return json({ error: error.message });

    const { data: order } = await admin.from("apex_orders").select(
      "ref,customer_email,tracking_token,shipping_carrier,shipment_tracking_number",
    ).eq("id", input.order).eq("fulfillment_stage", "shipped").maybeSingle();
    if (!order) return json({ email_state: "pending" });

    const { data: job } = await shipments.update({ email_state: "sending" }).eq("order_id", input.order)
      .eq("carrier", order.shipping_carrier).eq("tracking_number", order.shipment_tracking_number)
      .in("email_state", ["pending", "failed"]).select("carrier,tracking_number").maybeSingle();
    if (!job) {
      const { data: existing } = await shipments.select("email_state").eq("order_id", input.order).maybeSingle();
      return json({ email_state: existing?.email_state || "pending" });
    }

    const settle = async (state: string) => {
      const { error: saveError } = await shipments.update({ email_state: state }).eq("order_id", input.order)
        .eq("email_state", "sending");
      return json({ email_state: saveError ? "sending" : state });
    };

    const recipient = order.customer_email.trim();
    let accessToken;
    try {
      accessToken = await gmailToken();
    } catch {
      return await settle("failed");
    }
    if (!accessToken || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient) || recipient.length > 254) {
      return await settle("failed");
    }
    const subject = base64("Your Apex Computers order has shipped — " + order.ref);
    const body = [
      "Your Apex Computers order " + order.ref + " has shipped.",
      "",
      job.carrier + " tracking number: " + job.tracking_number,
      carrierLink(job.carrier, job.tracking_number),
      "",
      "View your order: " + site + "/#/track-order?token=" + order.tracking_token,
    ].join("\n");
    const mime = [
      "To: " + recipient,
      "From: Apex Computers <apexcomputers039@gmail.com>",
      "Subject: =?UTF-8?B?" + subject + "?=",
      "MIME-Version: 1.0",
      'Content-Type: text/plain; charset="UTF-8"',
      "Content-Transfer-Encoding: base64",
      "",
      base64(body).replace(/.{1,76}/g, "$&\r\n"),
    ].join("\r\n");

    try {
      const response = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
        method: "POST", signal: timeout(),
        headers: { Authorization: "Bearer " + accessToken, "Content-Type": "application/json" },
        body: JSON.stringify({ raw: base64(mime).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "") }),
      });
      return response.ok ? await settle("sent") : response.status < 500 ? await settle("failed") : json({ email_state: "sending" });
    } catch {
      return json({ email_state: "sending" });
    }
  } catch {
    return json({ error: "Shipment service unavailable. Reopen the order to check or retry." });
  }
});
