-- M28CampaignAssist: 托管单位不再“来回换目标”
--
-- 这个文件由引擎的 SCR_LuaDoFileConcat 追加到
--   mods/M28AI/lua/AI/M28Orders.lua
-- 的末尾，与原文件在同一个 chunk / 环境里。不复制、不修改 M28AI 源码。
--
-- 问题：
--   M28 的陆军每 11 tick（约 0.55 秒）重新评估一次目标，选到不同的敌人就发一条
--   新的 attack 命令。命令本身由 IssueTrackedAttack 去重（同一目标不会重复下发），
--   但「A -> B -> A」这种来回切会不断清掉当前攻击队列（内部会先 IssueTracked
--   ClearCommands），单位于是走到一半又掉头，进攻机会就浪费在路上了。
--
-- 做法：
--   在 IssueTrackedAttack 外面加一层「目标粘性」：单位第一次锁定某个目标后，
--   8 秒内如果 M28 想换一个别的目标，只要旧目标还活着、且仍在 120 距离内，
--   就把命令改写回旧目标。到期或旧目标失效/跑远后自动放开，不做永久锁定。
--
-- 范围：只影响「玩家 brain（BrainType == 'Human'）+ 单人战役 + 陆军战斗单位」。
--   防空、空军、海军、工程、ACU/SACU、实验级单位不受影响；敌方 AI 与遭遇战完全
--   不受影响。玩家自己下达的攻击命令走引擎，不经过这里。
--
-- 可调：把 ScenarioInfo.Options.M28AssistStickyTarget 设为 2 可关闭本功能。

do
    local bM28AssistStickyLogged = false

    -- 锁定保持时间（秒）
    local fM28AssistStickySeconds = 8
    -- 旧目标离单位超过这个距离就允许换目标（避免追着远处残兵不放）
    local fM28AssistStickyMaxDist = 120

    local function M28AssistWantsStickyTarget(oUnit)
        if type(oUnit) ~= 'table' then return false end
        if not oUnit.GetAIBrain then return false end

        local tScenarioInfo = rawget(_G, 'ScenarioInfo')
        if type(tScenarioInfo) ~= 'table' or tScenarioInfo.type ~= 'campaign' then return false end

        local tOptions = tScenarioInfo.Options
        if type(tOptions) ~= 'table' then return false end
        if tonumber(tOptions.M28AssistStickyTarget or 1) == 2 then return false end

        -- 这个函数每轮、每单位都会被调若干次，类别判定是这里最贵的一步，
        -- 而单位类别和 brain 类型在生命周期内不会变，所以按单位缓存一次。
        local bCached = oUnit.M28AssistStickyEligible
        if bCached ~= nil then return bCached end

        local bResult = false
        if type(oUnit.UnitId) == 'string'
            and not EntityCategoryContains(categories.COMMAND + categories.SUBCOMMANDER + categories.EXPERIMENTAL, oUnit.UnitId)
            and EntityCategoryContains(M28UnitInfo.refCategoryLandCombat, oUnit.UnitId) then
            local oBrain = oUnit:GetAIBrain()
            if oBrain ~= nil and oBrain.BrainType == 'Human' then bResult = true end
        end
        oUnit.M28AssistStickyEligible = bResult
        return bResult
    end

    local function M28AssistLockStillGood(oUnit, oLocked, fNow)
        if type(oLocked) ~= 'table' then return false end
        if oUnit.Dead then return false end
        if fNow >= (oUnit.M28AssistLockUntil or 0) then return false end
        if not M28UnitInfo.IsUnitValid(oLocked) then return false end
        local fDist = M28Utilities.GetDistanceBetweenPositions(oUnit:GetPosition(), oLocked:GetPosition())
        if fDist == nil or fDist > fM28AssistStickyMaxDist then return false end
        return true
    end

    local fnM28AssistOldAttack = IssueTrackedAttack

    function IssueTrackedAttack(oUnit, oOrderTarget, bAddToExistingQueue, sOptionalOrderDesc, bOverrideMicroOrder)
        -- 没有目标（清命令）或不属于本功能的单位：原样放行
        if oOrderTarget == nil or not M28AssistWantsStickyTarget(oUnit) then
            return fnM28AssistOldAttack(oUnit, oOrderTarget, bAddToExistingQueue, sOptionalOrderDesc, bOverrideMicroOrder)
        end

        local fNow = GetGameTimeSeconds()
        local oLocked = oUnit.M28AssistLockTarget

        -- 锁定期内、旧目标仍可用、且 M28 想换人：改写回旧目标
        if oLocked and oLocked ~= oOrderTarget and M28AssistLockStillGood(oUnit, oLocked, fNow) then
            return fnM28AssistOldAttack(oUnit, oLocked, bAddToExistingQueue, sOptionalOrderDesc, bOverrideMicroOrder)
        end

        local result = fnM28AssistOldAttack(oUnit, oOrderTarget, bAddToExistingQueue, sOptionalOrderDesc, bOverrideMicroOrder)

        -- 接受这个目标后重新起算锁定时间。M28 每轮都会对同一目标重复调用，
        -- 所以只要还在打它就一直续期；一旦它想换人，上面的分支会拦下并且不续期，
        -- 8 秒后锁自然过期，允许换目标。
        oUnit.M28AssistLockTarget = oOrderTarget
        oUnit.M28AssistLockUntil = fNow + fM28AssistStickySeconds
        if not bM28AssistStickyLogged then
            bM28AssistStickyLogged = true
            LOG('M28CampaignAssist: target stickiness enabled for human campaign land combat units')
        end
        return result
    end
end
