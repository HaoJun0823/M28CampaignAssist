-- M28CampaignAssist（M28AI 附属 mod）
-- hook/lua/SimCallbacks.lua
--
-- 作用：捕获玩家点击 M28 托管按钮时的「显式意图」，写进 mod 私有字段
--       M28AssistManaged / M28AssistExplicit，供 hook/lua/sim/Unit.lua 使用。
--
-- 为什么必须单独 hook 这里：
--   M28Active 是一个被多方共写的字段（玩家 toggle、M28Events.OnConstructionStarted
--   的继承、M28Overseer 对运输机/组件的动态开关）。只靠读 M28Active 无法分辨
--   「玩家亲手点亮」和「AI 顺手打上的标记」，于是传染判定会出现有时对有时错。
--   玩家意图只能在 toggle 发生的那一刻捕获，之后任何异步覆盖都不该改变它。
--
-- 装载约束：
--   * hook 文件按 mod 顺序拼接到同一个 chunk，所以这里能访问官方文件里的
--     local Callbacks，以及 M28AI（排在前面）追加的 M28SharedArmiesCallback。
--   * 仍用 pcall 读 Callbacks：万一某个 build 把 hook 当独立文件加载，
--     严格 _G 元表会让直接引用抛错，pcall 可以让它安静退化而不破坏官方回调表。

local bM28AssistGotCallbacks, tM28AssistCallbacks = pcall(function() return Callbacks end)

if bM28AssistGotCallbacks and type(tM28AssistCallbacks) == 'table' then
    local M28AssistOldCallback = tM28AssistCallbacks.M28SharedArmiesCallback

    if type(M28AssistOldCallback) == 'function' then
        tM28AssistCallbacks.M28SharedArmiesCallback = function(data, units)
            -- 先让 M28AI 原来的回调照常写 M28Active 和 UI stat
            M28AssistOldCallback(data, units)

            if type(data) ~= 'table' or data.Enable == nil then return end

            local iCount = 0
            for i, oUnit in units or {} do
                -- units 来自引擎选择集；单个元素出问题不该让整次 toggle 失败
                local bOK = pcall(function()
                    if oUnit and oUnit.GetAIBrain and not oUnit.Dead then
                        -- 权威值：这个单位从此由玩家明确指定，传染/跟随都不再改它
                        oUnit.M28AssistManaged = (data.Enable == true)
                        oUnit.M28AssistExplicit = true
                        oUnit.M28AssistFollow = false
                        oUnit.M28AssistBuilder = nil
                        iCount = iCount + 1
                    end
                end)
            end

            LOG('M28CampaignAssist: toggle Enable=' .. tostring(data.Enable)
                .. ' applied to ' .. tostring(iCount) .. ' unit(s)')
        end
        -- 告诉 hook/lua/sim/Unit.lua：玩家意图现在有可靠来源了。
        -- 有这条通路时，对账绝不能再从 M28Active/stat 反推玩家意图（见那边的注释）。
        rawset(_G, 'M28AssistToggleHooked', true)
        LOG('M28CampaignAssist: toggle callback hooked')
    else
        LOG('M28CampaignAssist: M28SharedArmiesCallback not found; relying on reconcile fallback')
    end
else
    LOG('M28CampaignAssist: Callbacks table unavailable; relying on reconcile fallback')
end
