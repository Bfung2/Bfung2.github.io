/* Owner-only manual business records. Encryption passwords never leave the browser. */
function recordBackupPage(){
 const denied=staffOwnerOnly();if(denied)return denied;
 return staffShell('Private record backup','Download encrypted business records and check saved files locally.',`<section class="panel"><h3>Create an encrypted copy</h3><p>Includes orders, employee profiles and roles, commissions, private notes, customer records and other included business tables. Your encryption password stays in this browser.</p><form onsubmit="recordBackupDownload(event)"><label class="field">Encryption password<input type="password" name="password" required minlength="16" maxlength="1024" autocomplete="new-password"></label><label class="field">Confirm encryption password<input type="password" name="confirm_password" required minlength="16" maxlength="1024" autocomplete="new-password"></label><p>Keep this password privately. Apex cannot recover it. Save the downloaded encrypted file somewhere private.</p><button class="btn gold">Encrypt and download records</button><p role="status" data-backup-status></p></form></section><section class="panel" style="margin-top:16px"><h3>Check a saved copy</h3><p>The file is decrypted only in this browser. This checks authentication, format and record counts. It does not restore or change the database.</p><form onsubmit="recordBackupCheck(event)"><label class="field">Encrypted backup file<input type="file" name="file" accept=".json,application/json" required></label><label class="field">Encryption password<input type="password" name="password" required minlength="16" maxlength="1024" autocomplete="off"></label><button class="btn ghost">Verify backup file locally</button><div role="status" data-backup-status></div></form></section><section class="notice" style="margin-top:16px"><strong>Coverage limits</strong><p>This is a manual copy of business records, not a complete database backup. It excludes Auth accounts/passwords/MFA, database schema and permissions, Storage file bytes, Edge secrets, provider configuration and the public GitHub catalog. Reconnecting restored records to Auth users requires a reviewed migration.</p><p>Scheduled backups are not enabled. Supabase Free has no scheduled project backups. Full recovery still needs the encrypted database-dump procedure and an isolated restore drill.</p></section>`);
}
function recordBackupStatus(form,message){const node=form.querySelector('[data-backup-status]');if(node)node.textContent=message;}
async function recordBackupDownload(event){
 event.preventDefault();if(!isOwner)return;
 const form=event.currentTarget,button=event.submitter,epoch=staffEpoch;
 let password=form.elements.password.value;const confirm=form.elements.confirm_password.value;
 if(password!==confirm){recordBackupStatus(form,'The passwords do not match.');return;}
 if(password.length<16){recordBackupStatus(form,'Choose at least 16 characters.');return;}
 staffBusy(button,true);recordBackupStatus(form,'Loading and encrypting private records…');
 try{
  const snapshot=await staffRPC('apex_owner_record_backup');if(epoch!==staffEpoch)return;
  const archive=await apexRecordCrypto.encrypt(snapshot,password);if(epoch!==staffEpoch)return;
  const blob=new Blob([JSON.stringify(archive)],{type:'application/json'}),url=URL.createObjectURL(blob);
  try{const a=document.createElement('a');a.href=url;a.download='apex-private-records-'+new Date().toISOString().replace(/[:.]/g,'-')+'.encrypted.json';a.click();}finally{setTimeout(()=>URL.revokeObjectURL(url),30000);}
  const incomplete=snapshot.missing_tables.length||snapshot.unlisted_tables.length;
  recordBackupStatus(form,'Encrypted file download requested. Check your downloads, then use “Check a saved copy” to verify it.'+(incomplete?' Some tables were absent or outside the export list; review the file coverage report.':''));
 }catch(e){if(epoch===staffEpoch)recordBackupStatus(form,e.message||'Backup could not be created.');}
 finally{password='';form.elements.password.value='';form.elements.confirm_password.value='';staffBusy(button,false);}
}
async function recordBackupCheck(event){
 event.preventDefault();const form=event.currentTarget,button=event.submitter,epoch=staffEpoch;
 const file=form.elements.file.files[0];if(!file)return;
 if(file.size>36*1024*1024){recordBackupStatus(form,'File is too large for browser verification.');return;}
 let password=form.elements.password.value;
 staffBusy(button,true);recordBackupStatus(form,'Decrypting and checking the saved file locally…');
 try{
  const snapshot=await apexRecordCrypto.decrypt(JSON.parse(await file.text()),password);if(epoch!==staffEpoch)return;
  const report=apexRecordCrypto.validate(snapshot),tables=Object.entries(report.counts),count=tables.reduce((n,[,c])=>n+c,0);
  const target=form.querySelector('[data-backup-status]');
  target.innerHTML=`<p><strong>File verified:</strong> ${tables.length} tables, ${count} records. Created ${esc(report.created_at)}.</p><ul>${tables.map(([name,c])=>`<li>${esc(name)}: ${c}</li>`).join('')}</ul><p>Missing tables: ${esc(report.missing_tables.join(', ')||'None')}. Tables outside this export: ${esc(report.unlisted_tables.join(', ')||'None')}.</p><p>Excluded: ${esc(report.excluded.join('; '))}.</p><p>No records were restored. A successful file check does not confirm full disaster recovery.</p>`;
 }catch(e){if(epoch===staffEpoch)recordBackupStatus(form,e.message||'The file could not be verified.');}
 finally{password='';form.elements.password.value='';form.elements.file.value='';staffBusy(button,false);}
}
