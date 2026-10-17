const {JSDOM}=require('jsdom');const fs=require('fs');const {execFileSync}=require('child_process');
const D=require('path').join(__dirname,'..','live')+'/', S=__dirname;
function pg(sql){try{const out=execFileSync('psql',['-h','/var/tmp/pgtest','-p','5544','-U','postgres','-d','e2e','-tAq','-v','ON_ERROR_STOP=1','-c',sql],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();return {data:out?JSON.parse(out):null,error:null}}catch(e){const m=(e.stderr||'').match(/ERROR:\s+(.*)/);return {data:null,error:{message:m?m[1]:String(e)}}}}
function page(file){let h=fs.readFileSync(D+file,'utf8')
  .replace(/<script src="vendor\/supabase[^"]*"><\/script>/,`<script>${fs.readFileSync(__dirname+'/fake-sb.js','utf8')}</script>`)
  .replace(/<script src="vendor\/qrcode[^"]*"><\/script>/,'<script>window.qrcode=()=>({addData(){},make(){},createSvgTag(){return "<svg></svg>"}})</script>')
  .replace(/<script src="shared\.js[^"]*"><\/script>/,`<script>${fs.readFileSync(D+'shared.js','utf8')}</script>`);
  const dom=new JSDOM(h,{runScripts:'dangerously',url:'https://grazysma.github.io/barberclub/live/'+file,beforeParse(w){w.__pg=pg;w.__users={'owner@barberclub.lt':'11111111-1111-1111-1111-111111111111','stranger@x.lt':'22222222-2222-2222-2222-222222222222'};w.console.error=(...a)=>console.log("CE",String(a[0]&&(a[0].message||a[0])))}});return dom}
const wait=(f,ms=4000)=>new Promise((res,rej)=>{const t0=Date.now();(function p(){let v;try{v=f()}catch(e){}if(v)return res(v);if(Date.now()-t0>ms)return rej(new Error('timeout'));setTimeout(p,30)})()});
const hm2=m=>String(Math.floor(m/60)).padStart(2,'0')+':'+String(m%60).padStart(2,'0');
const ok=(c,m)=>{console.log((c?'PASS ':'FAIL ')+m);if(!c)process.exitCode=1};
(async()=>{
 // ---------- client ----------
 let d=page('index.html'),w=d.window,doc=w.document,$=s=>doc.querySelector(s),txt=()=>doc.getElementById('client').textContent;
 await wait(()=>doc.querySelectorAll('[data-svc]').length);
 ok(doc.querySelectorAll('[data-svc]').length===9,'client: 9 services from DB');
 ok(!txt().includes('Barberio skydelis')&&!$('#tab-admin'),'client: no dashboard on client page');
 $('[data-svc="cut"]').click(); await wait(()=>$('[data-brb="any"]')); $('[data-brb="any"]').click();
 await wait(()=>$('[data-t]')); const day=$('[data-day][aria-pressed="true"]').dataset.day, t0=+$('[data-t]').dataset.t; $('[data-t]').click(); $('#next').click();
 await wait(()=>$('#f-email')); $('#f-name').value='Jonas';$('#f-phone').value='+370 612 34567';$('#f-email').value='bad'; $('#next').click();
 await wait(()=>$('#e-email')); ok(!!$('#e-email'),'client: bad email rejected');
 $('#f-email').value='jonas@gmail.com'; $('#next').click();
 await wait(()=>$('.done-box')); const code=$('.code').textContent; ok(/^BC-[A-Z0-9]{5}$/.test(code),'client: booking confirmed '+code+' '+day+' '+t0);
 const row=pg(`select json_agg(b) from bookings b where code='${code}'`).data[0]; ok(row&&row.client_email==='jonas@gmail.com'&&row.barber_id,'db: row saved, barber '+row.barber_id);
 // book same slot twice more with "any" -> 3rd barber, 4th fails
 for(const [n,ph] of [['Petras','+37061234568'],['Rokas','+37061234569']]){ pg(`set role anon; select * from create_booking('cut','any','${day}',${t0},'${n}','${ph}','x@y.lt')`); }
 // now UI: try same slot, any -> should be gone from list after refresh
 $('#again').click(); await wait(()=>$('[data-svc]')); $('[data-svc="cut"]').click(); await wait(()=>$('[data-brb]')); $('[data-brb="any"]').click();
 await wait(()=>$('[data-t]')); doc.querySelector(`[data-day="${day}"]`).click(); await new Promise(r=>setTimeout(r,200));
 ok(!doc.querySelector(`[data-t="${t0}"]`),'client: fully booked slot hidden for "any"');
 // race: slot shown but taken meanwhile -> friendly message
 const t1=+$('[data-t]').dataset.t; $('[data-t]').click(); $('#next').click(); await wait(()=>$('#f-name'));
 pg(`set role anon; select * from create_booking('cut','any','${day}',${t1},'Aistis','+37060000001','a@a.lt'); select * from create_booking('cut','any','${day}',${t1},'Benas','+37060000002','b@a.lt'); select * from create_booking('cut','any','${day}',${t1},'Celas','+37060000003','c@a.lt');`);
 $('#f-name').value='Ieva';$('#f-phone').value='+37061111111';$('#f-email').value='ieva@gmail.com';$('#next').click();
 await new Promise(r=>setTimeout(r,300)); await wait(()=>!doc.getElementById('toast').hidden); ok(/užimtas|taken/.test(doc.getElementById('toast').textContent),'client: race -> "taken" message, back to time step: '+!!$('[data-t]'));
 // EN
 doc.getElementById('lang-en').click(); ok(/Choose a time/.test(txt()),'client: English works');
 doc.getElementById('lang-tr').click(); ok(/Saat seçin/.test(txt()),'client: Turkish works');
 // ---------- admin ----------
 d=page('admin.html');w=d.window;doc=w.document;const A=s=>doc.querySelector(s),atx=()=>doc.getElementById('admin').textContent;
 await wait(()=>A('#lf')); ok(true,'admin: login form shown, no data before login');
 A('#l-email').value='owner@barberclub.lt';A('#l-pass').value='wrong';A('#lf').dispatchEvent(new w.Event('submit'));
 await wait(()=>A('.alert')); ok(/Neteisingas|Wrong/.test(A('.alert').textContent),'admin: wrong password rejected');
 A('#l-email').value='stranger@x.lt';A('#l-pass').value='pw';A('#lf').dispatchEvent(new w.Event('submit'));
 await wait(()=>A('.alert')&&/prieigos|access/.test(A('.alert').textContent)); ok(true,'admin: non-staff account blocked');
 A('#l-email').value='owner@barberclub.lt';A('#l-pass').value='pw';A('#lf').dispatchEvent(new w.Event('submit'));
 await wait(()=>A('.sched')); ok(true,'admin: owner sees dashboard');
 A(`[data-aday="${day}"]`).click(); await wait(()=>A('.appt'));
 const appts=[...doc.querySelectorAll('.appt')]; ok(appts.some(a=>a.textContent.includes('Jonas')),'admin: sees Jonas booking ('+appts.length+' on day)');
 appts.find(a=>a.textContent.includes('Jonas')).click(); await wait(()=>A('[data-act="noshow"]'));
 ok(atx().includes('+370 612 34567')&&atx().includes('jonas@gmail.com')&&atx().includes(code),'admin: details show phone, email, code');
 A('[data-act="noshow"]').click(); await wait(()=>A('[data-act="confirmed"]')); ok(pg(`select to_json(status) from bookings where code='${code}'`).data==='noshow','admin: no-show saved');
 A('[data-act="cancelled"]').click(); ok(/Tikrai|Really/.test(A('[data-act="cancelled"]').textContent),'admin: cancel asks confirmation');
 A('[data-act="cancelled"]').click(); await wait(()=>pg(`select to_json(status) from bookings where code='${code}'`).data==='cancelled'); ok(true,'admin: cancel saved'); await new Promise(r=>setTimeout(r,300));
 A('[data-panel="block"]').click(); await wait(()=>A('#b-save')); A('#b-brb').value='cagri'; A('#b-start').value='1080'; A('#b-len').value='60'; A('#b-save').click();
 await wait(()=>[...doc.querySelectorAll('.appt.block')].length); ok(true,'admin: block time added');
 ok(pg(`select count(*) from bookings where kind='block' and barber_id='cagri'`).data===1,'db: block row exists');

 // ---------- new: add visit ----------
 A('[data-panel="visit"]').click(); await wait(()=>A('#v-save'));
 A('#v-save').click(); await new Promise(r=>setTimeout(r,100)); ok(/vardą|name/.test(doc.getElementById('toast').textContent),'admin: visit requires name');
 A('#v-brb').value='mehmet'; A('#v-svc').value='beard'; A('#v-start').value='1200'; A('#v-name').value='Telefonas Tomas'; A('#v-phone').value='+37069999999'; A('#v-src').value='treatwell'; A('#v-save').click();
 await wait(()=>[...doc.querySelectorAll('.appt')].some(a=>a.textContent.includes('Telefonas Tomas'))); ok(true,'admin: phone/TW visit appears in calendar');
 ok(pg(`select to_json(source) from bookings where client_name='Telefonas Tomas'`).data==='treatwell','db: visit saved with source treatwell');
 [...doc.querySelectorAll('.appt')].find(a=>a.textContent.includes('Telefonas Tomas')).click(); await wait(()=>A('[data-act="noshow"]')); ok(/Treatwell/.test(atx()),'admin: detail shows source');
 // overlap -> busy toast
 A('[data-panel="visit"]').click(); await wait(()=>A('#v-save')); A('#v-brb').value='mehmet'; A('#v-svc').value='cut'; A('#v-start').value='1200'; A('#v-name').value='Dvigubas'; A('#v-save').click();
 await wait(()=>/jau yra|already/.test(doc.getElementById('toast').textContent)); ok(true,'admin: overlapping visit refused');

 // ---------- move a visit ----------
 [...doc.querySelectorAll('.appt')].find(a=>a.textContent.includes('Telefonas Tomas')).click(); await wait(()=>A('#m-open'));
 A('#m-open').click(); await wait(()=>A('#m-save'));
 const day2=[...A('#m-day').options].map(o=>o.value).find(v=>v>day); A('#m-day').value=day2; A('#m-brb').value='cagri'; A('#m-start').value='840'; A('#m-save').click();
 await wait(()=>/Perkelta|Moved/.test(doc.getElementById('toast').textContent));
 const mv=pg(`select json_agg(json_build_array(barber_id, (starts_at at time zone 'Europe/Vilnius')::date, extract(epoch from ends_at-starts_at)/60)) from bookings where client_name='Telefonas Tomas'`).data[0];
 ok(mv[0]==='cagri'&&mv[1]===day2&&mv[2]===35,'admin: visit moved to cagri '+day2+' 14:00, length kept 35 min');
 ok(A(`[data-aday="${day2}"]`).getAttribute('aria-pressed')==='true'&&[...doc.querySelectorAll('.appt')].some(a=>a.textContent.includes('14:00 Telefonas Tomas')),'admin: calendar jumps to new day and shows it');
 // move onto a taken slot -> refused
 pg(`set role anon; select * from create_booking('cut','cagri','${day2}',600,'Uzimtas','+37061112222','u@x.lt')`); await new Promise(r=>setTimeout(r,50));
 A('#ref').click(); await wait(()=>[...doc.querySelectorAll('.appt')].some(a=>a.textContent.includes('Telefonas Tomas')));
 [...doc.querySelectorAll('.appt')].find(a=>a.textContent.includes('Telefonas Tomas')).click(); await wait(()=>A('#m-open')); A('#m-open').click(); await wait(()=>A('#m-save'));
 A('#m-start').value='615'; A('#m-save').click(); await wait(()=>/jau yra|already/.test(doc.getElementById('toast').textContent)); ok(true,'admin: move onto busy time refused');
 // ---------- new: hours ----------
 const dow=new Date(day+'T12:00:00').getDay();
 A('[data-panel="hours"]').click(); await wait(()=>A('#h-save')); A('#h-brb').value='metin'; A('#h-brb').dispatchEvent(new w.Event('change')); await wait(()=>A('#h-save'));
 doc.querySelectorAll('[data-hd]').forEach(c=>{ if(+c.dataset.hd!==dow){ c.checked=false; c.dispatchEvent(new w.Event('change')); } });
 A(`[data-hs="${dow}"]`).value='720'; A(`[data-he="${dow}"]`).value='1020'; A('#h-save').click();
 await wait(()=>/išsaugotas|saved/.test(doc.getElementById('toast').textContent)); 
 ok(JSON.stringify(pg(`select json_agg(json_build_array(dow,start_min,end_min)) from barber_hours where barber_id='metin'`).data)===JSON.stringify([[dow,720,1020]]),'db: metin hours saved (1 day 12-17)');
 ok(doc.querySelectorAll('.off').length>0,'admin: off-hours shaded');
 // client sees metin only 12-17 that day, none other days
 let d2=page('index.html'),w2=d2.window,doc2=w2.document,$2=s=>doc2.querySelector(s);
 await wait(()=>$2('[data-svc]')); $2('[data-svc="kid"]').click(); await wait(()=>$2('[data-brb="metin"]')); $2('[data-brb="metin"]').click(); await wait(()=>$2('[data-day]'));
 const enabled=[...doc2.querySelectorAll('[data-day]')].filter(b=>!b.disabled).map(b=>b.dataset.day);
 ok(enabled.every(x=>new Date(x+'T12:00:00').getDay()===dow),'client: metin only bookable on his working weekday ('+enabled.length+' days)');
 const later=enabled.find(x=>x>day)||enabled[0]; doc2.querySelector(`[data-day="${later}"]`).click(); await new Promise(r=>setTimeout(r,100));
 const ts=[...doc2.querySelectorAll('[data-t]')].map(b=>+b.dataset.t); ok(ts.length&&Math.min(...ts)>=720&&Math.max(...ts)+30<=1020,'client: slots within 12:00-17:00 ('+hm2(Math.min(...ts))+'-'+hm2(Math.max(...ts))+')');
 doc.getElementById('lang-tr').click(); ok(/Kapalı|Randevu/.test(atx())&&/Çıkış/.test(doc.getElementById('logout').textContent),'admin: Turkish works'); A('#logout').click(); await wait(()=>A('#lf')); ok(true,'admin: logout returns to login');
 process.exit();
})().catch(e=>{console.log('FAIL exception',e.message);process.exit(1)});
