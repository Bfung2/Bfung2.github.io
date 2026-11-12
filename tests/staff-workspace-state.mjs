import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
const code=await fs.readFile(new URL('../staff-workspace.js',import.meta.url),'utf8');
let pendingNoteResolve;
const context=vm.createContext({S:{products:[],parts:[]},isOwner:true,isEmployee:false,employeeProfile:null,employeeProfiles:[],employeeAudit:[],performanceData:[],employeesLoaded:false,employeeAuditLoaded:false,performanceLoaded:false,employeeJobs:{},employeeJobsLoaded:false,
  Date,URLSearchParams,Intl,console,window:{addEventListener(){}},document:{addEventListener(){},hidden:false},location:{hash:'#/staff-notes'},route:()=>'/staff-notes',render:()=>{},esc:s=>String(s??''),supabaseClient:{rpc:async name=>name==='apex_staff_get_notes'?new Promise(resolve=>{pendingNoteResolve=resolve;}):{data:{roles:[],employees:[],permissions:{}}}},
});
vm.runInContext(code,context);
const run=source=>vm.runInContext(source,context);
await run('staffLoadContext()');
const loading=run('staffLoadNotes()');
assert.equal(run('staffNotes.loading'),true);
await run('staffLoadContext(true)');
pendingNoteResolve({data:[{id:'previous-session-note',body:'Sensitive old content'}]});await loading;
assert.equal(run('staffNotes.items.length'),0,'A superseded notes response must not reappear after permissions refresh');
run("isOwner=false;isEmployee=false;staffReset()");assert.match(run("staffGate('view_schedule')"),/Staff sign-in required/);assert.equal(run("staffCan('view_schedule')"),false);
run("isEmployee=true;staffState.loaded=true;staffState.permissions={view_schedule:true,edit_schedule:false}");assert.equal(run("staffCan('view_schedule')"),true);assert.equal(run("staffCan('edit_schedule')"),false);assert.equal(run('staffNav()').includes('Roles &amp; permissions'),false);assert.equal(run('staffNav()').includes('Roles & permissions'),false);
run('staffReset()');assert.equal(run('staffNotes.items.length'),0);assert.equal(run('staffState.employees.length'),0);
console.log('PASS: permission refresh discards stale private responses; customer/staff gates and session data reset.');
