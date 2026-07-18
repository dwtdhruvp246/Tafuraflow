(function(){
  const cfg=window.DINEQR_CONFIG;
  if(!cfg||!window.supabase) throw new Error('DineQR configuration did not load.');
  const db=window.supabase.createClient(cfg.supabaseUrl,cfg.supabaseAnonKey);
  const nav={
    super_admin:[['dashboard.html','Overview'],['companies.html','Companies'],['admin-finance.html','Owner payments']],
    owner:[['dashboard.html','Overview'],['tables.html','Tables & QR'],['orders.html','Orders'],['menu.html','Menu'],['staff.html','Staff'],['finance.html','Finances'],['settings.html','Settings']],
    manager:[['dashboard.html','Overview'],['tables.html','Tables & QR'],['orders.html','Orders'],['menu.html','Menu'],['staff.html','Staff']],
    waiter:[['dashboard.html','Overview'],['tables.html','Tables & QR'],['orders.html','Orders']],
    kitchen:[['orders.html','Kitchen orders']],
    cashier:[['dashboard.html','Overview'],['tables.html','Tables & bills'],['finance.html','Receipts']]
  };
  const titles={dashboard:'Overview',companies:'Companies','admin-finance':'Owner payments',tables:'Tables & QR codes',orders:'Orders',menu:'Menu',staff:'Staff',finance:'Finances',settings:'Restaurant settings'};
  const esc=v=>String(v??'').replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
  const money=(v,c='USD')=>new Intl.NumberFormat('en-US',{style:'currency',currency:c}).format(Number(v||0));
  const date=v=>v?new Intl.DateTimeFormat('en-US',{dateStyle:'medium',timeStyle:'short'}).format(new Date(v)):'—';
  function toast(message,type='ok'){let t=document.getElementById('toast');if(!t){t=document.createElement('div');t.id='toast';document.body.append(t)}t.className='toast'+(type==='error'?' error':'');t.textContent=message;t.classList.remove('hidden');clearTimeout(window.__dqToast);window.__dqToast=setTimeout(()=>t.classList.add('hidden'),3500)}
  function err(e){console.error(e);toast(e?.message||'Something went wrong.','error')}
  async function context(){const {data,error}=await db.rpc('get_my_context');if(error)throw error;return data}
  async function requireAuth(){const {data:{session}}=await db.auth.getSession();if(!session){location.replace('index.html');return null}const ctx=await context();if(!ctx?.profile)throw new Error('Your profile is not ready. Run the DineQR SQL file in Supabase.');if(ctx.membership&&ctx.restaurant?.active===false)throw new Error('This restaurant company has been suspended. Contact the DineQR Super Admin.');return ctx}
  function roleOf(ctx){return ctx?.profile?.platform_role==='super_admin'?'super_admin':ctx?.membership?.role}
  function allowed(ctx,page){const role=roleOf(ctx);return (nav[role]||[]).some(([u])=>u===page+'.html')}
  async function routeUser(){const ctx=await context();const role=roleOf(ctx);if(!role){location.replace('waiting.html');return}location.replace(role==='kitchen'?'orders.html':'dashboard.html')}
  async function signOut(){await db.auth.signOut();location.replace('index.html')}
  function shell(page,ctx){const role=roleOf(ctx), restaurant=ctx.restaurant?.name||(role==='super_admin'?'DineQR platform':'No company assigned');const links=(nav[role]||[]).map(([url,label])=>`<a href="${url}" class="${url===page+'.html'?'active':''}">${esc(label)}</a>`).join('');document.getElementById('app').className='shell';document.getElementById('app').innerHTML=`<aside class="sidebar" id="sidebar"><a class="brand" href="dashboard.html">Dine<span>QR</span></a><div class="company-block"><small>Company</small><strong>${esc(restaurant)}</strong></div><nav class="nav">${links}</nav><div class="sidebar-bottom"><div class="user-block"><strong>${esc(ctx.profile.full_name||ctx.profile.email)}</strong><small>${esc(String(role||'unassigned').replaceAll('_',' '))}</small></div><button class="btn ghost small" id="signout" style="color:#fff;border-color:#456057;width:100%">Sign out</button></div></aside><main class="main"><header class="topbar"><div class="actions"><button class="btn ghost small mobile-menu" id="mobile-menu">Menu</button><h2>${esc(titles[page]||'DineQR')}</h2></div><span class="muted">${esc(restaurant)}</span></header><div class="content" id="content"><div class="loading" style="min-height:50vh"><div class="spinner"></div></div></div></main>`;document.getElementById('signout').onclick=signOut;document.getElementById('mobile-menu')?.addEventListener('click',()=>document.getElementById('sidebar').classList.toggle('open'))}
  function modal(title,html){let root=document.getElementById('modal-root');if(!root){root=document.createElement('div');root.id='modal-root';document.body.append(root)}root.innerHTML=`<div class="modal-backdrop" data-close><div class="modal" onclick="event.stopPropagation()"><div class="modal-head"><h2>${esc(title)}</h2><button class="icon-btn" data-close aria-label="Close">×</button></div>${html}</div></div>`;root.querySelectorAll('[data-close]').forEach(x=>x.onclick=closeModal)}
  function closeModal(){const r=document.getElementById('modal-root');if(r)r.innerHTML=''}
  function formData(form){return Object.fromEntries(new FormData(form).entries())}
  async function setBusy(button,busy,label='Working…'){if(!button)return;if(busy){button.dataset.old=button.textContent;button.textContent=label;button.disabled=true}else{button.textContent=button.dataset.old||'Save';button.disabled=false}}
  window.dq={db,esc,money,date,toast,err,context,requireAuth,roleOf,allowed,routeUser,signOut,shell,modal,closeModal,formData,setBusy};
})();
