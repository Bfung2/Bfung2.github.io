/* Customer status uses an unguessable link, never an email or legacy local account as authentication. */
const TRACKING_STAGES=[['received','Order received'],['sourcing','Parts being ordered'],['building','Building / preparing'],['testing','Testing'],['ready','Ready for dispatch / pickup'],['shipped','Shipped'],['delivered','Delivered'],['on_hold','On hold'],['cancelled','Cancelled']];
let orderTracking={token:'',loading:false,data:null,error:''},trackingEpoch=0;
function newOrderTrackingToken(){const bytes=new Uint8Array(32);crypto.getRandomValues(bytes);return [...bytes].map(b=>b.toString(16).padStart(2,'0')).join('');}
function orderTrackingURL(token){return location.origin+location.pathname+'#/track-order?token='+encodeURIComponent(token);}
function savedOrderTracking(){try{const list=JSON.parse(localStorage.getItem('apex.trackingLinks')||'[]');return Array.isArray(list)?list.filter(x=>/^[a-f0-9]{64}$/.test(x.token)&&typeof x.ref==='string').slice(0,30):[];}catch{return [];}}
function rememberOrderTracking(o){const token=o.trackingToken||o.tracking_token;if(!/^[a-f0-9]{64}$/.test(token||''))return;try{const list=savedOrderTracking().filter(x=>x.token!==token);list.unshift({ref:o.ref,token});localStorage.setItem('apex.trackingLinks',JSON.stringify(list.slice(0,30)));}catch{}}
function trackingReceipt(o){const token=o.trackingToken||o.tracking_token;if(!token)return '';return `<section class="panel" style="margin-top:20px"><h3>Track your order</h3><p>Save this private link to check payment and fulfillment progress. Anyone with the link can see this order’s status and item list.</p><div class="row"><a class="btn gold" href="#/track-order?token=${esc(token)}">View order progress</a><button class="btn ghost" data-token="${esc(token)}" onclick="copyTrackingLink(this.dataset.token)">Copy tracking link</button></div></section>`;}
async function copyTrackingLink(token){try{await navigator.clipboard.writeText(orderTrackingURL(token));toast('Private tracking link copied.');}catch{openDlg(`<div class="dlg"><h3>Private tracking link</h3><input readonly aria-label="Private tracking link" value="${esc(orderTrackingURL(token))}"><button class="btn ghost" onclick="editDlg.close()">Close</button></div>`);}}
function trackingSavedLinks(){const links=savedOrderTracking();return links.length?`<section class="panel"><h3>Orders saved on this device</h3><p class="muted">These private links are saved by this browser, independently of your contact profile.</p>${links.map(x=>`<p><a href="#/track-order?token=${esc(x.token)}">${esc(x.ref)}</a></p>`).join('')}<button class="btn sm ghost" onclick="clearTrackingLinks()">Clear saved links on this device</button></section>`:'';}
function clearTrackingLinks(){localStorage.removeItem('apex.trackingLinks');render();}
function trackingStageLabel(stage){return TRACKING_STAGES.find(s=>s[0]===stage)?.[1]||'Awaiting update';}
function trackingNext(data){if(data.refund?.status==='full'&&!data.is_test)return 'A full refund is confirmed. Contact Apex for return or order questions.';if(data.is_test)return 'This is a simulated owner checkout. No payment was taken and no real fulfillment is promised.';if(data.archived&&data.stage!=='delivered')return 'This order is archived. Contact Apex if you need a newer update.';if(data.stage==='cancelled')return 'Contact Apex about any cancellation or refund questions. This page does not confirm a refund.';if(!data.payment_confirmed)return 'Payment has not been confirmed. Return to your original checkout or contact Apex before attempting another payment.';return {received:'Apex will review the order and update progress here.',sourcing:'Apex is arranging the parts for your order.',building:'Apex is building or preparing your order.',testing:'Apex is checking your order before handoff.',ready:'Apex will confirm dispatch or pickup details with you.',shipped:data.carrier_update?.status==='delivered'?'The carrier reports that your order was delivered.':data.delivery?.tracking_number?'Use the carrier and tracking number below for delivery updates.':'Your order has been marked shipped. Contact Apex for carrier details.',delivered:'Your order has been marked delivered. Contact Apex if you need support.',on_hold:'Check the update below or contact Apex for the next step.'}[data.stage]||'Contact Apex for the latest update.';}
async function loadCustomerTracking(token){const epoch=++trackingEpoch;orderTracking={token,loading:true,data:null,error:''};try{const {data,error}=await supabaseClient.rpc('apex_customer_order_status',{p_token:token});if(error)throw error;if(epoch!==trackingEpoch)return;orderTracking.data=data;
 if(['shipped','delivered'].includes(data.stage)&&data.delivery?.tracking_number&&!data.is_test){
  supabaseClient.functions.invoke('shipment-tracking',{body:{action:'status',token}}).then(({data:live})=>{
   if(epoch!==trackingEpoch||!live?.carrier_update)return;
   orderTracking.data={...data,carrier_update:live.carrier_update};
   if(route()==='/track-order')render();
  }).catch(()=>{});
 }
}catch(e){if(epoch===trackingEpoch)orderTracking.error='Tracking link is invalid or unavailable. Check the full link or contact Apex.';}finally{if(epoch===trackingEpoch){orderTracking.loading=false;if(route()==='/track-order')render();}}}
function openTrackingFromInput(event){event.preventDefault();const value=document.getElementById('trackingLinkInput').value.trim();let token=value;try{if(value.includes('://'))token=new URLSearchParams(new URL(value).hash.split('?')[1]||'').get('token')||'';}catch{}if(!/^[a-f0-9]{64}$/.test(token))return toast('Paste the full tracking link from checkout or Apex.');if(orderTracking.token===token){orderTracking.token='';render();}go('/track-order?token='+token);}
function customerTrackingPage(){const token=new URLSearchParams(location.hash.split('?')[1]||'').get('token')||'';if(token&&/^[a-f0-9]{64}$/.test(token)&&orderTracking.token!==token)loadCustomerTracking(token);const d=orderTracking.token===token?orderTracking.data:null;return `<div class="wrap tracking-page" style="max-width:900px"><div class="pagehead"><div><h2>Track your Apex order</h2><p>Use the private link from checkout or Apex Computers.</p></div></div>${!token?`<form class="panel" onsubmit="openTrackingFromInput(event);return false"><div class="field"><label for="trackingLinkInput">Private tracking link</label><input id="trackingLinkInput" required autocomplete="off" placeholder="Paste your full tracking link"></div><button class="btn gold" type="submit">View order</button></form>${trackingSavedLinks()}`:''}${token&&!/^[a-f0-9]{64}$/.test(token)?'<p class="notice" role="alert">Tracking link is invalid or unavailable.</p>':''}${orderTracking.token===token&&orderTracking.loading?'<p role="status">Loading order progress…</p>':''}${orderTracking.token===token&&orderTracking.error?`<div class="notice" role="alert">${esc(orderTracking.error)} <a href="#/contact">Contact Apex</a></div>`:''}${d?`<section class="panel">${d.is_test?'<span class="staff-pill">TEST · NO PAYMENT TAKEN</span>':''}<h3>Order ${esc(d.ref)}</h3><p><strong>Payment:</strong> ${d.is_test?'Simulated checkout':d.payment_confirmed?'Confirmed':'Awaiting confirmation'}</p><h3>${trackingStageLabel(d.stage==='shipped'&&d.carrier_update?.status==='delivered'?'delivered':d.stage)}</h3><p>${esc(trackingNext(d))}</p>${d.public_update?`<div class="notice staff-prewrap">${esc(d.public_update)}</div>`:''}<p class="muted">Latest record: ${new Date(d.updated_at).toLocaleString()}${d.archived?' · Archived':''}</p><button class="btn ghost" data-token="${esc(token)}" onclick="loadCustomerTracking(this.dataset.token)">Refresh progress</button> <button class="btn ghost" data-token="${esc(token)}" onclick="copyTrackingLink(this.dataset.token)">Copy private link</button>${trackingRefundMarkup(d)}${trackingDeliveryMarkup(d)}<h3 style="margin-top:22px">Your selection</h3>${(d.items||[]).map(i=>`<p>${esc(i.name)} × ${esc(i.qty)}</p>`).join('')}<p><strong>${d.is_test?'Test total':'Order total'}: ${money(d.total)}</strong></p></section><section class="panel" style="margin-top:20px"><h3>Progress updates</h3>${(d.events||[]).length?`<ol class="tracking-timeline">${d.events.map(e=>`<li><strong>${trackingStageLabel(e.stage)}</strong>${e.payment_confirmed?' · Payment confirmed':''}<br><small>${new Date(e.recorded_at).toLocaleString()}</small>${e.message?`<p class="staff-prewrap">${esc(e.message)}</p>`:''}</li>`).join('')}</ol>`:'<p>No progress changes recorded yet. Check back for the next update.</p>'}</section><p><a href="#/contact">Questions? Contact Apex Computers</a></p>`:''}</div>`;}
async function staffOpenOrderTracking(id){if(!(isOwner||isEmployee))return;try{const d=await staffRPC('apex_staff_order_tracking',{p_order:id});openDlg(`<div class="dlg staff-dialog"><h3>Customer order progress ${d.is_test?'· TEST':''}</h3><p>${esc(d.ref)}</p><p>Stage and message below are visible to anyone with the private customer link. Keep internal notes in Staff notes.</p><form onsubmit="staffSaveOrderTracking(event);return false" data-order="${esc(id)}" data-revision="${d.revision}"><div class="field"><label for="trackingStage">Customer-visible stage</label><select id="trackingStage">${TRACKING_STAGES.filter(([value])=>value!=='shipped'||d.stage==='shipped').map(([value,label])=>`<option value="${value}" ${d.stage===value?'selected':''}>${label}</option>`).join('')}</select></div><div class="field"><label for="trackingMessage">Customer update (optional)</label><textarea id="trackingMessage" maxlength="1000">${esc(d.public_update||'')}</textarea></div>${trackingDeliveryFields(d.delivery||{})}<div class="row"><button class="btn gold" type="submit">Save customer update</button>${!['cancelled','delivered'].includes(d.stage)?`<button class="btn ghost" type="button" data-order="${esc(id)}" onclick="staffOpenShipment(this.dataset.order)">${d.stage==='shipped'?'Shipment / email':'Shipped'}</button>`:''}<button class="btn ghost" type="button" data-token="${esc(d.token)}" onclick="copyTrackingLink(this.dataset.token)">Copy tracking link</button><a class="btn ghost" href="${esc(orderTrackingURL(d.token))}" target="_blank" rel="noopener noreferrer">Preview customer view</a></div></form><button class="btn ghost" style="margin-top:14px" onclick="editDlg.close()">Close</button></div>`);}catch(e){staffError(e);}}
async function staffSaveOrderTracking(event){event.preventDefault();const button=event.submitter,form=event.currentTarget;staffBusy(button,true);try{await staffRPC('apex_update_order_delivery',{p_order:form.dataset.order,p_revision:Number(form.dataset.revision),p_data:{stage:document.getElementById('trackingStage').value,public_update:document.getElementById('trackingMessage').value,carrier:document.getElementById('deliveryCarrier').value,tracking_number:document.getElementById('deliveryNumber').value,estimated_completion:document.getElementById('deliveryDate').value,pickup_instructions:document.getElementById('deliveryPickup').value}});editDlg.close();cloudOrdersLoaded=false;employeeJobsLoaded=false;render();toast('Customer progress updated.');}catch(e){staffError(e);}finally{staffBusy(button,false);}}

function trackingDeliveryFields(d){return `<h4>Customer-visible delivery details (optional)</h4><div class="staff-form-grid"><div class="field"><label for="deliveryCarrier">Carrier name</label><input id="deliveryCarrier" maxlength="80" value="${esc(d.carrier||'')}" placeholder="e.g. UPS, USPS, FedEx"></div><div class="field"><label for="deliveryNumber">Tracking number</label><input id="deliveryNumber" maxlength="100" value="${esc(d.tracking_number||'')}"></div><div class="field"><label for="deliveryDate">Estimated completion date</label><input id="deliveryDate" type="date" value="${esc(d.estimated_completion||'')}"></div></div><div class="field"><label for="deliveryPickup">Pickup instructions</label><textarea id="deliveryPickup" maxlength="1000">${esc(d.pickup_instructions||'')}</textarea></div><p class="muted">The date is shown as an estimate, not a delivery guarantee. Do not enter internal staff notes here.</p>`;}
function carrierTrackingLink(carrier, number){
 const links={UPS:'https://www.ups.com/track?tracknum=',USPS:'https://tools.usps.com/go/TrackConfirmAction?tLabels='};
 return Object.hasOwn(links,carrier)&&number?links[carrier]+encodeURIComponent(number):'';
}
function parseShipmentTracking(input, selectedCarrier){
 let number=input.trim(), carrier=selectedCarrier;
 if(number.includes('://')){
  const url=new URL(number);
  const hosts={
   'ups.com':'UPS','www.ups.com':'UPS','wwwapps.ups.com':'UPS',
   'usps.com':'USPS','www.usps.com':'USPS','tools.usps.com':'USPS'
  };
  if(url.protocol!=='https:'||url.username||url.password||url.port||!Object.hasOwn(hosts,url.hostname)){
   throw new Error('Paste an official UPS or USPS tracking link.');
  }
  carrier=hosts[url.hostname];
  const keys=carrier==='UPS'?['tracknum','trackNums','InquiryNumber1']:['tLabels','qtc_tLabels1'];
  const trackingEntry=[...url.searchParams].find(([key])=>keys.some(s=>s.toLowerCase()===key.toLowerCase()));
  number=trackingEntry?.[1]||'';
 }
 number=number.replace(/\s/g,'').toUpperCase();
 if(!carrier&&number.startsWith('1Z'))carrier='UPS';
 const valid=carrier==='UPS'?/^(1Z[A-Z0-9]{16}|T[0-9]{10}|[0-9]{9,26})$/.test(number):
  carrier==='USPS'&&/^([0-9]{16,34}|[A-Z]{2}[0-9]{9}[A-Z]{2})$/.test(number);
 if(!valid)throw new Error('Paste a UPS or USPS tracking link, or choose the carrier and enter one tracking number.');
 return {carrier,number};
}
async function staffOpenShipment(id){
 if(!(isOwner||isEmployee))return;
 try{
  const order=await staffRPC('apex_staff_order_tracking',{p_order:id});
  const delivery=order.delivery||{};
  openDlg(`<div class="dlg staff-dialog"><h3>Ship order ${esc(order.ref)}</h3>
   <p>${order.is_test?'Test order. A shipping email will be simulated.':'Confirming adds tracking to the order and sends the customer a shipping email.'}</p>
   <form data-order="${esc(id)}" data-revision="${order.revision}" onsubmit="staffConfirmShipment(event);return false">
    <label class="field">Tracking link or number<input name="tracking" autocomplete="off" spellcheck="false" required maxlength="1500" value="${esc(delivery.tracking_number||'')}"></label>
    <label class="field">Carrier for a tracking number<select name="carrier"><option value="">Choose carrier</option>
      ${['UPS','USPS'].map(c=>`<option ${c===delivery.carrier?'selected':''}>${c}</option>`).join('')}
    </select></label>
    ${order.stage==='shipped'?`<p><a href="${esc(orderTrackingURL(order.token))}" target="_blank" rel="noopener noreferrer">View order tracking</a></p>`:''}
    <p role="alert"></p>
    <div class="row"><button type="submit" class="btn gold">${order.stage==='shipped'?'Confirm shipment / retry email':'Shipped'}</button>
    <button type="button" class="btn ghost" onclick="editDlg.close()">Close</button></div>
   </form></div>`);
 }catch(e){staffError(e);}
}
async function staffConfirmShipment(event){
 event.preventDefault();
 const form=event.currentTarget, button=event.submitter, message=form.querySelector('[role="alert"]');
 message.textContent='';
 staffBusy(button,true);
 try{
  const values=new FormData(form);
  const tracking=parseShipmentTracking(values.get('tracking'),values.get('carrier'));
  const {data,error}=await supabaseClient.functions.invoke('shipment-tracking',{body:{
   action:'ship',order:form.dataset.order,revision:Number(form.dataset.revision),...tracking
  }});
  if(error||data?.error)throw new Error(data?.error||'Shipment confirmation is unavailable. Reopen the order to check its status.');
  cloudOrdersLoaded=false;
  employeeJobsLoaded=false;
  render();
  if(data?.email_state==='sent'||data?.email_state==='test'){
   if(form.isConnected)editDlg.close();
   toast(data.email_state==='test'?'Test shipment saved.':'Shipment saved and tracking email sent.');
  }else{
   message.textContent=data?.email_state==='sending'
    ?'Shipment saved. Gmail has not confirmed the email. Check the Apex Gmail Sent folder.'
    :'Shipment saved. The email is pending. Press the shipment button to retry.';
  }
 }catch(e){message.textContent=e.message;}
 finally{staffBusy(button,false);}
}
function trackingDeliveryMarkup(data){
 const d=data.delivery||{}, live=data.carrier_update||{};
 if(!d.carrier&&!d.tracking_number&&!d.estimated_completion&&!d.pickup_instructions)return '';
 const carrierUrl=carrierTrackingLink(d.carrier,d.tracking_number);
 const statuses={pre_transit:'Label created',in_transit:'In transit',out_for_delivery:'Out for delivery',delivered:'Delivered',
  available_for_pickup:'Available for pickup',return_to_sender:'Returning to sender',failure:'Delivery exception'};
 const status=Object.hasOwn(statuses,live.status)?statuses[live.status]:'';
 const formatDate=value=>{
  if(typeof value!=='string')return '';
  const date=value.slice(0,10);
  return /^\d{4}-\d{2}-\d{2}$/.test(date)?date:'';
 };
 const delivered=formatDate(live.delivered_at);
 const estimate=formatDate(live.estimated_delivery);
 return `<section class="notice"><h3>Delivery / pickup</h3>${d.carrier?`<p><strong>Carrier:</strong> ${esc(d.carrier)}</p>`:''}
  ${d.tracking_number?`<p><strong>Tracking number:</strong> ${esc(d.tracking_number)}</p>`:''}
  ${carrierUrl?`<p><a href="${esc(carrierUrl)}" target="_blank" rel="noopener noreferrer">Track with ${esc(d.carrier)}</a></p>`:''}
  ${status?`<p><strong>Carrier status:</strong> ${esc(status)}</p>`:''}
  ${delivered?`<p><strong>Delivered on:</strong> ${esc(delivered)}</p>`:''}
  ${live.status!=='delivered'&&data.stage!=='delivered'?(estimate?`<p><strong>Estimated delivery from ${esc(d.carrier)}:</strong> ${esc(estimate)}</p>`:d.estimated_completion?`<p><strong>Apex estimated completion:</strong> ${esc(d.estimated_completion)}</p>`:''):''}
  ${d.pickup_instructions?`<p><strong>Pickup instructions:</strong></p><p class="staff-prewrap">${esc(d.pickup_instructions)}</p>`:''}
 </section>`;
}

function trackingRefundMarkup(data){
 const refund=data.refund;if(data.is_test||!refund||!['full','partial'].includes(refund.status)||!Number.isSafeInteger(refund.amount_cents)||refund.amount_cents<=0)return '';
 return `<section class="notice" role="status"><h3>${refund.status==='full'?'Full refund confirmed':'Partial refund confirmed'}</h3><p>${money(refund.amount_cents/100)} refunded through PayPal. Your payment provider determines when the funds appear in your account.</p></section>`;
}
