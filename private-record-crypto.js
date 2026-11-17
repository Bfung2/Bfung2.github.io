/* Browser and Node Web Crypto only. No external encryption service or stored password. */
(function(root){
 'use strict';
 const iterations=600000,maxBytes=24*1024*1024;
 const aad=new TextEncoder().encode('Apex business record backup v1');
 function bytesTo64(bytes){let text='';for(let i=0;i<bytes.length;i+=8192)text+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(text);}
 function from64(value){if(typeof value!=='string'||value.length>maxBytes*1.5||!/^[A-Za-z0-9+/]*={0,2}$/.test(value))throw Error('Invalid encrypted backup');return Uint8Array.from(atob(value),c=>c.charCodeAt(0));}
 function validate(snapshot){
  if(!snapshot||snapshot.format!=='apex-business-records'||snapshot.version!==1||!snapshot.tables||!snapshot.counts||snapshot.automatic_restore!==false)throw Error('Not an Apex business-record backup');
  const names=Object.keys(snapshot.tables);
  if(!names.length||names.length>100||Object.keys(snapshot.counts).length!==names.length)throw Error('Backup table manifest is invalid');
  for(const name of names){if(!/^[a-z][a-z0-9_]*$/.test(name)||!Object.hasOwn(snapshot.counts,name)||!Array.isArray(snapshot.tables[name])||snapshot.counts[name]!==snapshot.tables[name].length)throw Error('Backup record count does not match its manifest');}
  if(!Array.isArray(snapshot.missing_tables)||!Array.isArray(snapshot.unlisted_tables)||!Array.isArray(snapshot.excluded)||!Number.isFinite(Date.parse(snapshot.created_at)))throw Error('Backup coverage manifest is invalid');
  return {created_at:snapshot.created_at,counts:snapshot.counts,missing_tables:snapshot.missing_tables,unlisted_tables:snapshot.unlisted_tables,excluded:snapshot.excluded};
 }
 async function keyFor(password,salt){
  if(typeof password!=='string'||password.length<16||password.length>1024)throw Error('Use an encryption password with 16–1024 characters');
  const material=await crypto.subtle.importKey('raw',new TextEncoder().encode(password),'PBKDF2',false,['deriveKey']);
  return crypto.subtle.deriveKey({name:'PBKDF2',salt,iterations,hash:'SHA-256'},material,{name:'AES-GCM',length:256},false,['encrypt','decrypt']);
 }
 async function encrypt(snapshot,password){
  validate(snapshot);const plaintext=new TextEncoder().encode(JSON.stringify(snapshot));if(plaintext.length>maxBytes)throw Error('Backup exceeds browser limit');
  const salt=crypto.getRandomValues(new Uint8Array(16)),iv=crypto.getRandomValues(new Uint8Array(12));
  const key=await keyFor(password,salt);
  const ciphertext=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:aad,tagLength:128},key,plaintext);
  plaintext.fill(0);
  return {format:'apex-encrypted-records',version:1,cipher:'AES-256-GCM',kdf:'PBKDF2-SHA256',iterations,salt:bytesTo64(salt),iv:bytesTo64(iv),ciphertext:bytesTo64(new Uint8Array(ciphertext))};
 }
 async function decrypt(archive,password){
  if(!archive||archive.format!=='apex-encrypted-records'||archive.version!==1||archive.cipher!=='AES-256-GCM'||archive.kdf!=='PBKDF2-SHA256'||archive.iterations!==iterations)throw Error('Unsupported encrypted backup format');
  const salt=from64(archive.salt),iv=from64(archive.iv),ciphertext=from64(archive.ciphertext);
  if(salt.length!==16||iv.length!==12||ciphertext.length<16||ciphertext.length>maxBytes+16)throw Error('Invalid encrypted backup');
  const key=await keyFor(password,salt);let plaintext;
  try{plaintext=new Uint8Array(await crypto.subtle.decrypt({name:'AES-GCM',iv,additionalData:aad,tagLength:128},key,ciphertext));}
  catch{throw Error('Incorrect password or damaged backup');}
  try{const snapshot=JSON.parse(new TextDecoder().decode(plaintext));validate(snapshot);return snapshot;}finally{plaintext.fill(0);}
 }
 root.apexRecordCrypto={encrypt,decrypt,validate,maxBytes};
 if(typeof module!=='undefined'&&module.exports)module.exports=root.apexRecordCrypto;
})(typeof globalThis!=='undefined'?globalThis:this);
