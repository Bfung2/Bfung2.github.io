/* Apex Computers Phase 11: owner-only, read-only operations overview.
   The server authenticates and authorizes each metrics RPC independently. */
const apexOpsState={data:null,loading:false,error:"",lastAttempt:0};
const OPS_REFRESH_MS=5*60*1000;

function opsCount(value){
 const num=Number(value);
 return Number.isFinite(num)&&num>=0?Math.floor(num):0;
}
function opsAlerts(data){
 if(!data||typeof data!=="object")return [];
 const n=data.notifications||{},o=data.orders||{},r=data.requests||{};
 const alerts=[],add=(tone,title,description,href)=>{
  alerts.push({tone,title,description,href});
 };
 if(opsCount(n.failed_or_retry)>0)add("critical","Notification retries need attention",
  opsCount(n.failed_or_retry)+" queued email record(s) have a recorded failure. Review the notification service before retrying.","#/inbox");
 if(opsCount(n.expired_leases)>0)add("critical","Expired email delivery leases",
  opsCount(n.expired_leases)+" notification lease(s) have expired. Verify the delivery state before retrying.","#/inbox");
 if(opsCount(n.orphaned)>0)add("warning","Unmatched notification records",
  opsCount(n.orphaned)+" pending email record(s) do not match a current order. They may be historical. Do not automatically resend or delete them.","#/inbox");
 if(opsCount(n.pending_over_30m)>0)add("warning","Pending paid-order messages",
  opsCount(n.pending_over_30m)+" queued notification(s) correspond to orders over 30 minutes old. Investigate delivery before retrying.","#/inbox");
 if(opsCount(o.older_than_48h)>0)add("warning","Orders awaiting attention",
  opsCount(o.older_than_48h)+" non-test order(s) remain open after 48 hours.","#/inbox");
 if(opsCount(r.older_than_48h)>0)add("warning","Service requests awaiting attention",
  opsCount(r.older_than_48h)+" service request(s) remain open after 48 hours.","#/inbox");
 if(opsCount(o.unassigned)+opsCount(r.unassigned)>0)add("info","Unassigned work",
  opsCount(o.unassigned)+" order(s) and "+opsCount(r.unassigned)+" service request(s) are unassigned.","#/inbox");
 return alerts;
}
function opsUpdateBadge(){
 const badge=document.getElementById("opsAlertBadge");
 if(!badge)return;
 const count=opsAlerts(apexOpsState.data).length;
 badge.hidden=!isOwner||count===0;
 badge.textContent=count+" alert"+(count===1?"":"s");
 badge.setAttribute("aria-label",count+" operations alert"+(count===1?"":"s"));
}
function opsRefreshIfStale(){
 if(!isOwner||apexOpsState.loading)return;
 if(Date.now()-apexOpsState.lastAttempt<OPS_REFRESH_MS)return;
 void opsRefresh();
}
async function opsRefresh(){
 if(!isOwner||apexOpsState.loading)return;
 apexOpsState.loading=true;apexOpsState.error="";
 try{
  const {data,error}=await supabaseClient.rpc("apex_owner_ops_health");
  if(error)throw error;
  if(!isOwner)return;
  if(!data||typeof data!=="object"||!data.notifications||!data.orders||!data.requests||!data.sales)throw new Error("Malformed operations response");
  apexOpsState.data=data;
 }catch(err){
  if(isOwner)apexOpsState.error="Could not refresh operations data. Check your owner session or Supabase connection, then retry.";
 }finally{
  apexOpsState.loading=false;
  apexOpsState.lastAttempt=Date.now();
  if(isOwner){
   opsUpdateBadge();
   if(route()==="/operations")render();
  }else{
   apexOpsState.data=null;
  }
 }
}
function opsKpi(label,value,description,href){
 const amount=opsCount(value);
 const title=String(label);
 return '<a class="ops-kpi" href="'+href+'"><span class="ops-kpi-label">'+title+
  '</span><strong>'+amount.toLocaleString()+'</strong><small>'+description+'</small></a>';
}
function opsPage(){
 if(!isOwner)return '<div class="wrap"><h2>Owner access required</h2><p>This operations dashboard is restricted to the Apex Computers owner.</p></div>';
 const data=apexOpsState.data,n=data?.notifications||{},o=data?.orders||{},r=data?.requests||{},s=data?.sales||{};
 const alerts=opsAlerts(data);
 const updated=data?.generated_at?new Date(data.generated_at):null;
 const timestamp=updated&&Number.isFinite(updated.valueOf())?updated.toLocaleString():"Not loaded yet";
 return '<div class="wrap ops-page"><div class="pagehead ops-heading"><div><span class="ops-eyebrow">APEX / OWNER OPERATIONS</span><h2>Operations center</h2><p>Read-only business health, email queues, and work that needs attention. No customer personal information is displayed.</p></div><button type="button" class="btn gold" onclick="opsRefresh()" '+(apexOpsState.loading?'disabled':'')+'>'+(apexOpsState.loading?'Refreshing…':'Refresh metrics')+'</button></div>'+
  '<p class="muted ops-timestamp" role="status">Last database snapshot: '+timestamp+'. Counts reflect the current database, not a forecast.</p>'+
  (apexOpsState.error?'<p class="notice" role="alert">'+apexOpsState.error+'</p>':'')+
  '<section class="ops-section"><div class="ops-section-head"><h3>Alerts requiring review</h3><span>'+alerts.length+' active</span></div>'+
  (!data?'<div class="panel">Loading the owner operations overview…</div>':alerts.length?'<div class="ops-alerts">'+alerts.map(a=>
   '<article class="ops-alert ops-alert-'+a.tone+'"><div><strong>'+a.title+'</strong><p>'+a.description+'</p></div><a class="btn ghost" href="'+a.href+'">Review</a></article>'
  ).join('')+'</div>':'<div class="panel"><strong>No operational alert thresholds triggered.</strong><p class="muted">Continue reviewing the daily catalog audit and GitHub monitor for issues that the database cannot detect.</p></div>')+'</section>'+
  '<section class="ops-section"><div class="ops-section-head"><h3>Customer orders and service requests</h3></div><div class="ops-kpi-grid">'+
  opsKpi("Open real orders",o.open,"Not marked completed or delivered","#/inbox")+
  opsKpi("Orders over 48 hours",o.older_than_48h,"Non-test, still open","#/inbox")+
  opsKpi("Open service requests",r.open,"Not marked completed or delivered","#/inbox")+
  opsKpi("Unassigned work",opsCount(o.unassigned)+opsCount(r.unassigned),"Orders and requests needing owners","#/inbox")+
  '</div></section>'+
  '<section class="ops-section"><div class="ops-section-head"><h3>Paid-order email delivery</h3></div><div class="ops-kpi-grid">'+
  opsKpi("Sent notifications",n.sent,"Recorded delivery successes","#/inbox")+
  opsKpi("Pending notifications",n.pending,"Includes unmatched historical records","#/inbox")+
  opsKpi("Pending unmatched",n.orphaned,"No corresponding current Apex order","#/inbox")+
  opsKpi("Failures and expired leases",opsCount(n.failed_or_retry)+opsCount(n.expired_leases),"Review before retrying","#/inbox")+
  '</div><p class="muted ops-explain">Pending means queued, not necessarily a Gmail failure. This page does not send or replay emails automatically. The existing protected notification sender remains responsible for delivery.</p></section>'+
  '<section class="ops-section"><div class="ops-section-head"><h3>Employee sale settlements</h3></div><div class="ops-kpi-grid">'+
  opsKpi("Unsettled sales credits",s.unsettled,"Review commission amounts","#/sales-credits")+
  opsKpi("Paid records",s.paid_records,"Payment marked by the owner","#/sales-credits")+
  opsKpi("Void records",s.void_records,"Contributions voided with history","#/sales-credits")+
  opsKpi("Owner test orders",o.test,"Test records are not paid revenue","#/inbox")+
  '</div></section>'+
  '<section class="ops-section ops-reference panel"><h3>Monitoring and recovery</h3>'+
  '<p>The GitHub storefront monitor checks the public website and critical assets on a schedule. Failures create or reopen one GitHub issue; a recovery closes it. This is separate from the existing Newegg price audit.</p>'+
  '<p><a href="https://github.com/Bfung2/Bfung2.github.io/actions/workflows/operations-monitor.yml" target="_blank" rel="noopener noreferrer">GitHub storefront monitor</a> · <a href="https://github.com/Bfung2/Bfung2.github.io/issues" target="_blank" rel="noopener noreferrer">Incident issues</a> · <a href="https://github.com/Bfung2/Bfung2.github.io/actions/workflows/catalog-audit.yml" target="_blank" rel="noopener noreferrer">Catalog integrity reports</a></p>'+
  '<p><strong>Backups:</strong> GitHub history preserves public catalog versions. It does not back up Supabase customer, employee, or order records. Keep a separate private Supabase backup and restore procedure for that data.</p>'+
  '<p><a href="https://supabase.com/dashboard/project/arvdrrrbobjpmmygojfm/database/backups" target="_blank" rel="noopener noreferrer">Review Supabase backup options</a></p>'+
  '</section></div>';
}
