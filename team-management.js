/* Staff-only overview and security. Private data is never stored in the catalog. */
let teamActivity={epoch:0,loaded:false,loading:false,items:[],error:''};
function teamReset(){teamActivity={epoch:teamActivity.epoch+1,loaded:false,loading:false,items:[],error:''};}
function teamOverview(){
 const denied=staffGate();if(denied)return denied;
 staffLoadSales();
 if(isOwner)return staffDashboardPage();
 if(!employeeJobsLoaded&&!employeeJobsLoading)loadEmployeeJobs();
 const mine=[...employeeJobs.orders,...employeeJobs.requests].filter(j=>j.assigned_to===employeeProfile?.user_id);
 const active=mine.filter(j=>!['completed','delivered','cancelled','done'].includes(j.status));
 return staffShell('My overview','Your work, sales and commission history.',`<div class="staff-metrics"><a class="panel" href="#/employee"><small>Assigned work</small><strong class="staff-metric">${active.length}</strong></a><a class="panel" href="#/sales-credits"><small>My real contributions</small><strong class="staff-metric">${staffSales.items.filter(c=>!c.is_test).length}</strong></a></div>${staffSales.error?`<p class="notice" role="alert">${esc(staffSales.error)}</p>`:''}${staffCommissionSummary(staffSales.items)}<div class="row"><a class="btn gold" href="#/employee">My assigned work</a><a class="btn ghost" href="#/sales-credits">Commission history</a>${staffCan('prepare_sales')?'<a class="btn ghost" href="#/market-sales">Customer links & sale progress</a>':''}</div><h3>My access</h3><ul>${STAFF_PERMISSIONS.filter(([k])=>staffCan(k)).map(([,label])=>`<li>${esc(label)}</li>`).join('')||'<li>No optional permissions enabled.</li>'}</ul>`);
}
async function teamLoadActivity(older=false){
 if(!isOwner||teamActivity.loading||(!older&&teamActivity.loaded))return;
 const state=teamActivity,epoch=staffEpoch;state.loading=true;state.error='';
 try{const rows=await staffRPC('apex_team_activity',{p_before:older?state.items.at(-1)?.id:null});if(epoch!==staffEpoch)return;state.items=older?[...state.items,...rows]:rows;state.loaded=true;state.more=rows.length===50;}
 catch(e){if(epoch===staffEpoch){state.error=e.message;state.loaded=true;}}
 finally{if(epoch===staffEpoch){state.loading=false;if(route()==='/team-activity')render();}}
}
function teamActivityPage(){
 const denied=staffOwnerOnly();if(denied)return denied;teamLoadActivity();
 return staffShell('Team activity','Order changes, permissions, notes and commission actions.',`${teamActivity.error?`<p class="notice" role="alert">${esc(teamActivity.error)}</p>`:''}<button class="btn ghost" onclick="teamReset();render()">Reload activity</button><label class="field">Search loaded events<input type="search" oninput="teamFilterActivity(this.value)"></label><div id="teamActivityRows">${teamActivity.items.map(e=>`<article class="panel" data-team-event><strong>${esc(e.event_type.replaceAll('_',' '))}</strong><p>${esc(e.actor_name)} · ${esc(new Date(e.created_at).toLocaleString())}</p><p>${esc(e.job_kind||'')} ${esc(e.job_id||'')}</p><details><summary>Details</summary><pre class="staff-prewrap">${esc(JSON.stringify(e.details,null,2))}</pre></details></article>`).join('')||'<p>No events loaded.</p>'}</div>${teamActivity.loading?'<p role="status">Loading…</p>':''}${teamActivity.more?'<button class="btn ghost" onclick="teamLoadActivity(true)">Load older activity</button>':''}`);
}
function teamFilterActivity(query){for(const row of document.querySelectorAll('[data-team-event]'))row.hidden=!row.textContent.toLowerCase().includes(query.toLowerCase());}
async function teamOrderNote(id){
 if(!(isOwner||isEmployee))return;
 const epoch=staffEpoch;try{const n=await staffRPC('apex_private_order_note',{p_order:id});if(epoch!==staffEpoch)return;openDlg(`<div class="dlg staff-dialog"><h3>Private order note</h3><p>Visible only to the owner and permitted staff assigned to this order.</p><form data-order="${esc(id)}" data-revision="${n.revision}" onsubmit="teamSaveNote(event)"><label class="field">Internal note<textarea name="body" maxlength="5000" ${staffCan('edit_notes')?'':'readonly'}>${esc(n.body)}</textarea></label>${staffCan('edit_notes')?'<button class="btn gold">Save note</button>':''}<button type="button" class="btn ghost" onclick="editDlg.close()">Close</button></form></div>`);}catch(e){staffError(e);}
}
async function teamSaveNote(event){event.preventDefault();const f=event.currentTarget,b=event.submitter;staffBusy(b,true);try{await staffRPC('apex_private_order_note',{p_order:f.dataset.order,p_body:f.elements.body.value,p_revision:Number(f.dataset.revision)});editDlg.close();toast('Private note saved.');}catch(e){staffError(e);}finally{staffBusy(b,false);}}
function teamSecurityPage(){if(!isOwner)return '<div class="wrap"><h2>Owner sign-in required</h2></div>';return `<div class="wrap" style="max-width:800px"><h2>Owner security</h2><section class="panel"><p>${staffSecurity.error?esc(staffSecurity.error):staffSecurity.verified?'Authenticator verified. Owner tools are unlocked.':staffSecurity.enrolled?'Enter your authenticator code to unlock owner tools.':'Set up an authenticator to unlock owner tools. Backend protection requires two-factor verification.'}</p><button class="btn gold" onclick="teamMFASetup()">${staffSecurity.enrolled?'Verify authenticator':'Set up authenticator'}</button>${staffSecurityControls()}</section>${staffSecurity.verified?'<p><a class="btn gold" href="#/team-overview">Open owner overview</a></p>':''}<section class="panel"><h3>Backups</h3><p>Supabase Free does not include scheduled backups. See the private backup and restore procedure in the repository. Backup coverage is unverified until an encrypted backup and restore drill succeed.</p><a href="https://supabase.com/dashboard/project/arvdrrrbobjpmmygojfm/database/backups" target="_blank" rel="noopener noreferrer">Review database backups</a></section></div>`;}

async function teamMFASetup(){
 try{const {data:f,error:fe}=await supabaseClient.auth.mfa.listFactors();if(fe)throw fe;if(f.totp.some(x=>x.status==='verified'))return teamMFAVerify();
 // Remove abandoned unverified enrollments before retrying setup.
 for(const x of f.totp.filter(x=>x.status==='unverified')){const {error}=await supabaseClient.auth.mfa.unenroll({factorId:x.id});if(error)throw error;}
 const {data,error}=await supabaseClient.auth.mfa.enroll({factorType:'totp',friendlyName:'Apex owner authenticator'});if(error)throw error;
 openDlg(`<div class="dlg"><h3>Scan with your authenticator</h3><img id="teamMFAQR" alt="Authenticator setup QR code" style="max-width:240px"><p>Or enter this setup key:</p><code>${esc(data.totp.secret)}</code>${teamMFAForm(data.id)}</div>`);
 document.getElementById('teamMFAQR').src=data.totp.qr_code.startsWith('data:image/')?data.totp.qr_code:'data:image/svg+xml;charset=utf-8,'+encodeURIComponent(data.totp.qr_code);
 }catch(e){staffError(e);}
}
function teamMFAForm(id){return `<form data-factor="${esc(id)}" onsubmit="teamMFAConfirm(event)"><label class="field">Authenticator code<input name="code" required inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autocomplete="one-time-code"></label><button class="btn gold">Verify code</button><button type="button" class="btn ghost" onclick="editDlg.close()">Cancel</button></form>`;}
async function teamMFAVerify(){try{const {data,error}=await supabaseClient.auth.mfa.listFactors();if(error)throw error;const factor=data.totp.find(f=>f.status==='verified');if(!factor)return toast('Set up an authenticator first.');openDlg(`<div class="dlg"><h3>Verify authenticator</h3>${teamMFAForm(factor.id)}</div>`);}catch(e){staffError(e);}}
async function teamMFAConfirm(event){event.preventDefault();const f=event.currentTarget,b=event.submitter;staffBusy(b,true);try{const {error}=await supabaseClient.auth.mfa.challengeAndVerify({factorId:f.dataset.factor,code:f.elements.code.value});if(error)throw error;editDlg?.close();staffSecurityReset();await staffSecurityLoad();await staffLoadContext(true);toast('Authenticator verified.');}catch(e){staffError(e);}finally{staffBusy(b,false);}}
function teamWorkflowPage(){
 const denied=staffGate();if(denied)return denied;
 if(isOwner&&!cloudOrdersLoaded&&!cloudOrdersLoading&&!cloudOrdersError){loadCloudOrders();}else if(!employeeJobsLoaded&&!employeeJobsLoading){loadEmployeeJobs();}
 const orders=isOwner?cloudOrders:(staffCan('orders')?employeeJobs.orders.filter(o=>o.assigned_to===employeeProfile?.user_id):[]);
 const stages=TRACKING_STAGES;
 return staffShell('Order workflow','Track fulfillment separately from payment. Customer progress messages are public to the private tracking link; staff notes stay private.',`<p><a class="btn ghost" href="#${isOwner?'/inbox':'/employee'}">Assignments & job details</a></p>${(isOwner?cloudOrdersLoading:employeeJobsLoading)?'<p role="status">Loading orders…</p>':''}${isOwner&&cloudOrdersError?`<p class="notice" role="alert">${esc(cloudOrdersError)}</p>`:''}${stages.map(([key,label])=>{const rows=orders.filter(o=>(o.fulfillment_stage||'received')===key);return `<section class="panel" style="margin-bottom:16px"><h3>${esc(label)} (${rows.length})</h3>${rows.map(o=>`<article style="border-top:1px solid var(--line);padding:12px 0"><strong>${esc(o.ref||o.id)}</strong>${o.is_test?' <span class="staff-pill">TEST</span>':''}<p>Payment / job status: ${esc(o.status)}${isOwner?' · '+esc(o.assigned_to?staffEmployeeName(o.assigned_to):'Unassigned'):''}</p><div class="row">${staffCan('update_status')?`<button class="btn sm gold" data-order="${esc(o.id)}" onclick="staffOpenOrderTracking(this.dataset.order)">Update progress</button>`:''}${staffCan('view_notes')?`<button class="btn sm ghost" data-order="${esc(o.id)}" onclick="teamOrderNote(this.dataset.order)">Private note</button>`:''}</div></article>`).join('')||'<p class="muted">No orders at this stage.</p>'}</section>`;}).join('')}`);
}
