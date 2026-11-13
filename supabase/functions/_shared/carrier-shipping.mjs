// Carrier quotes for Apex Computers. This module never guesses parcel dimensions,
// carrier prices, or the shipping origin. It can be tested in Node and used by Deno.
const money = v => Math.round((Number(v) + Number.EPSILON) * 100) / 100;
const shippingError = message => new Error("Shipping quote unavailable: " + message);

export function destinationFromAddress(value) {
  let destination;
  if (typeof value === "string") {
    // Apex's combineAddress() writes: "street, city, STATE ZIP".
    const m = value.trim().match(/^(.*),\s*([^,]+),\s*([a-zA-Z ]+)\s+(\d{5}(?:-\d{4})?)$/);
    if (!m) throw shippingError("Please enter a complete U.S. shipping address.");
    destination = { street: m[1], city: m[2], state: m[3], zip: m[4] };
  } else destination = value || {};
  const street = String(destination.street || "").trim();
  const city = String(destination.city || "").trim();
  const state = String(destination.state || "").trim();
  const zip = String(destination.zip || "").trim();
  if (street.length < 5 || !/\d/.test(street) || city.length < 2 ||
      !/^[a-zA-Z ]{2,30}$/.test(state) || !/^\d{5}(-\d{4})?$/.test(zip)) {
    throw shippingError("Please enter a valid U.S. street, city, state and ZIP.");
  }
  return { street1: street, city, state, zip, country: "US" };
}
export function parcelForRecord(record, assembledPC = false) {
  const pre = assembledPC ? "pcShip" : "ship";
  const values = {
    length: Number(record?.[pre + "LengthIn"]),
    width: Number(record?.[pre + "WidthIn"]),
    height: Number(record?.[pre + "HeightIn"]),
    weight: Number(record?.[pre + "WeightOz"]),
  };
  if (!Object.values(values).every(v => Number.isFinite(v) && v > 0) ||
      values.length > 108 || values.width > 108 || values.height > 108 || values.weight > 2400) {
    throw shippingError("Packed weight and box dimensions are missing or invalid for " +
      String(record?.name || "a product") + (assembledPC ? " (completed PC box)." : "."));
  }
  return values;
}
export function shipmentParcels(items, catalog) {
  const records = [...(catalog?.products || []), ...(catalog?.parts || [])];
  const byId = id => {
    const found = records.filter(r => r && String(r.id) === String(id));
    if (!found.length) throw shippingError("One of the items is no longer in the catalog.");
    return found[0];
  };
  const parcels = [];
  const addParcel = (record, assembledPC = false) => {
    const parcel = parcelForRecord(record, assembledPC);
    parcels.push({ parcel, name: String(record.name || "Item") });
    if (parcels.length > 12) throw shippingError("Orders with more than 12 packages require a manual quote.");
  };
  for (const item of items) {
    if (item.kind === "product") {
      const record = byId(item.id);
      if (record.category === "Tech Service") continue; // No delivery of an on-site service.
      for (let i = 0; i < item.qty; i++) addParcel(record);
    } else if (item.kind === "build" && item.assembly) {
      // The fully assembled computer ships in a single configured carton.
      // Its packed PC measurements MUST be entered on the selected case.
      const pcCase = (item.parts || []).find(part => part.category === "Case");
      if (!pcCase) throw shippingError("An assembled PC requires a case with packed PC shipping measurements.");
      addParcel(byId(pcCase.id), true);
    } else if (item.kind === "build") {
      // Parts-only builds are deliberately rated as separate physical packages.
      for (const part of item.parts || []) addParcel(byId(part.id));
    } else throw shippingError("Unsupported cart item.");
  }
  return parcels;
}
export async function quoteActualShipping(items, catalog, destination, options = {}) {
  const env = options.env || (key => Deno.env.get(key));
  const fetcher = options.fetcher || fetch;
  const apiKey = env("EASYPOST_API_KEY");
  const fromJSON = env("APEX_SHIP_FROM_JSON");
  if (!apiKey || !fromJSON) throw shippingError("Apex must configure its carrier account and ship-from address.");
  let from;
  try { from = JSON.parse(fromJSON); } catch { throw shippingError("The shop's shipping origin is not configured correctly."); }
  if (!from || !from.street1 || !from.city || !from.state || !/^\d{5}(?:-\d{4})?$/.test(String(from.zip || "")) ||
      String(from.country || "US").toUpperCase() !== "US") {
    throw shippingError("Apex must set a valid U.S. ship-from address.");
  }
  const to = destinationFromAddress(destination);
  const parcels = shipmentParcels(items, catalog);
  if (!parcels.length) return { charge: 0, carrierCost: 0, packages: [] };
  const feePercent = Number(catalog.settings?.pricingPolicy?.assumedPaymentFeePercent ?? 4.99);
  if (!(feePercent >= 0 && feePercent < 100)) throw shippingError("The payment processing allowance is invalid.");
  const packages = [];
  for (const { parcel, name } of parcels) {
    let response;
    try {
      response = await fetcher("https://api.easypost.com/v2/shipments", {
        method: "POST",
        headers: { Authorization: "Basic " + btoa(apiKey + ":"), "Content-Type": "application/json" },
        body: JSON.stringify({ shipment: { to_address: to, from_address: { ...from, country: "US" }, parcel } }),
      });
    } catch { throw shippingError("The carrier rating service could not be reached."); }
    if (!response.ok) throw shippingError("The carrier could not rate this package. Please contact Apex Computers.");
    const shipment = await response.json();
    if (shipment.mode !== "production" && !options.allowTest) {
      throw shippingError("Only live carrier rates can be used for paid orders.");
    }
    const available = (shipment.rates || []).filter(rate => rate.currency === "USD" &&
      Number.isFinite(Number(rate.rate)) && Number(rate.rate) > 0)
      .sort((a, b) => Number(a.rate) - Number(b.rate));
    if (!available.length) throw shippingError("No carrier service is available for " + name + ".");
    const cheapest = available[0];
    packages.push({ name, carrier: cheapest.carrier, service: cheapest.service,
      cost: money(Number(cheapest.rate)), shipmentId: String(shipment.id || ""),
      rateId: String(cheapest.id || "") });
  }
  const carrierCost = money(packages.reduce((sum, p) => sum + p.cost, 0));
  // Charge exactly quoted postage plus the processing percentage attributable
  // to shipping. Item base prices already cover the fixed PayPal transaction fee.
  const charge = Math.ceil(carrierCost / (1 - feePercent / 100) * 100) / 100;
  return { charge, carrierCost, packages };
}
