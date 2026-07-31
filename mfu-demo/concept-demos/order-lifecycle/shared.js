const PAGE_META=[
  ['issuer','1 订单进入','📮 发单方'],
  ['decomposer','2 拆成步骤','🧩 拆单方'],
  ['matching','3 平台匹配','🦄 匹配结果'],
  ['hunter','4 猎人完成','🏹 猎人'],
  ['review','5 汇总初验','📦 拆单方'],
  ['evaluation','6 最终评价','✅ 发单方'],
  ['network','7 联系上下游','🤝 人类猎人'],
  ['organization','8 形成组织','🏢 组织']
];
const PAGE_FILE={issuer:'01-issuer.html',decomposer:'02-decomposer.html',matching:'03-matching.html',hunter:'04-hunter.html',review:'05-review.html',evaluation:'06-evaluation.html',network:'07-network.html',organization:'08-organization.html',incubator:'09-incubator.html'};
const defaults={
  scene:'school',phase:1,orderPublished:false,topologyPublished:false,matched:false,workProgress:0,workSubmitted:false,
  initialReview:false,finalEvaluated:false,invites:[],organizationCreated:false,incubatorDecision:'',
  subtasks:[
    {id:'goal',name:'理解目标与选择渠道',output:'渠道选择与判断标准',route:null,status:'待安排'},
    {id:'material',name:'准备实验素材',output:'可投放的图文素材',route:null,status:'待安排'},
    {id:'run',name:'执行渠道实验',output:'实验记录与原始数据',route:null,status:'待安排'},
    {id:'data',name:'整理实验数据',output:'数据表与对比图',route:null,status:'待安排'},
    {id:'judge',name:'判断结果并写建议',output:'结论与下游建议',route:null,status:'待安排'}
  ],
  chat:[
    {who:'拆单方 · 林老师',text:'大家好，这里是旧书店订单协作群。有接口问题直接在这里沟通。'},
    {who:'纸飞机 · 视觉方案',text:'主视觉和三种尺寸模板已经上传，增长实验可以直接使用。'}
  ],
  order:{title:'为社区旧书店设计一次开学季增长计划',goal:'让更多大学生发现旧书循环服务，并在两周内完成第一次购买。',budget:6000,due:'两周后',criteria:'方案能够执行；包含视觉、内容、渠道实验和数据复盘。'},
  steps:[
    {id:1,name:'用户洞察',output:'访谈摘要与用户画像',owner:'阿青',status:'等待中'},
    {id:2,name:'视觉方案',output:'活动主视觉与模板',owner:'纸飞机',status:'等待中'},
    {id:3,name:'内容表达',output:'短内容与长文素材包',owner:'长尾巴',status:'等待中'},
    {id:4,name:'增长验证',output:'渠道实验与数据结论',owner:'我 · 小满',status:'我的步骤'},
    {id:5,name:'整合交付',output:'完整增长计划',owner:'北辰',status:'等待中'}
  ]
};
let state=load();
const page=document.body.dataset.page;

function load(){
  try{
    const saved=JSON.parse(localStorage.getItem('mfu-role-state')||'{}');
    return {...structuredClone(defaults),...saved,subtasks:saved.subtasks||structuredClone(defaults.subtasks),chat:saved.chat||structuredClone(defaults.chat)}
  }
  catch{return structuredClone(defaults)}
}
function save(){localStorage.setItem('mfu-role-state',JSON.stringify(state))}
function reset(){localStorage.removeItem('mfu-role-state');state=structuredClone(defaults);location.reload()}
function h(s=''){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function toast(msg){document.querySelector('.toast')?.remove();const el=document.createElement('div');el.className='toast';el.textContent=msg;document.body.append(el);setTimeout(()=>el.remove(),1800)}
function sceneName(){return state.scene==='school'?'在校期间':'真实社会'}
function roleContext(a,b){return state.scene==='school'?a:b}
function setScene(scene){state.scene=scene;save();render()}
function go(next){state.phase=Math.max(state.phase,PAGE_META.findIndex(x=>x[0]===next)+1);save();location.href=PAGE_FILE[next]}
function complete(flag,next,message){state[flag]=true;save();toast(message);setTimeout(()=>go(next),650)}
function shell(){
  const current=Math.max(0,PAGE_META.findIndex(x=>x[0]===page));
  document.querySelector('#app').innerHTML=`
    <div class="wrap">
      <header class="paper topbar">
        <div class="brand"><b>🦄 MFU · 角色操作台</b><small>一个订单 → 一群猎人 → 一些组织</small></div>
        <span class="tag ${state.scene==='school'?'school':'incu'}">${sceneName()}</span>
        <div class="spacer"></div>
        <div class="scene"><a class="btn small demo-back" href="../../versions/v0.15/demo/MFU-v0.15-可试玩原型.html">← 返回可玩 Demo</a><button class="btn small ${state.scene==='school'?'primary':''}" data-scene="school">🏫 在校</button><button class="btn small ${state.scene==='society'?'primary':''}" data-scene="society">🏙️ 社会</button><button class="btn small" id="reset">↺ 重置</button></div>
      </header>
      <nav class="progress">${PAGE_META.map((x,i)=>`<a href="${PAGE_FILE[x[0]]}" class="${x[0]===page?'current':i<state.phase-1?'complete':''}">${x[1]}</a>`).join('')}</nav>
      <div class="layout">
        <aside class="paper sidebar">
          <h2>角色页面</h2>
          ${PAGE_META.map(x=>`<a class="role-link ${x[0]===page?'current':''}" href="${PAGE_FILE[x[0]]}">${x[2]}<small>${x[1]}</small></a>`).join('')}
          <a class="role-link ${page==='incubator'?'current':''}" href="${PAGE_FILE.incubator}">🏭 孵化器<small>发现与筛选组织</small></a>
        </aside>
        <main class="paper main" id="screen"></main>
      </div>
      <p class="footer">订单全生命周期原型 · 当前状态保存在本浏览器 · 可随时返回 MFU v0.15 继续经营</p>
    </div>`;
  document.querySelectorAll('[data-scene]').forEach(b=>b.onclick=()=>setScene(b.dataset.scene));
  document.querySelector('#reset').onclick=reset;
}
function head(icon,title,sub,status='待操作'){
  return `<header class="page-head"><div class="page-icon">${icon}</div><div><h1>${title}</h1><p>${sub}</p></div><div class="status"><span class="tag gold">${status}</span><p>${sceneName()}</p></div></header>`;
}
function topology(){
  return `<div class="topology"><svg viewBox="0 0 950 300" preserveAspectRatio="none"><path d="M170 147 L225 70 M170 147 L225 225 M370 70 L440 147 M370 225 L440 147 M585 147 L660 147"/></svg>${state.steps.map((s,i)=>`<div class="node n${i+1} ${i===3?'mine':''} ${state.workSubmitted&&i===3?'done':''}"><b>${i+1}. ${h(s.name)}</b>${h(s.owner)}<br>${h(s.status)}</div>`).join('')}</div>`;
}
function issuer(){
  const published=state.orderPublished;
  return head('📮','发单方：发布一个完整订单',roleContext('老师把跨专业实践题发布到课余任务市场。','企业提出真实需求，并说明预算、时间和完整验收标准。'),published?'已发布':'草稿')+
  `<div class="mission">本页要完成的操作：把一个真实问题写成猎人可以理解、拆单方可以继续设计的完整订单。</div>
  <div class="grid"><section class="card"><h2>订单内容</h2>
    <div class="field"><label>订单名称</label><input id="orderTitle" value="${h(state.order.title)}"></div>
    <div class="field"><label>希望解决什么问题？</label><textarea id="orderGoal">${h(state.order.goal)}</textarea></div>
    <div class="grid"><div class="field"><label>奖金池</label><input id="orderBudget" type="number" value="${state.order.budget}"></div><div class="field"><label>截止时间</label><select id="orderDue">${['两周后','四周后','本学期末'].map(d=>`<option ${state.order.due===d?'selected':''}>${d}</option>`).join('')}</select></div></div>
    <div class="field"><label>完整结果的验收标准</label><textarea id="orderCriteria">${h(state.order.criteria)}</textarea></div>
  </section><section class="stack">
    <div class="card"><h2>${roleContext('🏫 教学设置','🏙️ 商业设置')}</h2><div class="checklist">
      ${roleContext('<label class="check"><input type="checkbox" checked>这是一项课余实践，不要求学生先上完课程</label><label class="check"><input type="checkbox" checked>需要设计、内容、增长等不同能力共同完成</label>','<label class="check"><input type="checkbox" checked>允许 freelancer 或其 Agent 承接步骤</label><label class="check"><input type="checkbox" checked>接受孵化器、协会或平台协助拆单</label>')}
    </div></div>
    <div class="card ${published?'success':''}"><h2>发布前检查</h2><ul><li>目标可以被理解</li><li>预算和时间明确</li><li>最终验收标准明确</li></ul>${published?'<p style="margin-top:9px"><span class="stamp">已发布</span></p>':''}</div>
  </section></div>
  <div class="actions"><button class="btn" id="saveDraft">保存草稿</button><button class="btn primary" id="publish">${published?'重新发布':'托管奖金并发布'}</button></div>`;
}
function bindIssuer(){
  const collect=()=>{state.order={title:orderTitle.value,goal:orderGoal.value,budget:+orderBudget.value,due:orderDue.value,criteria:orderCriteria.value};save()};
  saveDraft.onclick=()=>{collect();toast('草稿已保存')};
  publish.onclick=()=>{collect();if(!state.order.title.trim()||!state.order.goal.trim())return toast('请先写清订单名称和目标');complete('orderPublished','decomposer','订单已经进入市场')};
}
function decomposer(){
  return head('🧩','拆单方：把订单设计成步骤拓扑',roleContext('多专业老师共同设计步骤、依赖和局部验收标准。','孵化器、协会或平台工作人员把企业订单拆成可协作步骤。'),state.topologyPublished?'已发布':'编辑中')+
  `<div class="mission">你对完整结构负责。猎人以后只需要完成平台交给自己的那一步。</div>
  <div class="grid"><section class="card"><h2>原始订单</h2><h3>${h(state.order.title)}</h3><p>${h(state.order.goal)}</p><p style="margin-top:7px"><span class="tag gold">¥${state.order.budget.toLocaleString()}</span> <span class="tag gray">${h(state.order.due)}</span></p><p style="margin-top:7px">最终标准：${h(state.order.criteria)}</p></section>
  <section class="card"><h2>拆单检查</h2><div class="checklist"><label class="check"><input type="checkbox" class="topoCheck">每一步都有明确输出</label><label class="check"><input type="checkbox" class="topoCheck">上下游输入能够衔接</label><label class="check"><input type="checkbox" class="topoCheck">不同能力的猎人可以独立完成</label></div></section></div>
  <section class="card" style="margin-top:10px"><h2>步骤拓扑编辑器</h2><p style="margin-bottom:7px">当前原型可以修改步骤名称和输出。正式版中，步骤卡可以自由移动，也可以新增、删除或改接步骤之间的连线。</p><div class="step-list">${state.steps.map((s,i)=>`<div class="step-row"><div class="step-no">${i+1}</div><div><b contenteditable="true" data-step-name="${i}">${h(s.name)}</b><small contenteditable="true" data-step-output="${i}">输出：${h(s.output)}</small></div><span class="tag ${i===3?'gold':'gray'}">${i===3?'可独立匹配':'步骤'}</span></div>`).join('')}</div><div style="margin-top:9px">${topology()}</div></section>
  <div class="actions"><button class="btn" id="addStep">＋增加步骤</button><button class="btn primary" id="publishTopology">确认拓扑并发布</button></div>`;
}
function bindDecomposer(){
  addStep.onclick=()=>toast('v0.15 示例保持 5 个步骤；正式版可继续增加');
  publishTopology.onclick=()=>{
    if([...document.querySelectorAll('.topoCheck')].some(x=>!x.checked))return toast('请先完成三项拆单检查');
    document.querySelectorAll('[data-step-name]').forEach(el=>state.steps[+el.dataset.stepName].name=el.textContent.trim());
    document.querySelectorAll('[data-step-output]').forEach(el=>state.steps[+el.dataset.stepOutput].output=el.textContent.replace(/^输出[：:]\s*/,'').trim());
    save();complete('topologyPublished','matching','步骤拓扑已发布，平台开始匹配')
  };
}
function matching(){
  return head('🦄','平台匹配：猎人收到一个步骤','平台自动完成匹配；真人只需要确认是否承接。平台暂不解释算法，也不显示总分。',state.matched?'已承接':'等待确认')+
  `<div class="mission">系统消息：根据你的成长证据和可用时间，为你匹配到步骤 4「增长验证」。</div>${topology()}
  <div class="grid" style="margin-top:10px"><section class="card selected"><h2>我的步骤：增长验证</h2><p>输入：视觉方案、内容素材包<br>输出：渠道实验、数据结论与给整合环节的建议。</p><p style="margin-top:7px"><span class="tag assoc">预计 4 小时</span> <span class="tag school">增长实践</span></p></section><section class="card"><h2>同单协作者</h2><p>阿青 · 用户洞察　纸飞机 · 视觉方案<br>长尾巴 · 内容表达　北辰 · 整合交付</p><p style="margin-top:7px">所有协作者都可以进入订单聊天室，讨论接口和交付。</p></section></div>
  <div class="actions"><button class="btn danger" id="decline">暂时无法承接</button><button class="btn good" id="accept">${state.matched?'进入工作台':'确认承接'}</button></div>`;
}
function bindMatching(){decline.onclick=()=>toast('平台会寻找下一名猎人；本原型保留当前匹配');accept.onclick=()=>state.matched?go('hunter'):complete('matched','hunter','你已承接步骤 4')};
function hunter(){
  const done=state.subtasks.filter(x=>x.status==='已完成').length;
  const p=Math.round(done/state.subtasks.length*100);
  state.workProgress=p;
  return head('🏹','猎人工作台：只完成自己的步骤','你可以调用 AI 伙伴执行，但理解问题、判断结果和最终提交仍由你负责。',state.workSubmitted?'已提交':`完成 ${p}%`)+
  `<div class="mission">当前目标：完成一次小规模渠道实验。先把自己的步骤拆开，再决定每项由本人、AI 伙伴或其他猎人完成。</div>
  <div class="grid"><section class="card"><h2>我的输入</h2><div class="step-list"><div class="step-row"><div class="step-no">2</div><div><b>视觉方案</b><small>纸飞机已交付 · 可在群聊中沟通</small></div><span class="tag done">可使用</span></div><div class="step-row"><div class="step-no">3</div><div><b>内容素材包</b><small>长尾巴已交付 · 可在群聊中沟通</small></div><span class="tag done">可使用</span></div></div></section>
  <section class="card chat"><div class="chat-head"><h2 style="margin:0">💬 订单聊天室</h2><span class="tag assoc">5 人 + AI</span></div><div class="chat-messages">${state.chat.map((m,i)=>`<div class="msg ${m.who==='我 · 小满'?'me':m.who.includes('AI')?'ai':''}"><small>${h(m.who)}</small>${h(m.text)}</div>`).join('')}</div><div class="chat-send"><input id="chatInput" placeholder="问协作者，或同步当前进度"><button class="btn small" id="chatSend">发送</button></div></section></div>
  <section class="card" style="margin-top:10px"><h2>任务内路由：每一项谁来完成？</h2><p style="margin-bottom:8px">外包会把这一项发布成子任务，形成一次新的“拆分—匹配—完成”小循环。</p><div class="route-board">${state.subtasks.map((s,i)=>routeRow(s,i)).join('')}</div><div style="margin-top:9px"><div class="meter"><i style="width:${p}%"></i></div><p style="margin-top:5px">${done}/${state.subtasks.length} 项已完成。外包不会转移你的责任，你仍要检查和汇总全部结果。</p></div></section>
  <section class="card" style="margin-top:10px"><h2>提交给下游</h2><div class="field"><label>我的结论</label><textarea id="finding">校园社群对“旧书换新主人”的故事表达响应最好，建议先投放社群，再用海报承接。</textarea></div><div class="field"><label>交付物</label><input value="渠道实验记录-v1.pdf"></div></section>
  <div class="actions"><button class="btn primary" id="submitWork" ${p<100?'disabled':''}>提交我的步骤</button></div>`;
}
function routeRow(s,i){
  const labels={self:'👤 本人',agent:'🤖 小角',outsource:'📮 外包'};
  const stateTag=s.status==='已完成'?'done':s.status==='执行中'?'gold':s.route==='outsource'?'incu':'gray';
  let action='';
  if(!s.route)action='';
  else if(s.status==='已完成')action='<span class="tag done">已完成</span>';
  else if(s.route==='outsource'&&s.status==='待匹配')action=`<button class="btn small" data-outsource="${i}">查看匹配</button>`;
  else if(s.route==='outsource'&&s.status==='执行中')action=`<button class="btn small good" data-finish="${i}">收回成果</button>`;
  else action=`<button class="btn small good" data-finish="${i}">完成这一项</button>`;
  return `<div class="route-item ${s.status==='已完成'?'done':''}"><div class="step-no">${i+1}</div><div class="route-name"><b>${h(s.name)}</b><small>输出：${h(s.output)}</small></div><div class="route-options">${['self','agent','outsource'].map(k=>`<button class="route-pick ${k==='outsource'?'out':''} ${s.route===k?'on':''}" data-route="${k}" data-index="${i}" ${s.status==='已完成'?'disabled':''}>${labels[k]}${k==='self'?'<small> · 1 时间</small>':k==='agent'?'<small> · 12 算力</small>':''}</button>`).join('')}</div><div class="route-state"><span class="tag ${stateTag}">${h(s.status)}</span><div style="margin-top:5px">${action}</div></div></div>`;
}
function bindHunter(){
  document.querySelectorAll('[data-route]').forEach(b=>b.onclick=()=>{
    const s=state.subtasks[+b.dataset.index];
    if(b.dataset.route==='outsource')return openOutsource(+b.dataset.index);
    s.route=b.dataset.route;s.status='执行中';s.worker=b.dataset.route==='self'?'我 · 小满':'AI 伙伴 · 小角';save();render();toast(`已安排给${s.worker}`);
  });
  document.querySelectorAll('[data-finish]').forEach(b=>b.onclick=()=>{const s=state.subtasks[+b.dataset.finish];s.status='已完成';save();render();toast(s.route==='outsource'?`${s.worker}的成果已收回，请记得检查`:'这一项已完成')});
  document.querySelectorAll('[data-outsource]').forEach(b=>b.onclick=()=>openOutsource(+b.dataset.outsource,true));
  chatSend.onclick=sendChat;chatInput.onkeydown=e=>{if(e.key==='Enter')sendChat()};
  submitWork.onclick=()=>complete('workSubmitted','review','步骤已经提交给拆单方');
}
function sendChat(){
  const text=chatInput.value.trim();if(!text)return;
  state.chat.push({who:'我 · 小满',text});chatInput.value='';save();render();
}
function openOutsource(index,matching=false){
  const s=state.subtasks[index];
  const layer=document.createElement('div');layer.className='overlay';
  layer.innerHTML=`<div class="modal"><h2>${matching?'🏹 确认子任务协作者':'📮 把这一项外包给其他猎人'}</h2>
    ${matching?`<p style="font-size:11px;font-weight:700;line-height:1.7">平台根据“${h(s.name)}”的要求找到了两名候选猎人。你可以查看公开能力证据并确认协作者。</p>
      <div class="candidate"><div class="avatar">🧪</div><div><b>阿策 · 增长实验猎人</b><small>相关交付 8 次 · 按时率 94% · 报价 ¥380</small></div><button class="btn small primary chooseHunter" data-name="阿策">选择</button></div>
      <div class="candidate"><div class="avatar">📊</div><div><b>小数点 · 数据猎人</b><small>相关交付 5 次 · 按时率 100% · 报价 ¥450</small></div><button class="btn small chooseHunter" data-name="小数点">选择</button></div>`
    :`<div class="field"><label>子任务</label><input value="${h(s.name)}" disabled></div><div class="field"><label>需要交回什么？</label><textarea id="outOutput">${h(s.output)}</textarea></div><div class="grid"><div class="field"><label>奖金</label><input id="outBudget" type="number" value="400"></div><div class="field"><label>截止时间</label><select><option>24 小时内</option><option>两天内</option></select></div></div><div class="field"><label>验收要求</label><textarea>结果可以直接并入增长验证步骤，并说明使用的数据来源。</textarea></div>`}
    <div class="actions"><button class="btn closeLayer">取消</button>${matching?'':'<button class="btn primary publishSub">发布子任务</button>'}</div></div>`;
  document.body.append(layer);
  layer.querySelector('.closeLayer').onclick=()=>layer.remove();
  if(!matching)layer.querySelector('.publishSub').onclick=()=>{s.route='outsource';s.status='待匹配';s.budget=+layer.querySelector('#outBudget').value;s.output=layer.querySelector('#outOutput').value;save();layer.remove();render();toast('子任务已发布，平台正在匹配')};
  layer.querySelectorAll('.chooseHunter').forEach(b=>b.onclick=()=>{s.route='outsource';s.status='执行中';s.worker=b.dataset.name;s.hunter=b.dataset.name;state.chat.push({who:`${b.dataset.name} · 外包协作者`,text:`我已承接“${s.name}”，会在约定时间内把成果发回群聊。`});save();layer.remove();render();toast(`${b.dataset.name}已加入协作`)});
}
function review(){
  return head('📦','拆单方：汇总步骤并进行初验','逐步检查局部标准，把不合格的步骤退回，最后拼成一个完整结果。',state.initialReview?'初验通过':'待初验')+
  `<div class="mission">你不是重新完成所有工作，而是检查接口是否接得上、完整订单是否能够形成。</div>
  <div class="grid"><section class="card"><h2>步骤看板</h2><div class="step-list">${state.steps.map((s,i)=>`<div class="step-row"><div class="step-no">${i+1}</div><div><b>${h(s.name)}</b><small>${h(s.output)}</small></div><span class="tag ${i===3||state.initialReview?'done':'gray'}">${i===3||state.initialReview?'已提交':'等待中'}</span></div>`).join('')}</div></section>
  <section class="stack"><div class="card selected"><h2>正在初验：增长验证</h2><p>结论：校园社群的故事表达响应最好。<br>附件：渠道实验记录-v1.pdf</p><div class="checklist" style="margin-top:8px"><label class="check"><input type="checkbox" class="reviewCheck">有可追溯的数据</label><label class="check"><input type="checkbox" class="reviewCheck">结论回应订单目标</label><label class="check"><input type="checkbox" class="reviewCheck">给下游明确建议</label></div></div><div class="card"><h2>完整成果预览</h2><p>用户洞察 → 视觉与内容 → 增长验证 → 开学季增长计划</p></div></section></div>
  <div class="actions"><button class="btn danger" id="returnWork">退回修改</button><button class="btn primary" id="approveReview">通过并汇总整单</button></div>`;
}
function bindReview(){returnWork.onclick=()=>toast('已写入修改意见：补充样本范围');approveReview.onclick=()=>{if([...document.querySelectorAll('.reviewCheck')].some(x=>!x.checked))return toast('请先完成三项局部检查');complete('initialReview','evaluation','完整成果已交给发单方')}};
function evaluation(){
  return head('✅','发单方：验收完整结果并给出真实反馈','评价会成为猎人和组织的成长证据，而不是只留下一个总分。',state.finalEvaluated?'已评价':'待评价')+
  `<div class="mission">请回到发布订单时写下的目标与标准，判断完整成果是否真的解决问题。</div>
  <div class="grid"><section class="card"><h2>完整交付物</h2><h3>《旧书店开学季增长计划》</h3><ul><li>用户访谈与用户画像</li><li>活动视觉和内容素材</li><li>渠道实验与数据结论</li><li>两周执行排期</li></ul><p style="margin-top:7px"><button class="btn small">查看完整成果</button></p></section>
  <section class="card"><h2>评价表</h2><div class="field"><label>是否达到完整验收标准？</label><select id="decision"><option value="">请选择</option><option value="pass">通过</option><option value="revise">修改后通过</option><option value="fail">未通过</option></select></div><div class="field"><label>最有价值的反馈</label><textarea id="feedback">渠道选择有数据支持；下一轮需要扩大样本，并说明预算如何分配。</textarea></div><div class="field"><label>本次真实表现</label><select><option>达到预期</option><option>超出预期</option><option>仍需辅导</option></select></div></section></div>
  ${state.finalEvaluated?'<div class="card success" style="margin-top:10px"><h2>反馈已进入成长证据</h2><p>经验：完整交付 +1　信誉：按时履约 +4　作品：增长计划 +1<br>成长树是否点亮，仍需依据作品证据单独评价。</p></div>':''}
  <div class="actions"><button class="btn primary" id="sendEvaluation">${state.finalEvaluated?'查看上下游':'确认评价并发送反馈'}</button></div>`;
}
function bindEvaluation(){sendEvaluation.onclick=()=>state.finalEvaluated?go('network'):(decision.value?complete('finalEvaluated','network','真实反馈已发送给所有猎人'):toast('请先选择验收结果'))};
function network(){
  const invited=state.invites.length;
  return head('🤝','人类猎人：联系自己的上下游','完成任务后才解锁相邻猎人的公开名片。AI 伙伴不能主动联系或发起邀请。',invited?'邀请已发出':'可联系')+
  `<div class="mission">你在步骤 4「增长验证」。现在可以认识步骤 2、3 和 5 的猎人，寻找愿意长期合作的人。</div>
  <div class="grid three">${[
    ['🎨','视觉方案猎人','视觉交付 6 次 · 按时率 92%','2'],
    ['✍️','内容表达猎人','内容交付 9 次 · 客户好评 7 次','3'],
    ['📦','整合交付猎人','项目统筹 4 次 · 返工率低','5']
  ].map(x=>`<article class="card ${state.invites.includes(x[3])?'success':''}"><div class="person"><div class="avatar">${x[0]}</div><div><b>${x[1]}</b><small>${x[2]}</small></div><span class="tag assoc">步骤 ${x[3]}</span></div><p style="margin-top:8px">你们刚刚在同一订单中形成直接上下游关系。</p><div class="actions"><button class="btn small invite" data-person="${x[3]}">${state.invites.includes(x[3])?'已邀请':'发出合作邀请'}</button></div></article>`).join('')}</div>
  <section class="card warning" style="margin-top:10px"><h2>🤖 AI 伙伴的边界</h2><p>AI 可以替你整理对方的公开资料、起草邀请内容，但“联系谁、为什么合作、是否成立组织”必须由你本人决定。</p></section>
  <div class="actions"><button class="btn primary" id="toOrg" ${invited?'':'disabled'}>查看邀请回复</button></div>`;
}
function bindNetwork(){document.querySelectorAll('.invite').forEach(b=>b.onclick=()=>{if(!state.invites.includes(b.dataset.person))state.invites.push(b.dataset.person);save();render();toast('邀请已由你本人发出')});toOrg.onclick=()=>go('organization')};
function organization(){
  return head('🏢','组建组织：把一次合作变成长期能力','对方接受邀请后，成员共同确认名称、分工和第一类完整订单。',state.organizationCreated?'组织已成立':'等待确认')+
  `<div class="mission">组织不是平台自动生成的随机小组，而是猎人在真实合作后主动选择的长期伙伴。</div>
  <div class="grid"><section class="card"><h2>待确认成员</h2><div class="stack"><div class="person"><div class="avatar">🏹</div><div><b>小满 · 发起人</b><small>增长验证与最终判断</small></div><span class="tag done">已确认</span></div><div class="person"><div class="avatar">🎨</div><div><b>纸飞机 · 视觉猎人</b><small>同意继续合作</small></div><span class="tag done">已接受</span></div><div class="person"><div class="avatar">🤖</div><div><b>小角 · AI 伙伴</b><small>归属于小满，不拥有发起权</small></div><span class="tag gray">协作资产</span></div></div></section>
  <section class="card"><h2>组织档案</h2><div class="field"><label>组织名称</label><input id="orgName" value="折角工作室"></div><div class="field"><label>我们擅长完成什么订单？</label><textarea id="orgPromise">为校园与社区品牌完成从内容表达、视觉设计到增长验证的整合项目。</textarea></div><div class="checklist"><label class="check"><input type="checkbox" id="orgRule">所有人确认分工和作品归属</label></div></section></div>
  ${state.organizationCreated?'<div class="card success" style="margin-top:10px"><h2><span class="stamp">组织成立</span></h2><p style="margin-top:10px">组织档案已建立。下一轮市场匹配中，折角工作室可以尝试承接更完整的订单。</p></div>':''}
  <div class="actions"><button class="btn primary" id="createOrg">${state.organizationCreated?'进入孵化器视角':'共同确认并创建组织'}</button></div>`;
}
function bindOrganization(){createOrg.onclick=()=>{if(state.organizationCreated)return location.href=PAGE_FILE.incubator;if(!orgRule.checked)return toast('请先确认分工和作品归属');complete('organizationCreated','incubator','折角工作室已经成立')}};
function incubator(){
  return head('🏭','孵化器：发现并筛选候选组织','孵化器查看真实合作证据，必要时追加验证任务，再由真人决定是否邀请。',state.incubatorDecision||'待筛选')+
  `<div class="mission">平台帮助你发现候选组织，但不会用一个总分替你作出孵化决定。</div>
  <div class="grid"><section class="card"><div class="person"><div class="avatar">🏢</div><div><b>折角工作室</b><small>2 名人类成员 · 1 个 AI 伙伴</small></div><span class="tag incu">新组织</span></div><div class="step-list" style="margin-top:9px"><div class="step-row"><div class="step-no">1</div><div><b>真实订单证据</b><small>完成旧书店增长计划 · 发单方通过</small></div><span class="tag done">可查</span></div><div class="step-row"><div class="step-no">2</div><div><b>协作证据</b><small>从随机上下游形成双向邀请</small></div><span class="tag done">可查</span></div><div class="step-row"><div class="step-no">3</div><div><b>人机贡献记录</b><small>判断归人，数据整理归 AI</small></div><span class="tag done">可查</span></div></div></section>
  <section class="card"><h2>孵化判断</h2><div class="field"><label>还需要验证什么？</label><select><option>给出一项更复杂的完整订单</option><option>验证现金流与报价能力</option><option>不需要追加验证</option></select></div><div class="field"><label>给候选组织的说明</label><textarea>你们已证明跨专业协作能力。下一步希望验证能否独立报价并负责完整交付。</textarea></div><div class="actions"><button class="btn danger decision" data-decision="暂不邀请">暂不邀请</button><button class="btn decision" data-decision="追加验证">发验证任务</button><button class="btn primary decision" data-decision="进入预备营">邀请进入预备营</button></div></section></div>
  ${state.incubatorDecision?`<div class="card success" style="margin-top:10px"><h2>真人决定：${h(state.incubatorDecision)}</h2><p>决定已经写入候选档案。组织仍可继续经营并积累新的证据。</p></div>`:''}`;
}
function bindIncubator(){document.querySelectorAll('.decision').forEach(b=>b.onclick=()=>{state.incubatorDecision=b.dataset.decision;save();render();toast('孵化判断已记录')})}
function render(){
  shell();
  const views={issuer,decomposer,matching,hunter,review,evaluation,network,organization,incubator};
  document.querySelector('#screen').innerHTML=views[page]();
  ({issuer:bindIssuer,decomposer:bindDecomposer,matching:bindMatching,hunter:bindHunter,review:bindReview,evaluation:bindEvaluation,network:bindNetwork,organization:bindOrganization,incubator:bindIncubator})[page]();
}
render();
