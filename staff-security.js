/* Owner access is unlocked only by server-confirmed MFA. Employee credentials are independent. */
let staffSecurity={loading:false,loaded:false,owner:false,verified:false,enrolled:false,error:''};
let staffSecurityEpoch=0;
function staffSecurityReset(){staffSecurityEpoch++;staffSecurity={loading:false,loaded:false,owner:false,verified:false,enrolled:false,error:''};}
async function staffSecurityLoad(){
 if(staffSecurity.loading)return;const epoch=staffSecurityEpoch;staffSecurity.loading=true;
 try{const {data,error}=await supabaseClient.rpc('apex_staff_security_status');if(error)throw error;if(epoch!==staffSecurityEpoch)return;staffSecurity={...data,loaded:true,loading:false,error:''};if(data.verified)await staffLoadContext();}
 catch{if(epoch===staffSecurityEpoch)staffSecurity={loading:false,loaded:true,owner:false,verified:false,error:'Could not verify staff security. Retry or sign in again.'};}
 finally{if(epoch===staffSecurityEpoch)render();}
}
function staffSecurityGate(){
 if(!isOwner&&!isEmployee)return null;
 if(!staffSecurity.loaded){if(!staffSecurity.loading)void staffSecurityLoad();return '<div class="wrap"><p role="status">Verifying staff security…</p></div>';}
 if(staffSecurity.verified)return null;
 if(isOwner)return teamSecurityPage();
 return '<div class="wrap"><h2>Employee password setup required</h2><p>Ask the owner to issue your employee ID and a separate password from Employees. Previous code-only sessions no longer have staff access.</p><button class="btn gold" onclick="logout()">Sign out</button></div>';
}
function staffSecurityControls(){return `<div class="row"><button class="btn ghost" onclick="staffSecurityReset();render()">Refresh security status</button><button class="btn ghost" onclick="logout()">Sign out</button></div>`;}
