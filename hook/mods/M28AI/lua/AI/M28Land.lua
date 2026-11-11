-- M28CampaignAssist: 玩家陆军不再“向后撤”，直接压上去打
--
-- 这个文件由引擎的 SCR_LuaDoFileConcat 追加到
--   mods/M28AI/lua/AI/M28Land.lua
-- 的末尾，与原文件在同一个 chunk / 环境里。不复制、不修改 M28AI 源码。
--
-- 为什么挂在这里，而不是改 M28UnitInfo.refbCanKite：
--   refbCanKite 的语义是「这门武器能不能在移动中开火」，不是「这个单位会不会
--   后撤」。M28UnitInfo.lua:164 的注释写得很明白：
--     true unless weapon unpacks or experimental with a weapon fixed to body
--     (GC and megalith)
--   全 M28 有十几处分支拿它区分「机动作战单位」和「必须停下来打的站桩单位」。
--   早期版本把玩家陆军的这个字段整体清成 false，后撤确实止住了，但代价是这些
--   坦克在别的判定里被当成 GC/Megalith 处理（该绕行时可能选择停下）。
--
--   真正决定「后退多少米」的只有下面这一句（原文件 BackupUnitTowardsRally
--   IfAvailable 开头）：
--     if oUnit[M28UnitInfo.refbCanKite] then
--         iBackupDist = (oUnit:GetBlueprint().Physics.BackUpDistance or 0)
--     end
--     if iBackupDist >= 6 or iDefaultDistOverride then ... 开始后退 ...
--   所以正确做法是只拦这一个动作：对托管的玩家陆军直接返回，其余判断保持
--   M28 原样。这样既不再后退，也不会把单位误判成站桩单位。
--
-- 范围：只影响「玩家 brain（BrainType == 'Human'）+ 单人战役 + 陆军战斗单位」。
--   防空、空军、海军、工程、ACU/SACU、实验级单位不受影响；敌方 AI 与遭遇战完全
--   不受影响。
--
-- 可调：把 ScenarioInfo.Options.M28AssistNoKite 设为 2 可恢复 M28 原版后撤行为。

do
    local bM28AssistNoRetreatLogged = false

    local function M28AssistWantsNoRetreat(oUnit)
        if type(oUnit) ~= 'table' then return false end
        if not oUnit.GetAIBrain then return false end

        local tScenarioInfo = rawget(_G, 'ScenarioInfo')
        if type(tScenarioInfo) ~= 'table' or tScenarioInfo.type ~= 'campaign' then return false end

        local tOptions = tScenarioInfo.Options
        if type(tOptions) ~= 'table' then return false end
        if tonumber(tOptions.M28AssistNoKite or 1) == 2 then return false end

        if type(oUnit.UnitId) ~= 'string' then return false end
        if EntityCategoryContains(categories.COMMAND + categories.SUBCOMMANDER + categories.EXPERIMENTAL, oUnit.UnitId) then return false end
        if not EntityCategoryContains(M28UnitInfo.refCategoryLandCombat, oUnit.UnitId) then return false end

        local oBrain = oUnit:GetAIBrain()
        if oBrain == nil or oBrain.BrainType ~= 'Human' then return false end
        return true
    end

    local fnM28AssistOldBackup = BackupUnitTowardsRallyIfAvailable

    function BackupUnitTowardsRallyIfAvailable(oUnit, tRallyPoint, iIslandPlateauOrPondRef, sOrderDesc, bAmphibiousAndUsingPlateauRef, iDefaultDistOverride, iMaxAngleDifForMovingBackwardsOverride, bUsingPondRef)
        if M28AssistWantsNoRetreat(oUnit) then
            if not bM28AssistNoRetreatLogged then
                bM28AssistNoRetreatLogged = true
                LOG('M28CampaignAssist: retreat micro disabled for human campaign land combat units')
            end
            return
        end
        return fnM28AssistOldBackup(oUnit, tRallyPoint, iIslandPlateauOrPondRef, sOrderDesc, bAmphibiousAndUsingPlateauRef, iDefaultDistOverride, iMaxAngleDifForMovingBackwardsOverride, bUsingPondRef)
    end
end
