import { createClient } from "npm:@supabase/supabase-js@2";
import { quoteActualShipping } from "../_shared/carrier-shipping.mjs";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
const roundMoney = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100;

async function paypalToken(base: string, clientId: string, secret: string) {
  const response = await fetch(base + "/v1/oauth2/token", {
    method: "POST",
    headers: {
      Authorization: "Basic " + btoa(clientId + ":" + secret),
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });
  const data = await response.json();
  if (!response.ok || !data.access_token) throw new Error("PayPal authentication failed.");
  return data.access_token as string;
}

async function loadPublicCatalog() {
  // Add a unique query string so GitHub's raw-content CDN cannot reuse
  // an older catalog/settings snapshot during checkout after an owner edit.
  const catalogUrl =
    "https://raw.githubusercontent.com/Bfung2/Bfung2.github.io/main/data.json" +
    "?checkout_catalog=" + Date.now();
  const response = await fetch(catalogUrl, {
    cache: "no-store",
    headers: { "Cache-Control": "no-cache", Pragma: "no-cache" },
  });
  if (!response.ok) throw new Error("The shop catalog could not be loaded.");
  return await response.json();
}

// Browser-provided prices, names, fees and totals are ignored. All values are
// rebuilt from the canonical product catalog and shop settings on the server.
function calculateOrder(items: any, catalog: any) {
  if (!Array.isArray(items) || items.length < 1 || items.length > 50) {
    throw new Error("The cart is invalid. Please refresh it and try again.");
  }
  const allProducts = [...(catalog.products || []), ...(catalog.parts || [])];
  const resolve = (id: unknown) => {
    const matches = allProducts.filter((p: any) => p && String(p.id) === String(id || ""));
    if (!matches.length || matches.some((p: any) => {
      const seller = String(p.seller || "").trim().toLowerCase();
      const stock = String(p.stockStatus || "").trim().toLowerCase();
      return p.active === false || (seller && !["newegg", "newegg.com"].includes(seller)) ||
        /out\s*of\s*stock|back[\s-]*order(?:ed)?|sold\s*out|unavailable|discontinued|price\s*verification\s*required|not\s*available|pre[\s-]*order/.test(stock);
    })) return null;
    // A conflicting mirror cannot silently override the other catalog entry.
    if (new Set(matches.map((p: any) => Number(p.price))).size !== 1) return null;
    return matches[0];
  };
  const settings = catalog.settings || {};
  const buildFee = Number(settings.buildFee ?? 0);
  const shippingRatePercent = Number(settings.shippingRatePercent ?? 0);
  const taxRate = Number(settings.taxRate ?? 0);
  if (![buildFee, shippingRatePercent, taxRate].every(Number.isFinite) ||
      buildFee < 0 || shippingRatePercent < 0 || shippingRatePercent > 100 || taxRate < 0 || taxRate > 25) {
    throw new Error("Shop pricing settings are invalid. Please contact Apex Computers.");
  }

  let subtotal = 0;
  const verifiedItems: any[] = [];
  for (const item of items) {
    if (!item || typeof item !== "object") throw new Error("A cart item is invalid.");

    if (item.kind === "product") {
      const product: any = resolve(item.id);
      const qty = Number(item.qty ?? 1);
      if (!product || !Number.isInteger(qty) || qty < 1 || qty > 10) {
        throw new Error("A product in your cart is unavailable. Please refresh your cart.");
      }
      const price = Number(product.price);
      if (!Number.isFinite(price) || price <= 0 || price > 100000) {
        throw new Error("A product has an invalid price. Please contact Apex Computers.");
      }
      subtotal += price * qty;
      verifiedItems.push({ id: String(product.id), name: String(product.name), price: roundMoney(price), qty, kind: "product" });
      continue;
    }

    if (item.kind === "build") {
      if (!Array.isArray(item.parts) || item.parts.length < 1 || item.parts.length > 9) {
        throw new Error("Your custom build is incomplete. Please review it and try again.");
      }
      const seenIds = new Set<string>();
      const seenCategories = new Set<string>();
      const verifiedParts: any[] = [];
      let partsTotal = 0;
      for (const selected of item.parts) {
        const part: any = resolve(selected?.id);
        if (!part || seenIds.has(String(part.id)) || !String(part.category || "")) {
          throw new Error("A part in your custom build is unavailable. Please rebuild it.");
        }
        const category = String(part.category);
        if (seenCategories.has(category)) throw new Error("Your build has duplicate part categories.");
        const price = Number(part.price);
        if (!Number.isFinite(price) || price <= 0 || price > 100000) {
          throw new Error("A part has an invalid price. Please contact Apex Computers.");
        }
        seenIds.add(String(part.id));
        seenCategories.add(category);
        partsTotal += price;
        verifiedParts.push({ id: String(part.id), name: String(part.name), category, price: roundMoney(price) });
      }
      const assembly = item.assembly === true;
      const fee = assembly ? buildFee : 0;
      const price = roundMoney(partsTotal + fee);
      subtotal += price;
      verifiedItems.push({
        id: String(item.id || "custom-build"),
        name: "Custom PC build" + (assembly ? " (assembled by us)" : " (parts only)"),
        price, qty: 1, kind: "build", parts: verifiedParts, assembly, fee: roundMoney(fee),
      });
      continue;
    }
    throw new Error("Your cart contains an unsupported item. Please rebuild your cart.");
  }

  subtotal = roundMoney(subtotal);
  // Server recalculates percentage shipping from verified subtotal, ignoring browser totals.
  const shipping = settings.shippingMode === "carrier" ? 0 : (verifiedItems.length ? roundMoney(subtotal * shippingRatePercent / 100) : 0);
  const tax = roundMoney(subtotal * taxRate / 100);
  const total = roundMoney(subtotal + shipping + tax);
  if (!Number.isFinite(total) || total <= 0 || total > 1000000) {
    throw new Error("The order total is invalid. Please contact Apex Computers.");
  }
  return { items: verifiedItems, subtotal, shipping, tax, total };
}


/** Fail closed when a promotion would drop a purchase below modeled supplier and processor costs. */
function checkoutMeetsBreakEven(items: any[], catalog: any, locked: any, originalSubtotal: number, actualCarrierCost: number | null = null) {
  const records = [...(catalog.products || []), ...(catalog.parts || [])];
  const settings = catalog.settings || {};
  const policy = settings.pricingPolicy || {};
  const feePercent = Number(policy.assumedPaymentFeePercent ?? 4.99);
  const feeFixed = Number(policy.assumedPaymentFixedUSD ?? 0.49);
  const shippingExpensePercent = Number(policy.assumedShippingExpensePercent ?? settings.shippingRatePercent ?? 0);
  if (![feePercent, feeFixed, shippingExpensePercent].every(Number.isFinite) ||
      feePercent < 0 || feeFixed < 0 || shippingExpensePercent < 0) return false;
  const costOf = (id: any): number | null => {
    const matches = records.filter((p: any) => String(p?.id) === String(id));
    if (!matches.length) return null;
    const cost = Number(matches[0].neweggPrice);
    const other = Number(matches[0].extraCostUSD ?? 0);
    if (!Number.isFinite(cost) || cost <= 0 || !Number.isFinite(other) || other < 0 ||
        matches.some((p: any) => Number(p.neweggPrice) !== cost || Number(p.extraCostUSD ?? 0) !== other)) return null;
    return roundMoney(cost + other);
  };
  let supplierCost = 0;
  for (const item of items) {
    if (item.kind === "product") {
      const cost = costOf(item.id);
      if (cost === null) return false;
      supplierCost += cost * Number(item.qty);
    } else if (item.kind === "build") {
      for (const part of item.parts || []) {
        const cost = costOf(part.id);
        if (cost === null) return false;
        supplierCost += cost;
      }
    } else return false;
  }
  const subtotal = Number(locked.subtotal), shipping = Number(locked.shipping), total = Number(locked.total);
  if (![supplierCost, subtotal, shipping, total, originalSubtotal].every(Number.isFinite)) return false;
  const outboundCost = actualCarrierCost === null ? roundMoney(originalSubtotal * shippingExpensePercent / 100) : actualCarrierCost;
  const paymentFee = roundMoney(total * feePercent / 100 + feeFixed);
  // Collected sales tax is remitted and therefore excluded from contribution.
  return roundMoney(subtotal + shipping - supplierCost - outboundCost - paymentFee) >= 0;
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

    const base = environment === "live" ? "https://api-m.paypal.com" : "https://api-m.sandbox.paypal.com";
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const body = await req.json();
    const action = body?.action;
    if (action === "estimate") {
      // A read-only shipping estimate, calculated from trusted catalog metadata,
      // not user-provided prices, weights or shipping amounts.
      const catalog = await loadPublicCatalog();
      if (catalog.settings?.shippingMode !== "carrier") {
        return json({ error: "Carrier shipping is not enabled yet." }, 409);
      }
      const pricing = calculateOrder(body.items, catalog);
      const quote = await quoteActualShipping(pricing.items, catalog, body.address, { allowTest: environment === "sandbox" });
      pricing.shipping = quote.charge;
      pricing.total = roundMoney(pricing.subtotal + pricing.shipping + pricing.tax);
      return json({ pricing: { subtotal: pricing.subtotal, shipping: pricing.shipping,
        tax: pricing.tax, total: pricing.total }, packages: quote.packages.map(p => ({
        carrier: p.carrier, service: p.service, postage: p.cost })) });
    }
    const orderId = String(body?.orderId || "");
    if (!orderId || orderId.length > 160) return json({ error: "Invalid order." }, 400);

    const { data: order, error: orderError } = await admin
      .from("apex_orders")
      .select("id, ref, items, total, status, is_test, shipping_address")
      .eq("id", orderId)
      .maybeSingle();
    if (orderError || !order) return json({ error: "Order not found." }, 404);

    if (order.is_test) return json({ error: "Test orders cannot use real payment processing." }, 409);
    const token = await paypalToken(base, clientId, secret);

    if (action === "create") {
      if (order.status === "paid") return json({ error: "This order has already been paid." }, 409);
      const catalog = await loadPublicCatalog();
      const pricing = calculateOrder(order.items, catalog);
      const undiscountedSubtotal = pricing.subtotal;
      let carrierQuote: { charge: number; carrierCost: number } | null = null;
      if (catalog.settings?.shippingMode === "carrier") {
        carrierQuote = await quoteActualShipping(pricing.items, catalog, order.shipping_address,
          { allowTest: environment === "sandbox" });
        pricing.shipping = carrierQuote.charge;
        pricing.total = roundMoney(pricing.subtotal + pricing.shipping + pricing.tax);
      }

      const { data: locked, error: pricingError } = await admin.rpc("apex_lock_checkout_price", {
        p_order: order.id, p_items: pricing.items, p_subtotal: pricing.subtotal,
        p_shipping: pricing.shipping, p_tax_rate: Number(catalog.settings?.taxRate ?? 0),
      });
      if (pricingError || !locked) return json({ error: pricingError?.message || "Could not verify checkout pricing." }, 400);
      Object.assign(pricing, { subtotal: Number(locked.subtotal), shipping: Number(locked.shipping), tax: Number(locked.tax), total: Number(locked.total) });
      if (!checkoutMeetsBreakEven(pricing.items, catalog, pricing, undiscountedSubtotal, carrierQuote?.carrierCost ?? null)) {
        return json({ error: "This order would fall below its cost-recovery price, possibly because of a promo code. Remove the discount and try again." }, 409);
      }

      const response = await fetch(base + "/v2/checkout/orders", {
        method: "POST",
        headers: {
          Authorization: "Bearer " + token,
          "Content-Type": "application/json",
          "PayPal-Request-Id": "apex-create-" + order.id,
        },
        body: JSON.stringify({
          intent: "CAPTURE",
          purchase_units: [{
            reference_id: order.ref,
            custom_id: order.id,
            invoice_id: order.ref,
            amount: { currency_code: "USD", value: pricing.total.toFixed(2) },
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
      return json({ id: data.id, pricing: { ...locked, total: pricing.total } });
    }

    if (action === "capture") {
      const paypalOrderId = String(body?.paypalOrderId || "");
      if (!/^[A-Z0-9-]{8,}$/i.test(paypalOrderId)) return json({ error: "Invalid PayPal order." }, 400);
      const value = Number(order.total).toFixed(2);
      if (!Number.isFinite(Number(order.total)) || Number(order.total) <= 0) {
        return json({ error: "This order has not passed server-side price verification." }, 409);
      }

      const captureResponse = await fetch(base + "/v2/checkout/orders/" + encodeURIComponent(paypalOrderId) + "/capture", {
        method: "POST",
        headers: {
          Authorization: "Bearer " + token,
          "Content-Type": "application/json",
          "PayPal-Request-Id": "apex-capture-" + paypalOrderId,
        },
      });
      const captureResult = await captureResponse.json();
      if (!captureResponse.ok) {
        console.error("PayPal capture error:", captureResult);
        return json({ error: "PayPal could not complete the payment." }, 502);
      }

      // The capture response can omit custom_id. Verify against PayPal's canonical order record.
      const detailResponse = await fetch(base + "/v2/checkout/orders/" + encodeURIComponent(paypalOrderId), {
        headers: { Authorization: "Bearer " + token },
      });
      const detail = await detailResponse.json();
      if (!detailResponse.ok) {
        console.error("PayPal order verification error:", detail);
        return json({ error: "PayPal payment could not be verified. Contact Apex Computers." }, 502);
      }
      const unit = detail.purchase_units?.[0];
      const capture = unit?.payments?.captures?.[0];
      const capturedValue = Number(capture?.amount?.value);
      if (unit?.custom_id !== order.id ||
          capture?.status !== "COMPLETED" ||
          !Number.isFinite(capturedValue) ||
          capturedValue.toFixed(2) !== value ||
          capture?.amount?.currency_code !== "USD") {
        return json({ error: "Payment verification failed. Contact Apex Computers before retrying." }, 409);
      }

      const { error: updateError } = await admin.from("apex_orders")
        .update({ status: "paid", paypal_capture_id: capture.id }).eq("id", order.id);
      if (updateError) {
        console.error("Could not update paid order:", updateError);
        return json({ error: "Payment succeeded, but the order status needs manual review." }, 500);
      }
      // Delivery failures never turn a verified payment into a failed checkout.
      let notificationsPending = true;
      try {
        const {data:notification,error:notificationError}=await admin.functions.invoke("paid-order-notify",{body:{orderId:order.id}});
        notificationsPending=!!notificationError || !notification?.success;
      } catch { notificationsPending=true; }
      return json({ success: true, captureId: capture.id, status: "paid", notificationsPending });
    }
    return json({ error: "Unknown payment action." }, 400);
  } catch (error) {
    console.error("PayPal checkout error:", error);
    return json({ error: error instanceof Error ? error.message : "Payment service encountered an unexpected error." }, 500);
  }
});
