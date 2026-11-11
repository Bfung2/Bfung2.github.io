import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { paidOrderMessage, utf8Base64, notificationOwnerEmail } from './message.ts';
const cors = {'Access-Control-Allow-Origin':'https://bfung2.github.io','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'};
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,'Content-Type':'application/json'}});
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 if(req.method!=='POST')return json({error:'Method not allowed'},405);
 try{
  const url=Deno.env.get('SUPABASE_URL')!,key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!;
  if(!url||!key||!anon)return json({error:'Notification service is not configured'},500);
  const authorization=req.headers.get('Authorization')||'';
  if(authorization!=='Bearer '+key){
   const caller=createClient(url,anon,{global:{headers:{Authorization:authorization}},auth:{persistSession:false}});
   const {data:{user},error}=await caller.auth.getUser();
   if(error||!user||user.email?.toLowerCase()!=='apexcomputers039@gmail.com')return json({error:'Owner or payment server required'},403);
  }
  const input=await req.json(),orderId=String(input.orderId||'');
  if(!orderId||orderId.length>160)return json({error:'Order ID required'},400);
  let ownerRecipient: string;
  try {
    const response=await fetch('https://raw.githubusercontent.com/Bfung2/Bfung2.github.io/main/data.json?_='+Date.now(),{cache:'no-store',signal:AbortSignal.timeout(10000)});
    if(!response.ok)throw new Error('Site settings unavailable');
    const site=await response.json();ownerRecipient=notificationOwnerEmail(site.settings);
  } catch {return json({error:'Could not load a valid owner notification email from saved Site settings; notifications remain queued'},503);}
  const clientId=Deno.env.get('GOOGLE_CLIENT_ID'),clientSecret=Deno.env.get('GOOGLE_CLIENT_SECRET'),refreshToken=Deno.env.get('GOOGLE_REFRESH_TOKEN');
  if(!clientId||!clientSecret||!refreshToken)return json({error:'Gmail OAuth secrets are missing; paid notifications remain queued'},503);
  const tokenResponse=await fetch('https://oauth2.googleapis.com/token',{method:'POST',signal:AbortSignal.timeout(20000),headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:clientId,client_secret:clientSecret,refresh_token:refreshToken,grant_type:'refresh_token'})});
  const tokenData=await tokenResponse.json();if(!tokenResponse.ok||!tokenData.access_token)return json({error:'Gmail authorization failed; paid notifications remain queued'},503);
  const admin=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:jobs,error}=await admin.rpc('apex_claim_paid_notifications',{p_order:orderId});
  if(error)return json({error:'Could not claim notifications'},500);
  let sent=0,failed=0;
  for(const job of jobs||[]){
   let failure:string|null=null;
   try{
    if(job.recipient_kind==='owner'){
      job.recipient=ownerRecipient;
      const {error:recipientError}=await admin.from('apex_paid_notifications').update({recipient:ownerRecipient}).eq('id',job.id).eq('lease_token',job.lease_token).eq('state','sending');
      if(recipientError)throw new Error('Could not save the configured owner email for this notification');
    }
    if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(job.recipient)||/[<>,;]/.test(job.recipient)||job.recipient.length>254)throw new Error('Set a valid employee contact email, then retry');
    const message=paidOrderMessage(job.payload);
    const mime=['To: '+job.recipient,'From: Apex Computers <apexcomputers039@gmail.com>','Reply-To: '+ownerRecipient,'Subject: =?UTF-8?B?'+utf8Base64(message.subject)+'?=','Message-ID: <apex-paid-'+job.id+'@apexcomputers.internal>','MIME-Version: 1.0','Content-Type: text/plain; charset="UTF-8"','Content-Transfer-Encoding: base64','',utf8Base64(message.body).replace(/.{1,76}/g,'$&\r\n')].join('\r\n');
    const response=await fetch('https://gmail.googleapis.com/gmail/v1/users/me/messages/send',{method:'POST',signal:AbortSignal.timeout(20000),headers:{Authorization:'Bearer '+tokenData.access_token,'Content-Type':'application/json'},body:JSON.stringify({raw:utf8Base64(mime).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/g,'')})});
    if(!response.ok)throw new Error('Gmail delivery failed; retry from the owner dashboard');
   }catch(e){failure=e instanceof Error?e.message:'Notification failed';}
   const {error:finishError}=await admin.rpc('apex_finish_paid_notification',{p_id:job.id,p_lease:job.lease_token,p_success:!failure,p_error:failure});
   if(failure||finishError)failed++;else sent++;
  }
  return json({success:failed===0,sent,failed});
 }catch{return json({error:'Notification service unavailable; payment status is unchanged'},503);}
});
