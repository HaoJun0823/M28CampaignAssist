-- M28CampaignAssist（M28AI 附属 mod）
--
-- 作用：在单人战役里打开 M28AI 的「合并 AI/人类军队」，并让托管具备传染性 ——
--       被托管的单位造出来的东西（建筑、工厂、工程车、作战单位）同样归 M28AI 控制。
--
-- 背景：M28 的开关全部来自 ScenarioInfo.Options。
--   遭遇战里这些字段由大厅写入；单人战役的 session 由 lua/SinglePlayerLaunch.lua 的
--   SetupCampaignSession 重建 Options 表（只写 FogOfWar/Difficulty/DoNotShareUnitCap/
--   Timeouts/GameSpeed/FACampaignFaction 六项），其余字段永远缺失。
--   M28 内部用 tonumber(... or 2) 兜底，即按「2 = 关闭」处理：
--   既没有逐单位托管按钮，也没有继承。
--
-- 本 mod 只补两个字段：
--   M28CombinedArmy = 1  打开逐单位托管按钮。值 1 打开的是「按钮」不是「托管」：
--                        每个人类单位默认 M28Active = 0，必须玩家点亮才交出去。
--   M28CAInherit    = 1  打开继承：被托管单位造出来的单位自动托管。
--
-- 继承完全由 M28AI 自己实现，本 mod 不参与计算：
--   M28Events.lua 的 OnConstructionStarted（建造动作开始的那一刻）判断
--   「建造者 M28Active 为真 + 玩家 brain + M28CAInherit == 1」，
--   成立就给产物置 M28Active = true 并写同名 stat。
--   工厂也是建造者，所以：被托管的工程车造出的工厂会继承，该工厂随后产出的单位也会继承。
--   继承只发生在「建造开始」这一刻，不会回溯已经造好的单位，也不会因为建造者后来被
--   取消托管而连带取消产物。
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

-- 键名 -> 缺省值。只补「玩家/剧本没有显式设过」的键。
local tOptionDefaults = {
    M28CombinedArmy = 1,
    M28CAInherit = 1,
}

local function ApplyM28CampaignOptions()
    -- rawget 绕开严格的全局 __index：未定义时安静返回 nil，不抛错
    local scenarioInfo = rawget(_G, 'ScenarioInfo')
    if type(scenarioInfo) ~= 'table' then return end

    local options = scenarioInfo.Options
    if type(options) ~= 'table' then return end

    -- 只处理单人战役。遭遇战/多人由大厅决定，tutorial 等其它 session 也不插手
    if scenarioInfo.type ~= 'campaign' then return end

    for sKey, iValue in pairs(tOptionDefaults) do
        -- 已经有人设过值就不动，避免覆盖玩家的显式选择
        if options[sKey] == nil then
            options[sKey] = iValue
            LOG('M28CampaignAssist: set ScenarioInfo.Options.' .. sKey .. '=' .. iValue
                .. ' for scenario type=' .. tostring(scenarioInfo.type))
        end
    end
end

-- SetupSession：引擎在「ScenarioInfo 已就绪、军队尚未创建」时调用它，
-- 且它内部会加载存档与剧本脚本。放在它之后补值，让剧本自己设过的值优先。
local M28AssistOldSetupSession = rawget(_G, 'SetupSession')
if type(M28AssistOldSetupSession) == 'function' then
    function SetupSession()
        local result = M28AssistOldSetupSession()
        ApplyM28CampaignOptions()
        return result
    end
end

-- OnCreateArmyBrain：M28 正是在这里 fork 人类 brain 的初始化（会读这些选项），
-- 所以必须在这之前写好。原函数内部本就访问 ScenarioInfo，此处它必然已存在。
local M28AssistOldOnCreateArmyBrain = rawget(_G, 'OnCreateArmyBrain')
if type(M28AssistOldOnCreateArmyBrain) == 'function' then
    function OnCreateArmyBrain(index, brain, name, nickname)
        ApplyM28CampaignOptions()
        return M28AssistOldOnCreateArmyBrain(index, brain, name, nickname)
    end
end

-- BeginSession：兜底（读档等路径），也保证 M28 的 BeginSession 逻辑跑之前已就绪
local M28AssistOldBeginSession = rawget(_G, 'BeginSession')
if type(M28AssistOldBeginSession) == 'function' then
    function BeginSession()
        ApplyM28CampaignOptions()
        return M28AssistOldBeginSession()
    end
end
