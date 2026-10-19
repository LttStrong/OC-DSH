--[[----------------------------------------------------------------------------
  oc/dsk-config.example.lua —— 直连模式(dsk.lua)的配置

  用法:把本文件复制成 dsk-config.lua,填上 apiKey,和 dsk.lua 一起放到
        OC 电脑的 /home/ 下(面板服就用 SFTP 传,或游戏内 edit 粘贴)。

  ⚠️ 这个文件里有你的 API key。它存在服务器的存档文件里,
     任何能读到服务端文件的人都能看到。这是"面板服无终端"场景必须付出的代价。
     如果哪天能装东西了,建议改用中转服务方案(OC 不接触 key)。
----------------------------------------------------------------------------]]

return {
  -- ====== 必填 ======
  -- 去 https://platform.deepseek.com 生成,形如 sk-xxxxxxxx
  apiKey = "sk-填你自己的api",

  -- ====== 可选 ======
  -- 上游接口
  apiHost = "api.deepseek.com",     -- 只写域名,不要带 https://
  apiPath = "/chat/completions",
  model = "deepseek-chat",          -- 或 "deepseek-reasoner"(更慢)
  temperature = 0.7,
  maxTokens = 900,
  timeoutSeconds = 120,             -- 网络超时

  -- 会话(存在电脑本地,按 sessionId 分文件)
  sessionId = "oc1",
  historyLimit = 20,                -- 保留多少条历史消息
  saveHistory = true,               -- 是否把对话存到 /home/oc-chat-history-<id>.tbl
}
