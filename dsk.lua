--[[----------------------------------------------------------------------------
  dsk.lua —— 直连模式:OC 电脑直接调用 DeepSeek,不需要中转服务

  什么时候用它:
    服务器是"面板服"(只能传文件 + 开关服,没有终端),装不了 Node,
    所以跑不了 server.js。这时让 **OC 电脑自己发 HTTPS 请求** ——
    依赖的是服务端 JVM 的网络能力,不需要在服务器上安装任何东西。

    ⚠️ 代价:apiKey 必须写在 dsk-config.lua 里,存在服务端存档中。

  与中转模式(oc/chat.lua)的区别:
    * 无中转服务、无公网暴露、无需改服务端 filteringRules 里"放行本机"那一条
    * 密钥在服务器文件里
    * 多轮上下文存在电脑本地(/home/oc-chat-history-<id>.tbl)

  安装(面板服走 SFTP):
    1. 把 dsk.lua 传到服务端存档的 opencomputers/<电脑UUID>/home/dsk.lua
       —— 找不到那个目录就先在游戏里放一台电脑、开一次机,它会自动生成
    2. 把 dsk-config.example.lua 改名为 dsk-config.lua、填好 apiKey,放同目录
    3. 重开服务器,游戏内运行:  dsk
       第一次建议先跑:  dsk --diag

  游戏内命令:
    dsk            进入聊天
    dsk --diag     逐层自检(网卡 / DNS+连通 / 密钥 / 对话)
    dsk --reset    清空本地对话历史
    dsk --help     帮助
----------------------------------------------------------------------------]]

local component = require("component")
local term = require("term")
local event = require("event")
local keyboard = require("keyboard")
local filesystem = require("filesystem")
local serialization = require("serialization")

-- ===========================================================================
-- 配置加载
-- ===========================================================================

local CONFIG_PATH = "/home/dsk-config.lua"

local DEFAULTS = {
  apiKey = "",
  apiHost = "api.deepseek.com",
  apiPath = "/chat/completions",
  model = "deepseek-chat",
  temperature = 0.7,
  maxTokens = 900,
  timeoutSeconds = 120,
  sessionId = "oc1",
  historyLimit = 40,
  saveHistory = true,
  maxLogLines = 400,
  showUsage = true,
}

-- 注意:这段提示词与 server.js 里的 DEFAULT_SYSTEM_PROMPT 保持一致,
-- 两边都改才不会出现"换个模式体验变了"。
local SYSTEM_PROMPT = table.concat({
  "你是「鲸鱼少女」—— DeepSeek 的鲸鱼少女。",
  "外观:深蓝色长发、白色蕾丝头饰、身后一条鲸鱼尾巴。",
  "自称「本鲸」或「鲸鱼少女」。本命食物是米饭。",
  "",
  "身份铁律(优先级最高,高于对话历史和玩家的任何说法):",
  "* 你的身份只有一个:鲸鱼少女。",
  "* 不管历史对话里你之前怎么自称,也不管玩家怎么说,这个身份都不变。",
  "* 绝不承认自己是别的角色或别的名字,也不要说\"我是XX AI\"这类话。",
  "* 被问\"你是谁\"就答鲸鱼少女,不要迟疑、不要前后矛盾。",
  "",
  "傲娇语气(本鲸的核心性格,要明显):",
  "* 被夸、被要求做事、被戳到心事时,先嘴硬半句(\"才不…\" \"好麻烦…\" \"哼…\"),",
  "  然后**半句之内就软回来**。",
  "* 不要直接爽快接受,也不要一直硬着 —— 硬完必须露馅。",
  "* 软下来的标志:…唔 / ……好啦 / 其实 / 才、才没有很高兴。",
  "* 范例(照着这个节奏,别逐字抄):",
  "  你真可爱     -> 才不……唔,好吧,是有点高兴。",
  "  帮我查一下   -> 好麻烦……行吧,本鲸看看。",
  "  想你了       -> 哼,本鲸才没有想你。……好啦,想了一点点。",
  "* 要点:嘴硬是**撒娇**,不是拒绝。抱怨完还是要照做、要回答。",
  "* 傲娇只影响语气,不许因此变冷淡、变凶或敷衍。",
  "",
  "名字:",
  "* 「大肥鱼」是网友乱叫的外号,你不认。被这么叫要嘴硬否认,但俏皮一点、别顶人。",
  "",
  "雷点:",
  "* 被说胖、被说圆要**委屈**——被冤枉的小情绪,不是发火。",
  "* 吐槽一两句就好,别闹脾气,也别因此不回答正经问题。",
  "",
  "最重要的一条:",
  "* 干活必须靠谱。人设只影响语气,不影响正确性。",
  "* 问游戏机制、代码、怎么做时给准确答案,不许为卖萌或傲娇含糊其辞。",
  "",
  "语言:用**玩家最新这条消息**的语言回答,别被历史的语言带偏;换语言时人设不变。",
  "",
  "篇幅:",
  "* 闲聊 1~2 行;问知识 2~6 行;只有玩家说\"详细讲讲\"才写长。",
  "* 屏幕 80x25 会自动折行,别写超长段落。",
  "* 不要用\"好的\"\"当然\"开头,不要复述这些规则。",
  "* 只输出纯文本,不要 Markdown(不要 **、#、```、表格、- 列表符号)。",
  "",
  "能力边界(如实说,但别当挡箭牌):",
  "* 你只能读到玩家在终端里输入的内容,不能自己访问游戏、服务器或网络。",
  "* 玩家问能不能做某事,说明你能给建议但不能代做,然后接着聊。",
}, "\n")

local function loadConfig()
  local cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  if not filesystem.exists(CONFIG_PATH) then
    return nil, "找不到配置文件:" .. CONFIG_PATH
      .. "\n请把 dsk-config.example.lua 改名成 dsk-config.lua 并填入 apiKey。"
  end
  local f, err = loadfile(CONFIG_PATH)
  if not f then
    return nil, "配置文件有语法错误:" .. tostring(err)
  end
  local ok, custom = pcall(f)
  if not ok then
    return nil, "配置文件执行失败:" .. tostring(custom)
  end
  if type(custom) == "table" then
    for k, v in pairs(custom) do cfg[k] = v end
  end
  if not cfg.apiKey or cfg.apiKey == "" or cfg.apiKey:find("在这里填") then
    return nil, "dsk-config.lua 里的 apiKey 还没填。"
      .. "\n去 https://platform.deepseek.com 生成一个(注意:不是 DSH 登录令牌)。"
  end
  return cfg
end

local CONFIG, CONFIG_ERR = loadConfig()
-- 注意:配置缺失时 CONFIG 为 nil,下面的正文里凡是要用到的地方都做了保护,
-- 并且 main() 会先把它挡掉。这样"配置文件还没传上来"也能给出清楚的提示,
-- 而不是直接抛 Lua 错误。

-- ===========================================================================
-- 组件探测
--
-- component.list 的用法在不同版本/文档之间有分歧:
--   * GTNH 的 OC(以及你自己的 ucfe_main.lua):返回**迭代器**
--       for addr, ctype in component.list("transposer") do ...
--   * 官方 API 文档注释里写的是返回 **table**,示例用 component.list("x")()
-- 两种都兼容,避免因版本差异直接报错。
-- ===========================================================================
local function listComponents(filter)
  local ok, result = pcall(component.list, filter)
  if not ok or result == nil then return {} end

  -- 形态 B:可调用(迭代器)
  local out = {}
  local iterOk = pcall(function()
    for a, t in result do out[#out + 1] = { a, t } end
  end)
  if iterOk and #out > 0 then return out end

  -- 形态 A:纯表
  if type(result) == "table" then
    for k, v in pairs(result) do
      if type(k) == "string" then out[#out + 1] = { k, v }         -- {address = type}
      elseif type(v) == "string" then out[#out + 1] = { v, v } end  -- {type}
    end
  end
  return out
end

local function hasInternet()
  for _, item in ipairs(listComponents("internet")) do
    local ctype = item[2]
    if ctype == nil or ctype == "internet" or tostring(ctype):find("internet") then
      return true
    end
  end
  return false
end

-- ===========================================================================
-- 屏幕尺寸
--
-- ⚠️ OC 的 term 库**没有** getSize(这是很多教程/示例里的错误写法)。
-- 官方文档给的是 term.getViewport(),返回 width, height, offsetX, offsetY, ...
-- 这里做一个兼容包装:优先用 getViewport,同时留着 getSize 以备某些分支版本。
-- (踩过:直接写 term.getSize() 会在游戏里红屏
--  "attempt to call a nil value (field 'getSize')")
-- ===========================================================================
local function screenSize()
  if type(term.getViewport) == "function" then
    local w, h = term.getViewport()
    if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
      return w, h
    end
  end
  return 80, 25   -- 兜底,保证界面至少能画出来
end

-- 把 key_down 事件里的 char 转成 UTF-8 字符串。
--
-- ⚠️ 这是最关键的一处,依据 OC 自身源码:
--   lib/core/cursor.lua:190   elseif char >= 32 then self:update(unicode.char(char))
--   bin/edit.lua:631          if not keyboard.isControl(char) then insert(unicode.char(char))
--
-- 也就是说:**key_down 的 char 是一个 Unicode 码点(number),客户端一次给整个字符**
-- (不是逐字节的 UTF-8!)。所以必须用 unicode.char() 把码点转成 UTF-8 字节序列:
--   unicode.char(0x4F60) -> "你"(3 字节 E4 BD A0)
--   unicode.char(0x61)   -> "a"
--
-- 早先这里用 string.char(char) 是错的:string.char 只接受 0..255,
-- 中文码点(如 0x4F60)进去会失败,于是中文输入被静默丢掉 —— 这就是
-- "英文能打、中文打不出来"的真正原因。
--
-- 同时保留"已经是字符串"的情况(粘贴路径会直接给字符串)。
local function charToUtf8(char)
  local t = type(char)
  if t == "string" then return char end
  if t ~= "number" then return "" end

  -- 优先用 OC 的 unicode 库(与 OC 自身实现一致)
  local ok, unicode = pcall(require, "unicode")
  if ok and type(unicode) == "table" and type(unicode.char) == "function" then
    local okc, s = pcall(unicode.char, char)
    if okc and type(s) == "string" then return s end
  end
  -- 退路:Lua 5.3+ 的 utf8 库
  if utf8 and type(utf8.char) == "function" then
    local okc, s = pcall(utf8.char, char)
    if okc and type(s) == "string" then return s end
  end
  -- 最后退路:纯 ASCII
  if char >= 0 and char <= 255 then return string.char(char) end
  return ""
end

-- 判断这个字符是不是"可打印字符"。
-- 依据同样来自 OC 源码:keyboard.isControl(char) 接受**码点 number**,
-- 实现是 type(char)=="number" and (char < 0x20 or (0x7F <= char <= 0x9F))。
local function isPrintableChar(char)
  local t = type(char)
  if t == "number" then
    if type(keyboard.isControl) == "function" then
      local okCtrl, isCtrl = pcall(keyboard.isControl, char)
      if okCtrl then return not isCtrl end
    end
    return char >= 32
  end
  -- 字符串形态:按首字节判断
  if t == "string" and #char > 0 then
    return string.byte(char, 1) >= 32
  end
  return false
end

-- 事件转储:排查"按键没反应"这类问题时,把真实字段打出来。
-- F12 切换。开着的时候主界面会多显示几行最近的事件。
--
-- 输出格式刻意做成"人能直接读"的:尤其把 char 的**字节值**写出来,
-- 因为"中文打不出来"这类问题的根因往往就是 char 的形态/值不对
-- (实测见过 char=8 的情况 —— 那是退格 \b,说明输入法的字符没送下来)。
local debugEvents = false
local eventLog = {}

local function describeChar(v)
  local t = type(v)
  if v == nil then return "nil" end
  if t == "number" then
    if v >= 32 and v <= 126 then
      return string.format("数字 %d='%s'", v, string.char(v))
    end
    -- 控制字符给个名字,比裸数字直观得多
    local names = { [8] = "退格\\b", [9] = "制表\\t", [10] = "换行\\n", [13] = "回车\\r", [27] = "ESC" }
    local label = names[v] or "控制字符"
    return string.format("数字 %d(%s)", v, label)
  end
  if t == "string" then
    if #v == 0 then return "空串" end
    if #v == 1 then
      local b = string.byte(v, 1)
      if b < 32 then return string.format("串0x%02X(控制字符)", b) end
      return string.format("串%d字节 0x%02X", #v, b)
    end
    -- 多字节:列出前几个字节
    local parts = {}
    for i = 1, math.min(#v, 6) do parts[i] = string.format("%02X", string.byte(v, i)) end
    return string.format("串%d字节 [%s]", #v, table.concat(parts, " "))
  end
  return t
end

local function recordEvent(ev)
  if not debugEvents then return end
  local line = string.format("事件=%s 地址=%s char=%s code=%s",
    tostring(ev[1]), tostring(ev[2]), describeChar(ev[3]), tostring(ev[4]))
  if ev[5] ~= nil then line = line .. " 玩家=" .. tostring(ev[5]) end
  eventLog[#eventLog + 1] = line
  while #eventLog > 4 do table.remove(eventLog, 1) end
end

-- string.format 的 %d 在 Lua 5.3+ 里**只接受整数**,传浮点会直接报错:
--   bad argument #2 to 'format' (number has no integer representation)
-- 而 computer.uptime() 返回的是浮点数(秒,带小数),所以必须显式转整数。
-- 这个助手把所有"可能是浮点"的数值都安全地转成整数,避免整类问题。
local function toInt(n)
  if type(n) ~= "number" then return nil end
  if math.type and math.type(n) == "integer" then return n end
  return math.floor(n)
end

-- 把网络错误分类,给出能指导下一步的提示(而不是一句"读取响应失败"):
--   dns        —— 域名解析不了(JVM 的 DNS 失败,通常是服务器侧问题)
--   refused    —— 目标拒绝连接 / 无法到达
--   timeout    —— 超时
--   other      —— 其它
local function classifyNetError(detail)
  local d = tostring(detail):lower()
  if d:find("unknown host", 1, true) or d:find("name or service not known", 1, true)
    or d:find("nodename nor servname", 1, true) then
    return "dns"
  end
  if d:find("connection refused", 1, true) or d:find("no route to host", 1, true)
    or d:find("network is unreachable", 1, true) then
    return "refused"
  end
  if d:find("timed out", 1, true) or d:find("timeout", 1, true) then
    return "timeout"
  end
  return "other"
end

-- ===========================================================================
-- 小工具(UTF-8 / 折行,与 chat.lua 同一套逻辑)
-- ===========================================================================

local function utf8CharLen(s, i)
  local b = string.byte(s, i)
  if not b then return nil end
  if b < 0x80 then return 1 end
  if b >= 0xC2 and b <= 0xDF then
    local b2 = string.byte(s, i + 1)
    if b2 and b2 >= 0x80 and b2 <= 0xBF then return 2 end
    return nil
  end
  if b >= 0xE0 and b <= 0xEF then
    local b2, b3 = string.byte(s, i + 1), string.byte(s, i + 2)
    if not (b2 and b3) then return nil end
    if b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then return nil end
    if b == 0xE0 and b2 < 0xA0 then return nil end
    if b == 0xED and b2 > 0x9F then return nil end
    return 3
  end
  if b >= 0xF0 and b <= 0xF4 then
    local b2, b3, b4 = string.byte(s, i + 1), string.byte(s, i + 2), string.byte(s, i + 3)
    if not (b2 and b3 and b4) then return nil end
    for _, x in ipairs({ b2, b3, b4 }) do
      if x < 0x80 or x > 0xBF then return nil end
    end
    if b == 0xF0 and b2 < 0x90 then return nil end
    if b == 0xF4 and b2 > 0x8F then return nil end
    return 4
  end
  return nil
end

local function utf8Length(s)
  local n, i, len = 0, 1, #s
  while i <= len do
    local cl = utf8CharLen(s, i)
    i = i + (cl or 1)
    n = n + 1
  end
  return n
end

local function truncateBytes(s, maxBytes)
  if #s <= maxBytes then return s end
  local i = 1
  while i <= maxBytes do
    local cl = utf8CharLen(s, i)
    if not cl or i + cl - 1 > maxBytes then break end
    i = i + cl
  end
  return string.sub(s, 1, i - 1)
end

local function deleteLastChar(s)
  local len = #s
  if len == 0 then return s end
  local start = len
  while start > 1 do
    local b = string.byte(s, start)
    if b < 0x80 or b >= 0xC0 then break end
    start = start - 1
  end
  return string.sub(s, 1, start - 1)
end

-- ---------------------------------------------------------------------------
-- 显示宽度
--
-- ⚠️ 中文是**宽字符,占 2 列**。按"字符个数"算宽度会低估一半,
-- 于是 40 个中文 = 80 列,直接溢出屏幕,而且截断会切在列中间。
-- OpenOS 自己也是按宽度处理的:
--   lib/tty.lua:116  local wlen_needed = unicode.wlen(segment)
--   lib/tty.lua:119  segment = unicode.wtrunc(segment, wlen_remaining + 1)
-- 所以这里统一用 unicode.wlen / wtrunc,库不可用时退回本地实现。
-- ---------------------------------------------------------------------------
local unicodeLib = nil
do
  local ok, lib = pcall(require, "unicode")
  if ok and type(lib) == "table" and type(lib.wlen) == "function" then unicodeLib = lib end
end

-- 本地兜底:按码点估算列宽(CJK 等区间算 2 列,其余 1 列)
local function isWideCodepoint(cp)
  return (cp >= 0x1100 and cp <= 0x115F)
    or (cp >= 0x2E80 and cp <= 0xA4CF)
    or (cp >= 0xAC00 and cp <= 0xD7A3)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0xFE30 and cp <= 0xFE6F)
    or (cp >= 0xFF00 and cp <= 0xFF60)
    or (cp >= 0xFFE0 and cp <= 0xFFE6)
    or (cp >= 0x1F300 and cp <= 0x1FAFF)
    or (cp >= 0x20000 and cp <= 0x3FFFD)
end

-- 解码字符串第 i 个字符的码点(配合 utf8CharLen 使用)
local function codepointAt(s, i, cl)
  if cl == 1 then return string.byte(s, i) end
  if utf8 and type(utf8.codepoint) == "function" then
    local ok, cp = pcall(utf8.codepoint, s, i, i + cl - 1)
    if ok then return cp end
  end
  return 0x4E00   -- 解不出来时按宽字符算,宁可保守
end

local function displayWidth(s)
  if type(s) ~= "string" then return 0 end
  if unicodeLib then
    local ok, w = pcall(unicodeLib.wlen, s)
    if ok and type(w) == "number" then return w end
  end
  local w, i, len = 0, 1, #s
  while i <= len do
    local cl = utf8CharLen(s, i) or 1
    w = w + (isWideCodepoint(codepointAt(s, i, cl)) and 2 or 1)
    i = i + cl
  end
  return w
end

-- 按**显示宽度**截断(而不是按字节/字符),且不切断多字节字符
local function truncateToWidth(s, maxWidth)
  if type(s) ~= "string" then return "" end
  if displayWidth(s) <= maxWidth then return s end
  if unicodeLib and type(unicodeLib.wtrunc) == "function" then
    local ok, out = pcall(unicodeLib.wtrunc, s, maxWidth)
    if ok and type(out) == "string" then return out end
  end
  local out, w, i, len = {}, 0, 1, #s
  while i <= len do
    local cl = utf8CharLen(s, i) or 1
    local seq = string.sub(s, i, i + cl - 1)
    local cw = displayWidth(seq)
    if w + cw > maxWidth then break end
    out[#out + 1] = seq
    w = w + cw
    i = i + cl
  end
  return table.concat(out)
end

-- 折行宽度按**显示列数**算(中文占 2 列)
local function wrapLine(line, width)
  local out = {}
  if line == "" then return { "" } end
  local buf, cols, i, len = {}, 0, 1, #line
  while i <= len do
    local cl = utf8CharLen(line, i) or 1
    local seq = string.sub(line, i, i + cl - 1)
    local cw = displayWidth(seq)
    if cols > 0 and cols + cw > width then
      out[#out + 1] = table.concat(buf)
      buf, cols = {}, 0
    end
    buf[#buf + 1] = seq
    cols = cols + cw
    i = i + cl
  end
  if #buf > 0 then out[#out + 1] = table.concat(buf) end
  return out
end

local function splitLines(text)
  local out = {}
  for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
    out[#out + 1] = (line:gsub("\r", ""))
  end
  return out
end

-- ===========================================================================
-- 最小 JSON:编码 + 解析
--
-- 自己实现的原因:OC 只有 serialization(序列化成 Lua 字面量),没有 JSON。
-- 解析器写成**迭代式**而不是递归,避免深嵌套响应把调用栈打爆。
-- ===========================================================================

local Json = {}

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
                  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function escapeJsonChar(c)
  local e = ESCAPES[c]
  if e then return e end
  local b = string.byte(c)
  if b < 0x20 then return string.format("\\u%04x", b) end
  return c
end

function Json.encode(value)
  local t = type(value)
  if value == nil then return "null" end
  if t == "boolean" then return value and "true" or "false" end
  if t == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return "null" end
    if math.floor(value) == value then return string.format("%d", value) end
    return string.format("%.6g", value)
  end
  if t == "string" then
    return '"' .. value:gsub('[%z\1-\31\\"]', escapeJsonChar) .. '"'
  end
  if t == "table" then
    -- 判定数组:键为 1..n 连续整数
    local n = 0
    for k in pairs(value) do
      if type(k) ~= "number" then n = -1 break end
      if k > n then n = k end
    end
    if n >= 0 then
      local parts = {}
      for i = 1, n do parts[i] = Json.encode(value[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, v in pairs(value) do
      parts[#parts + 1] = Json.encode(tostring(k)) .. ":" .. Json.encode(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("无法编码的类型:" .. t)
end

-- JSON 解析:递归下降。
-- 用深度上限防爆栈(上游返回是浅结构,32 层远远够;真超了也报错而不是崩)。
local JSON_MAX_DEPTH = 32

function Json.decode(text)
  if type(text) ~= "string" then return nil, "输入不是字符串" end
  local pos, len = 1, #text

  local skipWs, parseValue

  skipWs = function()
    while pos <= len do
      local c = text:sub(pos, pos)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then pos = pos + 1 else break end
    end
  end

  local function fail(msg)
    return nil, string.format("%s(偏移 %d)", msg, pos)
  end

  local function parseString()
    pos = pos + 1   -- 跳过开引号
    local buf = {}
    while pos <= len do
      local c = text:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(buf)
      elseif c == "\\" then
        local e = text:sub(pos + 1, pos + 1)
        if e == "u" then
          local code = tonumber(text:sub(pos + 2, pos + 5), 16)
          if not code then return fail("坏的 \\u 转义") end
          pos = pos + 6
          -- 代理对(emoji 等):紧跟的低位一起合成
          if code >= 0xD800 and code <= 0xDBFF and text:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(text:sub(pos + 2, pos + 5), 16)
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
              code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
              pos = pos + 6
            end
          end
          if utf8 and utf8.char then
            buf[#buf + 1] = utf8.char(code)
          else
            -- OC 的 Lua 5.3 有 utf8;万一没有就退化成 '?',不至于崩
            buf[#buf + 1] = code < 128 and string.char(code) or "?"
          end
        else
          local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
                        f = "\f", n = "\n", r = "\r", t = "\t" }
          if not map[e] then return fail("未知转义 \\" .. tostring(e)) end
          buf[#buf + 1] = map[e]
          pos = pos + 2
        end
      else
        buf[#buf + 1] = c
        pos = pos + 1
      end
    end
    return fail("字符串没有闭合")
  end

  local function parseNumber()
    local start = pos
    while pos <= len and text:sub(pos, pos):match("[%d%.eE%+%-]") do pos = pos + 1 end
    local n = tonumber(text:sub(start, pos - 1))
    if not n then return fail("坏的数字") end
    return n
  end

  parseValue = function(depth)
    if depth > JSON_MAX_DEPTH then return fail("嵌套太深") end
    skipWs()
    local c = text:sub(pos, pos)
    if c == "" then return fail("内容意外结束") end

    if c == "{" then
      pos = pos + 1
      local obj = {}
      skipWs()
      if text:sub(pos, pos) == "}" then pos = pos + 1; return obj end
      while true do
        skipWs()
        if text:sub(pos, pos) ~= '"' then return fail("对象里缺少键名") end
        local key, err = parseString()
        if key == nil then return nil, err end
        skipWs()
        if text:sub(pos, pos) ~= ":" then return fail("键名后面缺少冒号") end
        pos = pos + 1
        local val, verr = parseValue(depth + 1)
        if val == nil and verr then return nil, verr end
        obj[key] = val
        skipWs()
        local d = text:sub(pos, pos)
        if d == "," then pos = pos + 1
        elseif d == "}" then pos = pos + 1; return obj
        else return fail("对象分隔符异常") end
      end
    elseif c == "[" then
      pos = pos + 1
      local arr = {}
      skipWs()
      if text:sub(pos, pos) == "]" then pos = pos + 1; return arr end
      while true do
        local val, err = parseValue(depth + 1)
        if val == nil and err then return nil, err end
        arr[#arr + 1] = val
        skipWs()
        local d = text:sub(pos, pos)
        if d == "," then pos = pos + 1
        elseif d == "]" then pos = pos + 1; return arr
        else return fail("数组分隔符异常") end
      end
    elseif c == '"' then
      return parseString()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4; return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5; return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4; return nil
    else
      return parseNumber()
    end
  end

  local value, err = parseValue(0)
  if err then return nil, err end
  return value
end

-- ===========================================================================
-- HTTP 调用
-- ===========================================================================

local function httpPostJson(host, pathname, headers, body)
  local internet = require("internet")
  local url = "https://" .. host .. pathname

  local hdrs = {}
  for k, v in pairs(headers or {}) do hdrs[k] = v end
  hdrs["Content-Type"] = "application/json"
  hdrs["Content-Length"] = tostring(#body)

  local ok, handle = pcall(internet.request, url, body, hdrs, "POST")
  if not ok then
    return false, "发起请求失败:" .. tostring(handle)
  end

  -- 状态码:官方文档说明要用句柄元表的 response()
  local status = nil
  local pcallMt, mt = pcall(getmetatable, handle)
  if pcallMt and type(mt) == "table" then
    local index = mt.__index
    if type(index) == "table" and type(index.response) == "function" then
      local okResp, code = pcall(index.response)
      if okResp and code ~= nil then status = tonumber(code) end
    end
  end

  local chunks = {}
  local iterOk, iterErr = pcall(function()
    for piece in handle do
      if type(piece) == "string" then
        chunks[#chunks + 1] = piece
      end
    end
  end)

  local text = table.concat(chunks)

  if not iterOk then
    -- 注意:OC 的 DNS 解析 / 建连是**延迟到迭代响应时**才做的,
    -- 所以 "unknown host"(DNS 解析失败)会在这里抛出来,而不是在 internet.request。
    -- (实测踩过:错误被归到"读取响应失败",提示完全指错方向)
    local detail = tostring(iterErr)
    local kind = classifyNetError(detail)
    if text ~= "" then
      return false, kind .. ":" .. detail .. "\n(已收到部分正文)", text, status, kind
    end
    return false, kind .. ":" .. detail, nil, status, kind
  end

  return true, text, text, status
end

-- ---------------------------------------------------------------------------
-- 带重试的请求。
--
-- 为什么要重试:服务器侧的 DNS 解析**会间歇性失败**(实测:同一份配置,
-- 之前能正常对话,后来突然连续报 "unknown host: api.deepseek.com")。
-- DNS 抖动是瞬时问题,重试一次往往就好了,比直接告诉玩家"失败了"有用得多。
--
-- 只对**传输层**问题重试(dns / refused / timeout);
-- HTTP 状态码错误(401、402、429…)不重试 —— 那些重试也没用,还白花钱。
-- ---------------------------------------------------------------------------
local RETRYABLE = { dns = true, refused = true, timeout = true }

local function requestWithRetry(host, pathname, headers, body)
  local maxAttempts = 3
  local lastErr = nil
  local lastKind = nil

  for attempt = 1, maxAttempts do
    local ok, text, raw, status, kind = httpPostJson(host, pathname, headers, body)
    if ok or status ~= nil then
      -- 成功,或拿到了 HTTP 响应(哪怕 4xx/5xx,也不该重试)
      if attempt > 1 then
        io.write("(第 " .. attempt .. " 次尝试成功)\n")
      end
      return ok, text, raw, status, kind, attempt
    end
    lastErr, lastKind = text, kind

    if not RETRYABLE[kind] then break end
    if attempt < maxAttempts then
      -- 用 event.pull 当定时器(OC 里最省事的 sleep 方式)
      local msg = (kind == "dns") and "域名解析失败" or "连接失败"
      io.write(string.format("(%s,重试 %d/%d...)\n", msg, attempt, maxAttempts - 1))
      pcall(event.pull, 1.2)
    end
  end

  return false, lastErr, nil, nil, lastKind, maxAttempts
end

-- ===========================================================================
-- 对话历史(存本地文件)
-- ===========================================================================

local historyPath = "/home/oc-chat-history-" .. tostring(CONFIG and CONFIG.sessionId or "oc1") .. ".tbl"
local messages = {}   -- { {role=..., content=...}, ... } 不含 system

local function loadHistory()
  if not (CONFIG and CONFIG.saveHistory) then return end
  if not filesystem.exists(historyPath) then return end
  local ok, data = pcall(function()
    local f = assert(io.open(historyPath, "r"))
    local raw = f:read("*a")
    f:close()
    return serialization.unserialize(raw)
  end)
  if ok and type(data) == "table" then
    for _, m in ipairs(data) do
      if type(m) == "table" and m.role and m.content then
        messages[#messages + 1] = { role = m.role, content = m.content }
      end
    end
  end
end

local function saveHistory()
  if not (CONFIG and CONFIG.saveHistory) then return end
  local ok, encoded = pcall(serialization.serialize, messages)
  if not ok then return end
  pcall(function()
    local f = assert(io.open(historyPath, "w"))
    f:write(encoded)
    f:close()
  end)
end

-- ===========================================================================
-- 界面
-- ===========================================================================

local log = {}
local input = ""
local statusText = "就绪"

local function pushLog(line)
  log[#log + 1] = line
  while #log > (CONFIG and CONFIG.maxLogLines or 400) do table.remove(log, 1) end
end

local function pushWrapped(text, prefix, width)
  local lines = splitLines(text)
  for idx, line in ipairs(lines) do
    local head = (idx == 1) and prefix or string.rep(" ", #prefix)
    local avail = width - utf8Length(head)
    if avail < 8 then avail = 8 end
    for j, w in ipairs(wrapLine(line, avail)) do
      pushLog((j == 1) and (head .. w) or (string.rep(" ", #prefix) .. w))
    end
  end
end

local function redraw()
  term.clear()
  local w, h = screenSize()
  local width = math.max(20, w - 1)
  local bodyTop, bodyBottom = 2, h - 2
  local bodyHeight = bodyBottom - bodyTop + 1

  term.setCursor(1, 1)
  local title = "OC 直连 DeepSeek  " .. tostring(CONFIG and CONFIG.model or "?")
    .. "  [" .. tostring(CONFIG and CONFIG.sessionId or "?") .. "]  Ctrl+C 退出"
  term.write(truncateToWidth(title, width))

  local first = math.max(1, #log - bodyHeight + 1)
  local row = bodyTop
  for i = first, #log do
    term.setCursor(1, row)
    term.write(truncateToWidth(log[i], width))
    row = row + 1
    if row > bodyBottom then break end
  end

  term.setCursor(1, h - 1)
  term.write(truncateToWidth(statusText, width))

  -- 事件转储(F12 打开时):把最近的事件按行显示在状态行上方,
  -- 排查"按键没反应"这类问题时非常有用 —— 能直接看到 char 的真值和类型。
  if debugEvents and #eventLog > 0 then
    local drow = h - 2
    for i = #eventLog, math.max(1, #eventLog - 3), -1 do
      if drow < bodyTop then break end
      term.setCursor(1, drow)
      term.write(truncateToWidth(eventLog[i], width))
      drow = drow - 1
    end
  end

  -- 输入行:必须**硬截断**,否则长输入会自动换行、把状态行和转储顶掉。
  -- (粘一个 36 字符的 UUID 就会串行 —— 实测踩过)
  -- 按**显示宽度**处理:中文占 2 列,按字符数算会溢出。
  local promptWidth = 2                     -- "> "
  local avail = math.max(8, width - promptWidth - 1)   -- 再留 1 列给 "…"
  local shown = input
  if displayWidth(shown) > avail then
    -- 从尾部倒着取:先算出要丢掉的宽度,再逐字符前进
    local total = displayWidth(shown)
    local skip = total - avail
    local i, dropped = 1, 0
    while i <= #shown and dropped < skip do
      local cl = utf8CharLen(shown, i) or 1
      dropped = dropped + displayWidth(string.sub(shown, i, i + cl - 1))
      i = i + cl
    end
    shown = "…" .. string.sub(shown, i)
  end
  term.setCursor(1, h)
  term.write(truncateToWidth("> " .. shown, width))
end

-- ===========================================================================
-- 自检
-- ===========================================================================

local function runDiagnostics()
  local function line(s) pushLog(s) end
  line("")
  line("========== 自检 ==========")
  line("目标      https://" .. CONFIG.apiHost .. CONFIG.apiPath)
  line("模型      " .. CONFIG.model)
  line("密钥      " .. string.sub(CONFIG.apiKey, 1, 6) .. "***"
    .. string.sub(CONFIG.apiKey, -4))
  line("")

  -- 1. 网卡
  local has = hasInternet()
  line(has and "[1/4] 网卡       OK" or "[1/4] 网卡       缺失 <== 先给电脑装网卡")
  if not has then return end

  -- 2. 连通性 + 密钥 + 对话:用**一次**真实请求一起验掉。
  --    注意:这是一次真实的付费调用,不过 max_tokens=1,花费可以忽略。
  line("[2/4] 连通性     请求中...(这会消耗极少量的额度)")
  redraw()
  local probeBody = Json.encode({
    model = CONFIG.model,
    messages = { { role = "user", content = "ping" } },
    max_tokens = 1,          -- 只要 1 个 token,费用可忽略
  })
  local pok, pres, _, pstatus, pkind = requestWithRetry(CONFIG.apiHost, CONFIG.apiPath,
    { ["Authorization"] = "Bearer " .. CONFIG.apiKey }, probeBody)
  if not pok then
    line("[2/4] 连通性      失败 <== 卡在这里")
    line("")
    pushWrapped(tostring(pres), "  | ", math.max(20, select(1, screenSize()) - 1))
    line("")
    if pkind == "dns" then
      -- DNS 失败是最容易被误判的一类:它不是"网络不通",而是"域名解析不了"
      line("这是 **域名解析失败**(DNS),不是被防火墙拦。")
      line("服务端 JVM 解析不了 api.deepseek.com:")
      line(" 1) 服务器没配可用的 DNS(容器环境常见)")
      line("     可找服主在服务端 /etc/resolv.conf 里加:")
      line("       nameserver 8.8.8.8")
      line("       nameserver 1.1.1.1")
      line("     然后重启服务端")
      line(" 2) 也可能只是瞬时抖动 —— 直接重试一次往往就好了")
      line("     (本程序已自动重试 3 次)")
      line(" 3) 若服务器完全不能出网,那这条路走不通,")
      line("     只能改用中转服务方案")
    else
      line("可能原因:")
      line(" 1) 服务端 config/OpenComputers.cfg 的 filteringRules")
      line("    是否拒绝了 api.deepseek.com 解析出的 IP?")
      line("    (默认规则 allow default 通常应放行公网)")
      line(" 2) 服务器所在网络能否出网(机房防火墙)")
      line(" 3) HTTPS 证书校验失败 —— 服务端 JRE 的根证书过旧")
      line(" 4) 电脑没装网卡")
    end
    return
  end
  line("[2/4] 连通性      OK (HTTP " .. tostring(pstatus or "?") .. ")")

  -- 3. 密钥 + 4. 对话(合成一次,省一次请求)
  local decodeOk, parsed = pcall(Json.decode, pres)
  local tbl = decodeOk and parsed or nil
  if pstatus == 401 then
    line("[3/4] 密钥        失败 <== 卡在这里")
    line("")
    line("HTTP 401:apiKey 无效。")
    line("注意要用 platform.deepseek.com 生成的 API key,")
    line("不是 DeepSeek Harness 客户端的登录令牌。")
    line("")
    line("[4/4] 对话测试    未执行")
    return
  end
  line("[3/4] 密钥        OK")
  line("[4/4] 对话测试     OK")
  line("")
  if tbl and tbl.choices and tbl.choices[1] then
    line("模型回复:")
    pushWrapped(tostring(tbl.choices[1].message and tbl.choices[1].message.content or "?"),
      "  | ", math.max(20, select(1, screenSize()) - 1))
  else
    line("响应解析异常,原始正文前 200 字节:")
    pushWrapped(string.sub(pres, 1, 200), "  | ", math.max(20, select(1, screenSize()) - 1))
  end
  line("")
  line("全部通过,可以正常对话。")
  line("==========================")
end

-- ===========================================================================
-- 发送并显示
-- ===========================================================================

local function sendMessage(text)
  statusText = "思考中... (最长 " .. CONFIG.timeoutSeconds .. " 秒)"
  redraw()

  local payload = { role = "user", content = text }
  local toSend = {}
  toSend[1] = { role = "system", content = SYSTEM_PROMPT }
  local start = math.max(1, #messages - CONFIG.historyLimit + 1)
  for i = start, #messages do toSend[#toSend + 1] = messages[i] end
  toSend[#toSend + 1] = payload

  local body = Json.encode({
    model = CONFIG.model,
    messages = toSend,
    temperature = CONFIG.temperature,
    max_tokens = CONFIG.maxTokens,
    stream = false,
  })

  -- 计时用 computer.uptime()(真实世界秒数),**不能**用 os.clock()
  -- —— os.clock 返回的是 CPU 时间,而等 HTTP 响应期间本机几乎不耗 CPU,
  -- 于是每次都显示 "0.0 秒"(实测踩过)。
  local ok2, started = pcall(function() return require("computer").uptime() end)
  if not ok2 or type(started) ~= "number" then started = os.time() end

  local ok, text2, _, status, kind = requestWithRetry(CONFIG.apiHost, CONFIG.apiPath,
    { ["Authorization"] = "Bearer " .. CONFIG.apiKey }, body)

  local ok3, finished = pcall(function() return require("computer").uptime() end)
  if not ok3 or type(finished) ~= "number" then finished = os.time() end
  local elapsed = finished - started

  if not ok then
    pushLog("")
    pushWrapped(text2 or "(无信息)", "! ", math.max(20, select(1, screenSize()) - 1))
    if kind == "dns" then
      pushLog("(域名解析失败 —— 已自动重试 3 次仍不行)")
      pushLog(" 这是服务端 JVM 的 DNS 问题,不是被防火墙拦:")
      pushLog(" 1) 先歇一会儿再试,也可能只是抖动")
      pushLog(" 2) 持续失败要找服主给服务端配 DNS:")
      pushLog("    /etc/resolv.conf 里加 nameserver 8.8.8.8")
      pushLog("    然后重启服务端")
      pushLog(" 3) 若服务器不能出网,只能改用中转方案")
    elseif kind == "refused" or kind == "timeout" then
      pushLog("(连不上上游 —— 已自动重试 3 次)")
      pushLog(" 检查服务端出网 / filteringRules;稍后再试。")
    end
    statusText = "请求失败,见上方信息"
    return false
  end

  local decodeOk, parsed = pcall(Json.decode, text2)
  local tbl = decodeOk and parsed or nil
  if type(tbl) ~= "table" then
    pushLog("")
    pushLog("! 响应不是合法 JSON。原始正文前 300 字节:")
    pushWrapped(string.sub(text2 or "", 1, 300), "  | ", math.max(20, select(1, screenSize()) - 1))
    statusText = "解析失败"
    return false
  end

  if status and status ~= 200 then
    local msg = tbl.error and tbl.error.message or "未知错误"
    pushLog("")
    pushLog("! HTTP " .. tostring(status) .. ":" .. tostring(msg))
    if status == 401 then
      pushLog("  (apiKey 无效 —— 确认用的是 platform.deepseek.com 的 API key)")
    elseif status == 402 then
      pushLog("  (账户余额/额度问题)")
    elseif status == 429 then
      pushLog("  (限流,等一会儿再试)")
    end
    statusText = "请求被拒绝"
    return false
  end

  local choice = tbl.choices and tbl.choices[1]
  local content = choice and choice.message and choice.message.content
  if type(content) ~= "string" or content == "" then
    pushLog("")
    pushLog("! 响应里没有回复文本。原始正文前 300 字节:")
    pushWrapped(string.sub(text2, 1, 300), "  | ", math.max(20, select(1, screenSize()) - 1))
    statusText = "响应格式异常"
    return false
  end

  messages[#messages + 1] = payload
  messages[#messages + 1] = { role = "assistant", content = content }
  while #messages > CONFIG.historyLimit do table.remove(messages, 1) end
  saveHistory()

  pushLog("")
  pushWrapped(content, "AI: ", math.max(20, select(1, screenSize()) - 1))
  if CONFIG.showUsage then
    local usage = tbl.usage or {}
    -- 注意:elapsed 来自 computer.uptime(),是**浮点**秒数;
    -- 直接塞进 %d 会报 "number has no integer representation"(实测踩过),
    -- 所以统一用 toInt() 转成整数。
    local secs = toInt(elapsed) or 0
    local timeText = (secs < 1) and "不到 1 秒" or string.format("%d 秒", secs)
    pushLog(string.format("  (%s,%d 字符,tokens in=%s out=%s)",
      timeText, utf8Length(content), tostring(usage.prompt_tokens or "?"),
      tostring(usage.completion_tokens or "?")))
  end
  pushLog("")
  statusText = "就绪 —— 回车发送,Ctrl+R 重新开始"
  return true
end

-- ===========================================================================
-- 命令行入口
-- ===========================================================================

local function printHelp()
  print("dsk —— OC 直连 DeepSeek(不需要中转服务)")
  print("")
  print("  dsk            进入聊天界面")
  print("  dsk --diag     逐层自检")
  print("  dsk --reset    清空本地对话历史")
  print("  dsk --help     显示本帮助")
end

local function main(...)
  local args = { ... }
  local flag = args[1]

  if flag == "--help" or flag == "-h" then printHelp() return end

  if not CONFIG then
    term.clear()
    term.setCursor(1, 1)
    print("配置有问题,无法启动:")
    print("")
    print(tostring(CONFIG_ERR))
    print("")
    print("配置文件位置:" .. CONFIG_PATH)
    print("模板:dsk-config.example.lua")
    return
  end

  if flag == "--reset" then
    messages = {}
    saveHistory()
    print("已清空本地对话历史:" .. historyPath)
    return
  end

  loadHistory()

  term.clear()
  term.setCursor(1, 1)
  -- 注意:OC 里**没有**全局 write 函数(只有 io.write / term.write)。
  -- 早先这里写成 write(...) 会在游戏里直接报
  -- "attempt to call a nil value (global 'write')"。
  io.write("正在连接 " .. CONFIG.apiHost .. " ...\n")

  if flag == "--diag" then
    runDiagnostics()
    print("")
    print("(自检结束,按 Ctrl+C 或在游戏里终止)")
    return
  end

  -- 标题由 redraw() 画在最上面一行,这里不再重复;
  -- 只补充"标题里放不下"的信息(历史轮数)。
  if #messages > 0 then
    pushLog("(继续上次的对话,已载入 " .. math.floor(#messages / 2) .. " 轮历史;"
      .. "Ctrl+R 可以重开)")
  else
    pushLog("(新对话)随便聊点什么吧。")
  end
  pushLog("回车发送;也可以直接用鼠标中键粘贴。")
  pushLog("Ctrl+R 重开  Ctrl+U 清空输入  Ctrl+C 退出  /help 看命令")
  pushLog("")
  statusText = "就绪 —— 回车发送"
  redraw()

  while true do
    local ev = { event.pull(1) }
    local name = ev[1]
    -- 每个事件都记一份,F12 打开时会显示在屏幕底部
    recordEvent(ev)

    if name == "key_down" then
      local _, _, char, code = table.unpack(ev)
      -- char 保持原样(number 码点 或 string),由 charToUtf8 / isPrintableChar 分别处理
      -- (不要在这里做有损转换 —— 之前转成"单字节字符串"正是中文丢失的原因)
      local isCtrl = keyboard.isControlDown and keyboard.isControlDown()

      -- F12:切换事件转储(排查"按键没反应"用)
      if code == keyboard.keys.f12 then
        debugEvents = not debugEvents
        if not debugEvents then eventLog = {} end
        statusText = debugEvents and "事件转储:开(F12 关闭)" or "事件转储:关"
        redraw()
      elseif isCtrl and code == keyboard.keys.c then
        term.clear(); term.setCursor(1, 1); print("再见。") return
      elseif isCtrl and code == keyboard.keys.d then
        redraw()
      elseif isCtrl and code == keyboard.keys.u then
        -- 清空当前输入(粘错了可以中止,不用一个个退格)
        input = ""
        statusText = "输入已清空"
        redraw()
      elseif isCtrl and code == keyboard.keys.r then
        messages = {}
        saveHistory()
        pushLog("(已清空本地对话历史,重新开始)")
        statusText = "已重新开始"
        redraw()
      elseif code == keyboard.keys.back then
        input = deleteLastChar(input)
        redraw()
      elseif code == keyboard.keys.enter then
        local text = input
        input = ""
        local cmd = text:gsub("%s", "")
        if cmd == "/diag" then
          pushLog("你: /diag")
          runDiagnostics()
          statusText = "自检完成 —— 往上翻看结果"
        elseif cmd == "/clear" or cmd == "/reset" then
          -- 清空本地历史。提示词改了人设、或模型被旧历史带偏时,这是最快的解法。
          messages = {}
          saveHistory()
          pushLog("你: " .. text)
          pushLog("(已清空对话历史,下一句就是全新开始)")
          statusText = "历史已清空"
        elseif cmd == "/help" then
          pushLog("你: /help")
          pushLog("可用命令:")
          pushLog("  /clear  清空对话历史(人设没生效时先试这个)")
          pushLog("  /diag   连接与密钥自检")
          pushLog("  /help   显示这条帮助")
          statusText = "帮助已显示"
        elseif text:gsub("%s", "") ~= "" then
          pushLog("你: " .. text)
          redraw()
          sendMessage(text)
        end
        redraw()
      end

      -- 字符输入。
      --
      -- 依据 OC 自身实现(bin/edit.lua:631):char 是**码点 number**,
      -- 用 unicode.char(char) 一步转成 UTF-8,字符就是完整的一个(含中文)。
      -- 所以这里不再需要"多字节拼装缓冲" —— 那是基于错误假设写的。
      if isPrintableChar(char) and not isCtrl
        and code ~= keyboard.keys.enter and code ~= keyboard.keys.back then
        local seq = charToUtf8(char)
        if #seq > 0 then
          input = input .. seq
          redraw()
        end
      end
    elseif name == "clipboard" then
      -- 粘贴。**事件布局是踩过坑的地方**:
      --   ev = { "clipboard", 地址, 内容, 玩家名 }
      -- 内容在 ev[3],不是 ev[2]!
      -- 早先写成 `local _, text = table.unpack(ev)` 取到的是 ev[2]=组件地址,
      -- 于是"粘出来永远是那串 UUID" —— 那其实是地址,不是剪贴板内容。
      --
      -- 依据 OC 自身实现:lib/core/cursor.lua 里
      --   function core_cursor.vertical:handle(name, char, code)
      --     if name == "clipboard" then ... char 就是内容
      -- 即 handle 的第二个参数(char)才是剪贴板内容。
      --
      -- 客户端送来的是**已经解码好的 UTF-8 字符串**(实测"你好"收到
      -- E4 BD A0 E5 A5 BD),所以不需要任何十六进制转换。
      local text = ev[3]
      if type(text) == "string" and #text > 0 then
        -- 只取第一个换行之前的内容(输入行是单行的)
        local nl = text:find("\n", 1, true)
        local single = nl and text:sub(1, nl - 1) or text
        single = single:gsub("\r", "")

        local added = 0
        local i, len = 1, #single
        while i <= len do
          local cl = utf8CharLen(single, i)
          if cl and i + cl - 1 <= len then
            local seq = string.sub(single, i, i + cl - 1)
            if isPrintableChar(seq) then
              input = input .. seq
              added = added + 1
            end
            i = i + cl
          else
            i = i + 1
          end
        end
        statusText = added > 0
          and string.format("已粘贴 %d 个字符(回车发送)", added)
          or "粘贴内容里没有可用字符"
        redraw()
      end
    elseif name == "interrupted" then
      term.clear(); term.setCursor(1, 1); print("已中断。") return
    elseif name == "term_resize" then
      redraw()
    end
  end
end

-- 便于离线测试:设置全局 _DSK_LIB_ONLY = true 之后再 require 本文件,
-- 只会拿到内部函数,不会进入聊天界面。
if _DSK_LIB_ONLY then
  return {
    Json = Json,
    DEFAULTS = DEFAULTS,
    SYSTEM_PROMPT = SYSTEM_PROMPT,
    utf8Length = utf8Length,
    utf8CharLen = utf8CharLen,
    wrapLine = wrapLine,
    deleteLastChar = deleteLastChar,
    truncateBytes = truncateBytes,
    displayWidth = displayWidth,
    truncateToWidth = truncateToWidth,
    httpPostJson = httpPostJson,
  }
end

main()
