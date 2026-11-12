/* Phase 6 customer features. All address data stays in scoped Supabase RPCs. */
function customerSavedAddresses(){return Array.isArray(customerState.addresses)?customerState.addresses:[];}
async function customerLoadAddressBook(epoch=customerEpoch){
 try{
  const list=await customerRPC('apex_customer_addresses',{p_action:'list'});
  if(epoch===customerEpoch){customerState.addresses=Array.isArray(list)?list:[];customerState.addressError='';}
 }catch{if(epoch===customerEpoch){customerState.addresses=[];customerState.addressError='Saved addresses are temporarily unavailable. Your account and checkout still work.';}}
}
function customerPreferredShippingAddress(){
 const list=customerSavedAddresses();
 if(customerState.checkoutAddressId==='manual')return {};
 const selected=list.find(a=>a.id===customerState.checkoutAddressId);
 return selected||list.find(a=>a.is_default)||list[0]||((me&&me.address)||{});
}
function customerShippingAddressPicker(){
 const list=customerSavedAddresses();if(!me||!list.length)return '';
 const chosen=customerPreferredShippingAddress(),selected=customerState.checkoutAddressId||chosen.id;
 return `<div class='field'><label for='savedShippingAddress'>Saved shipping address</label><select id='savedShippingAddress' onchange='customerSelectShippingAddress(this.value)'>${list.map(a=>`<option value='${esc(a.id)}' ${a.id===selected?'selected':''}>${esc(a.label)}${a.is_default?' (default)':''}</option>`).join('')}<option value='manual' ${selected==='manual'?'selected':''}>Enter another address for this checkout</option></select><small class='muted'>You can manage up to five saved addresses in your account.</small></div>`;
}
function customerSelectShippingAddress(id){
 customerState.checkoutAddressId=id;
 const a=customerPreferredShippingAddress();
 for(const [key,fieldId] of [['street','c_street'],['city','c_city'],['state','c_state'],['zip','c_zip']]){const el=document.getElementById(fieldId);if(el)el.value=String(a[key]||'');}
 if(typeof checkAddress==='function')checkAddress();
}
function customerAddressBookPanel(){
 const list=customerSavedAddresses(),editing=list.find(a=>a.id===customerState.addressEditing),a=editing||{};
 const input=(name,label,auto,max,value)=>`<div class='field'><label for='saved_${name}'>${label}</label><input id='saved_${name}' name='addr_${name}' required maxlength='${max}' autocomplete='${auto}' value='${esc(value||'')}'></div>`;
 const form=list.length>=5&&!editing?'<p class=muted>You have reached the five-address limit. Edit or remove one to add another.</p>':`<form class='panel' style='margin-top:12px' onsubmit='customerSaveAddress(event);return false'><h4>${editing?'Edit saved address':'Add a shipping address'}</h4>${input('label','Label (Home, Office, etc.)','off',50,a.label)}${input('street','Street address','street-address',200,a.street)}<div class='fields2'>${input('city','City','address-level2',100,a.city)}${input('state','State','address-level1',100,a.state)}</div>${input('zip','ZIP / postal code','postal-code',20,a.zip)}<label class='row' style='align-items:center;gap:8px'><input type='checkbox' name='addr_default' style='width:auto' ${a.is_default?'checked':''}>Make this my default shipping address</label><button class='btn gold' type='submit' ${customerState.addressBusy?'disabled':''}>${editing?'Update address':'Save address'}</button>${editing?` <button class='btn ghost' type='button' onclick='customerCancelAddressEdit()'>Cancel editing</button>`:''}</form>`;
 return `<section class='panel' style='margin-top:22px'><h3>Saved shipping addresses</h3><p class='muted'>Private to your verified account. The default address fills checkout, but you can choose another before ordering.</p>${customerState.addressError?`<p class='notice' role='alert'>${esc(customerState.addressError)}</p>`:''}${list.length?list.map(a=>`<div class='lineitem' style='align-items:flex-start'><span><strong>${esc(a.label)}</strong>${a.is_default?' · Default':''}<br><small>${esc([a.street,a.city,a.state,a.zip].filter(Boolean).join(', '))}</small></span><span class='row' style='gap:6px;flex-wrap:wrap'><button type='button' class='btn sm ghost' data-address-action='edit' data-address-id='${esc(a.id)}' onclick='customerAddressAction(event)'>Edit</button>${a.is_default?'':`<button type='button' class='btn sm ghost' data-address-action='default' data-address-id='${esc(a.id)}' onclick='customerAddressAction(event)'>Make default</button>`}<button type='button' class='btn sm danger' data-address-action='remove' data-address-id='${esc(a.id)}' onclick='customerAddressAction(event)'>Remove</button></span></div>`).join(''):'<p class=muted>No saved shipping addresses yet. Your account contact details can still be used at checkout.</p>'}${form}</section>`;
}
function customerCancelAddressEdit(){customerState.addressEditing=null;render();}
async function customerSaveAddress(event){
 event.preventDefault();if(customerState.addressBusy||!customerState.user)return;
 const form=event.currentTarget,field=k=>form.elements.namedItem('addr_'+k);
 const address={street:field('street').value.trim(),city:field('city').value.trim(),state:field('state').value.trim(),zip:field('zip').value.trim()};
 const label=field('label').value.trim(),p_id=customerState.addressEditing||null;
 if(!label||!looksLikeAddress(address)){customerMessage('Enter a label and a complete shipping address before saving.',true);return;}
 const epoch=customerEpoch;customerState.addressBusy=true;
 try{
  const rows=await customerRPC('apex_customer_addresses',{p_action:'save',p_id,p_label:label,p_address:address,p_default:!!form.elements.namedItem('addr_default').checked});
  if(epoch!==customerEpoch)return;
  customerState.addresses=Array.isArray(rows)?rows:[];customerState.addressEditing=null;customerState.addressError='';
  customerMessage('Shipping address saved to your account.');
 }catch{if(epoch===customerEpoch)customerMessage('Could not save that address. Check the details and try again.',true);}
 finally{if(epoch===customerEpoch){customerState.addressBusy=false;render();}}
}
async function customerAddressAction(event){
 const btn=event.target.closest('[data-address-action]');if(!btn||customerState.addressBusy)return;
 const id=btn.getAttribute('data-address-id'),action=btn.getAttribute('data-address-action');
 if(!customerSavedAddresses().some(a=>a.id===id))return;
 if(action==='edit'){customerState.addressEditing=id;render();return;}
 if(action==='remove'&&!window.confirm('Remove this saved address?'))return;
 if(action!=='remove'&&action!=='default')return;
 const epoch=customerEpoch;customerState.addressBusy=true;
 try{
  const rows=await customerRPC('apex_customer_addresses',{p_action:action==='default'?'set_default':'remove',p_id:id});
  if(epoch!==customerEpoch)return;
  customerState.addresses=Array.isArray(rows)?rows:[];customerState.checkoutAddressId=null;
  if(customerState.addressEditing===id)customerState.addressEditing=null;
  customerMessage(action==='remove'?'Saved address removed.':'Default shipping address updated.');
 }catch{if(epoch===customerEpoch)customerMessage('Could not update the saved address. Please try again.',true);}
 finally{if(epoch===customerEpoch){customerState.addressBusy=false;render();}}
}
function customerReceiptToken(raw){
 const value=String(raw||'').trim();if(/^[a-f0-9]{64}$/.test(value))return value;
 try{
  const url=new URL(value,location.origin);if(url.origin!==location.origin)return null;
  const hashQuery=url.hash.includes('?')?url.hash.slice(url.hash.indexOf('?')+1):'';
  const token=new URLSearchParams(hashQuery).get('token')||url.searchParams.get('token');
  return /^[a-f0-9]{64}$/.test(token||'')?token:null;
 }catch{return null;}
}
async function customerAttachReceipt(event){
 event.preventDefault();if(!customerState.user||customerState.loading)return;
 const token=customerReceiptToken(event.currentTarget.elements.namedItem('receipt_token').value);
 if(!token){customerMessage('Enter the private receipt link or its 64-character tracking token.',true);return;}
 const epoch=customerEpoch;customerState.loading=true;
 try{
  const linked=await customerRPC('apex_customer_link_order',{p_token:token});
  if(epoch!==customerEpoch)return;
  if(!linked){customerMessage('This receipt could not be linked. Its checkout email must match your verified account.',true);return;}
  await customerLoadOrders(epoch);if(epoch===customerEpoch)customerMessage('Receipt linked to your private order history.');
 }catch{if(epoch===customerEpoch)customerMessage('Could not link this receipt. Try again or contact Apex support.',true);}
 finally{if(epoch===customerEpoch){customerState.loading=false;render();}}
}
function customerSetOrderSearch(value){customerState.orderSearch=String(value||'').slice(0,100);render();}
function customerSetOrderFilter(value){customerState.orderFilter=['all','paid','pending','test','archived'].includes(value)?value:'all';render();}
function customerFilteredOrders(){
 const q=String(customerState.orderSearch||'').toLowerCase().trim(),filter=customerState.orderFilter||'all';
 return (Array.isArray(customerState.orders)?customerState.orders:[]).filter(o=>{
  if(filter==='paid'&&(!o.payment_confirmed||o.is_test))return false;
  if(filter==='pending'&&(o.payment_confirmed||o.is_test))return false;
  if(filter==='test'&&!o.is_test)return false;
  if(filter==='archived'&&!o.archived)return false;
  const haystack=String(o.ref||'')+' '+(o.items||[]).map(i=>i.name||'').join(' ');
  return !q||haystack.toLowerCase().includes(q);
 });
}
function customerOrdersPanel(){
 const all=customerState.orders||[],visible=customerFilteredOrders();
 return `<section class='panel' style='margin-top:22px'><h3>Your linked orders (${all.length})</h3><p class='muted'>Private order history follows your account across devices. Receipts link only when their checkout email matches your verified email.</p><div class='fields2'><div class='field'><label for='customerOrderSearch'>Search orders</label><input id='customerOrderSearch' maxlength='100' value='${esc(customerState.orderSearch||'')}' placeholder='Order reference or product' onchange='customerSetOrderSearch(this.value)'></div><div class='field'><label for='customerOrderFilter'>Show</label><select id='customerOrderFilter' onchange='customerSetOrderFilter(this.value)'>${[['all','All orders'],['paid','Paid'],['pending','Awaiting payment'],['test','Test orders'],['archived','Archived']].map(([value,label])=>`<option value='${value}' ${customerState.orderFilter===value?'selected':''}>${label}</option>`).join('')}</select></div></div><button class='btn ghost' onclick='customerRefreshOrders()' ${customerState.loading?'disabled':''}>${customerState.loading?'Loading…':'Refresh saved orders'}</button><form style='margin-top:18px' onsubmit='customerAttachReceipt(event);return false'><div class='field'><label for='customerReceiptToken'>Link a receipt from another device</label><input id='customerReceiptToken' name='receipt_token' autocomplete='off' maxlength='600' placeholder='Paste the private tracking link or token'></div><button class='btn ghost' type='submit' ${customerState.loading?'disabled':''}>Link receipt</button><small class='muted'>Only receipts with your verified account email can be linked. Keep private tracking links confidential.</small></form>${visible.length?visible.map(o=>`<article style='margin-top:18px'><h4><a href='#/track-order?token=${esc(o.token)}'>${esc(o.ref)}</a>${o.is_test?' · TEST':''}</h4><p>${esc(trackingStageLabel(o.stage))} · ${o.is_test?'Simulated payment':o.payment_confirmed?'Payment confirmed':'Awaiting payment'}${o.archived?' · Archived':''}</p><p>${money(o.total)} · ${(o.items||[]).map(i=>esc(i.name)+' × '+esc(i.qty)).join(', ')}</p></article>`).join(''):'<p class=muted>No orders match these filters. Guest receipts can still be tracked with their private links.</p>'}</section>`;
}
