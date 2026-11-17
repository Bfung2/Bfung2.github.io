import {createClient} from 'npm:@supabase/supabase-js@2';
const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json'}});
Deno.serve(async(req)=>{
 if(req.method!=='POST')return reply({error:'Method not allowed'},405);
 try{
 const signatureKeys=['paypal-transmission-id','paypal-transmission-time','paypal-cert-url','paypal-auth-algo','paypal-transmission-sig'];
 if(signatureKeys.some(k=>!req.headers.get(k)))return reply({error:'Signature required'},403);
 const raw=await req.text();if(raw.length>262144)return reply({error:'Event too large'},413);
 const event=JSON.parse(raw);const env=Deno.env.get('PAYPAL_ENVIRONMENT');if(!['live','sandbox'].includes(env||''))return reply({error:'Environment missing'},503);
 const base=env==='live'?'https://api-m.paypal.com':'https://api-m.sandbox.paypal.com';
 const cert=new URL(req.headers.get('paypal-cert-url')!);
 if(cert.protocol!=='https:'||!['api.paypal.com','api-m.paypal.com','api.sandbox.paypal.com','api-m.sandbox.paypal.com'].includes(cert.hostname)||!cert.pathname.startsWith('/v1/notifications/certs/'))return reply({error:'Invalid certificate URL'},403);
 const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
 const {data:config,error:configError}=await admin.from('apex_paypal_webhook_config').select('webhook_id').eq('environment',env).maybeSingle();
 if(configError||!config?.webhook_id)return reply({error:'Webhook not registered'},503);
 const tokenResponse=await fetch(base+'/v1/oauth2/token',{method:'POST',headers:{Authorization:'Basic '+btoa(Deno.env.get('PAYPAL_CLIENT_ID')+':'+Deno.env.get('PAYPAL_CLIENT_SECRET')),'Content-Type':'application/x-www-form-urlencoded'},body:'grant_type=client_credentials',signal:AbortSignal.timeout(20000)});
 const token=await tokenResponse.json();if(!tokenResponse.ok||!token.access_token)return reply({error:'Provider authentication failed'},503);
 const auth={Authorization:'Bearer '+token.access_token,'Content-Type':'application/json'};
 const signature={transmission_id:req.headers.get(signatureKeys[0]),transmission_time:req.headers.get(signatureKeys[1]),cert_url:req.headers.get(signatureKeys[2]),auth_algo:req.headers.get(signatureKeys[3]),transmission_sig:req.headers.get(signatureKeys[4]),webhook_id:config.webhook_id};
 // Embed the original event JSON without rewriting its content or number formatting.
 const verification=await fetch(base+'/v1/notifications/verify-webhook-signature',{method:'POST',headers:auth,body:JSON.stringify(signature).slice(0,-1)+',"webhook_event":'+raw+'}',signal:AbortSignal.timeout(20000)});
 const checked=await verification.json();if(!verification.ok)return reply({error:'Verification unavailable'},503);if(checked.verification_status!=='SUCCESS')return reply({error:'Signature invalid'},403);
 if(event.event_type!=='PAYMENT.CAPTURE.REFUNDED')return reply({ignored:true});
 const reference=String(event.resource?.id||'');if(!/^[A-Za-z0-9-]{8,100}$/.test(reference))return reply({error:'Refund reference missing'},400);
 const response=await fetch(base+'/v2/payments/refunds/'+encodeURIComponent(reference),{headers:auth,signal:AbortSignal.timeout(20000)});
 if(!response.ok)return reply({error:'Refund lookup unavailable'},503);const refund=await response.json();
 if(refund.id!==reference||refund.status!=='COMPLETED'||refund.amount?.currency_code!=='USD')return reply({error:'Completed USD refund required'},409);
 const parent=refund.links?.find((l:any)=>l.rel==='up')?.href;const prefix=[base,base.replace('api-m.','api.')].map(origin=>origin+'/v2/payments/captures/').find(prefix=>typeof parent==='string'&&parent.startsWith(prefix))||'';
 if(!prefix||typeof parent!=='string'||!parent.startsWith(prefix)||!/^[A-Za-z0-9-]{8,100}$/.test(parent.slice(prefix.length)))return reply({error:'Capture reference invalid'},409);
 const capture=parent.slice(prefix.length);
 const {data:ord,error}=await admin.from('apex_orders').select('id,is_test,total,tax').eq('paypal_capture_id',capture).maybeSingle();if(error)return reply({error:'Order lookup failed'},503);if(!ord||ord.is_test)return reply({ignored:true});
 if(typeof refund.amount.value!=='string'||!/^\d+(?:\.\d{1,2})?$/.test(refund.amount.value))return reply({error:'Invalid amount'},409);
 const amount=Math.round(Number(refund.amount.value)*100);if(!Number.isSafeInteger(amount)||amount<=0||amount>Math.round(Number(ord.total)*100))return reply({error:'Invalid amount'},409);
 const stored=await admin.from('apex_refund_inbox').upsert({reference,order_id:ord.id,capture_id:capture,amount_cents:amount},{onConflict:'reference',ignoreDuplicates:true});if(stored.error)return reply({error:'Could not record refund'},503);
 if(amount===Math.round(Number(ord.total)*100)){
 const recorded=await admin.rpc('apex_record_verified_refund',{p_order:ord.id,p_reference:reference,p_capture:capture,p_amount:amount,p_tax:Math.round(Number(ord.tax)*100)});
 if(recorded.error)return reply({error:'Refund recorded in inbox; financial reconciliation requires review'},503);
 }
 return reply({success:true});
 }catch{return reply({error:'Webhook processing failed; retry required'},503);}
});
