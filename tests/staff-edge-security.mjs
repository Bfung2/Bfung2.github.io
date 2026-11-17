import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {stripTypeScriptTypes} from 'node:module';

let handler,verified=false,profile,authPassword,matchingEmployees=[],nameFilter,staffVerified=true;
const audit=[];
const caller={
 auth:{getUser:async()=>({data:{user:{id:'owner',email:'apexcomputers039@gmail.com'}},error:null})},
 rpc:async()=>({data:verified,error:null}),
};
const employeeAuth={
 auth:{signInWithPassword:async ({email,password})=>{
  if(email!==profile.username+'@employees.apexcomputers.internal'||password!==authPassword)return {error:{status:400}};
  return {data:{user:{id:profile.user_id},session:{access_token:'access',refresh_token:'refresh'}}};
 }},
 rpc:async()=>({data:{verified:staffVerified,owner:false}}),
};
const admin={
 auth:{admin:{
  createUser:async ({password})=>{authPassword=password;return {data:{user:{id:'new-employee'}}};},
  updateUserById:async (id,{password})=>{assert.equal(id,profile.user_id);authPassword=password;return {};},
 }},
 from:table=>({
  select:()=>{
   const chain={
    ilike:(column,pattern)=>{assert.equal(column,'display_name');nameFilter=pattern;return chain;},
    eq:(column,value)=>{assert.equal(column,'active');assert.equal(value,true);return chain;},
    gte:(column,value)=>{assert.equal(column,'credential_version');assert.equal(value,1);return chain;},
    limit:async count=>{assert.equal(count,2);return {data:matchingEmployees};},
   };
   return chain;
  },
  insert:async row=>{if(table==='employee_profiles')profile=row;else audit.push(row);return {};},
  update:fields=>{
   let matches=true;
   const chain={
    eq:(key,value)=>{matches&&=profile[key]===value;return chain;},
    gt:(key,value)=>{matches&&=profile[key]>value;return chain;},
    or:()=>chain,
    select:()=>chain,
    maybeSingle:async()=>{if(!matches)return {data:null};Object.assign(profile,fields);return {data:{user_id:profile.user_id}};},
   };
   return chain;
  },
 }),
};
const context=vm.createContext({Request,Response,crypto,TextEncoder,console,createClient:(_url,key,options)=>key==='service'?admin:options.global?caller:employeeAuth,Deno:{env:{get:key=>({SUPABASE_URL:'https://example.invalid',SUPABASE_ANON_KEY:'anon',SUPABASE_SERVICE_ROLE_KEY:'service'})[key]},serve:fn=>handler=fn}});
vm.runInContext(stripTypeScriptTypes(fs.readFileSync('supabase/functions/manage-employee/index.ts','utf8').replace(/^import .*;$/m,'')),context);
const request=body=>handler(new Request('https://example.invalid/manage-employee',{method:'POST',headers:{Authorization:'Bearer test','Content-Type':'application/json'},body:JSON.stringify(body)}));
const create={action:'create',display_name:'Fixture',email:''};
assert.equal((await request(create)).status,403);
assert.equal(profile,undefined);

verified=true;
const response=await request(create);
assert.equal(response.status,200);
const {setup_code}=await response.json();
assert.match(setup_code,/^\d{6}\.[a-f0-9]{48}Aa!9$/);
assert.notEqual(authPassword,setup_code.split('.')[1]);
assert.equal(profile.credential_version,0);
assert.equal(profile.permissions.customer_details,false);
assert.notEqual(profile.setup_code_hash,setup_code);
assert.ok(!JSON.stringify(audit).includes(setup_code));

verified=false;
const activate={action:'activate',employee_id:profile.username,setup_code,password:'Employee chosen password!'};
assert.equal((await request({...activate,setup_code:setup_code.slice(0,7)+'0'.repeat(48)+'Aa!9'})).status,400);
assert.equal((await request({...activate,employee_id:'xxxxxx'})).status,400);
const expiry=profile.setup_code_expires_at;
profile.setup_code_expires_at='2000-01-01';
assert.equal((await request(activate)).status,400);
profile.setup_code_expires_at=expiry;
profile.active=false;
assert.equal((await request(activate)).status,400);
profile.active=true;
assert.equal((await request({...activate,password:'short'})).status,400);
const activated=await request(activate);
assert.equal(activated.status,200);
assert.equal((await activated.json()).passcode,profile.username);
assert.equal(profile.credential_version,1);
assert.equal(profile.setup_code_hash,null);
assert.equal(authPassword,activate.password);
assert.equal((await request({...activate,password:'A replay password'})).status,400);
assert.equal(authPassword,activate.password);
console.log('PASS: owner-gated issuance, hashed setup code, rejected invalid/expired/disabled activation and one-time employee password setup.');

const byName={action:'sign_in_by_name',name:' Alice_%* ',password:activate.password};
assert.equal((await request(byName)).status,401);
matchingEmployees=[{user_id:profile.user_id,username:profile.username}];
const named=await request(byName);
assert.equal(named.status,200);
assert.deepEqual(await named.json(),{access_token:'access',refresh_token:'refresh'});
assert.equal(nameFilter,String.raw`Alice\_\%\*`);
assert.equal((await request({...byName,password:'Different password'})).status,401);
staffVerified=false;
assert.equal((await request(byName)).status,401);
staffVerified=true;
matchingEmployees.push({user_id:'duplicate',username:'999999'});
assert.equal((await request(byName)).status,401);
console.log('PASS: name-based login validates the password and staff session, escapes wildcards, and rejects ambiguous names.');
