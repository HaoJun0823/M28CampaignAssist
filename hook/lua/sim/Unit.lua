-- M28CampaignAssist（M28AI 附属 mod）
-- hook/lua/sim/Unit.lua  -- v5
--
-- 目标：让「逐单位托管」像基因一样由建造者传给产物，并且按钮永远反映真实状态。
--
-- ============ v4 为什么会「有的能继承、有的不行」 ============
-- v3 把状态判成一次性事件：解析线程写一次 oUnit.M28Active = true/false 就结束。
-- 但 M28Active 是 M28AI 的公共字段，至少有四方在写它：
--   1) 玩家 toggle           SimCallbacks.lua
--   2) M28AI 自己的传染      M28Events.lua:2150（OnConstructionStarted）
--   3) M28AI 的 OnCreate     M28Events.lua:3796（只清 UI stat）
--   4) M28AI 的动态开关      M28Overseer.lua:3843 / 3941 / 4135
-- 两条异步线程各写一次，谁后跑完谁生效，于是同一批产物有的继承有的没有。
--
-- ============ v4 的核心思路（v5 完整保留） ============
--   * 权威状态放在 mod 私有字段 oUnit.M28AssistManaged，只有本 mod 写。
--     玩家 toggle 由 hook/lua/SimCallbacks.lua 捕获并直接写入权威值（Explicit）。
--   * 新单位抄建造者的权威值；施工期间继续「跟随」，完工定案。
--   * 一个全局线程持续把权威值投影到 M28Active 与两个 UI stat，
--     M28AI 无论何时改写，最多一个周期就被修回，事件先后不再重要。
--   * 找不到建造者的单位（ACU、剧本直接生成、赠予）不设权威值，不猜也不干预。
--
-- ============ v5：消除线程堆积与卡死风险 ============
-- 实测日志（一局 31 分钟）：v4 的对账表从 254 单调涨到 3328，而存活单位只有
-- 713，也就是每轮要空转 2600 多个死槽位；此外每个单位 OnCreate 都 ForkThread
-- 一个解析线程（最多挂 30 tick）。长局下线程数与遍历量会持续增长，挤占 sim
-- 单线程，观感就是卡顿、像卡死。v5 做了四件事：
--   1) 取消「每单位一个解析线程」，改为待解析队列，由唯一线程按轮处理。
--      全局线程数从「单位数量级」恒定为 1，不再有并发写权威值的窗口。
--   2) 单位登记表槽位复用：死后回收进空闲栈，新单位复用槽位。
--      遍历量从「历史累计单位数」降到「当前存活单位数」。
--   3) 静默期自适应降频 + 按钮可见性 stat 降频，稳态开销大幅下降。
--   4) 看门狗 + 世代编号：唯一线程若静默死亡，下一次建造动作会重启它；
--      重启时旧线程凭世代编号自行退出，不会出现两个线程同时投影。
--      线程长时间无事可做会主动退出，读档/切图后也不会留空转线程。
--
-- ============ 装载与兼容约束（都是踩过的坑） ============
--   * mod_info.lua 的 after 让本 mod 排在 M28AI 之后，M28AssistOldUnit
--     因而是 M28AI 已经 hook 过的 Unit 类。
--   * 本 build 的 _G 有严格 __index 元表，读未定义全局会抛错并中断 hook 装载；
--     可能未就绪的全局一律 rawget。
--   * simInit 串接装载不接受 function(...)；包装函数用具名参数 + unpack(arg)。
--   * sim 侧 Unit:GetStat(key, default) 返回 {Value=...}（零售版 Unit.lua:3086）。
--   * 零售版 Lua 词法器不接受取模运算符，也不接受某些现代符号。本文件全文
--     不使用该字符；判断周期一律用计数器累加后归零，不要改回取模写法。
--   * 不修改 M28AI 任何文件，也不改 ScenarioInfo 之外的全局状态。

local iM28AssistActiveTicks = 10        -- 有活干时的对账周期（tick，1 tick = 0.1 秒）
local iM28AssistQuietTicks = 30         -- 静默期周期（3 秒）
local iM28AssistQuietRounds = 3         -- 连续几轮无变化才进入静默
local iM28AssistExitRounds = 20         -- 无单位且无待解析，连续几轮后线程退出
local iM28AssistStallSeconds = 15       -- 看门狗：超过这么久没有心跳就重启线程
local iM28AssistPendingMaxRounds = 3    -- 新单位最多等几轮才放弃找建造者
local iM28AssistShowStatEvery = 3       -- 按钮可见性 stat 每几轮全量查一次
local iM28AssistMaxLogs = 200           -- 继承判定日志上限（仅防日志爆炸）

local tM28AssistSlots = {}               -- 单位槽位：数组，元素为 unit 或 false
local iM28AssistSlotTop = 0
local tM28AssistFree = {}                -- 已死亡单位的空闲槽位栈
local iM28AssistFreeCount = 0
local tM28AssistPending = {}             -- 待解析队列：数组，元素直接是 unit
local iM28AssistPendingCount = 0
local iM28AssistNewCount = 0

local bM28AssistThreadAlive = false
local iM28AssistGeneration = 0           -- 线程世代；重启后旧线程自行退出
local iM28AssistLastBeat = 0
local iM28AssistRound = 0
local iM28AssistQuiet = 0
local iM28AssistShowCounter = 0
local iM28AssistHeartbeat = 0
local iM28AssistLogCount = 0
local bM28AssistWarned = false

local function M28AssistLog(sText)
    LOG('M28CampaignAssist: ' .. sText)
end

local function M28AssistNow()
    local fnNow = rawget(_G, 'GetGameTimeSeconds')
    if type(fnNow) ~= 'function' then return 0 end
    local bOK, tNow = pcall(fnNow)
    if not bOK or type(tNow) ~= 'number' then return 0 end
    return tNow
end

local function M28AssistInheritEnabled()
    local scenarioInfo = rawget(_G, 'ScenarioInfo')
    if type(scenarioInfo) ~= 'table' or scenarioInfo.type ~= 'campaign' then return false end
    local options = scenarioInfo.Options
    if type(options) ~= 'table' then return false end
    -- 只认选项 1（逐单位手动托管）。3 / 4 是 MOBA / SimCity，由 M28AI 全权处理。
    return tonumber(options.M28CombinedArmy or 2) == 1
end

local function M28AssistIsAlive(oUnit)
    return oUnit ~= nil and not oUnit.Dead and oUnit.GetAIBrain ~= nil
end

local function M28AssistIsHumanUnit(oUnit)
    if not M28AssistIsAlive(oUnit) then return false end
    local brain = oUnit:GetAIBrain()
    return brain ~= nil and brain.BrainType == 'Human'
end

local function M28AssistIsComplete(oUnit)
    if not M28AssistIsAlive(oUnit) or not oUnit.GetFractionComplete then return true end
    local fFraction = oUnit:GetFractionComplete()
    if fFraction == nil then return true end
    return fFraction >= 1
end

local function M28AssistUnitLabel(oUnit)
    if not oUnit then return 'nil' end
    if oUnit.UnitId then return tostring(oUnit.UnitId) end
    if oUnit.GetBlueprint then
        local bp = oUnit:GetBlueprint()
        if bp and bp.BlueprintId then return tostring(bp.BlueprintId) end
    end
    return '?'
end

-- 读 UI stat。返回数字，读不到返回 nil（此时对账会无条件补写）。
-- 调用方统一由 per-unit pcall 保护，这里不再层层包 pcall，省掉每单位数次开销。
local function M28AssistReadStat(oUnit, sKey)
    if not oUnit.GetStat then return nil end
    local vStat = oUnit:GetStat(sKey, 0)
    if vStat == nil then return nil end
    if type(vStat) == 'table' then return tonumber(vStat.Value or 0) end
    if type(vStat) == 'number' then return vStat end
    return nil
end

-- 取某单位「当前应被视为的托管状态」，用于读取建造者。
-- 优先用 mod 权威值；尚未定案的单位则退回 M28AI 的实际字段。
local function M28AssistGetManaged(oUnit)
    if not oUnit then return false end
    if oUnit.M28AssistManaged ~= nil then return oUnit.M28AssistManaged == true end

    -- 与 M28Events.lua:2149 一致的特例：外部工厂单元自身可能不带标记，要看母体
    local tCategories = rawget(_G, 'categories')
    local fnContains = rawget(_G, 'EntityCategoryContains')
    local oParent = oUnit.Parent
    if oParent and oParent ~= oUnit and oUnit.UnitId and tCategories
        and tCategories.EXTERNALFACTORYUNIT and type(fnContains) == 'function' then
        local bIsExternal = fnContains(tCategories.EXTERNALFACTORYUNIT, oUnit.UnitId)
        if bIsExternal then
            -- 只回退一层，不做递归：Parent 链万一成环会拖死对账线程
            if oParent.M28AssistManaged ~= nil then
                return oParent.M28AssistManaged == true
            end
            return oParent.M28Active == true
        end
    end

    return oUnit.M28Active == true
end

-- 把权威值投影到 M28Active + 两个 UI stat。返回是否改动过。
-- bCheckShow 为 false 时跳过按钮可见性检查（低频全量查询即可）。
local function M28AssistProject(oUnit, bCheckShow)
    local vManaged = oUnit.M28AssistManaged
    if vManaged == nil then
        -- 未定案（ACU、剧本直接生成等）：不碰 M28Active，交给 M28AI 默认；
        -- 但仍保证托管按钮可见，否则玩家没法亲手点亮它。
        if bCheckShow then
            local iShow = M28AssistReadStat(oUnit, 'M28CombinedArmiesShowUI')
            if iShow == nil or iShow ~= 1 then
                oUnit:UpdateStat('M28CombinedArmiesShowUI', 1)
                return true
            end
        end
        return false
    end

    local bManaged = (vManaged == true)
    local bChanged = false

    if (oUnit.M28Active == true) ~= bManaged then
        oUnit.M28Active = bManaged
        bChanged = true
    end

    local iWanted = bManaged and 1 or 0
    local iActive = M28AssistReadStat(oUnit, 'M28Active')
    if iActive == nil or iActive ~= iWanted then
        oUnit:UpdateStat('M28Active', iWanted)
        bChanged = true
    end

    -- 按钮显不显示由这个 stat 决定（M28AI/hook/lua/ui/game/orders.lua:234）
    if bCheckShow then
        local iShow = M28AssistReadStat(oUnit, 'M28CombinedArmiesShowUI')
        if iShow == nil or iShow ~= 1 then
            oUnit:UpdateStat('M28CombinedArmiesShowUI', 1)
            bChanged = true
        end
    end

    return bChanged
end

-- 单位级对账：先处理「跟随建造者」，再处理玩家意图兜底，最后投影。
local function M28AssistReconcileUnit(oUnit, bCheckShow)
    -- 建造期间跟随建造者：玩家如果在施工中途改了建造者的托管状态，
    -- 产物会跟着改；完工即定案。显式 toggle 过的单位永远不跟随。
    if oUnit.M28AssistFollow and oUnit.M28AssistBuilder
        and not oUnit.M28AssistExplicit then
        local oBuilder = oUnit.M28AssistBuilder
        if M28AssistIsAlive(oBuilder) and not M28AssistIsComplete(oUnit) then
            oUnit.M28AssistManaged = M28AssistGetManaged(oBuilder)
        else
            oUnit.M28AssistFollow = false
            oUnit.M28AssistBuilder = nil
        end
    end

    -- 兜底：万一 SimCallbacks hook 没挂上，也要能认出玩家手动 toggle，
    -- 否则对账会把玩家刚点亮或熄灭的单位改回去。
    -- 判据：sim 字段与 UI stat 一致（toggle 会同时写两者），却与权威值不符，
    -- 且单位已完工（排除 M28AI 在建造开始时打上的继承标记）。
    if oUnit.M28AssistManaged ~= nil and not oUnit.M28AssistExplicit then
        local bSim = (oUnit.M28Active == true)
        local iStat = M28AssistReadStat(oUnit, 'M28Active')
        if iStat ~= nil and (iStat ~= 0) == bSim
            and bSim ~= (oUnit.M28AssistManaged == true)
            and M28AssistIsComplete(oUnit) then
            oUnit.M28AssistManaged = bSim
            oUnit.M28AssistExplicit = true
            oUnit.M28AssistFollow = false
            oUnit.M28AssistBuilder = nil
        end
    end

    -- 未定案单位数量很少，每轮都查按钮可见性；已定案的按低频全量查。
    if oUnit.M28AssistManaged == nil then bCheckShow = true end
    return M28AssistProject(oUnit, bCheckShow)
end

-- 槽位分配：优先复用死亡单位留下的槽位，避免登记表无限增长。
local function M28AssistTrackUnit(oUnit)
    if oUnit.M28AssistSlot ~= nil then return end
    local iSlot
    if iM28AssistFreeCount > 0 then
        iSlot = tM28AssistFree[iM28AssistFreeCount]
        tM28AssistFree[iM28AssistFreeCount] = nil
        iM28AssistFreeCount = iM28AssistFreeCount - 1
    else
        iM28AssistSlotTop = iM28AssistSlotTop + 1
        iSlot = iM28AssistSlotTop
    end
    tM28AssistSlots[iSlot] = oUnit
    oUnit.M28AssistSlot = iSlot
    iM28AssistNewCount = iM28AssistNewCount + 1
end

-- 待解析队列：只入队，不 ForkThread。轮数记在单位自己身上，省掉临时表。
local function M28AssistQueuePending(oUnit)
    if oUnit.M28AssistPending then return end
    oUnit.M28AssistPending = true
    oUnit.M28AssistPendingRounds = 0
    iM28AssistPendingCount = iM28AssistPendingCount + 1
    tM28AssistPending[iM28AssistPendingCount] = oUnit
end

-- 单个待解析单位：返回 bDone（是否出队）, bResolved（是否定案）。
-- 单独抽成函数，好让 pcall 逐单位隔离：一个坏单位不能让整轮对账作废。
local function M28AssistResolveOne(oUnit)
    if not M28AssistIsAlive(oUnit) then return true, false end
    if oUnit.M28AssistManaged ~= nil or oUnit.M28AssistExplicit then return true, false end

    local oBuilder = oUnit.M28AssistBuilder or oUnit.Parent
    if not (oBuilder and oBuilder ~= oUnit) then
        oUnit.M28AssistPendingRounds = (oUnit.M28AssistPendingRounds or 0) + 1
        if oUnit.M28AssistPendingRounds < iM28AssistPendingMaxRounds then
            return false, false
        end
        return true, false   -- 超时：保持 M28AI 默认，不猜
    end

    if M28AssistIsHumanUnit(oUnit) and M28AssistIsAlive(oBuilder) then
        local bManaged = M28AssistGetManaged(oBuilder)
        oUnit.M28AssistManaged = bManaged
        oUnit.M28AssistFollow = true
        oUnit.M28AssistBuilder = oBuilder
        if iM28AssistLogCount < iM28AssistMaxLogs then
            iM28AssistLogCount = iM28AssistLogCount + 1
            M28AssistLog('inherit ' .. M28AssistUnitLabel(oUnit)
                .. ' <- ' .. M28AssistUnitLabel(oBuilder)
                .. ' managed=' .. tostring(bManaged)
                .. ' (builderManaged=' .. tostring(oBuilder.M28AssistManaged)
                .. ', builderActive=' .. tostring(oBuilder.M28Active or false)
                .. ', builderHuman=' .. tostring(M28AssistIsHumanUnit(oBuilder))
                .. ')')
        end
        return true, true
    end
    return true, false
end

-- 每轮处理待解析队列：找到建造者就定案，超时就放弃（保持 M28AI 默认）。
-- 采用「原地压缩」写法，避免一边遍历一边删除造成跳过或死循环。
local function M28AssistResolvePending()
    if iM28AssistPendingCount == 0 then return 0, 0 end
    local iWrite = 0
    local iResolved = 0
    for i = 1, iM28AssistPendingCount do
        local oUnit = tM28AssistPending[i]
        local bDone, bResolved = true, false
        local bOK, a, b = pcall(M28AssistResolveOne, oUnit)
        if bOK then
            bDone, bResolved = a, b
        elseif not bM28AssistWarned then
            bM28AssistWarned = true
            M28AssistLog('resolve pending failed: ' .. tostring(a))
        end
        if bResolved then iResolved = iResolved + 1 end
        if bDone then
            if oUnit then
                oUnit.M28AssistPending = nil
                oUnit.M28AssistPendingRounds = nil
            end
        else
            iWrite = iWrite + 1
            tM28AssistPending[iWrite] = oUnit
        end
    end
    for i = iWrite + 1, iM28AssistPendingCount do
        tM28AssistPending[i] = nil
    end
    iM28AssistPendingCount = iWrite
    return iResolved, iWrite
end

-- 一轮完整的对账。返回：定案数、剩余待解析数、存活数、修正数、新登记数。
-- 整轮由外层 pcall 保护，任何单个单位出错都不会杀死唯一的线程。
local function M28AssistReconcileRound()
    if not M28AssistInheritEnabled() then return 0, 0, 0, 0, 0 end

    local iResolved, iPending = M28AssistResolvePending()

    iM28AssistRound = iM28AssistRound + 1
    iM28AssistShowCounter = iM28AssistShowCounter + 1
    local bCheckShow = false
    if iM28AssistShowCounter >= iM28AssistShowStatEvery then
        bCheckShow = true
        iM28AssistShowCounter = 0
    end
    -- 静默期一轮本来就是几秒，索性每轮都查一次，缩短按钮恢复窗口
    if iM28AssistQuiet >= iM28AssistQuietRounds then bCheckShow = true end

    local iAlive, iFixed = 0, 0
    for i = 1, iM28AssistSlotTop do
        local oUnit = tM28AssistSlots[i]
        if oUnit ~= nil and oUnit ~= false then
            if oUnit.Dead then
                tM28AssistSlots[i] = false
                oUnit.M28AssistSlot = nil
                iM28AssistFreeCount = iM28AssistFreeCount + 1
                tM28AssistFree[iM28AssistFreeCount] = i
            else
                iAlive = iAlive + 1
                local bOK, bFixed = pcall(M28AssistReconcileUnit, oUnit, bCheckShow)
                if not bOK then
                    if not bM28AssistWarned then
                        bM28AssistWarned = true
                        M28AssistLog('reconcile unit failed: ' .. tostring(bFixed))
                    end
                elseif bFixed then
                    iFixed = iFixed + 1
                end
            end
        end
    end

    local iNew = iM28AssistNewCount
    iM28AssistNewCount = 0

    iM28AssistHeartbeat = iM28AssistHeartbeat + 1
    -- 心跳：确认线程真的在跑。零售版词法器不接受取模运算符，用计数器代替。
    if iM28AssistRound == 1 or iM28AssistHeartbeat >= 30 then
        iM28AssistHeartbeat = 0
        M28AssistLog('reconcile round=' .. tostring(iM28AssistRound)
            .. ' slots=' .. tostring(iM28AssistSlotTop)
            .. ' alive=' .. tostring(iAlive)
            .. ' pending=' .. tostring(iPending)
            .. ' fixed=' .. tostring(iFixed)
            .. ' quiet=' .. tostring(iM28AssistQuiet))
    end

    return iResolved, iPending, iAlive, iFixed, iNew
end

-- 唯一的常驻线程。整轮 pcall + 世代编号，保证「不会静默死掉、不会双开」。
local function M28AssistReconcileLoop(iGeneration)
    while true do
        if iGeneration ~= iM28AssistGeneration then
            return   -- 已被看门狗重启，旧线程安静退出，不动共享标志
        end

        local bOK, a, b, c, d, e = pcall(M28AssistReconcileRound)
        local iResolved, iPending, iAlive, iFixed, iNew = 0, 0, 0, 0, 0
        if bOK and a then
            iResolved, iPending, iAlive, iFixed, iNew = a, b, c, d, e
        elseif not bM28AssistWarned then
            bM28AssistWarned = true
            M28AssistLog('reconcile round failed: ' .. tostring(a))
        end

        iM28AssistLastBeat = M28AssistNow()

        if iFixed > 0 or iResolved > 0 or iPending > 0 or iNew > 0 then
            iM28AssistQuiet = 0
        else
            iM28AssistQuiet = iM28AssistQuiet + 1
        end

        -- 长时间没有任何单位：退出线程，下次建造动作会重新拉起（读档/切图自愈）
        if iAlive == 0 and iPending == 0 and iM28AssistQuiet >= iM28AssistExitRounds then
            if iGeneration == iM28AssistGeneration then
                bM28AssistThreadAlive = false
                M28AssistLog('reconcile thread idle, exiting')
            end
            return
        end

        local iWait = iM28AssistActiveTicks
        if iM28AssistQuiet >= iM28AssistQuietRounds then
            iWait = iM28AssistQuietTicks
        end
        WaitTicks(iWait)
    end
end

-- 看门狗：正常时直接返回；唯一线程若超过阈值没心跳，重启它。
-- 每次 OnCreate / OnStartBuild 都会调用，代价只是一次时间查询。
local function M28AssistEnsureReconciler()
    local tNow = M28AssistNow()
    if bM28AssistThreadAlive then
        if tNow <= 0 then return end
        if tNow - iM28AssistLastBeat < iM28AssistStallSeconds then return end
        M28AssistLog('reconcile thread stalled, restarting (last beat '
            .. tostring(iM28AssistLastBeat) .. ', now ' .. tostring(tNow) .. ')')
    end
    bM28AssistThreadAlive = true
    iM28AssistGeneration = iM28AssistGeneration + 1
    iM28AssistLastBeat = tNow
    iM28AssistQuiet = 0
    ForkThread(M28AssistReconcileLoop, iM28AssistGeneration)
    M28AssistLog('reconcile thread started (generation '
        .. tostring(iM28AssistGeneration) .. ')')
end

local M28AssistOldUnit = Unit
Unit = Class(M28AssistOldUnit) {
    OnCreate = function(self)
        local result
        if M28AssistOldUnit.OnCreate then
            result = M28AssistOldUnit.OnCreate(self)
        end
        -- 非战役不介入：不登记、不入队、也不启动线程
        if M28AssistInheritEnabled() then
            M28AssistTrackUnit(self)
            M28AssistQueuePending(self)
            M28AssistEnsureReconciler()
        end
        return result
    end,

    -- 只记录建造者，不在这里判定：OnStartBuild 太早（产物 UnitId 可能还是 nil），
    -- 且 Repair / Upgrade 也会触发。真正的判定在唯一线程的待解析队列里做。
    OnStartBuild = function(self, built, order, ...)
        local result
        if M28AssistOldUnit.OnStartBuild then
            result = M28AssistOldUnit.OnStartBuild(self, built, order, unpack(arg))
        end
        if M28AssistInheritEnabled() then
            -- 读档后单位不会再触发 OnCreate；任何建造动作都顺带检查线程是否存活
            M28AssistEnsureReconciler()
            if result ~= false and built and not built.Dead
                and order ~= 'Repair'
                and built.M28AssistManaged == nil
                and not built.M28AssistExplicit then
                built.M28AssistBuilder = self
                -- 产物可能已经因为等待超时离开队列；补一次登记与入队
                M28AssistTrackUnit(built)
                M28AssistQueuePending(built)
            end
        end
        return result
    end,
}
