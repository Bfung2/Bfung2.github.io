import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

async function paypalToken(base: string, clientId: string, secret: string) {
  const credentials = btoa(`${clientId}:${secret}`);
  const response = await fetch(`${base}/v1/oauth2/token`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${credentials}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });
  const data = await response.json();
  if (!response.ok || !data.access_token) {
    throw new Error("PayPal authentication failed.");
  }
  return data.access_token as string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  try {
    const clientId = Deno.env.get("PAYPAL_CLIENT_ID");
    const secret = Deno.env.get("PAYPAL_CLIENT_SECRET");
    const environment = Deno.env.get("PAYPAL_ENVIRONMENT") || "sandbox";
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!clientId || !secret || !supabaseUrl || !serviceKey) {
      return json({ error: "Payment service is not configured." }, 500);
    }
    if (environment !== "sandbox" && environment !== "live") {
      return json({ error: "PAYPAL_ENVIRONMENT must be sandbox or live." }, 500);
    }

    const base = environment === "live"
      ? "https://api-m.paypal.com"
      : "https://api-m.sandbox.paypal.com";
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const body = await req.json();
    const action = body?.action;
    const orderId = String(body?.orderId || "");
    if (!orderId || orderId.length > 160) return json({ error: "Invalid order." }, 400);

    const { data: order, error: orderError } = await admin
      .from("apex_orders")
      .select("id, ref, total, status")
      .eq("id", orderId)
      .maybeSingle();

    if (orderError || !order) return json({ error: "Order not found." }, 404);
    const amount = Number(order.total);
    if (!Number.isFinite(amount) || amount <= 0) return json({ error: "Invalid order total." }, 400);
    const value = amount.toFixed(2);

    const token = await paypalToken(base, clientId, secret);

    if (action === "create") {
      if (order.status === "paid") return json({ error: "This order has already been paid." }, 409);
      const response = await fetch(`${base}/v2/checkout/orders`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
          "PayPal-Request-Id": `apex-create-${order.id}`,
        },
        body: JSON.stringify({
          intent: "CAPTURE",
          purchase_units: [{
            reference_id: order.ref,
            custom_id: order.id,
            invoice_id: order.ref,
            amount: { currency_code: "USD", value },
          }],
          application_context: {
            brand_name: "Apex Computers",
            user_action: "PAY_NOW",
            shipping_preference: "NO_SHIPPING",
          },
        }),
      });
      const data = await response.json();
      if (!response.ok || !data.id) {
        console.error("PayPal create order error:", data);
        return json({ error: "PayPal could not start this payment." }, 502);
      }
      return json({ id: data.id });
    }

    if (action === "capture") {
      const paypalOrderId = String(body?.paypalOrderId || "");
      if (!/^[A-Z0-9-]{8,}$/i.test(paypalOrderId)) {
        return json({ error: "Invalid PayPal order." }, 400);
      }
      const response = await fetch(`${base}/v2/checkout/orders/${encodeURIComponent(paypalOrderId)}/capture`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
          "PayPal-Request-Id": `apex-capture-${paypalOrderId}`,
        },
      });
      const data = await response.json();
      if (!response.ok) {
        console.error("PayPal capture error:", data);
        return json({ error: "PayPal could not complete the payment." }, 502);
      }

      const unit = data.purchase_units?.[0];
      const capture = unit?.payments?.captures?.[0];
      const capturedValue = Number(capture?.amount?.value);
      if (unit?.custom_id !== order.id ||
          capture?.status !== "COMPLETED" ||
          !Number.isFinite(capturedValue) ||
          capturedValue.toFixed(2) !== value ||
          capture?.amount?.currency_code !== "USD") {
        return json({ error: "Payment verification failed. Contact Apex Computers before retrying." }, 409);
      }

      const { error: updateError } = await admin
        .from("apex_orders")
        .update({ status: "paid" })
        .eq("id", order.id);
      if (updateError) {
        console.error("Could not update paid order:", updateError);
        return json({ error: "Payment succeeded, but the order status needs manual review." }, 500);
      }
      return json({ success: true, captureId: capture.id, status: "paid" });
    }

    return json({ error: "Unknown payment action." }, 400);
  } catch (error) {
    console.error("PayPal checkout error:", error);
    return json({ error: "Payment service encountered an unexpected error." }, 500);
  }
});
