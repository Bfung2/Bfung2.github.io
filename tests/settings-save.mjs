import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
const source=await fs.readFile(new URL('../index.html',import.meta.url),'utf8');
const settingsCode=source.slice(source.indexOf('let settingsDirty=false'),source.indexOf('\nfunction inventory()',source.indexOf('let settingsDirty=false')));
const defaults={s_shop:'Apex',s_tag:'Tagline',s_mail:'new-owner@example.invalid',s_phone:'555',s_fee:'20',s_ship:'18',s_tax:'14.5',s_addr:'Shop',s_zelle:'',s_paypal:'',s_apay:''};
function fixture({token=true,saveResult=true,local=false}={}){
 const controls=Object.entries(defaults).map(([id,value])=>({id,value}));controls.namedItem=id=>controls.find(c=>c.id===id);
 const form={elements:controls};const toasts=[];let resolve;
 const context=vm.createContext({isOwner:true,ghConfigured:!local,ghToken:()=>token?'test-token':'',S:{settings:{ownerEmail:'old-owner@example.invalid'}},clearTimeout(){},saveTimer:null,KEY:'settings',localStorage:{setItem(){}},cloudError:'Permission denied',toast:t=>toasts.push(t),document:{getElementById:id=>controls.namedItem(id)},render:()=>{},pushToGithub:()=>saveResult==='defer'?new Promise(r=>resolve=r):Promise.resolve(saveResult)});
 vm.runInContext(settingsCode,context);
 return {form,context,toasts,run:s=>vm.runInContext(s,context),save:()=>{context.event={target:form,preventDefault(){}};return vm.runInContext('saveSettings(event)',context);},resolve:v=>resolve(v)};
}
let f=fixture({token:false});await f.save();assert.equal(f.context.S.settings.ownerEmail,'old-owner@example.invalid');assert.equal(f.toasts.length,0);assert.match(f.run('settingsSaveError'),/No GitHub write token/);assert.equal(f.run('settingsDirty'),true);
f=fixture({saveResult:false});await f.save();assert.equal(f.context.S.settings.ownerEmail,'old-owner@example.invalid');assert.equal(f.run('settingsDraft.s_mail'),'new-owner@example.invalid');assert.match(f.run('settingsSaveError'),/Permission denied/);assert.ok(!f.toasts.some(t=>t.includes('saved to GitHub')));
f.form.elements.namedItem('s_mail').value='reset@example.invalid';f.run('restoreSettingsDraft()');assert.equal(f.form.elements.namedItem('s_mail').value,'new-owner@example.invalid');
f=fixture({saveResult:'defer'});let pending=f.save();assert.equal(f.run('settingsSaving'),true);assert.equal(f.toasts.length,0);f.resolve(true);await pending;assert.equal(f.run('settingsDirty'),false);assert.equal(f.run('settingsDraft'),null);assert.equal(f.context.S.settings.ownerEmail,'new-owner@example.invalid');assert.equal(f.context.S.settings.shippingRatePercent,18);assert.equal(f.context.S.settings.taxRate,14.5);assert.deepEqual(f.toasts,['Settings saved to GitHub.']);
f=fixture({saveResult:'defer'});pending=f.save();f.form.elements.namedItem('s_mail').value='later-edit@example.invalid';f.context.form=f.form;f.run('trackSettingsDraft(form)');f.resolve(true);await pending;assert.equal(f.run('settingsDirty'),true);assert.equal(f.run('settingsDraft.s_mail'),'later-edit@example.invalid');assert.equal(f.context.S.settings.ownerEmail,'new-owner@example.invalid');
f=fixture({local:true});await f.save();assert.deepEqual(f.toasts,['Settings saved on this device.']);
console.log('PASS: settings wait for confirmed save, preserve drafts across renders/failures, roll back failed source changes, and retain edits made during a save.');
