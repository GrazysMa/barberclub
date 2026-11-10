#!/usr/bin/env python3
"""Local preview/test server: serves ../live with a fake supabase-js that talks to the local test Postgres.
Usage: python3 serve.py [port]   (database: see reset-db.sh)"""
import http.server, json, subprocess, sys, os, re, functools
LIVE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'live')
PSQL = ['psql', '-h', '/var/tmp/pgtest', '-p', '5544', '-U', 'postgres', '-d', 'e2e', '-tAq', '-v', 'ON_ERROR_STOP=1', '-c']
USERS = {'meda@example.lt': '11111111-1111-1111-1111-111111111111', 'stranger@x.lt': '22222222-2222-2222-2222-222222222222'}
def lit(v):
    if v is None: return 'NULL'
    if isinstance(v, bool): return 'true' if v else 'false'
    if isinstance(v, (int, float)): return str(v)
    if isinstance(v, (dict, list)): return "'" + json.dumps(v).replace("'", "''") + "'::jsonb"
    return "'" + str(v).replace("'", "''") + "'"
def run(sql, sub=None):
    pre = f"set role authenticated; set request.jwt.claim.sub='{sub}';" if sub else 'set role anon;'
    r = subprocess.run(PSQL + [pre + sql], capture_output=True, text=True)
    if r.returncode:
        m = re.search(r'ERROR:\s+(.*)', r.stderr)
        return {'data': None, 'error': {'message': m.group(1) if m else r.stderr}}
    out = r.stdout.strip()
    try: return {'data': json.loads(out) if out else None, 'error': None}
    except ValueError: return {'data': out, 'error': None}
def kind(name):
    r = subprocess.run(PSQL + [f"select proretset::int || ',' || prorettype::regtype from pg_proc where proname={lit(name)} and pronamespace='public'::regnamespace limit 1"], capture_output=True, text=True)
    s, t = (r.stdout.strip() or '0,void').split(',', 1); return s == '1', t
FAKE = r'''
window.supabase = { createClient: (url) => {
  let session = null; try { session = JSON.parse(sessionStorage.getItem('fake-session')); } catch (e) {}
  const call = body => { const x = new XMLHttpRequest(); x.open('POST', '/__sb', false); x.send(JSON.stringify({ ...body, sub: session && session.user.id })); return Promise.resolve(JSON.parse(x.responseText)); };
  return {
    from(t) { const q = { t, eq: [], order: null, limit: null }; const b = {
      select() { return b; }, eq(c, v) { q.eq.push([c, v]); return b; }, order(c) { q.order = c; return b; }, limit(n) { q.limit = n; return b; },
      then(res, rej) { return call({ from: q }).then(res, rej); } }; return b; },
    rpc(name, args) { return call({ rpc: name, args: args || {} }); },
    storage: { from() { return { upload: async () => ({ data: {}, error: null }), remove: async () => ({ data: {}, error: null }) }; } },
    auth: {
      getSession: async () => ({ data: { session } }),
      signInWithPassword: async ({ email, password }) => {
        const u = window.__users[email];
        if (!u || password !== 'pw') return { data: { session: null }, error: { message: 'Invalid login credentials' } };
        session = { user: { id: u, email } }; sessionStorage.setItem('fake-session', JSON.stringify(session)); return { data: { session }, error: null };
      },
      signOut: async () => { session = null; sessionStorage.removeItem('fake-session'); return { error: null }; },
      updateUser: async () => ({ error: null }), resetPasswordForEmail: async () => ({ error: null }),
      onAuthStateChange() { return { data: { subscription: { unsubscribe() {} } } }; }
    }
  };
}};
window.__users = %s;
''' % json.dumps(USERS)
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if 'from' in b:
            q = b['from']; w = ' and '.join(f"{c} = {lit(v)}" for c, v in q['eq'])
            res = run(f"select coalesce(json_agg(x),'[]') from (select * from public.{q['t']}{' where ' + w if w else ''}{' order by ' + q['order'] if q['order'] else ''}{' limit ' + str(q['limit']) if q['limit'] else ''}) x;", b.get('sub'))
        else:
            a = ', '.join(f"{k} => {lit(v)}" for k, v in b['args'].items()); setof, typ = kind(b['rpc'])
            sql = f"select coalesce(json_agg(r),'[]') from public.{b['rpc']}({a}) r;" if setof else f"select public.{b['rpc']}({a});" if typ == 'void' else f"select to_json(public.{b['rpc']}({a}));"
            res = run(sql, b.get('sub'))
            if typ == 'void' and not res['error']: res['data'] = None
        out = json.dumps(res).encode(); self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(out)
    def do_GET(self):
        p = self.path.split('?')[0]
        if p == '/__fake.js':
            self.send_response(200); self.send_header('Content-Type', 'text/javascript'); self.end_headers(); self.wfile.write(FAKE.encode()); return
        if p.endswith('/'): p += 'index.html'
        f = os.path.join(LIVE, p.lstrip('/'))
        if p.endswith('.html') and os.path.isfile(f):
            h = open(f, encoding='utf-8').read()
            h = re.sub(r'<script src="vendor/supabase[^"]*"></script>', '<script src="/__fake.js"></script>', h)
            self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.end_headers(); self.wfile.write(h.encode()); return
        super().do_GET()
if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    http.server.ThreadingHTTPServer(('127.0.0.1', port), functools.partial(H, directory=LIVE)).serve_forever()
