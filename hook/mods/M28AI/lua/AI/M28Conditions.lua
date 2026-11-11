
-- M28CampaignAssist: factory count cap
--
-- 这个文件由引擎的 SCR_LuaDoFileConcat 追加到
--   mods/M28AI/lua/AI/M28Conditions.lua
-- 的末尾，和原文件在同一个 chunk / 环境里。不复制、不修改 M28AI 源码。
--
-- 为什么挂在这里：
--   M28AI 在决定“还要不要再造一座工厂”时，陆/空/海和 ACU 的建造逻辑都会先问
--   M28Conditions.WantMoreFactories()。它返回 false 时，工程师/ACU 就不再把
--   新建工厂排进计划，但已有的工厂继续生产。
--   这正好对应“工厂太多、很多停摆”的症状：不是拆掉已有工厂，而是停止继续铺。
--
-- 只对玩家队伍（队里存在 BrainType == 'Human' 的 brain）生效，战役敌方 AI 不受影响。
-- 带 bIgnoreMainEcoConditions 的调用（实验级/ACU 的特殊路径）不拦，避免误伤。
--
-- 可调（写在 ScenarioInfo.Options 里，不写就用默认值）：
--   M28AssistFactoryCap 玩家队伍工厂总数上限，默认 10

do
    local iDefaultFactoryCap = 10
    local iFactoryCapLogGap = 15

    local function M28AssistGetFactoryCap()
        local tScenarioInfo = rawget(_G, 'ScenarioInfo')
        if type(tScenarioInfo) ~= 'table' then return iDefaultFactoryCap end
        local tOptions = tScenarioInfo.Options
        if type(tOptions) ~= 'table' then return iDefaultFactoryCap end
        return tonumber(tOptions.M28AssistFactoryCap) or iDefaultFactoryCap
    end

    -- 实时数“人类玩家”的工厂。不用 M28Team 的缓存计数，因为那个字段在本版本里
    -- 只有初始化、没有可靠的维护点，可能长期为 0。GetCurrentUnits 是引擎查询，
    -- 结果稳定；按队伍做 1 秒缓存，避免 WantMoreFactories 高频调用时反复扫单位。
    local function M28AssistCountHumanFactories(iTeam)
        local tTeamData = M28Team.tTeamData[iTeam]
        if type(tTeamData) ~= 'table' then return nil end
        local tBrains = tTeamData[M28Team.subreftoFriendlyHumanAndAIBrains]
        if type(tBrains) ~= 'table' then return nil end

        local fNow = GetGameTimeSeconds()
        if tTeamData.M28AssistFactoryCountTime and fNow < tTeamData.M28AssistFactoryCountTime then
            return tTeamData.M28AssistFactoryCount
        end

        local iTotal = 0
        local bFoundHuman = false
        for iBrain, oBrain in tBrains do
            if oBrain and oBrain.BrainType == 'Human' then
                bFoundHuman = true
                local bOK, iCount = pcall(function()
                    return oBrain:GetCurrentUnits(M28UnitInfo.refCategoryFactory)
                end)
                if bOK and type(iCount) == 'number' then iTotal = iTotal + iCount end
            end
        end

        if not bFoundHuman then return nil end
        tTeamData.M28AssistFactoryCountTime = fNow + 1
        tTeamData.M28AssistFactoryCount = iTotal
        return iTotal
    end

    local fnM28AssistOldWantMoreFactories = WantMoreFactories

    function WantMoreFactories(iTeam, iPlateau, iLandZone, bIgnoreMainEcoConditions)
        local bResult = fnM28AssistOldWantMoreFactories(iTeam, iPlateau, iLandZone, bIgnoreMainEcoConditions)
        if not bResult then return bResult end
        if bIgnoreMainEcoConditions then return bResult end

        local iTotal = M28AssistCountHumanFactories(iTeam)
        if iTotal == nil then return bResult end

        local iCap = M28AssistGetFactoryCap()
        if iTotal < iCap then return bResult end

        local tTeamData = M28Team.tTeamData[iTeam]
        local fNow = GetGameTimeSeconds()
        if fNow - (tTeamData.M28AssistFactoryCapLogTime or -100) >= iFactoryCapLogGap then
            tTeamData.M28AssistFactoryCapLogTime = fNow
            LOG('M28CampaignAssist: factory cap reached total=' .. tostring(iTotal) .. '/' .. tostring(iCap)
                .. ' (no new factories; existing ones keep producing)')
        end
        return false
    end

    LOG('M28CampaignAssist: factory cap hook installed (default cap=' .. tostring(iDefaultFactoryCap) .. ')')
end
