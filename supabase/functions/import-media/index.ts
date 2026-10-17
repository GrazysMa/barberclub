// One-time helper: copies the salon's own barber photos from Treatwell into Supabase Storage (bucket "media")
// and stores the paths on public.barbers. Only fixed Treatwell CDN URLs are used. Delete this function after use.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const T = 'https://cdn1.treatwell.net/images/view/';
const SRC: Record<string, { photo: string; gallery: string[] }> = {
  mehmet: { photo: 'v2.i15728872.w256.h256.xBA411421', gallery: ['v2.i15745094.w800.h1066.xFA523356','v2.i15745103.w800.h1066.xF4620C29','v2.i15745146.w800.h1066.x2296FC48','v2.i15745150.w800.h1066.xCA88A706','v2.i15745160.w800.h1066.x96968435','v2.i15745168.w800.h1066.x8BD33280','v2.i15765611.w800.h1066.x7A0C190E','v2.i15797021.w800.h1066.x3A6DC24B','v2.i15797022.w800.h1066.x02BDE646','v2.i15797025.w800.h1066.x458837A0','v2.i15831178.w800.h1066.x48A12E40','v2.i15831185.w800.h1066.x95766F75','v2.i16033227.w800.h1066.x22D6EE00','v2.i16033235.w800.h1066.xCDB32272','v2.i16106655.w800.h1066.xD270271B','v2.i16560314.w800.h1066.x65CAF386'] },
  metin: { photo: 'v2.i15653668.w256.h256.xBF0D2EA7', gallery: ['v2.i15654538.w800.h1066.xB90F023D','v2.i15654543.w800.h1066.x6488D08D','v2.i15654546.w800.h1066.x50A918F3','v2.i15654547.w800.h1066.x1C2EC400','v2.i15654551.w800.h1066.xBD269F5B','v2.i15654556.w800.h1066.x3B498E8B','v2.i15654567.w800.h1066.xE974490C','v2.i15669066.w800.h1066.x61EA1BDF','v2.i15669073.w800.h1066.xC5B4E656','v2.i15684431.w800.h1066.xAE457F4F','v2.i15684470.w800.h1066.x28563798','v2.i15684484.w800.h1066.x57C646D8','v2.i15684501.w800.h1066.xBCB79267','v2.i15684516.w800.h1066.x05F53739'] },
  cagri: { photo: 'v2.i17198413.w256.h256.xB18410D3', gallery: [] },
};

Deno.serve(async () => {
  let sk = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!sk) { try { const k = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}'); sk = k.default ?? Object.values(k)[0] ?? ''; } catch { /* none */ } }
  const db = createClient(Deno.env.get('SUPABASE_URL')!, sk, { auth: { persistSession: false } });
  const out: Record<string, unknown> = {};
  for (const [id, s] of Object.entries(SRC)) {
    const put = async (src: string, path: string) => {
      const r = await fetch(T + src + '/');
      if (!r.ok) throw new Error(`${src} ${r.status}`);
      const type = r.headers.get('content-type') ?? 'image/jpeg';
      const { error } = await db.storage.from('media').upload(path, await r.arrayBuffer(), { contentType: type, upsert: true, cacheControl: '31536000' });
      if (error) throw new Error(`${path} ${error.message}`);
      return path;
    };
    try {
      const photo = await put(s.photo, `barbers/${id}/avatar.jpg`);
      const gallery: string[] = [];
      for (let i = 0; i < s.gallery.length; i++) gallery.push(await put(s.gallery[i], `barbers/${id}/g${String(i + 1).padStart(2, '0')}.jpg`));
      const { error } = await db.from('barbers').update({ photo, gallery }).eq('id', id);
      out[id] = error ? error.message : { photo, gallery: gallery.length };
    } catch (e) { out[id] = String(e); }
  }
  return new Response(JSON.stringify(out), { headers: { 'Content-Type': 'application/json' } });
});
