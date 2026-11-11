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
-- 做法：只在 type == 'campaign' 的 session、且字段缺失时写入下表这些值。
--       * M28CombinedArmy = 1 打开的是「按钮」，不是「托管」：每个人类单位默认
--         M28Active = 0，必须手动点亮才交出去
--       * M28CAInherit = 1 打开「传染」：被托管单位造出来的单位继承托管状态。
--         M28 里只有两处读它，且都要求父/建造单位的 M28Active 为真：
--           - M28Events.lua:2149（工程师造建筑）
--           - M28Events.lua:3789（单位已完全建成且 oUnit.Parent.M28Active）
--         缺省不设时按 2（关闭）处理，所以默认没有任何继承
--       * 光补选项还不够：M28 那两处传播逻辑在零售版战役里不可靠（见
--         hook/lua/sim/Unit.lua 的说明），真正的传染由那个 hook 在引擎事件层面完成。
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

-- 要补的选项。键是 ScenarioInfo.Options 的键，值是写入的数字（M28 侧用数值比较）。
local tM28AssistDefaults = {
    M28CombinedArmy = 1,   -- 1 = Yes (toggle for all units)
    M28CAInherit = 1,      -- 1 = Yes (被托管单位造出的单位继承托管)

    -- 行为调参（全部是 M28AI 已有的运行时选项，这里只是补上战役缺失的值）
    -- 1) 攻击更积极：0.6 会明显低估敌方威胁，从而更愿意用地面部队交战、更敢推进。
    --    代价：核弹目标判定会变粗（M28 官方 help 已说明）。想稳一点改 0.7。
    M28Aggression = 0.6,
    -- 2) 关闭闪避位移与空中悬停微操：止住“反复闪避/躲藏”。
    --    注意这两个选项是 bUseKeyAsValueInScenarioInfo，必须写数字，写字符串会静默失效。
    M28DodgeMicro = 2,
    M28HoverMicro = 2,
    -- 3) 关闭“固定优先造某几种单位”：提高单位多样性，也削弱单一阵营权重。
    M28PrioritiseBPs = 2,
    -- 4) 保持 1.0 的重评估周期（11 tick）：更跟得上战场，减少“发呆”。
    --    写 1.5 会让决策慢下来，之前用来压切目标频率，但副作用是反应迟钝。
    M28TimeBetweenOrders = 1.0,

    -- 5) 本 mod 自己的开关（不是 M28AI 的选项，由 hook/mods/M28AI 下的包装读取）：
    --    1 = 玩家单位不再风筝后退，贴上去打（更敢换血）
    --    2 = 保留 M28 原版风筝行为
    M28AssistNoKite = 1,
}

local function ApplyM28AssistOptions()
    -- rawget 绕开严格的全局 __index：未定义时安静返回 nil，不抛错
    local scenarioInfo = rawget(_G, 'ScenarioInfo')
    if type(scenarioInfo) ~= 'table' then return end

    local options = scenarioInfo.Options
    if type(options) ~= 'table' then return end

    -- 只处理单人战役。遭遇战/多人由大厅决定，tutorial 等其它 session 也不插手
    if scenarioInfo.type ~= 'campaign' then return end

    for sKey, vValue in pairs(tM28AssistDefaults) do
        -- 已经有人设过值就不动，避免覆盖玩家的显式选择
        if options[sKey] == nil then
            options[sKey] = vValue
            LOG('M28CampaignAssist: set ScenarioInfo.Options.' .. sKey .. '='
                .. tostring(vValue) .. ' for scenario type=' .. tostring(scenarioInfo.type))
        end
    end
end

-- SetupSession：引擎在「ScenarioInfo 已就绪、军队尚未创建」时调用它，
-- 且它内部会加载存档与剧本脚本。放在它之后补值，让剧本自己设过的值优先。
local M28AssistOldSetupSession = rawget(_G, 'SetupSession')
if type(M28AssistOldSetupSession) == 'function' then
    function SetupSession()
        local result = M28AssistOldSetupSession()
        ApplyM28AssistOptions()
        return result
    end
end

-- OnCreateArmyBrain：M28 正是在这里 fork 人类 brain 的初始化（会读该选项），
-- 所以必须在这之前写好。原函数内部本就访问 ScenarioInfo，此处它必然已存在。
local M28AssistOldOnCreateArmyBrain = rawget(_G, 'OnCreateArmyBrain')
if type(M28AssistOldOnCreateArmyBrain) == 'function' then
    function OnCreateArmyBrain(index, brain, name, nickname)
        ApplyM28AssistOptions()
        return M28AssistOldOnCreateArmyBrain(index, brain, name, nickname)
    end
end

-- BeginSession：兜底（读档等路径），也保证 M28 的 BeginSession 逻辑跑之前已就绪
local M28AssistOldBeginSession = rawget(_G, 'BeginSession')
if type(M28AssistOldBeginSession) == 'function' then
    function BeginSession()
        ApplyM28AssistOptions()
        return M28AssistOldBeginSession()
    end
end
