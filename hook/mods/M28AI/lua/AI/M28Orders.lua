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
--      v12 修正：锁定时间以前是每次调用都无条件续期，包括「刚刚把目标改写回旧目标」
--      的那些轮次。结果锁永不过期 —— 只要目标活着且没跑远，单位会一直咬住不放，
--      这本身就是「一堆单位永远打同一个目标」的另一半原因。现在只有 M28 自己也
--      选中了锁定目标时才续期，被拦下的轮次不续期，到期自然放开。
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
    -- 同一个单位两次「找替代目标」的最小间隔（秒）。范围查询很贵，必须限流。
    local fM28AssistSpreadQueryGap = 2
    -- 占用表的过期条目清理间隔（秒）
    local fM28AssistAttackerSweep = 10
    -- 单个目标上最多记多少个攻击者（纯防御，正常不会碰到）
    local iM28AssistAttackerCap = 24

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

        -- 纯防御：这张表正常情况下最多几个条目。万一异常增长（比如过期清理
        -- 一直没轮到），直接重建，别让一个敌方单位挂着几百个引用。
        if oTarget.M28AssistAttackerCount2 and oTarget.M28AssistAttackerCount2 > iM28AssistAttackerCap then
            tSet = {}
            oTarget.M28AssistAttackers = tSet
            oTarget.M28AssistAttackerCount2 = 0
        end
        oTarget.M28AssistAttackerCount2 = (oTarget.M28AssistAttackerCount2 or 0) + 1
        tSet[oUnit] = fNow

        -- 定期清掉过期条目。清理只是控制表大小，漏清不影响上面的判定
        -- （计数时本来就会按时间过滤）。
        if oTarget.M28AssistAttackerSweep == nil
            or fNow - oTarget.M28AssistAttackerSweep >= fM28AssistAttackerSweep then
            oTarget.M28AssistAttackerSweep = fNow
            local iKept = 0
            for oAttacker, fTime in tSet do
                if fNow - fTime > fM28AssistLoadDecay then
                    tSet[oAttacker] = nil
                else
                    iKept = iKept + 1
                end
            end
            oTarget.M28AssistAttackerCount2 = iKept
        end
    end

    local function M28AssistLockStillGood(oUnit, oLocked, fNow)
        if type(oLocked) ~= 'table' then return false end
        if oUnit.Dead then return false end
        if fNow >= (oUnit.M28AssistLockUntil or 0) then return false end
        if not M28UnitInfo.IsUnitValid(oLocked) then return false end
        local tPos = oUnit:GetPosition()
        local tLockPos = oLocked:GetPosition()
        if tPos == nil or tLockPos == nil then return false end
        local fDist = M28Utilities.GetDistanceBetweenPositions(tPos, tLockPos)
        if fDist == nil or fDist > fM28AssistStickyMaxDist then return false end
        return true
    end

    -- 在附近找一个负载低于配额的敌人。挑负载最低的，同负载挑最近的。
    -- 找不到就返回 nil，调用方保持原目标（集火总比发呆好）。
    local function M28AssistPickSpreadTarget(oUnit, oRejected, fNow)
        if oUnit.Dead then return nil end
        local oBrain = oUnit:GetAIBrain()
        if oBrain == nil then return nil end

        local iRange = (oUnit[M28UnitInfo.refiCombatRange] or 0) + iM28AssistSpreadRangeBonus
        if iRange < iM28AssistSpreadRangeMin then iRange = iM28AssistSpreadRangeMin end
        if iRange > iM28AssistSpreadRangeMax then iRange = iM28AssistSpreadRangeMax end

        local tPos = oUnit:GetPosition()
        if tPos == nil then return nil end
        local tCandidates = oBrain:GetUnitsAroundPoint(M28UnitInfo.refCategoryLandCombat,
            tPos, iRange, 'Enemy')
        if tCandidates == nil or M28Utilities.IsTableEmpty(tCandidates) then return nil end

        local oBest, iBestLoad, fBestDist = nil, 0, 0
        for i, oEnemy in tCandidates do
            if oEnemy ~= oRejected and M28UnitInfo.IsUnitValid(oEnemy) then
                local iLoad = M28AssistAttackerCount(oEnemy, fNow)
                if iLoad < iM28AssistTargetQuota then
                    local tEnemyPos = oEnemy:GetPosition()
                    local fDist = nil
                    if tEnemyPos ~= nil then
                        fDist = M28Utilities.GetDistanceBetweenPositions(tPos, tEnemyPos)
                    end
                    if fDist ~= nil and (oBest == nil or iLoad < iBestLoad
                        or (iLoad == iBestLoad and fDist < fBestDist)) then
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

    -- 清掉指向已失效单位的锁。顺带把 Lua 侧对敌方单位的引用释放掉。
    local function M28AssistDropStaleLocks(oUnit)
        local oLock = oUnit.M28AssistLockTarget
        if oLock ~= nil and not M28UnitInfo.IsUnitValid(oLock) then
            oUnit.M28AssistLockTarget = nil
            oUnit.M28AssistLockUntil = 0
        end
        local oSpread = oUnit.M28AssistSpreadLockTarget
        if oSpread ~= nil and not M28UnitInfo.IsUnitValid(oSpread) then
            oUnit.M28AssistSpreadLockTarget = nil
            oUnit.M28AssistSpreadLockUntil = 0
        end
    end

    -- 决定这次实际打谁。0 / 1 / 2 三步都在这里。
    -- 关键目标（ACU / 敌方实验级 / T3 建筑）永远放行：既不参与分散，也不被粘性拦住。
    local function M28AssistChooseTarget(oUnit, oOrderTarget, fNow, bSpreadUnit)
        M28AssistDropStaleLocks(oUnit)

        -- 0) 分流防抖：上一次分流选定的目标在有效期内优先。
        -- 没有这层，M28 每轮都会把原目标重新算成最佳，单位就在几个目标之间来回跳。
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
            -- 找替代目标是一次范围扫描 + 逐单位类别匹配，很贵。
            -- 每个单位最多每 2 秒查一次；查不到就继续集火，下一轮再说。
            local fNextQuery = oUnit.M28AssistSpreadQueryAt or 0
            if fNow >= fNextQuery then
                oUnit.M28AssistSpreadQueryAt = fNow + fM28AssistSpreadQueryGap
                local oAlt = M28AssistPickSpreadTarget(oUnit, oOrderTarget, fNow)
                if oAlt ~= nil then
                    oOrderTarget = oAlt
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
        end

        -- 2) 目标粘性：锁定期内、旧目标仍可用、且 M28 想换人：改写回旧目标。
        -- 关键目标例外：锁定期间出现 ACU / 敌方实验级 / T3 建筑，允许立刻转火。
        if M28AssistOptionValue('M28AssistStickyTarget', 1) ~= 2
            and not M28AssistIsHighValueTarget(oOrderTarget) then
            local oLocked = oUnit.M28AssistLockTarget
            if oLocked ~= nil and oLocked ~= oOrderTarget
                and M28AssistLockStillGood(oUnit, oLocked, fNow) then
                oOrderTarget = oLocked
            end
        end

        return oOrderTarget
    end

    -- 记账：占用统计与锁定时间。
    -- bRewritten = 这次的目标是被上面改写过（而不是 M28 自己选的）。
    local function M28AssistRecord(oUnit, oOrderTarget, fNow, bSpreadUnit, bRewritten)
        M28AssistBumpAttacker(oOrderTarget, oUnit, fNow)

        if M28AssistOptionValue('M28AssistStickyTarget', 1) == 2 then
            oUnit.M28AssistLockTarget = nil
            oUnit.M28AssistLockUntil = 0
            return
        end

        -- v12：只有 M28 自己也选中了这个目标才续期。
        -- 之前是无条件续期，于是「改写回旧目标」这一步每轮都会把到期时间往后推，
        -- 锁永远不会过期 —— 单位会一直咬着同一个敌人，直到它死或跑出 120 距离。
        -- 现在被拦下的那几轮不续期，锁到期后自然放开，M28 重新获得选目标的自由。
        if not bRewritten then
            local fSticky = fM28AssistStickySeconds
            if bSpreadUnit then fSticky = fM28AssistStickySecondsExp end
            oUnit.M28AssistLockTarget = oOrderTarget
            oUnit.M28AssistLockUntil = fNow + fSticky
            if not bM28AssistStickyLogged then
                bM28AssistStickyLogged = true
                LOG('M28CampaignAssist: target stickiness enabled for human campaign land combat units')
            end
        end
    end

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

        -- 选目标这一步会碰到别的单位：可能已失效、brain 可能为空。
        -- 整段 pcall：一旦出错就按原目标下发。绝不能把异常抛回 M28 的调用方 ——
        -- 那会终止它整条命令线程，从此一批单位都不再收到命令，看着就是「集体发呆」。
        local bOK, oChosen = pcall(M28AssistChooseTarget, oUnit, oOrderTarget, fNow, bSpreadUnit)
        if not bOK or oChosen == nil then oChosen = oOrderTarget end

        local result = fnM28AssistOldAttack(oUnit, oChosen, bAddToExistingQueue, sOptionalOrderDesc, bOverrideMicroOrder)

        -- 记账同样隔离：写失败不影响已经下发出去的命令
        pcall(M28AssistRecord, oUnit, oChosen, fNow, bSpreadUnit, oChosen ~= oOrderTarget)

        return result
    end
end
