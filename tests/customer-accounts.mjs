import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
let options,authListener,sendCount=0,staffSignOuts=0,profileResolve;
const calls=[];
const client={auth:{onAuthStateChange(fn){authListener=fn;},getSession:async()=>({data:{session:null}}),signOut:async()=>({}),signUp:async()=>{sendCount++;return {};},resetPasswordForEmail:async()=>{sendCount++;return {};},updateUser:async()=>({})},rpc:async(name,args)=>{calls.push({name,args});if(name==='apex_customer_profile')return {data:{email:'real@test.invalid',name:'<customer>',address:{}}};if(name==='apex_customer_orders')return {data:[{ref:'AC-ONE',token:'c'.repeat(64),is_test:true,items:[{name:'<script>',qty:1}],total:10}]};return {data:true};}};
const ctx=vm.createContext({window:{supabase:{createClient:(url,key,opts)=>{options=opts;return client;}}},SUPABASE_URL:'https://test.invalid',SUPABASE_ANON_KEY:'public',customerAuthCallback:false,me:null,supabaseClient:{auth:{signOut(){staffSignOuts++;}}},savedOrderTracking:()=>[{token:'c'.repeat(64)}],trackingSavedLinks:()=>'',trackingStageLabel:()=>'<stage>',money:n=>'$'+n,esc:s=>String(s??'').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;'),location:{origin:'https://bfung2.github.io',pathname:'/'},localStorage:{removeItem(){}},render(){},go(){},toast(){},setTimeout});
vm.runInContext(await fs.readFile(new URL('../customer-accounts.js',import.meta.url),'utf8'),ctx);const run=s=>vm.runInContext(s,ctx);
assert.equal(options.auth.storageKey,'apex.customer.auth');assert.equal(options.auth.flowType,'pkce');assert.equal(options.auth.detectSessionInUrl,false);
await run('initializeCustomerAuth()');assert.ok(run('customerState.ready'));assert.equal(run('me'),null);
await run("customerApplySession({user:{id:'one'}})");assert.equal(run('me.email'),'real@test.invalid');assert.equal(run('customerState.orders.length'),1);assert.ok(calls.some(x=>x.name==='apex_customer_link_order'));
let html=run('customerAccountPage()');assert.ok(html.includes('&lt;customer&gt;'));assert.ok(html.includes('&lt;script&gt;'));assert.ok(html.includes('TEST'));assert.ok(html.includes('Simulated payment'));
// Signing out must invalidate a pending profile response and leave staff auth alone.
const originalRpc=client.rpc;
client.rpc=async()=>new Promise(r=>{profileResolve=r;});const pending=run("customerApplySession({user:{id:'old'}})");await run('customerLogout()');profileResolve({data:{email:'old@test.invalid'}});await pending;assert.equal(run('me'),null);assert.equal(run('customerState.orders.length'),0);assert.equal(staffSignOuts,0);
// A stale receipt must not prevent the rest of the customer's history from loading.
ctx.savedOrderTracking=()=>[{token:'b'.repeat(64)},{token:'c'.repeat(64)}];
client.rpc=async(name,args)=>{
 if(name==='apex_customer_link_order'&&args.p_token==='b'.repeat(64))return {error:{message:'old receipt'}};
 return originalRpc(name,args);
};
await run("customerApplySession({user:{id:'valid'}})");
assert.equal(run('customerState.orders.length'),1);
assert.ok(calls.some(x=>x.name==='apex_customer_orders'));
// Recovery stays available if the profile RPC fails.
client.rpc=async(name,args)=>name==='apex_customer_profile'?{error:{message:'unavailable'}}:originalRpc(name,args);
await run("customerApplySession({user:{id:'recover'}})");
run('customerState.recovery=true');
assert.equal(run('me'),null);
assert.equal(run('customerState.user.id'),'recover');
assert.ok(run('customerLoginPage()').includes('Reset your password'));
client.rpc=originalRpc;
for(const mode of ['signup','reset']){run(`customerSetMode('${mode}')`);await run("customerLogin({preventDefault(){},currentTarget:{elements:{email:{value:'test@invalid.test'},password:{value:'password'}}}})");}assert.equal(sendCount,0);
assert.ok(run('customerLoginPage()').includes('New accounts and password reset are being set up'));
authListener('PASSWORD_RECOVERY',null);assert.equal(run('customerState.recovery'),true);
const index=await fs.readFile(new URL('../index.html',import.meta.url),'utf8');assert.ok(index.includes('detectSessionInUrl:!customerAuthCallback'));assert.ok(!index.includes('JSON.parse(localStorage.getItem("apex.customer")'));assert.ok(index.includes('customerLinkReceipt(o.trackingToken)'));
console.log('PASS: resilient receipt linking, recovery without profile, separate staff/customer sessions, PKCE callback isolation, verified-profile display, escaped test history, pending-response logout isolation, rollout email gate and recovery event.');
