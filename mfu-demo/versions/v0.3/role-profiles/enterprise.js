window.MFU_ROLE_PROFILES ??= {};
window.MFU_ROLE_PROFILES.enterprise = {
  roleId: "enterprise",
  label: "企业创新负责人",
  subtitle: "把员工、专家、Agent、数据和 IP 组合成高效的项目 MVO",
  brand: "🏢 谷雨食品 · 创新实验室",
  reputationLabel: "企业信誉",
  reputation: 592,
  recommendedIndustries: ["消费与零售", "软件与 AI", "内容与品牌"],
  initial: {
    cash: 68000,
    compute: 520,
    coachHours: 1,
    tasks: [
      {id:"enterprise-retail",icon:"🧃",name:"新品便利店试销",client:"谷雨食品渠道部",reward:"¥12,000",difficulty:"进阶",industry:"消费与零售",status:"unassigned",orgId:null,quotedAmount:12000,invoiceStatus:"not_issued",paymentStatus:"not_due",cost:0,income:0},
      {id:"enterprise-ai",icon:"🧠",name:"客服知识库验证",client:"客户体验部",reward:"¥9,600",difficulty:"进阶",industry:"软件与 AI",status:"running",orgId:"enterprise-service",quotedAmount:9600,invoiceStatus:"not_issued",paymentStatus:"not_due",cost:1800,income:0}
    ],
    orgs: [
      {id:"enterprise-product",icon:"🧃",name:"新品验证 MVO",level:5,status:"working",task:"零糖茶概念测试",progress:76,eta:"预计 1 天",steps:["洞察","打样","试销"],gems:["👩‍💼","🧪","📊"]},
      {id:"enterprise-service",icon:"🎧",name:"智能客服 MVO",level:4,status:"working",task:"客服知识库验证",progress:43,eta:"预计 3 天",steps:["整理","生成","质检"],gems:["👨‍💻","🤖","📚"]},
      {id:"enterprise-brand",icon:"✨",name:"品牌增长 MVO",level:4,status:"idle",task:null,progress:0,eta:"",steps:["策略","内容","投放"],gems:["👩‍💼","✍️","📈"]}
    ],
    people: [
      {id:"enterprise-pm",icon:"👩‍💼",name:"陈澄 · 产品经理",ability:78,experience:26,cert:"产品验证认证",portfolio:9,status:"新品验证 MVO"},
      {id:"enterprise-data",icon:"🧑‍🔬",name:"顾远 · 数据专家",ability:81,experience:29,cert:"数据认证",portfolio:11,status:"新品验证 MVO"},
      {id:"enterprise-dev",icon:"👨‍💻",name:"陆山 · AI 工程",ability:76,experience:22,cert:"AI 应用认证",portfolio:7,status:"智能客服 MVO"}
    ],
    agents: [
      {id:"enterprise-agent-customer",icon:"🤖",name:"客户洞察 Agent",ability:7.2,assets:8,status:"新品验证 MVO",history:["复盘：新品试销偏差"]},
      {id:"enterprise-agent-service",icon:"🎧",name:"客服 Agent",ability:6.8,assets:6,status:"智能客服 MVO",history:["写守则：敏感问题转人工"]}
    ],
    assets: [
      {id:"enterprise-data-crm",icon:"🗃️",name:"CRM 数据集",kind:"IP / 数据",meta:"企业内部 · 受控"},
      {id:"enterprise-ip-brand",icon:"®️",name:"品牌资产库",kind:"IP",meta:"企业自有"},
      {id:"enterprise-tool-bi",icon:"📊",name:"BI 实验工具",kind:"工具",meta:"已安装"}
    ],
    actions: [],
    logs: ["W18 · 新品验证 MVO 完成第三轮样品反馈", "W18 · 智能客服 MVO 等待知识库质检"],
    archive: [{orgId:"enterprise-product",task:"春季口味验证",client:"谷雨食品",quality:"A",income:18000}],
    chats: {}
  }
};
