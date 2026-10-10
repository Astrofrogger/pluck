import Foundation

/// The web page a shared Library shows in a browser (see `LibraryServer`): one self-contained
/// page with Pluck's look, for phones and computers, light and dark.
enum LibraryPage {
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The page's words, in the Mac's language.
    private static var words: String {
        let strings: [String: String] = [
            "search": String(localized: "Search"),
            "all": String(localized: "Everything"),
            "videos": String(localized: "Videos"),
            "audio": String(localized: "Music & Audio"),
            "photos": String(localized: "Photos"),
            "download": String(localized: "Download"),
            "close": String(localized: "Close"),
            "empty": String(localized: "Nothing here yet."),
            "nothing": String(localized: "Nothing found."),
            "items": String(localized: "items"),
            "paste": String(localized: "Paste a link to download on this Mac"),
            "add": String(localized: "Download"),
            "added": String(localized: "Added. It’s downloading on the Mac."),
            "notLink": String(localized: "That doesn’t look like a link."),
            "send": String(localized: "Send Files"),
            "sending": String(localized: "Sending"),
            "sent": String(localized: "Sent to the Mac."),
            "failed": String(localized: "Didn’t work. Try again."),
            "downloads": String(localized: "Downloads"),
            "waiting": String(localized: "Waiting"),
            "paused": String(localized: "Paused"),
            "done": String(localized: "Done"),
            "error": String(localized: "Failed"),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: strings)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
    }

    private static let style = """
    :root{--bg:#f5f5f7;--card:#ffffff;--text:#1d1d1f;--muted:#6e6e73;--line:rgba(0,0,0,.08);--accent:#0a84ff;--chip:#e8e8ed;--radius-card:16px;--radius-thumb:10px;--radius-badge:4px;--gap:16px;--control:44px}
    @media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--card:#2c2c2e;--text:#f5f5f7;--muted:#98989d;--line:rgba(255,255,255,.1);--chip:#3a3a3c}}
    *{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--text);font:15px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
    header{position:sticky;top:0;z-index:2;background:color-mix(in srgb,var(--bg) 85%,transparent);backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);padding:16px max(16px,env(safe-area-inset-left)) 12px;border-bottom:1px solid var(--line)}
    h1{font-size:20px;margin:0 0 12px;display:flex;align-items:baseline;gap:8px}h1 small{color:var(--muted);font-weight:400;font-size:14px}
    .bar{display:flex;gap:10px;flex-wrap:wrap}
    input[type=search]{flex:1 1 220px;height:var(--control);border-radius:999px;border:1px solid var(--line);background:var(--card);color:var(--text);padding:0 16px;font:inherit;outline:none}
    input[type=search]:focus{border-color:var(--accent)}
    .chips{display:flex;gap:8px;overflow-x:auto;scrollbar-width:none}.chips::-webkit-scrollbar{display:none}
    .chip{height:var(--control);padding:0 16px;border-radius:999px;border:0;background:var(--chip);color:var(--text);font:inherit;white-space:nowrap;cursor:pointer}
    .chip[aria-pressed=true]{background:var(--accent);color:#fff}
    main{padding:var(--gap) max(16px,env(safe-area-inset-left));display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:var(--gap)}
    @media (max-width:480px){main{grid-template-columns:repeat(2,1fr);gap:12px}}
    .card{background:var(--card);border-radius:var(--radius-card);padding:8px;border:0;text-align:left;color:inherit;font:inherit;cursor:pointer;display:flex;flex-direction:column;gap:6px}
    .card:focus-visible{outline:3px solid var(--accent)}
    .thumb{position:relative;aspect-ratio:16/9;border-radius:var(--radius-thumb);background:var(--chip);overflow:hidden;display:grid;place-items:center;color:var(--muted);font-size:28px}
    .thumb img{width:100%;height:100%;object-fit:cover}
    .badge{position:absolute;right:6px;bottom:6px;background:rgba(0,0,0,.65);color:#fff;font-size:12px;font-weight:600;padding:1px 5px;border-radius:var(--radius-badge)}
    .title{font-weight:600;font-size:14px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
    .meta{color:var(--muted);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .empty{grid-column:1/-1;text-align:center;color:var(--muted);padding:48px 0}
    dialog{border:0;border-radius:var(--radius-card);padding:0;background:var(--card);color:var(--text);width:min(960px,96vw);max-height:94vh}
    dialog::backdrop{background:rgba(0,0,0,.6)}
    dialog video,dialog img{display:block;width:100%;max-height:70vh;background:#000;object-fit:contain}
    dialog audio{width:100%;margin-top:8px}
    .sheet{padding:16px;display:flex;flex-direction:column;gap:12px}
    .actions{display:flex;gap:10px;justify-content:flex-end}
    .button{height:var(--control);padding:0 20px;border-radius:999px;border:0;font:inherit;font-weight:600;cursor:pointer;display:inline-flex;align-items:center;text-decoration:none}
    .primary{background:var(--accent);color:#fff}.secondary{background:var(--chip);color:var(--text)}
    form.login{max-width:340px;margin:18vh auto 0;padding:24px;background:var(--card);border-radius:var(--radius-card);display:flex;flex-direction:column;gap:12px;text-align:center}
    form.login input{height:var(--control);border-radius:999px;border:1px solid var(--line);background:var(--bg);color:var(--text);text-align:center;font:600 22px/1 ui-monospace,monospace;letter-spacing:6px}
    .error{color:#ff453a;font-size:14px}
    .tools{display:none;gap:10px;flex-wrap:wrap;margin-top:10px}.tools.on{display:flex}
    .tools input[type=url]{flex:1 1 220px;height:var(--control);border-radius:999px;border:1px solid var(--line);background:var(--card);color:var(--text);padding:0 16px;font:inherit;outline:none}
    .status{color:var(--muted);font-size:13px;margin-top:6px;min-height:1em}
    #queue{display:none;padding:0 max(16px,env(safe-area-inset-left));margin-top:12px}#queue.on{display:block}
    #queue h2{font-size:13px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em;margin:0 0 6px}
    .job{background:var(--card);border-radius:var(--radius-box,12px);padding:10px 12px;margin-bottom:8px;display:grid;grid-template-columns:1fr auto;gap:4px 12px;align-items:center}
    .job .name{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:14px}.job .state{color:var(--muted);font-size:12px}
    .job progress{grid-column:1/-1;width:100%;height:4px;appearance:none;-webkit-appearance:none;border:0;border-radius:2px;background:var(--chip);overflow:hidden}
    .job progress::-webkit-progress-bar{background:var(--chip)}.job progress::-webkit-progress-value{background:var(--accent)}.job progress::-moz-progress-bar{background:var(--accent)}
    """

    static func login(error: Bool) -> String {
        let title = escape(String(localized: "Pluck Library"))
        let prompt = escape(String(localized: "Enter the access code shown in Pluck on the Mac."))
        let wrong = escape(String(localized: "That code isn’t right. Check it in Pluck’s Library window."))
        let button = escape(String(localized: "Open"))
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>\(title)</title><style>\(style)</style></head><body>
        <form class="login" method="post" action="/login"><h1 style="justify-content:center">\(title)</h1><div class="meta" style="white-space:normal">\(prompt)</div>
        <input name="code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" autofocus aria-label="Code">
        \(error ? "<div class=\"error\" role=\"alert\">\(wrong)</div>" : "")
        <button class="button primary" style="justify-content:center">\(button)</button></form></body></html>
        """
    }

    static var library: String {
        let title = escape(String(localized: "Pluck Library"))
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>\(title)</title><style>\(style)</style></head><body>
        <header><h1><span id="name">\(title)</span><small id="count"></small></h1>
        <div class="bar"><input type="search" id="q" autocomplete="off"><div class="chips" id="chips" role="group"></div></div>
        <div class="tools" id="tools"><form id="linkform" style="display:contents"><input type="url" id="link" inputmode="url"><button class="button primary" id="addbtn"></button></form>
        <label class="button secondary" id="sendlabel" style="display:none"><span id="sendtext"></span><input type="file" id="files" multiple hidden></label></div>
        <div class="status" id="status" role="status"></div></header>
        <section id="queue"><h2 id="qtitle"></h2><div id="jobs"></div></section>
        <main id="grid" aria-live="polite"></main>
        <dialog id="viewer"><div id="media"></div><div class="sheet"><div><div class="title" id="vtitle"></div><div class="meta" id="vmeta"></div></div>
        <div class="actions"><a class="button primary" id="dl"></a><button class="button secondary" id="close"></button></div></div></dialog>
        <script>
        const T=\(words);let items=[],kind='all';
        const $=s=>document.querySelector(s);
        const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
        const dur=s=>{if(!s)return'';s=Math.round(s);const h=Math.floor(s/3600),m=Math.floor(s%3600/60),x=String(s%60).padStart(2,'0');return h?`${h}:${String(m).padStart(2,'0')}:${x}`:`${m}:${x}`};
        const size=b=>{if(!b)return'';const u=['B','KB','MB','GB'];let i=0;while(b>=1000&&i<3){b/=1000;i++}return `${b.toFixed(i?1:0)} ${u[i]}`};
        const icon={video:'🎬',audio:'🎵',photo:'🖼'};
        $('#q').placeholder=T.search;$('#dl').textContent=T.download;$('#close').textContent=T.close;
        $('#chips').innerHTML=['all','videos','audio','photos'].map(k=>`<button class="chip" data-k="${k}" aria-pressed="${k==='all'}">${esc(T[k])}</button>`).join('');
        $('#chips').onclick=e=>{const b=e.target.closest('.chip');if(!b)return;kind=b.dataset.k;document.querySelectorAll('.chip').forEach(c=>c.setAttribute('aria-pressed',c===b));render()};
        $('#q').oninput=render;
        function render(){const q=$('#q').value.toLowerCase().trim();const want={videos:'video',audio:'audio',photos:'photo'}[kind];
          const list=items.filter(i=>(!want||i.kind===want)&&(!q||[i.title,i.uploader,i.site,...(i.tags||[])].join(' ').toLowerCase().includes(q)));
          $('#count').textContent=`${list.length} ${T.items}`;
          $('#grid').innerHTML=list.length?list.map(i=>`<button class="card" data-id="${i.id}"><div class="thumb">${i.thumb?`<img loading="lazy" alt="" src="${i.thumb}">`:icon[i.kind]||''}${i.duration?`<span class="badge">${dur(i.duration)}</span>`:''}</div><div class="title">${esc(i.title)}</div><div class="meta">${esc([i.site||i.uploader,size(i.size)].filter(Boolean).join(' · '))}</div></button>`).join(''):`<div class="empty">${esc(items.length?T.nothing:T.empty)}</div>`}
        $('#grid').onclick=e=>{const c=e.target.closest('.card');if(!c)return;const i=items.find(x=>x.id===c.dataset.id);const src='/file/'+i.id;
          $('#media').innerHTML=i.kind==='video'?`<video controls autoplay playsinline src="${src}"></video>`:i.kind==='audio'?`${i.thumb?`<img alt="" src="${i.thumb}">`:''}<audio controls autoplay src="${src}"></audio>`:`<img alt="${esc(i.title)}" src="${src}">`;
          $('#vtitle').textContent=i.title;$('#vmeta').textContent=[i.uploader,i.site,size(i.size),dur(i.duration)].filter(Boolean).join(' · ');
          $('#dl').href=src+'?download=1';$('#viewer').showModal()};
        $('#close').onclick=()=>$('#viewer').close();
        $('#viewer').addEventListener('close',()=>{$('#media').innerHTML=''});
        const say=t=>{$('#status').textContent=t||''};
        $('#link').placeholder=T.paste;$('#addbtn').textContent=T.add;$('#sendtext').textContent=T.send;$('#qtitle').textContent=T.downloads;
        $('#linkform').onsubmit=async e=>{e.preventDefault();const url=$('#link').value.trim();if(!/^https?:/i.test(url)){say(T.notLink);return}
          const r=await fetch('/api/download',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({url})}).catch(()=>null);
          if(r&&r.ok){$('#link').value='';say(T.added);poll()}else say(T.failed)};
        $('#files').onchange=async()=>{const files=[...$('#files').files];for(const [n,f] of files.entries()){
          await new Promise(res=>{const x=new XMLHttpRequest();x.open('POST','/api/upload?name='+encodeURIComponent(f.name));
            x.upload.onprogress=e=>{if(e.lengthComputable)say(`${T.sending} ${files.length>1?(n+1)+'/'+files.length+' ':''}${Math.round(e.loaded/e.total*100)}%`)};
            x.onload=()=>{say(x.status===200?T.sent:T.failed);res()};x.onerror=()=>{say(T.failed);res()};x.send(f)})}
          $('#files').value='';load()};
        const label={waiting:T.waiting,downloading:'',paused:T.paused,done:T.done,failed:T.error};
        let timer=null;
        async function poll(){const d=await fetch('/api/downloads').then(r=>r.json()).catch(()=>null);if(!d)return;
          const jobs=d.items||[];$('#queue').classList.toggle('on',jobs.length>0);
          $('#jobs').innerHTML=jobs.map(j=>`<div class="job"><div class="name">${esc(j.title)}</div><div class="state">${j.state==='downloading'?Math.round(j.progress*100)+'%':esc(label[j.state]||'')}</div>${j.state==='downloading'||j.state==='waiting'?`<progress max="1" value="${j.progress||0}"></progress>`:''}</div>`).join('');
          const active=jobs.some(j=>j.state==='downloading'||j.state==='waiting');
          if(jobs.some(j=>j.state==='done'&&j.id&&!items.find(i=>i.id===j.id)))load();
          clearTimeout(timer);timer=setTimeout(poll,active?1500:8000)}
        function load(){fetch('/api/library').then(r=>r.json()).then(d=>{items=d.items||[];$('#name').textContent=d.name||$('#name').textContent;document.title=$('#name').textContent;
          $('#tools').classList.toggle('on',!!(d.canDownload||d.canUpload));$('#linkform').style.display=d.canDownload?'contents':'none';
          $('#sendlabel').style.display=d.canUpload?'inline-flex':'none';render()})}
        load();poll();
        </script></body></html>
        """
    }

    /// A Send to Phone link that has run out.
    static var expired: String {
        let title = escape(String(localized: "This link has expired"))
        let text = escape(String(localized: "Send to Phone links work for ten minutes. Make a new one in Pluck on the Mac."))
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>\(title)</title><style>\(style)</style></head><body>
        <div class="login" style="max-width:340px;margin:18vh auto 0;padding:24px;background:var(--card);border-radius:var(--radius-card);text-align:center">
        <h1 style="justify-content:center">\(title)</h1><div class="meta" style="white-space:normal">\(text)</div></div></body></html>
        """
    }

    /// Send to Phone: the file downloads as soon as the page opens; a button and a preview too.
    static func send(title: String, kind: String, size: String?, file: String) -> String {
        let heading = escape(title)
        let saving = escape(String(localized: "Saving to your phone…"))
        let again = escape(String(localized: "Download"))
        let preview = escape(String(localized: "Play here"))
        let detail = escape(size ?? "")
        let media = kind == "video" ? "<video controls playsinline preload=\"none\" src=\"\(file)\"></video>"
            : kind == "audio" ? "<audio controls preload=\"none\" src=\"\(file)\"></audio>"
            : kind == "photo" ? "<img alt=\"\" src=\"\(file)\">" : ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>\(heading)</title><style>\(style)
        .send{max-width:520px;margin:10vh auto 0;padding:24px;background:var(--card);border-radius:var(--radius-card);display:flex;flex-direction:column;gap:12px}
        .send video,.send img{width:100%;border-radius:var(--radius-thumb);background:#000}.send audio{width:100%}
        details summary{cursor:pointer;color:var(--muted)}</style></head><body>
        <div class="send"><div class="title" style="font-size:18px">\(heading)</div><div class="meta">\(detail)</div>
        <div class="status" id="s">\(saving)</div>
        <a class="button primary" style="justify-content:center" href="\(file)?download=1" download>\(again)</a>
        \(media.isEmpty ? "" : "<details><summary>\(preview)</summary>\(media)</details>")</div>
        <script>window.addEventListener('load',()=>{const a=document.createElement('a');a.href='\(file)?download=1';a.download='';document.body.appendChild(a);a.click()})</script>
        </body></html>
        """
    }
}
