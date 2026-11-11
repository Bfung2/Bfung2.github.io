/* Private staff workspace. Data stays in Supabase, never in the public catalog or localStorage. */
const STAFF_PERMISSIONS = [
  ['own_sales_receipts','View own paid-sale customer details and receive receipts'],['manage_promos','Create, edit and remove promo codes'],['prepare_sales','Prepare customer sales links'],['orders','View orders'],['requests','View service requests'],['customer_details','View customer contact details'],
  ['claim_jobs','Claim unassigned jobs'],['update_status','Update assigned job status'],
  ['view_schedule','View staff schedule'],['edit_schedule','Add, edit and remove shifts'],
  ['view_reports','View individual employee reports'],['view_product_notes','View product notes'],['edit_product_notes','Edit product notes'],['view_notes','View permitted internal notes'],
  ['edit_notes','Edit notes shared with their roles'],['manage_notes','Create, delete and change access to permitted notes']
];
let staffState={loaded:false,loading:false,error:'',roles:[],employees:[],permissions:{}};
let staffEpoch=0,staffReadEpoch=0, staffSchedule={key:'',loading:false,error:'',items:[]},staffNotes={key:null,loading:false,error:'',items:[]};
let staffReport={key:'',loading:false,error:'',data:null},staffWeek=staffWeekStart(new Date()),staffScheduleEmployee='';
function staffWeekStart(date){const d=new Date(date);d.setHours(0,0,0,0);d.setDate(d.getDate()-((d.getDay()+6)%7));return d;}
function staffCan(key){return isOwner || !!(isEmployee&&staffState.permissions[key]);}
function staffReset(){if(typeof ownerTestCodeSettings!=="undefined")ownerTestCodeSettings={loaded:false,loading:false,data:null,error:""};if(typeof marketProgress!=="undefined")marketProgress=[];if(typeof promoAdmin!=="undefined")promoAdmin={loaded:false,loading:false,error:"",items:[]};if(typeof marketDrafts!=="undefined")marketDrafts={loaded:false,loading:false,error:"",items:[]};staffSales={loaded:false,loading:false,error:"",items:[]};if(typeof editDlg!=="undefined"&&editDlg){editDlg.close();editDlg.remove();editDlg=null;}staffWeek=staffWeekStart(new Date());staffScheduleEmployee="";staffEpoch++;staffReadEpoch++;staffState={loaded:false,loading:false,error:'',roles:[],employees:[],permissions:{}};staffSchedule={key:'',loading:false,error:'',items:[]};staffNotes={key:null,loading:false,error:'',items:[]};staffReport={key:'',loading:false,error:'',data:null};employeeProfiles=[];employeeAudit=[];performanceData=[];employeesLoaded=false;employeeAuditLoaded=false;performanceLoaded=false;}
async function staffRPC(name,args={}){const {data,error}=await supabaseClient.rpc(name,args);if(error)throw new Error(error.message||'Staff request failed.');return data;}
async function staffLoadContext(force=false){
  if(!(isOwner||isEmployee)||staffState.loading||(!force&&staffState.loaded))return;
  const epoch=staffEpoch;staffState.loading=true;staffState.error='';staffReadEpoch++;
  staffSchedule={key:'',loading:false,error:'',items:[]};staffNotes={key:null,loading:false,error:'',items:[]};staffReport={key:'',loading:false,error:'',data:null};
  try{const data=await staffRPC('apex_staff_context');if(epoch!==staffEpoch)return;
    staffState.roles=data.roles||[];staffState.employees=data.employees||[];staffState.permissions=data.permissions||{};
    if(isEmployee&&employeeProfile){const previousPermissions=JSON.stringify(employeeProfile.permissions||{});const p=staffState.employees.find(p=>p.user_id===employeeProfile.user_id);if(p)employeeProfile={...employeeProfile,...p,permissions:staffState.permissions};if(previousPermissions!==JSON.stringify(employeeProfile.permissions||{})){employeeJobs={orders:[],requests:[]};employeeJobsLoaded=false;}}
    staffState.loaded=true;
  }catch(e){if(epoch===staffEpoch){staffState.error=e.message;staffState.loaded=true;}}
  finally{if(epoch===staffEpoch){staffState.loading=false;render();}}
}
function staffNav(){if(!(isOwner||isEmployee))return '';return `<nav class="staff-nav" aria-label="Staff workspace">${[
  ['/promo-codes','Promo codes',staffCan('manage_promos')],['/market-sales','Prepare sale',staffCan('prepare_sales')],['/sales-credits','Sales contributions',true],['/employee','My work',isEmployee],['/employees','Employees',isOwner],['/roles','Roles & permissions',isOwner],
  ['/schedule','Schedule',staffCan('view_schedule')],['/employee-reports','Reports',staffCan('view_reports')],['/staff-notes','Internal notes',staffCan('view_notes')]
].filter(x=>x[2]).map(([url,label])=>`<a class="btn sm ${route()===url?'gold':'ghost'}" href="#${url}">${label}</a>`).join('')}</nav>`;}
function staffNotice(){return staffState.error?`<div class="notice" role="alert"><strong>Staff workspace setup is required.</strong><p>${esc(staffState.error)}</p><p>The owner needs to apply the staff workspace database migration in Supabase. Existing job tools remain available.</p><button class="btn sm ghost" onclick="staffLoadContext(true)">Retry connection</button></div>`:'';}
function staffShell(title,description,body){return `<div class="wrap staff-workspace"><div class="pagehead"><div><span class="shop-section-kicker">APEX · STAFF ONLY</span><h2>${esc(title)}</h2><p>${esc(description)}</p></div><button class="btn ghost" onclick="staffRefresh()">Refresh</button></div>${staffNav()}${staffNotice()}${staffState.loading?'<p role="status">Loading staff workspace…</p>':''}${body}</div>`;}
function staffGate(key){if(!(isOwner||isEmployee))return '<div class="wrap"><div class="empty"><h2>Staff sign-in required</h2><p>This area is available only to active Apex staff.</p><a class="btn gold" href="#/employee-login">Employee sign-in</a> <a class="btn ghost" href="#/staff">Owner sign-in</a></div></div>';if(!staffState.loaded&&!staffState.loading)staffLoadContext();if(!staffState.loaded||staffState.error)return staffShell('Staff workspace','Private team tools.','');if(key&&!staffCan(key))return staffShell('Access unavailable','Ask the owner if your role needs this permission.','');return null;}
async function staffRefresh(){if(typeof promoAdmin!=="undefined")promoAdmin.loaded=false;staffSales.loaded=false;staffSchedule.key='';staffNotes.key=null;staffReport.key='';await staffLoadContext(true);}
function staffEmployeeName(id){return staffState.employees.find(p=>p.user_id===id)?.display_name||'Former employee';}
function staffRoleNames(ids){return (ids||[]).map(id=>staffState.roles.find(r=>r.id===id)?.name||'Removed role').join(', ')||'No roles';}
function staffOwnerOnly(){return !isOwner?staffGate('owner_only')||staffShell('Owner access required','Only the owner can manage roles and employee access.',''):staffGate();}
function staffCheckbox(id,label,checked=false){return `<label class="staff-check"><input type="checkbox" id="${id}" ${checked?'checked':''}>${esc(label)}</label>`;}
function staffRoleChecks(prefix,selected=[]){return staffState.roles.map(r=>staffCheckbox(prefix+r.id,r.name,selected.includes(r.id))).join('')||'<p class="muted">Create a role first.</p>';}
function staffCheckedRoles(prefix){return staffState.roles.filter(r=>document.getElementById(prefix+r.id)?.checked).map(r=>r.id);}
function staffBusy(button,busy){if(button)button.disabled=busy;}
function staffError(err){toast(err.message||'Unable to save.');}

function staffEmployeesPage(){
  const denied=staffOwnerOnly();if(denied)return denied;
  const list=staffState.employees;
  return staffShell('Employees','Select an employee for their report, roles, permissions and internal notes.',`
    <form class="panel staff-create" onsubmit="createEmployee(event);return false"><h3>Create employee login</h3>
      <div class="staff-form-grid"><div class="field"><label for="newEmployeeName">Name</label><input id="newEmployeeName" required maxlength="100"></div><div class="field"><label for="newEmployeeEmail">Contact email</label><input id="newEmployeeEmail" type="email" maxlength="254"></div></div>
      <p class="muted">A six-digit sign-in code is generated automatically. Assign roles and overrides after creating the account.</p><button class="btn gold">Create employee</button></form>
    <section class="staff-cards" aria-label="Employee accounts">${list.map(p=>`<article class="panel staff-person"><div class="staff-person-head"><div><button class="staff-name" onclick="staffOpenReport('${p.user_id}')">${esc(p.display_name)}</button><p class="muted">${esc(p.email||'No contact email')}</p></div><span class="staff-pill">${p.active?'Active':'Disabled'}</span></div><p>${esc(staffRoleNames(p.role_ids))}${!p.access_configured?' · Legacy permissions':''}</p>
      <div class="row"><button class="btn sm ghost" onclick="staffEditContact('${p.user_id}')">Contact details</button><button class="btn sm gold" onclick="staffOpenReport('${p.user_id}')">View report</button><button class="btn sm ghost" onclick="editEmployee('${p.user_id}')">Roles / permissions</button><button class="btn sm ghost" onclick="staffOpenNotes('employee','${p.user_id}')">Notes</button></div>
      <details class="staff-account-tools"><summary>Account controls</summary><div class="row"><button class="btn sm ghost" onclick="staffResetCode('${p.user_id}')">Reset code</button><button class="btn sm ghost" onclick="staffToggleEmployee('${p.user_id}',${!p.active})">${p.active?'Disable':'Enable'}</button><button class="btn sm danger" onclick="staffDeleteEmployee('${p.user_id}')">Delete account</button></div></details></article>`).join('')||'<div class="empty">No employees yet.</div>'}</section>`);
}
async function staffResetCode(id){await resetEmployeePasscode(id,staffEmployeeName(id));}
async function staffToggleEmployee(id,active){await setEmployeeActive(id,active);await staffRefresh();}
async function staffDeleteEmployee(id){await deleteEmployee(id,staffEmployeeName(id));await staffRefresh();}
function staffEditEmployee(id){
  if(!isOwner)return;const p=staffState.employees.find(p=>p.user_id===id);if(!p)return;
  const overrides=p.access_configured?(p.permission_overrides||{}):(p.permissions||{});
  openDlg(`<div class="dlg staff-dialog"><h3>${esc(p.display_name)} · Roles & permissions</h3><div class="staff-form-grid"><div class="field"><label for="editEmployeeName">Name</label><input id="editEmployeeName" required maxlength="100" value="${esc(p.display_name)}"></div><div class="field"><label for="editEmployeeEmail">Contact email</label><input id="editEmployeeEmail" type="email" maxlength="254" value="${esc(p.email||'')}"></div></div>
    <h4>Assigned roles</h4><p class="muted">Role permissions combine. An individual Allow or Deny overrides every role.</p><div class="staff-checks">${staffRoleChecks('staff_emp_role_',p.role_ids)}</div>
    ${!p.access_configured?'<div class="notice">Existing access is preserved as individual overrides. Choose “Inherit” for permissions you want the roles to control.</div>':''}
    <div class="row"><button class="btn sm ghost" onclick="document.querySelectorAll('[data-staff-override]').forEach(s=>s.value='inherit')">Use role defaults for all</button></div>
    <h4>Individual overrides</h4><div class="staff-permission-list">${STAFF_PERMISSIONS.map(([key,label])=>`<label class="staff-permission">${label}<select data-staff-override id="staff_override_${key}" aria-label="${label}">${[['inherit','Inherit from roles'],['true','Allow'],['false','Deny']].map(([v,t])=>`<option value="${v}" ${String(overrides[key])===v||(!(key in overrides)&&v==='inherit')?'selected':''}>${t}</option>`).join('')}</select></label>`).join('')}</div>
    <p class="muted">Owner access stays separate. Staff cannot give themselves roles or change access permissions.</p><div class="row"><button class="btn gold" onclick="staffSaveEmployee('${id}',this)">Save employee</button><button class="btn ghost" onclick="editDlg.close()">Cancel</button></div></div>`);
}
async function staffSaveEmployee(id,button){
  const overrides={};for(const [key] of STAFF_PERMISSIONS){const v=document.getElementById('staff_override_'+key).value;if(v!=='inherit')overrides[key]=v==='true';}
  staffBusy(button,true);try{await staffRPC('apex_staff_admin',{p_action:'employee_access',p_data:{user_id:id,display_name:document.getElementById('editEmployeeName').value.trim(),email:document.getElementById('editEmployeeEmail').value.trim(),role_ids:staffCheckedRoles('staff_emp_role_'),overrides}});editDlg.close();await staffRefresh();toast('Employee roles and permissions saved.');}catch(e){staffError(e);}finally{staffBusy(button,false);}
}
function staffRolesPage(){
  const denied=staffOwnerOnly();if(denied)return denied;
  return staffShell('Roles & permissions','Create roles, set their permissions, and assign multiple roles to each employee.',`<div class="row" style="margin-bottom:20px"><button class="btn gold" onclick="staffEditRole()">＋ Create role</button></div><div class="staff-cards">${staffState.roles.map(r=>`<article class="panel"><h3>${esc(r.name)}</h3><p class="muted">${STAFF_PERMISSIONS.filter(([k])=>r.permissions[k]).length} permissions enabled</p><ul class="staff-role-summary">${STAFF_PERMISSIONS.filter(([k])=>r.permissions[k]).map(([,label])=>`<li>${label}</li>`).join('')||'<li>No permissions</li>'}</ul><div class="row"><button class="btn gold sm" onclick="staffEditRole('${r.id}')">Edit role</button><button class="btn danger sm" onclick="staffDeleteRole('${r.id}')">Remove role</button></div></article>`).join('')}</div>`);
}
function staffEditRole(id=''){
  if(!isOwner)return;const role=staffState.roles.find(r=>r.id===id)||{name:'',permissions:{}};
  openDlg(`<div class="dlg staff-dialog"><h3>${id?'Edit':'Create'} role</h3><div class="field"><label for="staffRoleName">Role name</label><input id="staffRoleName" maxlength="60" required value="${esc(role.name)}"></div><div class="staff-permission-list">${STAFF_PERMISSIONS.map(([key,label])=>staffCheckbox('staff_role_perm_'+key,label,role.permissions[key])).join('')}</div><p class="muted">Editing requires the matching viewing permission. Note access also depends on each note’s role lists.</p><div class="row"><button class="btn gold" onclick="staffSaveRole('${id}',this)">Save role</button><button class="btn ghost" onclick="editDlg.close()">Cancel</button></div></div>`);
}
async function staffSaveRole(id,button){
  const permissions=Object.fromEntries(STAFF_PERMISSIONS.map(([k])=>[k,!!document.getElementById('staff_role_perm_'+k).checked]));staffBusy(button,true);
  try{await staffRPC('apex_staff_admin',{p_action:'role_save',p_data:{id,name:document.getElementById('staffRoleName').value.trim(),permissions}});editDlg.close();await staffRefresh();toast('Role saved. Assigned employees inherit the changes.');}catch(e){staffError(e);}finally{staffBusy(button,false);}
}
async function staffDeleteRole(id){if(!isOwner||!confirm('Remove this role from every employee? Permissions from this role will be removed. Individual overrides remain.'))return;try{await staffRPC('apex_staff_admin',{p_action:'role_delete',p_data:{id}});await staffRefresh();toast('Role removed.');}catch(e){staffError(e);}}

function staffLocalInput(date){const d=new Date(date);return new Date(d.getTime()-d.getTimezoneOffset()*60000).toISOString().slice(0,16);}
function staffWeekMove(n){staffWeek.setDate(staffWeek.getDate()+7*n);staffSchedule.key='';render();}
async function staffLoadSchedule(){
  const start=new Date(staffWeek),end=new Date(staffWeek);end.setDate(end.getDate()+7);const key=start.toISOString(),epoch=staffEpoch,readEpoch=staffReadEpoch;
  if(staffSchedule.loading||staffSchedule.key===key)return;staffSchedule.loading=true;staffSchedule.error='';
  try{const rows=await staffRPC('apex_staff_schedule',{p_from:start.toISOString(),p_to:end.toISOString()});if((epoch!==staffEpoch||readEpoch!==staffReadEpoch))return;staffSchedule.items=rows||[];staffSchedule.key=key;}catch(e){if((epoch===staffEpoch&&readEpoch===staffReadEpoch)){staffSchedule.key=key;staffSchedule.error=e.message;staffSchedule.items=[];}}
  finally{if((epoch===staffEpoch&&readEpoch===staffReadEpoch)){staffSchedule.loading=false;if(route()==='/schedule')render();}}
}
function staffSchedulePage(){
  const denied=staffGate('view_schedule');if(denied)return denied;staffLoadSchedule();const end=new Date(staffWeek);end.setDate(end.getDate()+6);
  const days=Array.from({length:7},(_,i)=>{const d=new Date(staffWeek);d.setDate(d.getDate()+i);return d;});
  return staffShell('Staff schedule','Visible to active staff with schedule access. Customers cannot open this schedule.',`
    <div class="panel staff-schedule-toolbar"><div class="row"><button class="btn ghost sm" aria-label="Previous week" onclick="staffWeekMove(-1)">←</button><strong>${staffWeek.toLocaleDateString()} – ${end.toLocaleDateString()}</strong><button class="btn ghost sm" aria-label="Next week" onclick="staffWeekMove(1)">→</button><button class="btn ghost sm" onclick="staffWeek=staffWeekStart(new Date());staffSchedule.key='';render()">This week</button></div><div class="row"><label>Employee <select aria-label="Filter schedule by employee" onchange="staffScheduleEmployee=this.value;render()"><option value="">Everyone</option>${staffState.employees.filter(p=>p.active).map(p=>`<option value="${p.user_id}" ${staffScheduleEmployee===p.user_id?'selected':''}>${esc(p.display_name)}</option>`).join('')}</select></label>${staffCan('edit_schedule')?'<button class="btn gold" onclick="staffEditShift()">＋ Add shift</button>':''}</div></div>
    <p class="muted">Times shown in ${esc(Intl.DateTimeFormat().resolvedOptions().timeZone)}. Overnight shifts appear on every day they span.</p>
    ${staffSchedule.error?`<div class="notice" role="alert">${esc(staffSchedule.error)}</div>`:''}${staffSchedule.loading?'<p role="status">Loading shifts…</p>':''}
    <div class="staff-week">${days.map(day=>{const next=new Date(day);next.setDate(next.getDate()+1);const shifts=staffSchedule.items.filter(s=>(!staffScheduleEmployee||s.employee_id===staffScheduleEmployee)&&new Date(s.starts_at)<next&&new Date(s.ends_at)>day);return `<section class="staff-day"><h3>${day.toLocaleDateString(undefined,{weekday:'short',month:'short',day:'numeric'})}</h3>${shifts.map(s=>`<article class="staff-shift"><strong>${esc(staffEmployeeName(s.employee_id))}</strong><p>${esc(s.title)}</p><small>${new Date(s.starts_at).toLocaleString(undefined,{weekday:'short',hour:'numeric',minute:'2-digit'})} – ${new Date(s.ends_at).toLocaleString(undefined,{weekday:'short',hour:'numeric',minute:'2-digit'})}</small>${s.location?`<p>${esc(s.location)}</p>`:''}${s.details?`<p class="staff-prewrap">${esc(s.details)}</p>`:''}${staffCan('edit_schedule')?`<button class="btn sm ghost" onclick="staffEditShift('${s.id}')">Edit shift</button>`:''}</article>`).join('')||'<p class="muted">No shifts</p>'}</section>`;}).join('')}</div>`);
}
function staffEditShift(id=''){
  if(!staffCan('edit_schedule'))return;const s=staffSchedule.items.find(s=>s.id===id)||{};const start=new Date();start.setMinutes(0,0,0);const end=new Date(start.getTime()+4*3600000);
  openDlg(`<div class="dlg staff-dialog"><h3>${id?'Edit':'Add'} shift</h3><form onsubmit="staffSaveShift(event,'${id}',${s.revision||0});return false"><div class="field"><label for="staffShiftEmployee">Employee</label><select id="staffShiftEmployee" required><option value="">Choose employee</option>${staffState.employees.filter(p=>p.active).map(p=>`<option value="${p.user_id}" ${s.employee_id===p.user_id?'selected':''}>${esc(p.display_name)}</option>`).join('')}</select></div><div class="field"><label for="staffShiftTitle">Shift / work</label><input id="staffShiftTitle" required maxlength="120" value="${esc(s.title||'')}" placeholder="PC repairs"></div><div class="staff-form-grid"><div class="field"><label for="staffShiftStart">Starts</label><input id="staffShiftStart" type="datetime-local" required value="${staffLocalInput(s.starts_at||start)}"></div><div class="field"><label for="staffShiftEnd">Ends</label><input id="staffShiftEnd" type="datetime-local" required value="${staffLocalInput(s.ends_at||end)}"></div></div><div class="field"><label for="staffShiftLocation">Location</label><input id="staffShiftLocation" maxlength="300" value="${esc(s.location||'')}"></div><div class="field"><label for="staffShiftDetails">Staff details</label><textarea id="staffShiftDetails" maxlength="2000">${esc(s.details||'')}</textarea></div><p class="muted">${esc(Intl.DateTimeFormat().resolvedOptions().timeZone)} · Overlapping shifts for the same employee are blocked.</p><div class="row"><button class="btn gold" type="submit">Save shift</button>${id?`<button class="btn danger" type="button" onclick="staffDeleteShift('${id}',${s.revision},this)">Delete shift</button>`:''}<button class="btn ghost" type="button" onclick="editDlg.close()">Cancel</button></div></form></div>`);
}
async function staffSaveShift(e,id,revision){e.preventDefault();const button=e.submitter;staffBusy(button,true);try{const starts_at=new Date(document.getElementById('staffShiftStart').value).toISOString(),ends_at=new Date(document.getElementById('staffShiftEnd').value).toISOString();if(ends_at<=starts_at)throw new Error('End must be after start.');await staffRPC('apex_staff_save_shift',{p_data:{id,revision,employee_id:document.getElementById('staffShiftEmployee').value,title:document.getElementById('staffShiftTitle').value.trim(),starts_at,ends_at,location:document.getElementById('staffShiftLocation').value,details:document.getElementById('staffShiftDetails').value}});editDlg.close();staffSchedule.key='';render();toast('Shift saved.');}catch(e){staffError(e);}finally{staffBusy(button,false);}}
async function staffDeleteShift(id,revision,button){if(!confirm('Delete this shift?'))return;staffBusy(button,true);try{await staffRPC('apex_staff_save_shift',{p_data:{id,revision},p_delete:true});editDlg.close();staffSchedule.key='';render();toast('Shift deleted.');}catch(e){staffError(e);}finally{staffBusy(button,false);}}

function staffQuery(){return new URLSearchParams((location.hash.split('?')[1]||''));}
function staffOpenReport(id){go('/employee-report?employee='+encodeURIComponent(id));}
function staffProductNoteAccess(edit=false){return isOwner || (staffCan('view_notes') && staffCan(edit?'edit_product_notes':'view_product_notes'));}
function staffOpenProductNotes(id){if(!staffProductNoteAccess())return toast('Product notes access is not enabled.');staffOpenNotes('product',id);}
function staffOpenNotes(type='',id=''){if(editDlg?.open)editDlg.close();go('/staff-notes'+(type?'?type='+encodeURIComponent(type)+'&entity='+encodeURIComponent(id):''));}
async function staffLoadReport(id,more=false){
  if(staffReport.loading||(!more&&staffReport.key===id))return;const epoch=staffEpoch,readEpoch=staffReadEpoch;staffReport.loading=true;staffReport.error='';
  try{const events=staffReport.data?.events||[];const data=await staffRPC('apex_employee_report',{p_user_id:id,p_before:more&&events.length?events.at(-1).created_at:null,p_before_id:more&&events.length?events.at(-1).id:null,p_limit:50});if((epoch!==staffEpoch||readEpoch!==staffReadEpoch))return;
    if(more)data.events=[...events,...(data.events||[])];staffReport={key:id,loading:true,error:'',data};
  }catch(e){if((epoch===staffEpoch&&readEpoch===staffReadEpoch)){staffReport.error=e.message;staffReport.key=id;}}
  finally{if((epoch===staffEpoch&&readEpoch===staffReadEpoch)){staffReport.loading=false;if(route()==='/employee-report')render();}}
}
function staffReportsPage(){
  const denied=staffGate('view_reports');if(denied)return denied;
  return staffShell('Employee reports','Select an employee to review their recorded work.',`<div class="staff-cards">${staffState.employees.map(p=>`<article class="panel"><h3>${esc(p.display_name)}</h3><p class="muted">${p.active?'Active':'Disabled'}</p><button class="btn gold" onclick="staffOpenReport('${p.user_id}')">View report</button></article>`).join('')}</div>`);
}
function staffReportPage(){
  const denied=staffGate('view_reports');if(denied)return denied;const id=staffQuery().get('employee');if(!staffState.employees.some(p=>p.user_id===id))return staffShell('Employee report','Choose an employee from Manage employees.','');
  staffLoadReport(id);if(isOwner)staffLoadSales();const d=staffReport.key===id?staffReport.data:null;const p=staffState.employees.find(p=>p.user_id===id);
  const metric=(label,value)=>`<div class="panel"><small class="muted">${label}</small><strong class="staff-metric">${esc(value)}</strong></div>`;
  return staffShell(p.display_name+' · Report','Recorded work, account changes, scheduling and notes activity.',`
    <div class="row" style="margin-bottom:20px">${isOwner?`<button class="btn gold" onclick="editEmployee('${id}')">Edit roles / permissions</button>`:''}${staffCan('view_notes')?`<button class="btn ghost" onclick="staffOpenNotes('employee','${id}')">Employee notes</button>`:''}</div>
    ${isOwner?`<p><strong>Roles:</strong> ${esc(staffRoleNames(p.role_ids))}</p>`:''}
    ${staffReport.error?`<div class="notice" role="alert">${esc(staffReport.error)}</div>`:''}${staffReport.loading?'<p role="status">Loading report…</p>':''}
    ${d?`<div class="staff-metrics">${metric('Currently assigned jobs',d.assigned_jobs)}${metric('Jobs completed by employee',d.completed_by_employee)}${metric('Actions in last 30 days',d.activity_30d)}${metric('Last activity',d.last_activity?new Date(d.last_activity).toLocaleString():'No activity yet')}</div>
    ${isOwner?'<h3>Sales contributed ('+staffSales.items.filter(c=>c.employee_id===id).length+')</h3>'+staffSalesList(staffSales.items.filter(c=>c.employee_id===id)):''}<h3>Activity history</h3><p class="muted">“By employee” shows their actions. “About employee” shows changes someone else made. Older work may predate activity tracking.</p>
    <div class="staff-timeline">${(d.events||[]).map(e=>`<article class="panel"><div class="row"><span class="staff-pill">${e.actor_user_id===id?'By employee':'About employee'}</span><small class="muted">${new Date(e.created_at).toLocaleString()}</small></div><h4>${esc(e.event_type.replaceAll('_',' '))}</h4><p>${esc(e.actor_name)}${e.job_kind?' · '+esc(e.job_kind)+' '+esc(e.job_id||''):''}</p><details><summary>Event details</summary><pre>${esc(JSON.stringify(e.details||{},null,2))}</pre></details></article>`).join('')||'<div class="empty">No recorded activity for this employee.</div>'}</div>
    ${(d.events||[]).length&&d.events.length%50===0?`<button class="btn ghost" ${staffReport.loading?'disabled':''} onclick="staffLoadReport('${id}',true)">Load older activity</button>`:''}`:''}`);
}
function staffNoteFilter(){const q=staffQuery();return {type:q.get('type')||null,entity:q.get('entity')||null};}
async function staffLoadNotes(){
  const filter=staffNoteFilter(),key=JSON.stringify(filter),epoch=staffEpoch,readEpoch=staffReadEpoch;if(staffNotes.loading||staffNotes.key===key)return;staffNotes.loading=true;staffNotes.error='';
  try{const items=await staffRPC('apex_staff_get_notes',{p_type:filter.type,p_entity:filter.entity});if((epoch!==staffEpoch||readEpoch!==staffReadEpoch))return;staffNotes.items=items||[];staffNotes.key=key;}
  catch(e){if((epoch===staffEpoch&&readEpoch===staffReadEpoch)){staffNotes.error=e.message;staffNotes.items=[];staffNotes.key=key;}}
  finally{if((epoch===staffEpoch&&readEpoch===staffReadEpoch)){staffNotes.loading=false;if(route()==='/staff-notes')render();}}
}
function staffProductSourceLink(id){const p=catalogAll().find(p=>p.id===id);const url=p?.sourceUrl||'';return url.startsWith('https://')?'<a href="'+esc(url)+'" target="_blank" rel="noopener noreferrer">'+esc(url)+'</a>':'No product source link available';}
function staffEntityLabel(type,id){if(type==='employee')return staffEmployeeName(id);if(type==='product')return catalogAll().find(p=>p.id===id)?.name||id||'Product';return id||'General';}
function staffNotesPage(){
  const denied=staffGate('view_notes');if(denied)return denied;const f=staffNoteFilter();if(f.type==='product'&&!staffProductNoteAccess())return staffShell('Product notes','Product note viewing is disabled.','');staffLoadNotes();
  return staffShell('Internal notes','Private notes with separate viewing and editing access for each role.',`
    <div class="row" style="margin-bottom:20px"><label>Show <select aria-label="Filter internal notes" onchange="staffOpenNotes(this.value)">${[['','All permitted notes'],['general','General'],['product','Products & parts'],['employee','Employees'],['other','Other']].map(([v,t])=>`<option value="${v}" ${f.type===v||(!f.type&&!v)?'selected':''}>${t}</option>`).join('')}</select></label>${f.entity?`<span class="staff-pill">${esc(staffEntityLabel(f.type,f.entity))}</span><button class="btn ghost sm" onclick="staffOpenNotes()">Clear filter</button>`:''}${staffCan('manage_notes')?'<button class="btn gold" onclick="staffEditNote()">＋ New note</button>':''}</div>
    ${staffNotes.error?`<div class="notice" role="alert">${esc(staffNotes.error)}</div>`:''}${staffNotes.loading?'<p role="status">Loading notes…</p>':''}
    <section class="staff-cards">${staffNotes.items.filter(n=>n.entity_type!=='product'||staffProductNoteAccess()).map(n=>`<article class="panel staff-note"><small class="muted">${esc(n.entity_type)} · ${esc(staffEntityLabel(n.entity_type,n.entity_id))}</small><h3>${esc(n.title)}</h3><p class="staff-prewrap">${esc(n.body)}</p>${n.entity_type==="product"?`<p><strong>Product link:</strong> ${staffProductSourceLink(n.entity_id)}</p>`:""}<small class="muted">Updated ${new Date(n.updated_at).toLocaleString()}</small><p><strong>View:</strong> ${n.all_staff?'All staff with notes access':esc(staffRoleNames([...new Set([...n.view_role_ids,...n.edit_role_ids])]))}<br><strong>Edit:</strong> ${esc(staffRoleNames(n.edit_role_ids))}</p>${n.can_edit&&(n.entity_type!=='product'||staffProductNoteAccess(true))?`<button class="btn sm ghost" onclick="staffEditNote('${n.id}')">${staffCan('manage_notes')?'Edit / access':'Edit note'}</button>`:''}</article>`).join('')||'<div class="empty">No notes shared with your roles in this view.</div>'}</section>`);
}
function staffEditNote(id=''){
  const n=staffNotes.items.find(n=>n.id===id)||{},f=staffNoteFilter();if(id&&!n.can_edit||!id&&!staffCan('manage_notes'))return;if((n.entity_type||f.type)==='product'&&!staffProductNoteAccess(!!id))return;
  const manage=staffCan('manage_notes'),type=n.entity_type||f.type||'general';
  openDlg(`<div class="dlg staff-dialog"><h3>${id?'Edit':'New'} internal note</h3><form onsubmit="staffSaveNote(event,'${id}',${n.revision||0});return false"><div class="field"><label for="staffNoteTitle">Title</label><input id="staffNoteTitle" maxlength="160" required value="${esc(n.title||'')}"></div><div class="field"><label for="staffNoteBody">Note</label><textarea id="staffNoteBody" maxlength="10000" rows="7" required>${esc(n.body||'')}</textarea></div>
    ${manage?`<div class="field"><label for="staffNoteType">Attach to</label><select id="staffNoteType" onchange="staffNoteTargetOptions(this.value,'')">${['general','product','employee','other'].map(t=>`<option value="${t}" ${t===type?'selected':''}>${t==='product'?'Product / part':t[0].toUpperCase()+t.slice(1)}</option>`).join('')}</select></div><div class="field" id="staffNoteTargetField"></div><h4>Who can view?</h4>${staffCheckbox('staffNoteAll','All staff with notes viewing permission',n.all_staff)}<div class="staff-checks">${staffRoleChecks('staff_note_view_',n.view_role_ids||[])}</div><h4>Who can edit?</h4><div class="staff-checks">${staffRoleChecks('staff_note_edit_',n.edit_role_ids||[])}</div><p class="muted">Editing roles also get viewing access. Employees still need their global notes permissions. With no audience selected, only the owner can view or edit this note. The owner always retains access.</p>`:'<p class="muted">You can edit the content. Access settings are controlled by the owner or an authorized note manager.</p>'}
    <div class="row"><button class="btn gold" type="submit">Save note</button>${id&&manage?`<button class="btn danger" type="button" onclick="staffDeleteNote('${id}',${n.revision},this)">Delete note</button>`:''}<button class="btn ghost" type="button" onclick="editDlg.close()">Cancel</button></div></form></div>`);
  if(manage)staffNoteTargetOptions(type,n.entity_id||f.entity||'');
}
function staffNoteTargetOptions(type,id){
  const el=document.getElementById('staffNoteTargetField');if(!el)return;
  if(['product','employee'].includes(type)){const list=type==='employee'?staffState.employees.map(p=>({id:p.user_id,name:p.display_name})):catalogAll();el.innerHTML=`<label for="staffNoteEntity">${type==='employee'?'Employee':'Product / part'}</label><select id="staffNoteEntity" required><option value="">Choose…</option>${list.map(p=>`<option value="${esc(p.id)}" ${p.id===id?'selected':''}>${esc(p.name)}</option>`).join('')}${id&&!list.some(p=>p.id===id)?`<option selected value="${esc(id)}">${esc(id)} (no longer listed)</option>`:''}</select>`;}
  else el.innerHTML=`<label for="staffNoteEntity">${type==='other'?'Reference (optional)':'Reference'}</label><input id="staffNoteEntity" maxlength="200" value="${esc(id)}" ${type==='general'?'readonly':''}>`;
}
async function staffSaveNote(e,id,revision){e.preventDefault();const button=e.submitter;staffBusy(button,true);const p_data={id,revision,title:document.getElementById('staffNoteTitle').value.trim(),body:document.getElementById('staffNoteBody').value};if(staffCan('manage_notes'))Object.assign(p_data,{entity_type:document.getElementById('staffNoteType').value,entity_id:document.getElementById('staffNoteEntity').value,all_staff:document.getElementById('staffNoteAll').checked,view_role_ids:staffCheckedRoles('staff_note_view_'),edit_role_ids:staffCheckedRoles('staff_note_edit_')});
  try{await staffRPC('apex_staff_save_note',{p_data});editDlg.close();staffNotes.key=null;render();toast('Internal note saved.');}catch(e){staffError(e);}finally{staffBusy(button,false);}}
async function staffDeleteNote(id,revision,button){if(!confirm('Delete this internal note?'))return;staffBusy(button,true);try{await staffRPC('apex_staff_save_note',{p_data:{id,revision},p_delete:true});editDlg.close();staffNotes.key=null;render();toast('Internal note deleted.');}catch(e){staffError(e);}finally{staffBusy(button,false);}}
// Refresh live permissions on staff navigation so role edits take effect in existing sessions.
window.addEventListener('hashchange',()=>{if((isEmployee||isOwner)&&['/employee','/employees','/roles','/schedule','/staff-notes','/employee-report','/employee-reports'].includes(route()))staffLoadContext(true);});

document.addEventListener('visibilitychange',()=>{if(!document.hidden&&(isOwner||isEmployee))staffLoadContext(true);});

/* Sales origin is separate from the employee assigned to fulfill a job. Owner-approved credit only. */
let staffSales={loaded:false,loading:false,error:'',items:[]};
async function staffLoadSales(){
 if(staffSales.loaded||staffSales.loading||!(isOwner||isEmployee))return;
 const epoch=staffEpoch;staffSales.loading=true;
 try{const items=await staffRPC('apex_sales_credits');if(epoch!==staffEpoch)return;staffSales.items=items||[];staffSales.error='';}
 catch(e){if(epoch===staffEpoch)staffSales.error=e.message;}
 finally{if(epoch===staffEpoch){staffSales.loaded=true;staffSales.loading=false;render();}}
}
function staffSalesList(items){return items.length?`<div class="staff-timeline">${items.map(c=>`<article class="panel"><strong>${esc(c.customer_name||'Customer')}</strong><p>${esc(c.reference)} · ${c.job_kind==='request'?'Tech request lead':'Order contribution'}</p>${isOwner?`<p>Credited to ${esc(c.employee_name)}</p>`:''}<small class="muted">${new Date(c.credited_at).toLocaleString()} · ${esc(c.job_id)}</small></article>`).join('')}</div>`:'<div class="empty">No sales contributions credited yet.</div>';}
function staffSalesPage(){const denied=staffGate();if(denied)return denied;staffLoadSales();return staffShell(isOwner?'Sales contributions':'My sales contributions','Owner-recorded sales and tech leads you helped bring in. Credit does not mean the customer has paid.',`${staffSales.loading?'<p>Loading sales credits…</p>':''}${staffSales.error?`<div class="notice">${esc(staffSales.error)} Apply the sales attribution migration to enable this feature.</div>`:''}${staffSalesList(staffSales.items)}`);}
function staffCreditSale(kind,id){
 if(!isOwner)return;
 const credit=staffSales.items.find(c=>c.job_kind===kind&&c.job_id===id);
 openDlg(`<div class="dlg"><h3>Who brought in this sale?</h3><p>This credit is separate from the employee assigned to do the work. Tech requests count as leads, not confirmed payments.</p><label class="field">Contributing employee<select id="staffSaleEmployee"><option value="">No employee credit</option>${staffState.employees.filter(p=>p.active).map(p=>`<option value="${p.user_id}" ${credit?.employee_id===p.user_id?'selected':''}>${esc(p.display_name)}</option>`).join('')}</select></label><div class="row"><button class="btn gold" data-kind="${esc(kind)}" data-job="${esc(id)}" onclick="staffSaveSaleCredit(this)">Save sales credit</button><button class="btn ghost" onclick="editDlg.close()">Cancel</button></div></div>`);
}
async function staffSaveSaleCredit(button){staffBusy(button,true);try{await staffRPC('apex_credit_sale',{p_kind:button.dataset.kind,p_job:button.dataset.job,p_employee:document.getElementById('staffSaleEmployee').value||null});editDlg.close();staffSales.loaded=false;await staffLoadSales();toast('Sales contribution recorded.');}catch(e){staffError(e);}finally{staffBusy(button,false);}}
function staffSaleButton(kind,id){const c=staffSales.items.find(c=>c.job_kind===kind&&c.job_id===id);return `<button class="btn sm ghost" data-kind="${esc(kind)}" data-job="${esc(id)}" onclick="staffCreditSale(this.dataset.kind,this.dataset.job)">${c?'Sale: '+esc(c.employee_name):'Credit sale / lead'}</button>`;}
