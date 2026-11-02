// The public gallery page behind an expiring share link (/s/<token>).

function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
}

export interface SharedItem { id: string; kind: string; filename: string | null; takenAt: number }

export function sharePage(token: string, title: string | null, items: SharedItem[], allowOriginal: boolean, expiresAt: number): string {
  const name = esc(title || 'Shared photos');
  const expires = new Date(expiresAt).toUTCString().replace(/:\d\d GMT/, ' GMT');
  const tiles = items.map((it) => {
    const date = new Date(it.takenAt).toISOString().slice(0, 10);
    const label = esc(`${it.kind === 'video' ? 'Video' : 'Photo'} · ${date}`);
    return `<button class="tile" data-id="${esc(it.id)}" data-video="${it.kind === 'video' ? 1 : 0}" aria-label="${label}">
      <img loading="lazy" src="/s/${token}/t/${esc(it.id)}" alt="${label}">${it.kind === 'video' ? '<span class="badge">▶</span>' : ''}</button>`;
  }).join('');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>${name}</title>
<meta name="robots" content="noindex">
<style>
:root{--bg:#fff;--fg:#111;--muted:#666;--line:#e5e5e5}
@media (prefers-color-scheme:dark){:root{--bg:#0b0b0c;--fg:#f2f2f2;--muted:#9a9a9a;--line:#26262a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.4 -apple-system,system-ui,sans-serif}
header{padding:20px 16px 8px}h1{font-size:22px;margin:0 0 4px}p{margin:0;color:var(--muted);font-size:13px}
main{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:3px;padding:8px 3px 40px}
.tile{position:relative;padding:0;border:0;background:var(--line);aspect-ratio:1;cursor:pointer}
.tile img{width:100%;height:100%;object-fit:cover;display:block}
.badge{position:absolute;right:6px;bottom:4px;color:#fff;text-shadow:0 1px 3px #000}
dialog{border:0;padding:0;max-width:100vw;max-height:100vh;width:100vw;height:100vh;background:#000}
dialog img{width:100%;height:calc(100% - 56px);object-fit:contain}
.bar{display:flex;justify-content:space-between;align-items:center;height:56px;padding:0 16px}
.bar a,.bar button{color:#fff;background:none;border:1px solid #555;border-radius:8px;padding:8px 12px;font-size:14px;text-decoration:none}
</style></head><body>
<header><h1>${name}</h1><p>${items.length} item${items.length === 1 ? '' : 's'} · link expires ${esc(expires)}</p></header>
<main>${tiles}</main>
<dialog id="d"><img id="big" alt=""><div class="bar"><button id="close">Close</button>
${allowOriginal ? '<a id="dl" href="#">Download original</a>' : '<a id="dl" href="#" download>Download</a>'}</div></dialog>
<script>
const d=document.getElementById('d'),big=document.getElementById('big'),dl=document.getElementById('dl');
document.querySelectorAll('.tile').forEach(t=>t.addEventListener('click',()=>{const id=t.dataset.id;
big.src='/s/${token}/p/'+id;dl.href=${allowOriginal ? "'/s/" + token + "/o/'+id" : "'/s/" + token + "/p/'+id"};d.showModal();}));
document.getElementById('close').onclick=()=>d.close();
</script></body></html>`;
}
