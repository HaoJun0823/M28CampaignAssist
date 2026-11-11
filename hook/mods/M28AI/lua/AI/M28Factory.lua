-- M28CampaignAssist: 工厂选兵不再“来回重复同一种”
--
-- 这个文件由引擎的 SCR_LuaDoFileConcat 追加到
--   mods/M28AI/lua/AI/M28Factory.lua
-- 的末尾，与原文件在同一个 chunk / 环境里。不复制、不修改 M28AI 源码。
--
-- 背景（读原文件确认过的）：
--   GetBlueprintThatCanBuildOfCategory 末尾是 math.random(1, iBestBlueprints)，
--   看起来已经随机了，但随机是在一个可能只有两三个元素的候选表里做的：
--     - iBestBlueprints 是「科技等级 >= 当前最高科技、且优先级最高」的那批
--     - 蓝图优先级表 reftBlueprintPriorityOverride 在 M28AI v328 里没有任何写入点，
--       所以全表为空、所有蓝图优先级都是 0，候选表实际上就是「同科技的全部可造单位」
--   问题在于：纯随机不保证不重复。工厂连续几次抽到同一辆坦克、或连着几个单位都是
--   同一阵营，观感就是「翻来覆去只造那几种」，多阵营建造能力下尤其明显。
--
-- 做法：
--   在函数外面包一层「最近建造记录」：
--     - 记录该工厂最近 3 次选中的蓝图
--     - 若本次结果与最近 2 次中的任何一个相同，重抽一次
--     - 若最近 3 次都是同一阵营（按 UnitId 前两位判断），也重抽一次
--   重抽只调用一次原函数（成本 2 倍，仅发生在命中重复时），拿不到不同结果就保留原值，
--   绝不循环。
--
-- 范围：只影响「玩家 brain（BrainType == 'Human'）+ 单人战役 + 有实体的工厂」。
--   只处理普通选兵模式；求最慢/最快/最便宜/最贵这四种明确的最优解查询完全放行，
--   因为重抽会破坏它们「唯一最优」的语义。敌方 AI 与遭遇战完全不受影响。
--
-- 可调：把 ScenarioInfo.Options.M28AssistBuildVariety 设为 2 可关闭本功能。

do
    local bM28AssistVarietyLogged = false

    local function M28AssistWantsVariety(aiBrain, oFactory)
        if type(aiBrain) ~= 'table' then return false end
        if type(oFactory) ~= 'table' or type(oFactory.UnitId) ~= 'string' then return false end

        -- 这个函数也被用来给工程师/Acu 挑建筑蓝图（M28Engineer、M28Economy、M28ACU），
        -- 那些调用不该被「最近三次」记录影响，所以这里只放行真正的工厂。
        if not EntityCategoryContains(M28UnitInfo.refCategoryFactory, oFactory.UnitId) then return false end

        local tScenarioInfo = rawget(_G, 'ScenarioInfo')
        if type(tScenarioInfo) ~= 'table' or tScenarioInfo.type ~= 'campaign' then return false end

        local tOptions = tScenarioInfo.Options
        if type(tOptions) ~= 'table' then return false end
        if tonumber(tOptions.M28AssistBuildVariety or 1) == 2 then return false end

        if aiBrain.BrainType ~= 'Human' then return false end
        return true
    end

    local function M28AssistFactionOf(sBlueprint)
        if type(sBlueprint) ~= 'string' or string.len(sBlueprint) < 2 then return nil end
        return string.sub(sBlueprint, 1, 2)
    end

    local fnM28AssistOldGetBlueprint = GetBlueprintThatCanBuildOfCategory

    function GetBlueprintThatCanBuildOfCategory(aiBrain, iCategoryCondition, oFactory, bGetSlowest, bGetFastest, bGetCheapest, iOptionalCategoryThatMustBeAbleToBuild, bIgnoreTechDifferences, iOptionalMaxSkirtSize, bGetMostExpensive)
        local sBlueprint = fnM28AssistOldGetBlueprint(aiBrain, iCategoryCondition, oFactory, bGetSlowest, bGetFastest, bGetCheapest, iOptionalCategoryThatMustBeAbleToBuild, bIgnoreTechDifferences, iOptionalMaxSkirtSize, bGetMostExpensive)

        -- 只处理「普通选兵」：四种明确的最优解查询直接放行
        if bGetSlowest or bGetFastest or bGetCheapest or bGetMostExpensive then
            return sBlueprint
        end
        if type(sBlueprint) ~= 'string' then return sBlueprint end
        if not M28AssistWantsVariety(aiBrain, oFactory) then return sBlueprint end

        local tRecent = oFactory.M28AssistRecentBPs
        if type(tRecent) ~= 'table' then
            tRecent = {}
            oFactory.M28AssistRecentBPs = tRecent
        end

        -- 与最近两次重复？
        local bRepeated = (sBlueprint == tRecent[1]) or (sBlueprint == tRecent[2])

        -- 最近三次是否都是同一阵营？
        local bSameFactionStreak = false
        local sFaction = M28AssistFactionOf(sBlueprint)
        if sFaction and M28AssistFactionOf(tRecent[1]) == sFaction
            and M28AssistFactionOf(tRecent[2]) == sFaction
            and M28AssistFactionOf(tRecent[3]) == sFaction then
            bSameFactionStreak = true
        end

        if bRepeated or bSameFactionStreak then
            local sAlt = fnM28AssistOldGetBlueprint(aiBrain, iCategoryCondition, oFactory, bGetSlowest, bGetFastest, bGetCheapest, iOptionalCategoryThatMustBeAbleToBuild, bIgnoreTechDifferences, iOptionalMaxSkirtSize, bGetMostExpensive)
            if type(sAlt) == 'string' and sAlt ~= sBlueprint then
                sBlueprint = sAlt
                if not bM28AssistVarietyLogged then
                    bM28AssistVarietyLogged = true
                    LOG('M28CampaignAssist: build variety reroll active for human campaign factories')
                end
            end
        end

        -- 记录（最新的在前）
        tRecent[3] = tRecent[2]
        tRecent[2] = tRecent[1]
        tRecent[1] = sBlueprint
        return sBlueprint
    end
end
