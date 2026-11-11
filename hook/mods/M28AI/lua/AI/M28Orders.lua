-- M28CampaignAssist: 托管单位的攻击目标管理
--
-- 这个文件由引擎的 SCR_LuaDoFileConcat 追加到
--   mods/M28AI/lua/AI/M28Orders.lua
-- 的末尾，与原文件在同一个 chunk / 环境里。不复制、不修改 M28AI 源码。
--
-- 解决两个现象（都出现在玩家托管的陆军战斗单位上）：
--
--   A) 视野内出现敌军就换目标，不管强弱远近。
--      M28 的陆军每 11 tick（约 0.55 秒）重新评估一次目标，选到不同的敌人就发一条
--      新的 attack 命令。命令本身由 IssueTrackedAttack 去重（同一目标不会重复下发），
--      但「A -> B -> A」这种来回切会不断清掉当前攻击队列（内部会先 IssueTracked
--      ClearCommands），单位于是走到一半又掉头。
--      → 目标粘性：锁定后 8 秒（实验级 12 秒）内，旧目标还活着且仍在 120 距离内，
--        就把命令改写回旧目标。到期或旧目标失效/跑远后自动放开。
--
--   B) 7-8 个实验级单位同时围攻同一个目标，火力严重过剩。
--      M28 的目标选择是「每个单位独立挑最合适的敌人」，没有占用概念，于是同一批
--      单位会全部指向同一个目标。第一个目标通常 1-2 秒就打死了，其余火力全是浪费。
--      → 火力分散：只对实验级生效。给每个目标记录「最近 6 秒内有多少个托管的实验级
--        在打它」，超过 3 个就换一个附近负载更低的目标。附近没有别的目标时照旧集火
--        （总比发呆好）。敌方 ACU / SACU / 实验级 / T3 建筑属于关键目标，不受配额限制。
--
-- 范围：只影响「玩家 brain（BrainType == 'Human'）+ 单人战役 + 陆军战斗单位 +
--   M28Active 已打开」。防空、空军、海军、工程、ACU/SACU 不在内；敌方 AI 与遭遇战
--   完全不受影响。玩家自己下达的攻击命令走引擎，不经过这里。
--
-- 可调：ScenarioInfo.Options.M28AssistStickyTarget = 2 关闭粘性
--       ScenarioInfo.Options.M28AssistSpreadTarget  = 2 关闭火力分散

do
    local bM28AssistStickyLogged = false
    local bM28AssistSpreadLogged = false

    -- 粘性：普通陆军 8 秒，实验级 12 秒（走得慢，换一次目标的代价更大）
    local fM28AssistStickySeconds = 8
    local fM28AssistStickySecondsExp = 12
    -- 旧目标离单位超过这个距离就允许换目标（避免追着远处残兵不放）
    local fM28AssistStickyMaxDist = 120

    -- 分散：同一目标最多几个托管的实验级同时打
    local iM28AssistTargetQuota = 3
    -- 超过这么多秒没有再次请求，就不再算作「正在打这个目标」
    local fM28AssistLoadDecay = 6
    -- 一次分流后保持多久不再重新挑目标（秒）。太短会在几个目标之间跳，太长会追着残兵。
    local fM28AssistSpreadSeconds = 8
    -- 分流时搜索附近敌人的半径 = 自身射程 + 20，钳在 [40, 120]
    local iM28AssistSpreadRangeMin = 40
    local iM28AssistSpreadRangeMax = 120
    local iM28AssistSpreadRangeBonus = 20
    -- 占用表的过期条目清理间隔（秒）
    local fM28AssistAttackerSweep = 10

    local function M28AssistOptionValue(sKey, iDefault)
        local tScenarioInfo = rawget(_G, 'ScenarioInfo')
        if type(tScenarioInfo) ~= 'table' then return iDefault end
        local tOptions = tScenarioInfo.Options
        if type(tOptions) ~= 'table' then return iDefault end
        return tonumber(tOptions[sKey] or iDefault) or iDefault
    end

    -- 实验级移动单位。注意不用 refCategoryLandExperimental：那个类别把
    -- 「T3 工程造的直接火力单位」也算进来了，会把普通 T3 一起分流。
    local function M28AssistIsExperimentalUnit(oUnit)
        if type(oUnit) ~= 'table' or type(oUnit.UnitId) ~= 'string' then return false end
        local bCached = oUnit.M28AssistIsExp
        if bCached ~= nil then return bCached end
        local bResult = EntityCategoryContains(categories.EXPERIMENTAL * categories.MOBILE, oUnit.UnitId)
        oUnit.M28AssistIsExp = bResult
        return bResult
    end

    -- 关键目标不吃配额：ACU/SACU、敌方实验级、T3 建筑还是该集火
    local function M28AssistIsHighValueTarget(oTarget)
        if type(oTarget) ~= 'table' or type(oTarget.UnitId) ~= 'string' then return false end
        local bCached = oTarget.M28AssistIsHV
        if bCached ~= nil then return bCached end
        local bResult = EntityCategoryContains(
            categories.COMMAND + categories.SUBCOMMANDER + categories.EXPERIMENTAL
            + (categories.STRUCTURE * categories.TECH3), oTarget.UnitId)
        oTarget.M28AssistIsHV = bResult
        return bResult
    end

    -- 是否属于本功能的单位。类别与 brain 类型在生命周期内不变，按单位缓存一次。
    local function M28AssistEligible(oUnit)
        if type(oUnit) ~= 'table' then return false end
        if not oUnit.GetAIBrain then return false end

        local tScenarioInfo = rawget(_G, 'ScenarioInfo')
        if type(tScenarioInfo) ~= 'table' or tScenarioInfo.type ~= 'campaign' then return false end

        local bCached = oUnit.M28AssistEligible
        if bCached ~= nil then return bCached end

        local bResult = false
        if type(oUnit.UnitId) == 'string'
            and not EntityCategoryContains(categories.COMMAND + categories.SUBCOMMANDER, oUnit.UnitId)
            and EntityCategoryContains(M28UnitInfo.refCategoryLandCombat, oUnit.UnitId) then
            local oBrain = oUnit:GetAIBrain()
            -- brain 还没挂上时不缓存，下一次调用再判（缓存 false 会让这个单位永久失效）
            if oBrain == nil then return false end
            if oBrain.BrainType == 'Human' then bResult = true end
        end
        oUnit.M28AssistEligible = bResult
        return bResult
    end

    -- 有多少个「托管的实验级」最近还在打这个目标。
    -- 数据记在目标单位自己身上，单位死了字段跟着消失，不需要额外的全局清理。
    local function M28AssistAttackerCount(oTarget, fNow)
        if type(oTarget) ~= 'table' or type(oTarget.UnitId) ~= 'string' then return 0 end
        local tSet = oTarget.M28AssistAttackers
        if tSet == nil then return 0 end
        local iCount = 0
        for oAttacker, fTime in tSet do
            if fNow - fTime <= fM28AssistLoadDecay
                and oAttacker.M28Active
                and M28AssistIsExperimentalUnit(oAttacker) then
                iCount = iCount + 1
            end
        end
        return iCount
    end

    local function M28AssistBumpAttacker(oTarget, oUnit, fNow)
        -- 只记在真正的单位上。攻击命令的目标通常是单位，但也可能是位置表，
        -- 往那种共享表上挂字段没有意义还容易出错。
        if type(oTarget) ~= 'table' or type(oTarget.UnitId) ~= 'string' then return end
        local tSet = oTarget.M28AssistAttackers
        if tSet == nil then
            tSet = {}
            oTarget.M28AssistAttackers = tSet
        end
        tSet[oUnit] = fNow

        -- 定期清掉过期条目。清理只是控制表大小，漏清不影响上面的判定
        -- （计数时本来就会按时间过滤）。
        if oTarget.M28AssistAttackerSweep == nil
            or fNow - oTarget.M28AssistAttackerSweep >= fM28AssistAttackerSweep then
            oTarget.M28AssistAttackerSweep = fNow
            for oAttacker, fTime in tSet do
                if fNow - fTime > fM28AssistLoadDecay then
                    tSet[oAttacker] = nil
                end
            end
        end
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

    -- 在附近找一个负载低于配额的敌人。挑负载最低的，同负载挑最近的。
    -- 找不到就返回 nil，调用方保持原目标（集火总比发呆好）。
    local function M28AssistPickSpreadTarget(oUnit, oRejected, fNow)
        local oBrain = oUnit:GetAIBrain()
        if oBrain == nil then return nil end

        local iRange = (oUnit[M28UnitInfo.refiCombatRange] or 0) + iM28AssistSpreadRangeBonus
        if iRange < iM28AssistSpreadRangeMin then iRange = iM28AssistSpreadRangeMin end
        if iRange > iM28AssistSpreadRangeMax then iRange = iM28AssistSpreadRangeMax end

        local tPos = oUnit:GetPosition()
        local tCandidates = oBrain:GetUnitsAroundPoint(M28UnitInfo.refCategoryLandCombat,
            tPos, iRange, 'Enemy')
        if tCandidates == nil or M28Utilities.IsTableEmpty(tCandidates) then return nil end

        local oBest, iBestLoad, fBestDist = nil, 0, 0
        for i, oEnemy in tCandidates do
            if oEnemy ~= oRejected and M28UnitInfo.IsUnitValid(oEnemy) then
                local iLoad = M28AssistAttackerCount(oEnemy, fNow)
                if iLoad < iM28AssistTargetQuota then
                    local fDist = M28Utilities.GetDistanceBetweenPositions(tPos, oEnemy:GetPosition())
                    if oBest == nil or iLoad < iBestLoad
                        or (iLoad == iBestLoad and fDist < fBestDist) then
                        oBest = oEnemy
                        iBestLoad = iLoad
                        fBestDist = fDist
                    end
                end
            end
        end
        return oBest
    end

    local fnM28AssistOldAttack = IssueTrackedAttack

    function IssueTrackedAttack(oUnit, oOrderTarget, bAddToExistingQueue, sOptionalOrderDesc, bOverrideMicroOrder)
        -- 没有目标（清命令）、M28 的组合军队被整体关闭、不属于本功能的单位、
        -- 或托管没打开（原版也不会下发命令）：原样放行。
        -- 后两个条件很重要：未托管单位如果也记占用，会污染分流统计。
        if oOrderTarget == nil or bDontConsiderCombinedArmy
            or not M28AssistEligible(oUnit) or not oUnit.M28Active then
            return fnM28AssistOldAttack(oUnit, oOrderTarget, bAddToExistingQueue, sOptionalOrderDesc, bOverrideMicroOrder)
        end

        local fNow = GetGameTimeSeconds()
        local bSpreadUnit = M28AssistIsExperimentalUnit(oUnit)

        -- 0) 分流防抖：上一次分流选定的目标在有效期内优先。
        -- 没有这层，M28 每轮都会把原目标重新算成最佳，单位就在几个目标之间来回跳。
        -- 关键目标（ACU / 敌方实验级 / T3 建筑）不防抖：出现了就该立刻去打。
        if bSpreadUnit and not M28AssistIsHighValueTarget(oOrderTarget) then
            local oSpread = oUnit.M28AssistSpreadLockTarget
            if oSpread ~= nil and oSpread ~= oOrderTarget
                and fNow < (oUnit.M28AssistSpreadLockUntil or 0)
                and M28UnitInfo.IsUnitValid(oSpread) then
                oOrderTarget = oSpread
            end
        end

        -- 1) 火力分散：目标已经被足够多的实验级盯上，且不是关键目标
        if bSpreadUnit
            and M28AssistOptionValue('M28AssistSpreadTarget', 1) ~= 2
            and not M28AssistIsHighValueTarget(oOrderTarget)
            and M28AssistAttackerCount(oOrderTarget, fNow) >= iM28AssistTargetQuota then
            local oAlt = M28AssistPickSpreadTarget(oUnit, oOrderTarget, fNow)
            if oAlt ~= nil then
                oOrderTarget = oAlt
                -- 记下这次分流，有效期内的后续请求会被第 0 步改回这个目标
                oUnit.M28AssistSpreadLockTarget = oAlt
                oUnit.M28AssistSpreadLockUntil = fNow + fM28AssistSpreadSeconds
                -- 同时清掉粘性锁：否则第 2 步会立刻把它改回旧目标
                oUnit.M28AssistLockTarget = nil
                oUnit.M28AssistLockUntil = 0
                if not bM28AssistSpreadLogged then
                    bM28AssistSpreadLogged = true
                    LOG('M28CampaignAssist: experimental fire spreading enabled (quota '
                        .. tostring(iM28AssistTargetQuota) .. ' per target)')
                end
            end
        end

        -- 2) 目标粘性：锁定期内、旧目标仍可用、且 M28 想换人：改写回旧目标。
        -- 关键目标例外：锁定期间出现 ACU / 敌方实验级 / T3 建筑，允许立刻转火。
        local bSticky = M28AssistOptionValue('M28AssistStickyTarget', 1) ~= 2
        if bSticky and not M28AssistIsHighValueTarget(oOrderTarget) then
            local oLocked = oUnit.M28AssistLockTarget
            if oLocked ~= nil and oLocked ~= oOrderTarget
                and M28AssistLockStillGood(oUnit, oLocked, fNow) then
                oOrderTarget = oLocked
            end
        end

        local result = fnM28AssistOldAttack(oUnit, oOrderTarget, bAddToExistingQueue, sOptionalOrderDesc, bOverrideMicroOrder)

        -- 3) 记账：占用统计与锁定时间
        M28AssistBumpAttacker(oOrderTarget, oUnit, fNow)

        if bSticky then
            local fSticky = fM28AssistStickySeconds
            if bSpreadUnit then fSticky = fM28AssistStickySecondsExp end
            -- M28 每轮都会对同一目标重复调用，所以只要还在打它就一直续期；
            -- 一旦它想换人，上面的分支会拦下并且不续期，到期后锁自然放开。
            oUnit.M28AssistLockTarget = oOrderTarget
            oUnit.M28AssistLockUntil = fNow + fSticky
            if not bM28AssistStickyLogged then
                bM28AssistStickyLogged = true
                LOG('M28CampaignAssist: target stickiness enabled for human campaign land combat units')
            end
        end

        return result
    end
end
