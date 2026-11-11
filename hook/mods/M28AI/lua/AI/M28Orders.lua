
-- M28CampaignAssist: 禁止 M28AI 对玩家单位执行 ctrl-K（自毁/自爆）
--
-- 这个文件由引擎的 SCR_LuaDoFileConcat 追加到
--   mods/M28AI/lua/AI/M28Orders.lua
-- 的末尾，与原文件在同一个 chunk / 环境里。不复制、不修改 M28AI 源码。
--
-- 为什么挂在这里：
--   M28AI 所有“把自己单位销毁掉”的路径，最终都只经过一个函数
--   M28Orders.IssueTrackedKillUnit（全库 20 多处调用）。常见来源：
--     * M28Economy.lua  工程师太多 + 质量卡顿时，每次 ctrl-K 2 个工程师
--     * M28Overseer.lua 接近人口上限时按类别批量 ctrl-K 低价值单位
--     * M28Land.lua     岛上多余的 T1/T2 单位、被更好雷达取代的旧雷达
--     * M28Micro.lua    飞不回去的空军先乱移再 ctrl-K
--   对玩家来说，这些就是“单位莫名其妙自己爆了”。拦截这一个入口即可全部挡住。
--
-- 范围：只拦「玩家 brain（BrainType == 'Human'）+ 单人战役 + 生产/经济资产」。
--   受保护：机动单位、工厂、电厂、质量矿点（mass extractor）。
--   仍允许 M28 清理：旧雷达、失败/低血护盾、墙、挡路建筑 —— 这些是正常升级与腾位置，
--   拦掉反而会让工厂出口被堵。战役里的敌方 AI、以及遭遇战/多人，完全不受影响。
--
-- 可调：把 ScenarioInfo.Options.M28AssistBlockSelfDestruct 设为 2 可关闭本保护。

do
    local iM28AssistKillLogCount = 0
    local iM28AssistKillLogMax = 20

    local function M28AssistIsProtectedUnit(oUnit)
        if type(oUnit) ~= 'table' then return false end
        if not oUnit.GetAIBrain then return false end
        if oUnit.Dead or (oUnit.BeenDestroyed and oUnit:BeenDestroyed()) then return false end

        local tScenarioInfo = rawget(_G, 'ScenarioInfo')
        if type(tScenarioInfo) ~= 'table' or tScenarioInfo.type ~= 'campaign' then return false end

        local tOptions = tScenarioInfo.Options
        if type(tOptions) ~= 'table' then return false end
        if tonumber(tOptions.M28AssistBlockSelfDestruct or 1) == 2 then return false end

        if type(oUnit.UnitId) ~= 'string' then return false end
        local bProtected = EntityCategoryContains(categories.MOBILE, oUnit.UnitId)
            or EntityCategoryContains(M28UnitInfo.refCategoryFactory, oUnit.UnitId)
            or EntityCategoryContains(M28UnitInfo.refCategoryPower, oUnit.UnitId)
            or EntityCategoryContains(M28UnitInfo.refCategoryMex, oUnit.UnitId)
        if not bProtected then return false end

        local oBrain = oUnit:GetAIBrain()
        if oBrain == nil or oBrain.BrainType ~= 'Human' then return false end
        return true
    end

    local fnM28AssistOldKillUnit = IssueTrackedKillUnit

    function IssueTrackedKillUnit(oUnit)
        if M28AssistIsProtectedUnit(oUnit) then
            if iM28AssistKillLogCount < iM28AssistKillLogMax then
                iM28AssistKillLogCount = iM28AssistKillLogCount + 1
                LOG('M28CampaignAssist: blocked M28 self-destruct of '
                    .. tostring(oUnit.UnitId) .. ' (asset kept alive, blocked so far='
                    .. tostring(iM28AssistKillLogCount) .. ')')
            end
            return
        end
        return fnM28AssistOldKillUnit(oUnit)
    end

    LOG('M28CampaignAssist: self-destruct guard installed (human campaign units/factories/power/mex are never ctrl-Ked)')
end
