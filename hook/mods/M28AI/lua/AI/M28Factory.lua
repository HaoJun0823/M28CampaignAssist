
-- M28CampaignAssist: engineer production cap
--
-- 这个文件由引擎的 SCR_LuaDoFileConcat 追加到
--   mods/M28AI/lua/AI/M28Factory.lua
-- 的末尾，和原文件在同一个 chunk / 环境里。它不复制、也不修改 M28AI 的任何源码。
--
-- 为什么挂在这里：
--   M28AI 的陆/空/海/实验级工厂，最终都要经过 AdjustBlueprintForOverrides()
--   决定“这轮造什么”。它返回 nil 时，调用方 ConsiderBuildingCategory 会继续试
--   下一个条件类别，也就是工厂会自动改道去造战斗单位，而不是停工。
--   所以这里是唯一一个“改产物但不改排产框架”的干净闸口。
--
-- 只对玩家（BrainType == 'Human'）生效，战役里的敌方 AI 完全不受影响。
--
-- 可调（写在 ScenarioInfo.Options 里，不写就用默认值）：
--   M28AssistEngiCap   总工程师上限，默认 20
--   M28AssistEngiT1Cap T1 工程师上限，默认 8

do
    local iDefaultEngiCap = 20
    local iDefaultEngiT1Cap = 8
    local iEngiCacheSeconds = 1

    local function M28AssistGetOptionNumber(sKey, iDefault)
        local tScenarioInfo = rawget(_G, 'ScenarioInfo')
        if type(tScenarioInfo) ~= 'table' then return iDefault end
        local tOptions = tScenarioInfo.Options
        if type(tOptions) ~= 'table' then return iDefault end
        local vValue = tOptions[sKey]
        if vValue == nil then return iDefault end
        return tonumber(vValue) or iDefault
    end

    local function M28AssistCountEngineers(aiBrain)
        local iTotal = 0
        local iT1 = 0
        local bOK, iValue = pcall(function()
            return aiBrain:GetCurrentUnits(M28UnitInfo.refCategoryEngineer)
        end)
        if bOK and type(iValue) == 'number' then iTotal = iValue end
        bOK, iValue = pcall(function()
            return aiBrain:GetCurrentUnits(M28UnitInfo.refCategoryEngineer * categories.TECH1)
        end)
        if bOK and type(iValue) == 'number' then iT1 = iValue end
        return iTotal, iT1
    end

    local fnM28AssistOldAdjustBlueprintForOverrides = AdjustBlueprintForOverrides

    function AdjustBlueprintForOverrides(aiBrain, oFactory, sBPIDToBuild, tLZTeamData, iFactoryTechLevel)
        local sResult = fnM28AssistOldAdjustBlueprintForOverrides(aiBrain, oFactory, sBPIDToBuild, tLZTeamData, iFactoryTechLevel)
        if not sResult then return sResult end
        if not aiBrain or aiBrain.BrainType ~= 'Human' then return sResult end
        if not EntityCategoryContains(M28UnitInfo.refCategoryEngineer, sResult) then return sResult end

        local fNow = GetGameTimeSeconds()
        local iTotal = aiBrain.M28AssistEngiTotal
        local iT1 = aiBrain.M28AssistEngiT1
        if iTotal == nil or iT1 == nil or fNow >= (aiBrain.M28AssistEngiCacheTime or 0) then
            iTotal, iT1 = M28AssistCountEngineers(aiBrain)
            aiBrain.M28AssistEngiCacheTime = fNow + iEngiCacheSeconds
            aiBrain.M28AssistEngiTotal = iTotal
            aiBrain.M28AssistEngiT1 = iT1
        end

        local iCapTotal = M28AssistGetOptionNumber('M28AssistEngiCap', iDefaultEngiCap)
        local iCapT1 = M28AssistGetOptionNumber('M28AssistEngiT1Cap', iDefaultEngiT1Cap)
        local bBlocked = (iTotal >= iCapTotal) or (iT1 >= iCapT1)

        if bBlocked ~= aiBrain.M28AssistEngiGateClosed then
            aiBrain.M28AssistEngiGateClosed = bBlocked
            if fNow - (aiBrain.M28AssistEngiGateLogTime or -100) >= 10 then
                aiBrain.M28AssistEngiGateLogTime = fNow
                LOG('M28CampaignAssist: engineer gate ' .. tostring(bBlocked and 'closed' or 'open')
                    .. ' total=' .. tostring(iTotal) .. '/' .. tostring(iCapTotal)
                    .. ' t1=' .. tostring(iT1) .. '/' .. tostring(iCapT1))
            end
        end

        if bBlocked then return nil end
        return sResult
    end

    LOG('M28CampaignAssist: engineer cap hook installed (default total=' .. tostring(iDefaultEngiCap)
        .. ', t1=' .. tostring(iDefaultEngiT1Cap) .. ')')
end
