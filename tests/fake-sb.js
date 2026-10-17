// Fake supabase-js backed by the local Postgres (runs inside jsdom via a Node bridge)
window.supabase = { createClient: () => {
  const run = window.__pg; let session = window.__session || null;
  const lit = v => v === null || v === undefined ? 'NULL' : typeof v === 'number' ? String(v) : typeof v === 'object' ? "'" + JSON.stringify(v).replace(/'/g, "''") + "'::jsonb" : "'" + String(v).replace(/'/g, "''") + "'";
  const pre = () => session ? `set role authenticated; set request.jwt.claim.sub='${session.user.id}';` : 'set role anon;';
  const q = sql => { const r = run(pre() + sql); return Promise.resolve(r); };
  const SETOF = ['busy_slots','create_booking','staff_bookings','my_staff','booking_by_token'];
  return {
    from(t) { let order = null, limit = null; const b = {
      select() { return b; }, order(c) { order = c; return b; }, limit(n) { limit = n; return b; },
      then(res, rej) { return q(`select coalesce(json_agg(x),'[]') from (select * from public.${t}${order ? ' order by ' + order : ''}${limit ? ' limit ' + limit : ''}) x;`).then(res, rej); } }; return b; },
    rpc(name, args) {
      const a = Object.entries(args || {}).map(([k, v]) => `${k} => ${lit(v)}`).join(', ');
      return q(SETOF.includes(name) ? `select coalesce(json_agg(r),'[]') from public.${name}(${a}) r;` : `select to_json(public.${name}(${a}));`);
    },
    auth: {
      getSession: async () => ({ data: { session } }),
      signInWithPassword: async ({ email, password }) => {
        const u = window.__users[email];
        if (!u || password !== 'pw') return { data: { session: null }, error: { message: 'Invalid login credentials' } };
        session = { user: { id: u, email } }; return { data: { session }, error: null };
      },
      signOut: async () => { session = null; return { error: null }; }
    }
  };
}};
