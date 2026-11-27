const pcQuoteCosts = {
  parts: 'Parts', freight: 'Inbound freight', labor: 'Assembly and testing labor',
  packing: 'Packaging', postage: 'Outbound shipping', commission: 'Employee commission', other: 'Other costs'
};

let pcQuoteOwner = { rows: [], loaded: false, loading: false, error: '' };
let pcQuoteCustomer = { token: '', data: null, error: '' };
let pcQuoteDraftToken = '';

function pcQuoteReset() {
  pcQuoteOwner = { rows: [], loaded: false, loading: false, error: '' };
}

function pcQuoteURL(token) {
  return location.origin + location.pathname + '#/pc-quote?token=' + token;
}

function pcQuoteLanding() {
  return `<div class="wrap">
    <div class="pagehead"><div><h1>Get a custom PC quote</h1><p>Tell us what you want to run and how much you want to spend. Apex will send you a parts list and a total to review.</p></div><a class="btn ghost" href="#/pc-quote">Open an existing quote</a></div>
    <div class="split">
      <form class="panel" onsubmit="pcQuoteSubmit(event)" aria-label="Custom PC quote request">
        <div class="fields2">
          <label class="field">Name<input name="name" autocomplete="name" required maxlength="120" value="${esc(me?.name || '')}"></label>
          <label class="field">Email<input name="email" autocomplete="email" type="email" required maxlength="254" value="${esc(me?.email || '')}"></label>
          <label class="field">Total budget ($)<input name="budget" type="number" min="10" max="99999" step="1" required></label>
          <label class="field">Monitor resolution<select name="resolution"><option>Unsure</option><option>1080p</option><option>1440p</option><option>4K</option></select></label>
        </div>
        <label class="field">Games or apps you use<textarea name="use" required maxlength="1000" placeholder="Fortnite, Warzone, Premiere Pro…"></textarea></label>
        <label class="field">How would you like to receive it?<select name="delivery" onchange="pcQuoteDelivery(this.form)"><option value="pickup">Local pickup</option><option value="shipping">Ship within the US</option></select></label>
        <fieldset name="address" hidden disabled><legend>Shipping address</legend>
          <label class="field">Street address<input name="street" autocomplete="street-address" maxlength="150" required></label>
          <div class="fields2">
            <label class="field">City<input name="city" autocomplete="address-level2" maxlength="80" required></label>
            <label class="field">State (two letters)<input name="state" autocomplete="address-level1" maxlength="2" pattern="[A-Za-z]{2}" required></label>
            <label class="field">ZIP code<input name="zip" autocomplete="postal-code" pattern="[0-9]{5}(-[0-9]{4})?" required></label>
          </div>
        </fieldset>
        <label class="field">Anything else? <span class="muted">(optional)</span><textarea name="details" maxlength="1500" placeholder="Parts you already own, size or color preferences, or when you need it"></textarea></label>
        <button type="submit" class="btn gold">Request a quote</button>
        <p role="alert" data-quote-error></p>
      </form>
      <aside class="panel"><h2>Example builds</h2>
        <p>Use these examples to tell us what you’re after. Component choices and prices are confirmed in your quote.</p>
        <h3>1080p gaming</h3><p>A six-core processor, 16 GB RAM, 1 TB SSD and a dedicated graphics card for games like Fortnite and Rocket League.</p>
        <h3>1440p gaming and streaming</h3><p>32 GB RAM, a 1–2 TB SSD and a stronger graphics card for higher settings and streaming while you play.</p>
        <h3>Editing and 3D work</h3><p>32–64 GB RAM, fast storage for projects, and a graphics card chosen for the apps you use.</p>
      </aside>
    </div></div>`;
}

function pcQuoteDelivery(form) {
  const shipping = form.elements.delivery.value === 'shipping';
  const address = form.elements.address;
  address.hidden = !shipping;
  address.disabled = !shipping;
}

async function pcQuoteRequest(action, token, payload = {}) {
  const { data, error } = await supabaseClient.rpc('apex_pc_quote_customer', {
    p_action: action, p_token: token, p_data: payload
  });
  if (error) throw error;
  return data;
}

async function pcQuoteSubmit(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const payload = Object.fromEntries(new FormData(form));
  payload.email = payload.email.trim();
  if (payload.state) payload.state = payload.state.trim().toUpperCase();
  pcQuoteDraftToken ||= newOrderTrackingToken();
  const token = pcQuoteDraftToken;
  await pcQuoteFormAction(event, async () => {
    pcQuoteCustomer = { token, data: await pcQuoteRequest('request', token, payload), error: '' };
    pcQuoteDraftToken = '';
    if (route() === '/custom-pc') go('/pc-quote?token=' + token);
  });
}

async function pcQuoteFormAction(event, task) {
  const button = event.submitter;
  const errorLine = event.currentTarget.querySelector('[data-quote-error]');
  if (button) button.disabled = true;
  if (errorLine) errorLine.textContent = '';
  try {
    await task();
  } catch (error) {
    if (errorLine) errorLine.textContent = error.message || 'Could not save. Try again.';
  } finally {
    if (button) button.disabled = false;
  }
}

async function pcQuoteLoad(token) {
  const state = { token, data: null, error: '' };
  pcQuoteCustomer = state;
  try {
    state.data = await pcQuoteRequest('status', token);
  } catch {
    state.error = 'This quote could not be opened. Check the private link or contact Apex.';
  }
  if (state === pcQuoteCustomer && route() === '/pc-quote') render();
}

async function pcQuoteRespond(event) {
  event.preventDefault();
  const state = pcQuoteCustomer;
  const { action } = event.currentTarget.dataset;
  const { message } = Object.fromEntries(new FormData(event.currentTarget));
  await pcQuoteFormAction(event, async () => {
    state.data = await pcQuoteRequest(action, state.token, { revision: state.data.revision, message });
    if (state.data.order) {
      rememberOrderTracking(state.data.order);
      void customerLinkReceipt(state.data.order.trackingToken);
    }
    if (state === pcQuoteCustomer && route() === '/pc-quote') render();
  });
}

function pcQuoteOffer(offer) {
  return `<h3>Proposed parts and services</h3><p class="staff-prewrap">${esc(offer.parts)}</p>
    ${offer.message ? `<p class="staff-prewrap">${esc(offer.message)}</p>` : ''}
    <dl><dt>Build</dt><dd>${money(offer.subtotal / 100)}</dd>
      <dt>${offer.delivery === 'pickup' ? 'Local pickup' : 'Shipping'}</dt><dd>${money(offer.shipping / 100)}</dd>
      <dt>Sales tax</dt><dd>${money(offer.tax / 100)}</dd>
      <dt><strong>Total</strong></dt><dd><strong>${money(offer.total / 100)}</strong></dd></dl>`;
}

function pcQuoteCustomerPage() {
  const token = new URLSearchParams(location.hash.split('?')[1] || '').get('token') || '';
  const valid = /^[a-f0-9]{64}$/.test(token);
  if (valid && pcQuoteCustomer.token !== token) void pcQuoteLoad(token);
  const { data, error } = pcQuoteCustomer;
  const order = data?.order;
  return `<div class="wrap tracking-page"><div class="pagehead"><h1>Your custom PC quote</h1></div>
    ${!valid ? `<form class="panel" onsubmit="pcQuoteOpen(event)"><label class="field">Private quote link<input name="link" required autocomplete="off"></label>
      <button class="btn gold">Open quote</button><p role="alert" data-quote-error>${token ? 'This quote link is invalid.' : ''}</p></form>`
      : error ? `<p role="alert">${esc(error)}</p><button class="btn ghost" onclick="pcQuoteLoad(pcQuoteCustomer.token)">Try again</button>`
      : !data ? '<p role="status">Loading quote…</p>' : `<section class="panel">
        <div class="row"><button type="button" class="btn ghost" onclick="pcQuoteCopy(pcQuoteCustomer.token)">Copy private quote link</button>
        <button type="button" class="btn ghost" onclick="pcQuoteLoad(pcQuoteCustomer.token)">Refresh quote</button></div>
        ${data.status === 'requested' ? '<h2>Request received</h2><p>Save this private link to review your quote when Apex publishes it.</p>' : ''}
        ${data.status === 'changes' ? `<h2>Changes requested</h2><p class="staff-prewrap">${esc(data.change_message)}</p><p>Apex will review your request.</p>` : ''}
        ${data.offer ? pcQuoteOffer(data.offer) : ''}
        ${data.status === 'offered' ? `
          <p>${data.expired ? 'This offer expired. Ask Apex for an updated quote.' : `Offer expires ${esc(new Date(data.expires_at).toLocaleDateString())}.`}</p>
          ${data.expired ? '' : `<form data-action="accept" onsubmit="pcQuoteRespond(event)"><button class="btn gold">Accept quote and continue to payment</button><p role="alert" data-quote-error></p></form>`}
          <form data-action="change" onsubmit="pcQuoteRespond(event)"><label class="field">What would you like changed?<textarea name="message" maxlength="1500" required></textarea></label><button class="btn ghost">Request a change</button><p role="alert" data-quote-error></p></form>` : ''}
        ${data.status === 'accepted' ? (order ? `
          <p>Order ${esc(order.ref)} · ${order.closed ? 'Closed' : order.paid ? 'Payment confirmed' : 'Awaiting payment'}</p>
          <p><a class="btn ghost" href="#/track-order?token=${esc(order.trackingToken)}">View order progress</a></p>
          ${order.paid || order.closed ? '' : '<button class="btn gold" onclick="pcQuotePay(this)">Continue to PayPal</button><p id="quotePayStatus" role="status"></p><div id="quotePayButtons"></div>'}
          <form data-action="change" onsubmit="pcQuoteRespond(event)"><p>Keep the accepted price while Apex reviews your change request.</p><label class="field">Request a change to this order<textarea name="message" maxlength="1500" required></textarea></label><button class="btn ghost">Send change request</button><p role="alert" data-quote-error></p></form>
          ${data.change_message ? `<p class="staff-prewrap">Latest change request: ${esc(data.change_message)}</p>` : ''}`
          : '<p>Contact Apex for this order’s archived status.</p>') : ''}
      </section>`}
    <p><a href="#/contact">Contact Apex Computers</a></p></div>`;
}

async function pcQuoteOpen(event) {
  event.preventDefault();
  const value = new FormData(event.currentTarget).get('link').trim();
  await pcQuoteFormAction(event, () => {
    const token = /^[a-f0-9]{64}$/.test(value) ? value
      : new URLSearchParams(value.split('?')[1] || '').get('token');
    if (!/^[a-f0-9]{64}$/.test(token || '')) throw new Error('Paste the private quote link from Apex.');
    if (pcQuoteCustomer.token === token) void pcQuoteLoad(token);
    go('/pc-quote?token=' + token);
  });
}

async function pcQuoteCopy(token) {
  try {
    await navigator.clipboard.writeText(pcQuoteURL(token));
    toast('Private quote link copied.');
  } catch {
    openDlg(`<div class="dlg"><h3>Private quote link</h3><input aria-label="Private quote link" readonly value="${esc(pcQuoteURL(token))}"><button class="btn ghost" onclick="editDlg.close()">Close</button></div>`);
  }
}

async function pcQuotePay(button) {
  const { order, offer } = pcQuoteCustomer.data || {};
  if (!order || order.paid || order.closed) return;
  const status = document.getElementById('quotePayStatus');
  button.disabled = true;
  try {
    if (!globalThis.paypal?.Buttons) throw new Error('PayPal could not load. Refresh and try again.');
    const payment = { ...order, fromQuote: true, total: offer.total / 100 };
    rememberOrderTracking(order);
    await mountApexPaypal(payment, document.getElementById('quotePayButtons'), status, false);
    button.hidden = true;
  } catch (error) {
    status.textContent = error.message || 'PayPal could not open.';
    button.disabled = false;
  }
}

async function pcQuoteOwnerLoad(older = false) {
  const state = pcQuoteOwner;
  if (state.loading) return;
  state.loading = true;
  state.error = '';
  try {
    const rows = await staffRPC('apex_pc_quote_owner', {
      p_action: 'list', p_data: { before: older ? state.rows.at(-1)?.created_at : null,
        before_id: older ? state.rows.at(-1)?.id : null }
    });
    state.rows = older ? [...state.rows, ...rows] : rows;
    state.more = rows.length === 50;
  } catch (error) {
    state.error = error.message;
  } finally {
    state.loaded = true;
    state.loading = false;
    if (state === pcQuoteOwner && isOwner && route() === '/pc-quotes') render();
  }
}

function pcQuoteOwnerPage() {
  const denied = staffOwnerOnly();
  if (denied) return denied;
  const { rows, loaded, loading, error, more } = pcQuoteOwner;
  if (!loaded && !loading) void pcQuoteOwnerLoad();
  return staffShell('Custom PC quotes', 'Review incoming requests, price builds, and share a private quote link.', `
    <button class="btn ghost" onclick="pcQuoteOwnerLoad()" ${loading ? 'disabled' : ''}>Refresh quotes</button>
    ${error ? `<p role="alert">${esc(error)}</p>` : ''}
    ${loaded && !rows.length ? '<p>No quotes yet.</p>' : ''}
    ${rows.map(q => `<article class="panel" style="margin-top:16px">
      <h3>${esc(q.customer_name)} · ${esc(q.status === 'changes' ? 'Changes requested' : q.status)}</h3>
      <p>${esc(q.customer_email)} · ${esc(new Date(q.created_at).toLocaleString())}</p>
      <p>Budget ${money(q.request.budget)} · ${esc(q.request.resolution)} · ${esc(q.request.address)}</p>
      <p class="staff-prewrap">${esc(q.request.use)}\n${esc(q.request.details)}</p>
      ${q.change_message ? `<p class="staff-prewrap"><strong>Change requested</strong><br>${esc(q.change_message)}</p>` : ''}
      ${q.estimate ? `<p>Estimated contribution <strong>${money(q.estimate.profit / 100)}</strong>${q.estimate.profit < 35000 ? ' · Below $350 target' : ''}</p>` : ''}
      ${q.offer ? `<details><summary>Published offer</summary>${pcQuoteOffer(q.offer)}</details>` : ''}
      <div class="row">
        ${q.status === 'accepted' ? `<a class="btn gold" href="#/finances?order=${esc(q.order_id)}">Actual costs and refunds</a><a class="btn ghost" href="#/inbox">Order assignments</a>`
          : `<button class="btn gold" data-id="${esc(q.id)}" onclick="pcQuoteEdit(this.dataset.id)">${q.offer ? 'Revise offer' : 'Price this build'}</button>`}
        ${q.offer ? `<button class="btn ghost" data-token="${esc(q.token)}" onclick="pcQuoteCopy(this.dataset.token)">Copy quote link</button>
          <button class="btn ghost" data-id="${esc(q.id)}" onclick="pcQuoteEmail(this)">Email quote link</button>` : ''}
      </div></article>`).join('')}
    ${more ? `<button class="btn ghost" onclick="pcQuoteOwnerLoad(true)" ${loading ? 'disabled' : ''}>Load older quotes</button>` : ''}`);
}

async function pcQuoteEmail(button) {
  const quote = pcQuoteOwner.rows.find(row => row.id === button.dataset.id);
  if (!quote) return;
  button.disabled = true;
  try {
    const sent = await mailCustomer(quote.customer_email, 'Your Apex Computers custom PC quote',
      `Hi ${quote.customer_name},\n\nReview your custom PC quote here:\n${pcQuoteURL(quote.token)}\n\nKeep this link private.\n\nApex Computers`);
    if (!sent) toast('Email did not send. Copy the private quote link to share it.');
  } catch (error) {
    toast(error.message || 'Email failed. You can still copy the quote link.');
  } finally {
    button.disabled = false;
  }
}

function pcQuoteMoneyField(name, label, value, min = 0) {
  return `<label class="field">${label}<input name="${name}" type="number" min="${min}" max="99999.99" step="0.01" value="${esc(value)}" required></label>`;
}

function pcQuoteEdit(id) {
  const q = pcQuoteOwner.rows.find(row => row.id === id);
  if (!q) return;
  const offer = q.offer || {};
  const estimate = q.estimate || {};
  const pickup = q.request.delivery === 'pickup';
  const policy = S.settings.pricingPolicy || {};
  openDlg(`<div class="dlg staff-dialog"><h2>Price this build</h2>
    <form data-id="${esc(id)}" data-revision="${q.revision}" oninput="pcQuotePreview(this)" onsubmit="pcQuotePublish(event)">
      <label class="field">Parts list and services<textarea name="parts" required maxlength="3000">${esc(offer.parts || '')}</textarea></label>
      <label class="field">Message to customer<textarea name="message" maxlength="1500">${esc(offer.message || '')}</textarea></label>
      <h3>Customer charges</h3>
      <div class="fields2">
        ${pcQuoteMoneyField('subtotal', 'Build price ($)', offer.subtotal ? offer.subtotal / 100 : '', 0.01)}
        ${pickup ? '<input name="shipping" type="hidden" value="0">' : pcQuoteMoneyField('shipping', 'Shipping charge ($)', (offer.shipping || 0) / 100)}
        ${pcQuoteMoneyField('tax', 'Sales tax ($)', offer.tax === undefined ? '' : offer.tax / 100)}
      </div>
      <h3>Private cost estimate</h3>
      <div class="fields2">
        ${Object.entries(pcQuoteCosts).map(([key, label]) => pcQuoteMoneyField('cost_' + key, label + ' ($)',
          estimate.costs?.[key] === undefined && key === 'parts' ? '' : (estimate.costs?.[key] || 0) / 100, key === 'parts' ? 0.01 : 0)).join('')}
        <label class="field">Payment fee (%)<input name="fee_bps" type="number" min="0" max="99.99" step="0.01" required value="${esc(estimate.fee_bps === undefined ? policy.assumedPaymentFeePercent ?? 4.99 : estimate.fee_bps / 100)}"></label>
        ${pcQuoteMoneyField('fee_fixed', 'Fixed payment fee ($)', estimate.fee_fixed === undefined ? policy.assumedPaymentFixedUSD ?? 0.49 : estimate.fee_fixed / 100)}
      </div>
      <output class="notice" data-quote-preview></output>
      <label class="field"><span><input type="checkbox" name="confirm_low" style="width:auto"> Publish even if estimated contribution is below $350</span></label>
      <button class="btn gold">Publish offer</button>
      <button type="button" class="btn ghost" onclick="editDlg.close()">Cancel</button>
      <p role="alert" data-quote-error></p>
    </form></div>`);
  pcQuotePreview(editDlg.querySelector('form'));
}

function pcQuotePriceInput(form) {
  const fields = new FormData(form);
  const cents = key => Math.round((Number(fields.get(key)) + Number.EPSILON) * 100);
  const costs = Object.fromEntries(Object.keys(pcQuoteCosts).map(key => [key, cents('cost_' + key)]));
  return { subtotal: cents('subtotal'), shipping: cents('shipping'), tax: cents('tax'), costs,
    fee_bps: cents('fee_bps'), fee_fixed: cents('fee_fixed') };
}

function pcQuotePreview(form) {
  const p = pcQuotePriceInput(form);
  const total = p.subtotal + p.shipping + p.tax;
  const fee = Math.round(total * p.fee_bps / 10000) + p.fee_fixed;
  const profit = p.subtotal + p.shipping - fee - Object.values(p.costs).reduce((sum, cost) => sum + cost, 0);
  form.querySelector('[data-quote-preview]').textContent =
    `Customer total ${money(total / 100)} · Estimated payment fee ${money(fee / 100)} · Estimated contribution ${money(profit / 100)}` +
    (profit < 35000 ? ' · Below $350 target' : '');
}

async function pcQuotePublish(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const fields = new FormData(form);
  const state = pcQuoteOwner;
  await pcQuoteFormAction(event, async () => {
    const quote = await staffRPC('apex_pc_quote_owner', { p_action: 'offer', p_data: {
      ...pcQuotePriceInput(form), id: form.dataset.id, revision: Number(form.dataset.revision),
      parts: fields.get('parts'), message: fields.get('message'), confirm_low: fields.has('confirm_low')
    } });
    if (state !== pcQuoteOwner || !isOwner) return;
    state.rows = state.rows.map(row => row.id === quote.id ? quote : row);
    editDlg.close();
    render();
    toast('Offer published. Copy or email the private link.');
  });
}
