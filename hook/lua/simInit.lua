-- M28CampaignAssist（M28AI 附属 mod）
--
-- 作用：让 M28AI 的「合并 AI/人类军队」(combined AI-human armies) 在单人战役里可用，
--       即逐单位托管玩家自己的部队：选中单位点亮指令面板里的 M28 按钮即交给 M28，
--       熄灭即收回。
--
-- 背景：M28 的唯一开关是 ScenarioInfo.Options.M28CombinedArmy。
--   遭遇战里该字段由大厅写入；单人战役的 session 由 lua/SinglePlayerLaunch.lua 的
--   SetupCampaignSession 重建 Options 表（只写 FogOfWar/Difficulty/DoNotShareUnitCap/
--   Timeouts/GameSpeed/FACampaignFaction 六项），该字段永远缺失。
--   M28 内部用 tonumber(... or 2) 兜底，于是按「2 = 关闭」处理：既不把人类 brain
--   登记成 M28 brain，也不给单位打 M28CombinedArmiesShowUI 标记，
--   结果既没有托管、也没有 UI 按钮。
--
-- 做法：只在 type == 'campaign' 的 session、且字段缺失时补 1（= Yes，逐单位切换）。
--       * 值 1 打开的是「按钮」，不是「托管」：每个人类单位默认 M28Active = 0，
--         即默认不被 M28 接管，必须手动点亮才交出去
--       * M28CAInherit 未设置时缺省按 2 处理，所以新造单位也不会自动继承托管
--       * 不覆盖大厅/剧本已经设过的值
--       * 不写 CampAI 等其他选项，战役默认 AI 仍保持原版行为
--
-- 两个必须遵守的约束（都是踩过的坑，改这个文件前先读）：
--   1. 本 build 给 _G 装了 __index 报错元表
--      （gamedata/mohodata.scd 的 lua/system/config.lua:51-56）。
--      读取「尚未定义」的全局会抛错并中断整个 hook 的装载。
--      所以一律用 rawget 取可能不存在的全局，绝不直接引用 ScenarioInfo。
--   2. 本 build 的 simInit 串接装载不接受变长参数写法 function(...)。
--      用了会报 unexpected symbol near '...'，导致整个 simInit 装载失败、
--      Sim::Create() 崩溃、进不去游戏。
--      所以包装函数一律用具名参数。

local refOptionKey = 'M28CombinedArmy'
local iCombinedArmyEnabled = 1   -- 1 = Yes (toggle for all units)

local function ApplyM28CombinedArmyOption()
    -- rawget 绕开严格的全局 __index：未定义时安静返回 nil，不抛错
    local scenarioInfo = rawget(_G, 'ScenarioInfo')
    if type(scenarioInfo) ~= 'table' then return end

    local options = scenarioInfo.Options
    if type(options) ~= 'table' then return end

    -- 只处理单人战役。遭遇战/多人由大厅决定，tutorial 等其它 session 也不插手
    if scenarioInfo.type ~= 'campaign' then return end

    -- 已经有人设过值就不动，避免覆盖玩家的显式选择
    if options[refOptionKey] ~= nil then return end

    options[refOptionKey] = iCombinedArmyEnabled
    LOG('M28CampaignAssist: set ScenarioInfo.Options.' .. refOptionKey .. '='
        .. iCombinedArmyEnabled .. ' for scenario type='
        .. tostring(scenarioInfo.type))
end

-- SetupSession：引擎在「ScenarioInfo 已就绪、军队尚未创建」时调用它，
-- 且它内部会加载存档与剧本脚本。放在它之后补值，让剧本自己设过的值优先。
local M28AssistOldSetupSession = rawget(_G, 'SetupSession')
if type(M28AssistOldSetupSession) == 'function' then
    function SetupSession()
        local result = M28AssistOldSetupSession()
        ApplyM28CombinedArmyOption()
        return result
    end
end

-- OnCreateArmyBrain：M28 正是在这里 fork 人类 brain 的初始化（会读该选项），
-- 所以必须在这之前写好。原函数内部本就访问 ScenarioInfo，此处它必然已存在。
local M28AssistOldOnCreateArmyBrain = rawget(_G, 'OnCreateArmyBrain')
if type(M28AssistOldOnCreateArmyBrain) == 'function' then
    function OnCreateArmyBrain(index, brain, name, nickname)
        ApplyM28CombinedArmyOption()
        return M28AssistOldOnCreateArmyBrain(index, brain, name, nickname)
    end
end

-- BeginSession：兜底（读档等路径），也保证 M28 的 BeginSession 逻辑跑之前已就绪
local M28AssistOldBeginSession = rawget(_G, 'BeginSession')
if type(M28AssistOldBeginSession) == 'function' then
    function BeginSession()
        ApplyM28CombinedArmyOption()
        return M28AssistOldBeginSession()
    end
end
