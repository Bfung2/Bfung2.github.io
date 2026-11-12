/* Apex policy pages. Requires database migration sql/apex-shop-policies.sql.
   Never store unpublished drafts in data.json or the customer's browser. */
(function(){
"use strict";
const titles={warranty:"Warranty policy",returns:"Returns & refunds policy"};
const state={public:{},owner:{},loading:{},busy:false,kind:"warranty"};
const safe=v=>String(v==null?"":v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const valid=k=>Object.prototype.hasOwnProperty.call(titles,k)?k:"warranty";
const $=id=>document.getElementById(id);
const pretty=v=>v?new Date(v).toLocaleString():"Not published";
const lines=v=>safe(v).replace(/\r?\n/g,"<br>");
function refresh(){if(typeof render==="function")render();}
function alertError(e){if(typeof toast==="function")toast("Policy: "+(e.message||e));}
async function loadPublic(kind){
  kind=valid(kind);if(state.loading["p"+kind])return;
  state.loading["p"+kind]=true;
  try{const {data,error}=await supabaseClient.rpc("apex_public_policy",{p_kind:kind});
    if(error)throw error;state.public[kind]={data};
  }catch(e){state.public[kind]={error:e.message||String(e)};}
  finally{state.loading["p"+kind]=false;refresh();}
}
async function loadOwner(kind){
  kind=valid(kind);if(state.loading["o"+kind])return;
  state.loading["o"+kind]=true;
  try{const {data,error}=await supabaseClient.rpc("apex_owner_policy",{p_action:"read",p_kind:kind});
    if(error)throw error;state.owner[kind]={data};
  }catch(e){state.owner[kind]={error:e.message||String(e)};}
  finally{state.loading["o"+kind]=false;refresh();}
}
function publicPage(kind){
  kind=valid(kind);
  if(!state.public[kind]&&!state.loading["p"+kind])void loadPublic(kind);
  const entry=state.public[kind],p=entry&&entry.data;
  return '<div class="wrap"><div class="pagehead"><div><h2>'+titles[kind]+'</h2><p>Current published information from Apex Computers.</p></div></div>'+
   '<div class="panel">'+(!entry?'Loading policy…':entry.error?
    '<p role="alert">Policy is temporarily unavailable. Please contact us for current terms.</p>':
    p&&p.published?'<div class="apex-policy-body">'+lines(p.body)+'</div><p class="muted" style="margin-top:24px">Published '+safe(pretty(p.published_at))+' · Version '+Number(p.version)+'</p>':
    '<p>No policy has been published yet. Please contact Apex Computers for current terms before placing an order.</p>')+
   '</div><p><a href="#/contact">Contact us</a></p></div>';
}
function ownerPage(){
  if(!isOwner)return staff();
  const kind=state.kind;
  if(!state.owner[kind]&&!state.loading["o"+kind])void loadOwner(kind);
  const entry=state.owner[kind],p=entry&&entry.data;
  const tab=k=>'<button type="button" class="btn '+(kind===k?'gold':'ghost')+'" onclick="apexPolicies.select(\''+k+'\')">'+titles[k]+'</button>';
  let content=!entry?'<p>Loading private draft…</p>':entry.error?
    '<p role="alert">'+safe(entry.error)+'</p><button class="btn ghost" onclick="apexPolicies.reload()">Retry</button>':
    '<p class="muted">Only an owner can save or publish a policy. Saved drafts remain private until explicitly published.</p>'+
    '<label for="apexPolicyDraft"><strong>Private draft</strong></label>'+
    '<textarea id="apexPolicyDraft" rows="16" maxlength="30000" style="width:100%;margin-top:8px" '+(state.busy?'disabled':'')+'>'+safe(p.draft)+'</textarea>'+
    '<div class="row" style="gap:10px;margin-top:16px;flex-wrap:wrap">'+
    '<button class="btn ghost" '+(state.busy?'disabled':'')+' onclick="apexPolicies.save()">Save private draft</button>'+
    '<button class="btn gold" '+(state.busy?'disabled':'')+' onclick="apexPolicies.publish()">Publish saved draft</button>'+
    '<button class="btn ghost" '+(state.busy?'disabled':'')+' onclick="apexPolicies.reload()">Reload</button></div>'+
    '<p class="muted">Draft revision '+Number(p.revision)+' · Live version '+Number(p.version)+' · '+safe(pretty(p.published_at))+'</p>'+
    '<h3>Currently published text</h3><div class="panel">'+(p.published?lines(p.published_body):'Not published')+'</div>'+
    '<h3>Publication history</h3><p class="muted">Previous published versions are retained privately in Supabase.</p>'+
    '<ul>'+(p.history||[]).map(v=>'<li>Version '+Number(v.version)+' · '+safe(pretty(v.published_at))+'</li>').join('')+'</ul>';
  return '<div class="wrap"><div class="pagehead"><div><h2>Store policy editor</h2><p>Owner-only drafts and controlled publishing.</p></div><a class="btn ghost" href="#/manage">Back to settings</a></div>'+
    '<div class="row" style="gap:10px;flex-wrap:wrap;margin-bottom:18px">'+tab("warranty")+tab("returns")+'</div><div class="panel">'+content+'</div></div>';
}
async function act(action){
  if(!isOwner||state.busy)return;
  const kind=state.kind,entry=state.owner[kind],p=entry&&entry.data;
  if(!p)return;
  const body=($("apexPolicyDraft")||{}).value;
  if(action==="publish"){
    if(body!==p.draft){alert("Save your draft first, then publish.");return;}
    if(!p.draft.trim()){alert("Write and save the policy before publishing.");return;}
    if(!confirm("Publish the saved "+titles[kind]+" to customers? This will replace the current live version."))return;
  }
  state.busy=true;
  try{
    const args={p_action:action,p_kind:kind,p_revision:p.revision};
    if(action==="save")args.p_body=body;
    const {data,error}=await supabaseClient.rpc("apex_owner_policy",args);
    if(error)throw error;
    state.owner[kind]={data};
    delete state.public[kind];
    if(typeof toast==="function")toast(action==="save"?"Private draft saved.":"Policy published.");
  }catch(e){alertError(e);delete state.owner[kind];}
  finally{state.busy=false;refresh();}
}
window.apexPolicies={
  publicPage,ownerPage,
  select(kind){state.kind=valid(kind);refresh();},
  reload(){delete state.owner[state.kind];refresh();},
  save(){return act("save");},
  publish(){return act("publish");}
};
})();
