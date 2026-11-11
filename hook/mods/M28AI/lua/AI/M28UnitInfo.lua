
-- M28CampaignAssist: 玩家陆军不再“风筝后退”
--
-- 这个文件由引擎的 SCR_LuaDoFileConcat 追加到
--   mods/M28AI/lua/AI/M28UnitInfo.lua
-- 的末尾，与原文件在同一个 chunk / 环境里。不复制、不修改 M28AI 源码。
--
-- 为什么挂在这里：
--   M28AI 的陆军交战逻辑用单位字段 refbCanKite 判断“打不过能不能边退边打”。
--   该字段由 RecordUnitRange() 在单位建成/升级时写入（M28UnitInfo.lua 2451 起），
--   之后 M28Land 在“继续推进”和“后撤风筝”之间做选择时会反复读它。
--   把它对玩家陆军置为 false，M28 就会按“不能风筝”的分支处理：
--   靠近敌人后改为 manual attack / attack move 压上去，而不是掉头拉开距离。
--
-- 范围：只影响「玩家 brain（BrainType == 'Human'）+ 单人战役 + 陆军战斗单位」。
--   防空、空军、海军、工程、ACU/SACU、实验级单位不受影响；敌方 AI 与遭遇战完全不受影响。
--
-- 可调：把 ScenarioInfo.Options.M28AssistNoKite 设为 2 可恢复 M28 原版风筝行为。

do
    local bM28AssistNoKiteLogged = false

    local function M28AssistWantsNoKite(oUnit)
        if type(oUnit) ~= 'table' then return false end
        if not oUnit.GetAIBrain then return false end

        local tScenarioInfo = rawget(_G, 'ScenarioInfo')
        if type(tScenarioInfo) ~= 'table' or tScenarioInfo.type ~= 'campaign' then return false end

        local tOptions = tScenarioInfo.Options
        if type(tOptions) ~= 'table' then return false end
        if tonumber(tOptions.M28AssistNoKite or 1) == 2 then return false end

        if type(oUnit.UnitId) ~= 'string' then return false end
        if EntityCategoryContains(categories.COMMAND + categories.SUBCOMMANDER + categories.EXPERIMENTAL, oUnit.UnitId) then return false end
        if not EntityCategoryContains(refCategoryLandCombat, oUnit.UnitId) then return false end

        local oBrain = oUnit:GetAIBrain()
        if oBrain == nil or oBrain.BrainType ~= 'Human' then return false end
        return true
    end

    local fnM28AssistOldRecordUnitRange = RecordUnitRange

    function RecordUnitRange(oUnit, bReferenceIsATableWithUnitId)
        local result = fnM28AssistOldRecordUnitRange(oUnit, bReferenceIsATableWithUnitId)
        if M28AssistWantsNoKite(oUnit) then
            oUnit[refbCanKite] = false
            if not bM28AssistNoKiteLogged then
                bM28AssistNoKiteLogged = true
                LOG('M28CampaignAssist: kiting disabled for human campaign land combat units')
            end
        end
        return result
    end
end
