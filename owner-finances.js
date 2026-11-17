/* Private owner records. Recording a refund never moves money. */
const financeState={rows:[],loaded:false,busy:false,error:''};
const financeKeys=['supplier','postage','processing','packing','commissions','other'];
function financeProfit(row){
 if(!row.paid||row.is_test||!row.costs||!financeKeys.every(k=>Number.isSafeInteger(row.costs[k])&&row.costs[k]>=0))return null;
 const refund=(row.refunds||[]).reduce((sum,r)=>sum+Number(r.amount_cents)-Number(r.tax_cents),0);
 return Math.round((Number(row.subtotal)-Number(row.discount_amount||0)+Number(row.shipping))*100)-refund-financeKeys.reduce((sum,k)=>sum+row.costs[k],0);
}
async function financeRefresh(){
 if(!isOwner||financeState.busy)return;
 financeState.busy=true;financeState.error='';
 try{const {data,error}=await supabaseClient.rpc('apex_owner_finances');if(error)throw error;if(isOwner){financeState.rows=data||[];financeState.loaded=true;}}
 catch(e){if(isOwner)financeState.error=e.message||'Could not load financial records';}
 finally{financeState.busy=false;if(isOwner&&route()==='/finances')render();else{financeState.rows=[];financeState.loaded=false;}}
}
function financePage(){
 if(!isOwner){financeState.rows=[];financeState.loaded=false;return '<div class="wrap">Owner access required</div>';}
 return `<div class="wrap"><h2>Order finances</h2><p>Latest 100 real orders. Profit uses your recorded actual costs, excludes collected tax, and subtracts refunds excluding refunded tax. Enter zero explicitly when a cost does not apply. Include all commission expense here; payouts are not automatically imported.</p><button class="btn gold" onclick="financeRefresh()" ${financeState.busy?'disabled':''}>${financeState.busy?'Loading…':'Load / refresh orders'}</button><p role="status">${esc(financeState.error)}</p>${financeState.loaded&&!financeState.rows.length?'<p>No real orders yet.</p>':''}${financeState.rows.map((r,i)=>{
 const profit=financeProfit(r);
 return `<section class="panel" style="margin-top:16px"><h3>${esc(r.ref)}</h3><p>${r.paid?'Payment captured':'Awaiting payment'} · Recorded net contribution: <strong>${profit===null?'Costs incomplete':money(profit/100)}</strong></p>${r.paid?`<form onsubmit="return financeSave(event,${i})"><div class="grid">${financeKeys.map(k=>`<label>${esc(k)} ($)<input name="${k}" type="number" min="0" max="1000000" step="0.01" required value="${r.costs?.[k]===undefined?'':r.costs[k]/100}"></label>`).join('')}</div><button class="btn" ${financeState.busy?'disabled':''}>Save actual costs</button></form><details><summary>PayPal refund tools</summary><p>Verify an existing refund or issue a full refund. Partial refunds and disputed/changed captures must be handled in PayPal.</p><button type="button" class="btn" onclick="financeFullRefund(${i})">Issue full refund…</button><form onsubmit="return financeVerify(event,${i})"><label>Existing PayPal refund ID<input name="reference" required pattern="[A-Za-z0-9-]{8,100}"></label><label>Tax refunded ($)<input name="tax" type="number" required min="0" step="0.01"></label><button class="btn">Verify with PayPal</button></form></details><details><summary>Record a completed refund manually</summary><p>Refund the customer in PayPal first. This records your external refund; it does not issue or verify a PayPal refund. Review employee commission adjustments separately.</p><form onsubmit="return financeRefund(event,${i})"><label>Provider refund reference<input name="reference" required pattern="[A-Za-z0-9-]{8,100}"></label><label>Total refunded ($, including tax)<input name="amount" type="number" required min="0.01" step="0.01"></label><label>Tax refunded ($)<input name="tax" type="number" required min="0" step="0.01"></label><button class="btn" ${financeState.busy?'disabled':''}>Record completed refund</button></form></details>`:''}<p>${(r.refunds||[]).map(x=>esc(x.reference)+(x.verified_at?' (PayPal verified)':' (manual, unverified)')+': '+money(Number(x.amount_cents)/100)).join('<br>')}</p></section>`;
 }).join('')}</div>`;
}
function financeSave(e,index){e.preventDefault();const f=new FormData(e.target),r=financeState.rows[index],costs={};for(const k of financeKeys)costs[k]=Math.round(Number(f.get(k))*100);void financeWrite('costs',{order_id:r.id,revision:r.revision,costs});return false;}
function financeRefund(e,index){e.preventDefault();const f=new FormData(e.target),r=financeState.rows[index];void financeWrite('refund',{order_id:r.id,reference:String(f.get('reference')).trim(),amount_cents:Math.round(Number(f.get('amount'))*100),tax_cents:Math.round(Number(f.get('tax'))*100)});return false;}
async function financeWrite(action,data){
 if(!isOwner||financeState.busy)return;financeState.busy=true;
 try{const {error}=await supabaseClient.rpc('apex_owner_finances',{p_action:action,p_data:data});if(error)throw error;financeState.busy=false;await financeRefresh();}
 catch(e){financeState.busy=false;if(isOwner){financeState.error=e.message||'Save failed';render();}}
}

function financeVerify(e,index){e.preventDefault();const f=new FormData(e.target);void financeProvider({action:'verify',orderId:financeState.rows[index].id,reference:String(f.get('reference')),taxCents:Math.round(Number(f.get('tax'))*100)});return false;}
function financeFullRefund(index){
 if(!isOwner||financeState.busy)return;const r=financeState.rows[index];
 const answer=prompt('This will return '+money(Number(r.total))+' to the customer through PayPal. Type the order ID '+r.id+' to authorize. Commission adjustments require separate review.');
 if(answer!==r.id)return;void financeProvider({action:'full',orderId:r.id,confirmation:answer});
}
async function financeProvider(body){
 if(!isOwner||financeState.busy)return;financeState.busy=true;
 try{const {data,error}=await supabaseClient.functions.invoke('paypal-refunds',{body});if(error){let detail;try{detail=await error.context?.json();}catch{}throw Error(detail?.error||error.message);}if(!data?.success)throw Error(data?.error||'Refund requires review');financeState.busy=false;await financeRefresh();}
 catch(e){financeState.busy=false;if(isOwner){financeState.error=e.message;render();}}
}
