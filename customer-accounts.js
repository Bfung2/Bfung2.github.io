/* Customer sessions have separate storage from staff sessions. Email delivery must be
   configured and tested before turning on account creation / password recovery. */
const CUSTOMER_EMAIL_READY=false;
const customerClient=window.supabase.createClient(SUPABASE_URL,SUPABASE_ANON_KEY,{auth:{storageKey:'apex.customer.auth',flowType:'pkce',detectSessionInUrl:customerAuthCallback}});
let customerState={ready:false,loading:false,user:null,orders:[],error:'',message:'',mode:'signin',recovery:false},customerEpoch=0;
function customerRedirect(kind){return location.origin+location.pathname+'?customer_auth='+kind;}
function customerMessage(text,error=false){customerState.error=error?text:'';customerState.message=error?'':text;render();}
async function customerRPC(name,args={}){const {data,error}=await customerClient.rpc(name,args);if(error)throw error;return data;}
async function customerApplySession(session){
 const epoch=++customerEpoch;me=null;customerState.user=null;customerState.orders=[];customerState.loading=!!session;
 try{
  if(session){
   const profile=await customerRPC('apex_customer_profile');
   if(epoch!==customerEpoch)return;
   me=profile;customerState.user=session.user;
   await customerLoadOrders(epoch);
  }
 }catch{if(epoch===customerEpoch)customerState.error='Your account could not be loaded. Confirm your email, then sign in again or retry.';}
 finally{if(epoch===customerEpoch){customerState.ready=true;customerState.loading=false;render();}}
}
async function customerLoadOrders(epoch=customerEpoch){
 for(const link of savedOrderTracking()){
  if(epoch!==customerEpoch)return;
  await customerRPC('apex_customer_link_order',{p_token:link.token});
 }
 const orders=await customerRPC('apex_customer_orders');
 if(epoch===customerEpoch)customerState.orders=orders;
}
async function initializeCustomerAuth(){
 customerClient.auth.onAuthStateChange((event,session)=>{
  if(event==='PASSWORD_RECOVERY')customerState.recovery=true;
  if(event==='INITIAL_SESSION'||event==='TOKEN_REFRESHED')return;
  setTimeout(()=>customerApplySession(session),0);
 });
 try{
  const {data,error}=await customerClient.auth.getSession();if(error)throw error;
  await customerApplySession(data.session);
  if(customerAuthCallback){
   if(!data.session)customerState.error='This confirmation or recovery link expired or was opened in a different browser. Request a new link and open it in the browser where you started.';
   history.replaceState(null,'',location.pathname+'#/account');render();
  }
 }catch{customerState.ready=true;customerMessage('Unable to check your account session. Refresh and try again.',true);}
}
function customerSetMode(mode){customerState.mode=mode;customerState.error='';customerState.message='';render();}
async function customerLogin(event){
 event.preventDefault();if(customerState.loading)return;
 const form=event.currentTarget,mode=customerState.mode,email=form.elements.email.value.trim(),password=form.elements.password?.value;
 if(mode!=='signin'&&!CUSTOMER_EMAIL_READY)return customerMessage('Account emails are being set up. Guest checkout and private tracking links remain available.',true);
 customerState.loading=true;customerState.error='';customerState.message='';render();
 try{
  if(mode==='signup'){
   const {error}=await customerClient.auth.signUp({email,password,options:{emailRedirectTo:customerRedirect('confirm')}});if(error)throw error;
   customerMessage('If this email is eligible, a confirmation link has been sent. Open it in this browser, then sign in. Check spam too.');
  }else if(mode==='reset'){
   const {error}=await customerClient.auth.resetPasswordForEmail(email,{redirectTo:customerRedirect('recovery')});if(error)throw error;
   customerMessage('If an account exists, a password reset link has been sent. Open it in this browser.');
  }else{
   const {data,error}=await customerClient.auth.signInWithPassword({email,password});if(error)throw error;
   await customerApplySession(data.session);
   if(me){customerState.error='';go('/account');}
  }
 }catch{customerMessage(mode==='signin'?'Sign-in failed. Check your email/password and confirm your email first.':'The email could not be sent. Wait a moment and try again, or contact Apex.',true);}
 finally{customerState.loading=false;render();}
}
async function customerLogout(){
 try{const {error}=await customerClient.auth.signOut({scope:'local'});if(error)throw error;}
 catch{customerMessage('Sign-out could not finish. Please retry before leaving a shared device.',true);return;}
 ++customerEpoch;me=null;customerState.user=null;customerState.orders=[];customerState.recovery=false;customerState.error='';
 try{localStorage.removeItem('apex.customer');}catch{}
 go('/login');render();
}
async function customerSaveProfile(event){
 event.preventDefault();const form=event.currentTarget,epoch=customerEpoch;
 const details={name:form.elements.name.value,phone:form.elements.phone.value,address:Object.fromEntries(['street','city','state','zip'].map(k=>[k,form.elements[k].value]))};
 const button=event.submitter;if(button)button.disabled=true;
 try{const profile=await customerRPC('apex_customer_profile',{p_details:details});if(epoch!==customerEpoch)return;me=profile;customerMessage('Contact details saved to your account.');}
 catch{if(epoch===customerEpoch)customerMessage('Could not save your details. Please retry.',true);}finally{if(button)button.disabled=false;}
}
async function customerLinkReceipt(token){
 if(!customerState.user)return;
 try{await customerRPC('apex_customer_link_order',{p_token:token});}catch{toast('Your order is saved. Open your account later to link its receipt.');}
}
async function customerRefreshOrders(){
 if(customerState.loading)return;customerState.loading=true;customerState.error='';const epoch=customerEpoch;render();
 try{await customerLoadOrders(epoch);}catch{if(epoch===customerEpoch)customerState.error='Could not load order history. Your private receipt links still work.';}
 finally{if(epoch===customerEpoch){customerState.loading=false;render();}}
}
async function customerSavePassword(event){
 event.preventDefault();const form=event.currentTarget,password=form.elements.password.value;
 if(password!==form.elements.confirm_password.value)return customerMessage('The passwords do not match.',true);
 const button=event.submitter;if(button)button.disabled=true;
 try{const {error}=await customerClient.auth.updateUser({password});if(error)throw error;customerState.recovery=false;customerMessage('Password updated.');}
 catch{customerMessage('Password could not be updated. Request a new recovery link and try again.',true);}finally{if(button)button.disabled=false;}
}
function customerNotices(){return `${customerState.error?`<p class="notice" role="alert">${esc(customerState.error)}</p>`:''}${customerState.message?`<p class="notice" role="status">${esc(customerState.message)}</p>`:''}`;}
function customerLoginPage(){
 if(!customerState.ready)return '<div class="wrap"><p role="status">Checking your account…</p></div>';
 if(me){go('/account');return '';}
 const mode=customerState.mode,title={signin:'Customer sign in',signup:'Create an account',reset:'Reset password'}[mode];
 return `<div class="wrap" style="max-width:560px"><div class="pagehead"><div><h2>${title}</h2><p>Verified email access to your saved details and linked orders.</p></div></div>${customerNotices()}${!CUSTOMER_EMAIL_READY?'<div class="notice">New accounts and password reset are being set up. You can still check out as a guest and track orders with your private receipt link.</div>':''}<form class="panel" onsubmit="customerLogin(event);return false"><div class="field"><label for="customerEmail">Email</label><input id="customerEmail" name="email" type="email" required maxlength="254" autocomplete="username"></div>${mode!=='reset'?`<div class="field"><label for="customerPassword">Password</label><input id="customerPassword" name="password" type="password" required ${mode==='signup'?'minlength="12"':''} autocomplete="${mode==='signup'?'new-password':'current-password'}"></div>`:''}<button class="btn gold" type="submit" ${customerState.loading||mode!=='signin'&&!CUSTOMER_EMAIL_READY?'disabled':''}>${customerState.loading?'Please wait…':title}</button></form><div class="row" style="margin-top:18px"><button class="btn ghost" onclick="customerSetMode('signin')">Sign in</button><button class="btn ghost" onclick="customerSetMode('signup')">Create account</button><button class="btn ghost" onclick="customerSetMode('reset')">Forgot password</button></div><p><a href="#/track-order">Track an order without signing in</a></p><p><a href="#/staff">Staff and owner sign-in</a></p></div>`;
}
function customerAccountPage(){
 if(!customerState.ready)return '<div class="wrap"><p role="status">Checking your account…</p></div>';
 if(!me){return customerLoginPage();}
 const address=me.address||{};
 return `<div class="wrap" style="max-width:900px"><div class="pagehead"><div><h2>Your account</h2><p>${esc(me.email)} · Verified email</p></div><button class="btn ghost" onclick="customerLogout()">Sign out</button></div>${customerNotices()}${customerState.recovery?'<form class="panel" onsubmit="customerSavePassword(event);return false"><h3>Choose a new password</h3><div class="field"><label for="newCustomerPassword">New password (at least 12 characters)</label><input id="newCustomerPassword" name="password" type="password" minlength="12" required autocomplete="new-password"></div><div class="field"><label for="confirmCustomerPassword">Confirm password</label><input id="confirmCustomerPassword" name="confirm_password" type="password" minlength="12" required autocomplete="new-password"></div><button class="btn gold">Update password</button></form>':''}<form class="panel" onsubmit="customerSaveProfile(event);return false"><h3>Your contact details</h3><p class="muted">Saved privately to your account for checkout. Changing these details does not change existing orders.</p>${[['name','Name',120,'name',me.name],['phone','Phone',40,'tel',me.phone],['street','Street address',200,'address-line1',address.street],['city','City',200,'address-level2',address.city],['state','State',200,'address-level1',address.state],['zip','ZIP / postal code',200,'postal-code',address.zip]].map(([key,label,max,auto,val])=>`<div class="field"><label for="profile_${key}">${label}</label><input id="profile_${key}" name="${key}" maxlength="${max}" autocomplete="${auto}" value="${esc(val||'')}"></div>`).join('')}<button class="btn gold">Save details</button></form><section class="panel" style="margin-top:22px"><h3>Your linked orders</h3><p class="muted">Your latest 100 linked orders are available across devices. Orders saved in this browser link only when their checkout email matches your verified email. Older archived orders may require help from Apex.</p><button class="btn ghost" onclick="customerRefreshOrders()" ${customerState.loading?'disabled':''}>${customerState.loading?'Loading…':'Refresh / link saved receipts'}</button>${customerState.orders.length?customerState.orders.map(o=>`<article style="margin-top:18px"><h4><a href="#/track-order?token=${esc(o.token)}">${esc(o.ref)}</a>${o.is_test?' · TEST':''}</h4><p>${esc(trackingStageLabel(o.stage))} · ${o.is_test?'Simulated payment':o.payment_confirmed?'Payment confirmed':'Awaiting payment'}${o.archived?' · Archived':''}</p><p>${money(o.total)} · ${(o.items||[]).map(i=>esc(i.name)+' × '+esc(i.qty)).join(', ')}</p></article>`).join(''):'<p>No orders linked yet. Guest checkout still works; keep your private receipt link.</p>'}</section><div style="margin-top:22px">${trackingSavedLinks()}</div></div>`;
}
