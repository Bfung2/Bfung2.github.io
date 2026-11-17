import { createClient } from 'npm:@supabase/supabase-js@2';
const headers={'Access-Control-Allow-Origin':'https://bfung2.github.io','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'};
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...headers,'Content-Type':'application/json'}});
function refundCents(value:unknown){if(typeof value!=='string'||!/^\d+(?:\.\d{1,2})?$/.test(value))throw Error('Invalid provider amount');const n=Math.round(Number(value)*100);if(!Number.isSafeInteger(n)||n<=0)throw Error('Invalid provider amount');return n;}
function verifyRefund(data:any,reference:string,capture:string,base:string){
 if(data.id!==reference||data.status!=='COMPLETED'||data.amount?.currency_code!=='USD'||!Array.isArray(data.links)||!data.links.some((l:any)=>l.rel==='up'&&[base,base.replace('api-m.','api.')].some(origin=>l.href===origin+'/v2/payments/captures/'+encodeURIComponent(capture))))throw Error('Refund is not completed for this capture');
 return refundCents(data.amount.value);
}
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers});if(req.method!=='POST')return json({error:'Method not allowed'},405);
 try{
 const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!,key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
 const caller=createClient(url,anon,{global:{headers:{Authorization:req.headers.get('Authorization')||''}},auth:{persistSession:false}});
 const {data:{user},error:authError}=await caller.auth.getUser();if(authError||!user)return json({error:'Owner required'},403);
 const {data:owner,error:ownerError}=await caller.rpc('apex_is_owner');if(ownerError||owner!==true)return json({error:'Verified owner authenticator required'},403);
 const input=await req.json();if(!['verify','full','configure'].includes(input.action)||(input.action!=='configure'&&(typeof input.orderId!=='string'||input.orderId.length>160)))return json({error:'Invalid action or order'},400);
 const admin=createClient(url,key,{auth:{persistSession:false}});
 const env=Deno.env.get('PAYPAL_ENVIRONMENT');if(!['live','sandbox'].includes(env||''))throw Error('Payment environment is not configured');
 const base=env==='live'?'https://api-m.paypal.com':'https://api-m.sandbox.paypal.com';
 const client=Deno.env.get('PAYPAL_CLIENT_ID'),secret=Deno.env.get('PAYPAL_CLIENT_SECRET');if(!client||!secret)throw Error('Payment service not configured');
 const tokenResponse=await fetch(base+'/v1/oauth2/token',{method:'POST',headers:{Authorization:'Basic '+btoa(client+':'+secret),'Content-Type':'application/x-www-form-urlencoded'},body:'grant_type=client_credentials',signal:AbortSignal.timeout(20000)});
 const tokenData=await tokenResponse.json();if(!tokenResponse.ok||!tokenData.access_token)throw Error('PayPal authentication failed');
 const auth={Authorization:'Bearer '+tokenData.access_token,'Content-Type':'application/json'};
 const get=async(path:string)=>{const r=await fetch(base+path,{headers:auth,signal:AbortSignal.timeout(20000)});if(!r.ok)throw Error('PayPal lookup failed; reconcile before retrying');return await r.json();};
 if(input.action==='configure'){
 const endpoint=url+'/functions/v1/paypal-webhook';
 const existing=await get('/v1/notifications/webhooks');
 let hook=existing.webhooks?.find((h:any)=>h.url===endpoint);
 if(hook&&!hook.event_types?.some((e:any)=>e.name==='PAYMENT.CAPTURE.REFUNDED'||e.name==='*'))throw Error('Existing webhook needs its refund subscription updated in PayPal');
 if(!hook){const response=await fetch(base+'/v1/notifications/webhooks',{method:'POST',headers:auth,body:JSON.stringify({url:endpoint,event_types:[{name:'PAYMENT.CAPTURE.REFUNDED'}]}),signal:AbortSignal.timeout(20000)});if(!response.ok)throw Error('Webhook registration failed; retry to discover an existing registration');hook=await response.json();}
 if(!hook?.id)throw Error('Provider returned no webhook ID');
 const saved=await admin.from('apex_paypal_webhook_config').upsert({environment:env,webhook_id:hook.id},{onConflict:'environment'});if(saved.error)throw Error('Webhook registered but local verification setup failed; retry configuration');
 return json({success:true,configured:true});
 }
 const {data:ord,error}=await admin.from('apex_orders').select('id,total,tax,is_test,paypal_capture_id').eq('id',input.orderId).maybeSingle();
 if(error||!ord||ord.is_test||!ord.paypal_capture_id)return json({error:'Real captured order required'},409);
 let reference=String(input.reference||''),tax=Number(input.taxCents),attempt:any=null;
 if(input.action==='full'){
 if(input.confirmation!==ord.id)return json({error:'Type the exact order ID to authorize a full refund'},400);
 const reservation=await admin.rpc('apex_reserve_full_refund',{p_order:ord.id});if(reservation.error)throw Error(reservation.error.message);attempt=reservation.data;
 reference=attempt.refund_id||'';tax=Math.round(Number(ord.tax)*100);
 if(!reference){
 if(Date.now()-Date.parse(attempt.created_at)>3600000)throw Error('Refund attempt is over one hour old. Reconcile in PayPal; automatic retry is blocked');
 const capture=await get('/v2/payments/captures/'+encodeURIComponent(ord.paypal_capture_id));
 if(capture.id!==ord.paypal_capture_id||capture.status!=='COMPLETED'||capture.amount?.currency_code!=='USD'||refundCents(capture.amount?.value)!==Math.round(Number(ord.total)*100))throw Error('Capture changed or was already refunded. Reconcile in PayPal');
 const response=await fetch(base+'/v2/payments/captures/'+encodeURIComponent(ord.paypal_capture_id)+'/refund',{method:'POST',headers:{...auth,'PayPal-Request-Id':attempt.request_id,Prefer:'return=representation'},body:JSON.stringify({amount:{currency_code:'USD',value:Number(ord.total).toFixed(2)}}),signal:AbortSignal.timeout(20000)});
 const data=await response.json();if(!response.ok||!data.id)throw Error('Refund result is uncertain. Retry this same order within one hour or reconcile in PayPal');reference=data.id;
 const saved=await admin.from('apex_refund_attempts').update({refund_id:reference}).eq('order_id',ord.id);if(saved.error)throw Error('Refund submitted; saving its reference failed. Reconcile in PayPal');
 }
 }
 if(!/^[A-Za-z0-9-]{8,100}$/.test(reference)||!Number.isSafeInteger(tax)||tax<0)throw Error('Valid refund ID and refunded tax required');
 const detail=await get('/v2/payments/refunds/'+encodeURIComponent(reference));
 const amount=verifyRefund(detail,reference,ord.paypal_capture_id,base);
 if(input.action==='full'&&amount!==Math.round(Number(ord.total)*100))throw Error('Refund amount needs manual review');
 const result=await admin.rpc('apex_record_verified_refund',{p_order:ord.id,p_reference:reference,p_capture:ord.paypal_capture_id,p_amount:amount,p_tax:tax});if(result.error)throw Error('Provider refund confirmed, but local records need review: '+result.error.message);
 return json({success:true,reference,amountCents:amount,commissionReviewRequired:true});
 }catch(e){return json({error:e instanceof Error?e.message:'Refund processing failed'},409);}
});
