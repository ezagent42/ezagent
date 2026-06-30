// 诊断：注入 cookie → navigate → 等 → 抓 body 文本 + console 报错 + 关键请求失败。
const http = require('http');
const COOKIE = process.env.COOKIE, SHOT_URL = process.env.SHOT_URL;
const WAIT_MS = parseInt(process.env.WAIT_MS || '10000', 10);
function getJSON(p){return new Promise((res,rej)=>{http.get({host:'127.0.0.1',port:9222,path:p},r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>res(JSON.parse(d)));}).on('error',rej);});}
async function main(){
  const t=(await getJSON('/json')).find(x=>x.type==='page');
  const ws=new WebSocket(t.webSocketDebuggerUrl);let id=0;const p=new Map();
  const send=(m,pr={})=>new Promise(r=>{const i=++id;p.set(i,r);ws.send(JSON.stringify({id:i,method:m,params:pr}));});
  const logs=[];
  await new Promise(r=>ws.onopen=r);
  ws.onmessage=ev=>{const m=JSON.parse(ev.data);
    if(m.id&&p.has(m.id)){p.get(m.id)(m.result);p.delete(m.id);}
    if(m.method==='Log.entryAdded')logs.push('LOG '+m.params.entry.level+': '+m.params.entry.text);
    if(m.method==='Runtime.consoleAPICalled')logs.push('CONSOLE '+m.params.type+': '+(m.params.args||[]).map(a=>a.value||a.description||'').join(' '));
    if(m.method==='Runtime.exceptionThrown')logs.push('EXCEPTION: '+(m.params.exceptionDetails&&m.params.exceptionDetails.text)+' '+JSON.stringify(m.params.exceptionDetails&&m.params.exceptionDetails.exception&&m.params.exceptionDetails.exception.description||''));
    if(m.method==='Network.loadingFailed')logs.push('NETFAIL '+m.params.type+': '+m.params.errorText);
  };
  await send('Network.enable');await send('Page.enable');await send('Log.enable');await send('Runtime.enable');
  await send('Network.setCookie',{name:'_ezagent_web_key',value:COOKIE,domain:'world.localhost',path:'/',httpOnly:true});
  await send('Page.navigate',{url:SHOT_URL});
  await new Promise(r=>setTimeout(r,WAIT_MS));
  const ev=await send('Runtime.evaluate',{expression:'JSON.stringify({title:document.title, bodyLen:document.body.innerText.length, text:document.body.innerText.slice(0,500), hasReactRoot: !!document.querySelector("#root,#app,[data-phx-main]"), spinners: document.querySelectorAll("svg,.animate-spin,[class*=spin]").length})',returnByValue:true});
  console.log('=== PAGE ===');console.log(ev.result.value);
  console.log('=== LOGS ('+logs.length+') ===');console.log(logs.slice(0,25).join('\n'));
  ws.close();process.exit(0);
}
main().catch(e=>{console.error('DIAG_ERR '+e.message);process.exit(1);});
