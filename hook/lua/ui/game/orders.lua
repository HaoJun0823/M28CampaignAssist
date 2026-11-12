-- M28CampaignAssist（M28AI 附属 mod）
-- hook/lua/ui/game/orders.lua  -- v15
--
-- 这个文件只做一件事：让 M28 托管按钮的勾选状态与「真实的托管状态」一致。
--
-- ============ 原版为什么会「有开有关」 ============
-- M28AI 的按钮实现在 mods/M28AI/hook/lua/ui/game/orders.lua，它只信任屏幕上的值：
--   1) 勾选只在「选中单位的那一刻」按 stat 算一次（M28ScriptButtonInitFunction），
--      之后选中期间不再重算；
--   2) 点击时用 self:IsChecked() 取反当作玩家意图。
-- 于是只要屏幕值和真实状态分叉，同一次点击就可能发出相反的值：屏幕显示「亮」而
-- 实际已关 → 点一下发出去的是「关」，看着毫无反应；屏幕显示「暗」而实际开着 →
-- 点一下发的还是「开」。这就是「有开有关、点两下才对」。
--
-- ============ v13 / v14 为什么没解决 ============
-- v13 让按钮每 0.1 秒从 stat 'M28Active' 重算勾选。两个问题：
--   a) 点击之后 stat 要经过 UI→sim→UI 的一次往返才更新，这期间重算把刚画出来的
--      勾选抹回旧值，按钮看起来点了没反应（v14 加「等待窗口」只是在绕这个问题）。
--   b) 更要紧的是实测发现这个 stat 在战役里并不可靠地同步回 UI。它不是蓝图
--      General.StatToggles 里声明的引擎 stat（官方 SetStatByCallback 只接受那种），
--      而是 M28AI 用 UpdateStat 在 Lua 里动态创建的；引擎的同步层对这种 stat 的
--      处理并不等价，切走再切回时读到的仍是 0，按钮就永远显示成暗的。
--
-- ============ v15：勾选状态不再依赖「读 sim」 ============
-- 按以下优先级决定，每一层都不需要网络往返：
--   1) 本局点击记忆 —— 玩家亲手点过的单位，记住他点出来的状态（唯一权威来源）；
--   2) stat 为 1 —— sim 明确说「在托管」，这个方向不会误判；
--   3) 建造者的点击记忆 —— 复现 sim 的继承规则（产物跟着建造者走）；
--   4) stat 为 0。
-- 四层都读不到时保持按钮当前的样子，绝不把按钮强行画成「关」。
--
-- 同时去掉 onframe：勾选只在选择变化时算一次（initialStateFunc），点击时立刻按
-- 目标状态重画。没有逐帧重算，就不存在「重算把点击结果抹掉」的窗口，也不再需要
-- 给按钮挂那个会一直呼吸的光效（AddOrder 只在有 onframe 时才创建它）。
--
-- 装载约束：本文件被 SCR_LuaDoFileConcat 追加到 lua/ui/game/orders.lua 末尾，
-- 因此 defaultOrdersTable / currentSelection / controls 都在同一个 chunk 里可见。
-- M28AI 的 hook 用的是同一套写法（lua/ui/game/orders.lua 里那个
-- local defaultOrdersTable = defaultOrdersTable or { }），mod_info 的 after 保证
-- 它在前面，所以这里拿到的是 M28AI 已经写入 M28Toggle 的那张表。

local tM28AssistOrderInfo = nil

-- 用 pcall 取表：万一某个 build 没有在同一 chunk 里暴露 defaultOrdersTable，
-- 严格 _G 元表会让直接引用抛错并中断整个 UI 文件的装载。宁可安静退化。
local bM28AssistGotTable, tM28AssistTable = pcall(function() return defaultOrdersTable end)

if bM28AssistGotTable and type(tM28AssistTable) == 'table' then
    tM28AssistOrderInfo = tM28AssistTable['M28Toggle']
end

if type(tM28AssistOrderInfo) == 'table' then
    local iM28AssistClickLogs = 0
    local iM28AssistSelectLogs = 0

    -- 点击记忆：entityId -> { b = 状态, s = 蓝图 id }
    -- 只在玩家点击时写，不随时间失效；这是本文件唯一的权威来源。
    local tM28AssistClicked = {}

    local function M28AssistEntityId(oUnit)
        if oUnit == nil or type(oUnit.GetEntityId) ~= 'function' then return nil end
        local iId = oUnit:GetEntityId()
        if type(iId) ~= 'number' then return nil end
        return iId
    end

    local function M28AssistBlueprintId(oUnit)
        if oUnit == nil or type(oUnit.GetUnitId) ~= 'function' then return nil end
        local sId = oUnit:GetUnitId()
        if sId == nil then return nil end
        return tostring(sId)
    end

    -- 读点击记忆：true / false；没有记录返回 nil。
    local function M28AssistFromMemory(oUnit)
        local iId = M28AssistEntityId(oUnit)
        if iId == nil then return nil end
        local tRecord = tM28AssistClicked[iId]
        if tRecord == nil then return nil end
        -- entityId 会被引擎复用；蓝图对不上就当这条记忆属于另一个单位
        local sId = M28AssistBlueprintId(oUnit)
        if tRecord.s ~= nil and sId ~= nil and tRecord.s ~= sId then
            tM28AssistClicked[iId] = nil
            return nil
        end
        return tRecord.b == true
    end

    local function M28AssistRemember(oUnit, bState)
        local iId = M28AssistEntityId(oUnit)
        if iId == nil then return false end
        tM28AssistClicked[iId] = { b = (bState == true), s = M28AssistBlueprintId(oUnit) }
        return true
    end

    -- 读 stat：true / false / nil（nil = 这个单位读不到该 stat）。
    local function M28AssistFromStat(oUnit)
        if oUnit == nil or type(oUnit.GetStat) ~= 'function' then return nil end
        local vStat = oUnit:GetStat('M28Active', 0)
        if vStat == nil then return nil end
        local iValue = nil
        if type(vStat) == 'table' then
            iValue = tonumber(vStat.Value)
        elseif type(vStat) == 'number' then
            iValue = vStat
        end
        if iValue == nil then return nil end
        return iValue ~= 0
    end

    -- 建造者被玩家点过时，产物沿用同一状态（sim 侧的继承规则就是这样）。
    -- 往上找几层：玩家点的是工厂，工厂造的工程车再造出来的东西属于「两跳继承」，
    -- 只查一层的话这些单位会被显示成暗的。
    local function M28AssistFromCreator(oUnit)
        if oUnit == nil or type(oUnit.GetCreator) ~= 'function' then return nil end
        local oCurrent = oUnit
        for iStep = 1, 4 do
            if oCurrent == nil or type(oCurrent.GetCreator) ~= 'function' then return nil end
            local oCreator = oCurrent:GetCreator()
            if oCreator == nil or oCreator == oCurrent then return nil end
            local bMemory = M28AssistFromMemory(oCreator)
            if bMemory ~= nil then return bMemory end
            oCurrent = oCreator
        end
        return nil
    end

    -- 读一个单位当前的托管状态：true / false；读不到返回 nil。
    local function M28AssistReadState(oUnit)
        if oUnit == nil or oUnit.Dead == true then return nil end
        local bMemory = M28AssistFromMemory(oUnit)
        if bMemory ~= nil then return bMemory end

        -- stat 为 1 是 sim 的明确肯定，任何情况下都可以信
        local bStat = M28AssistFromStat(oUnit)
        if bStat == true then return true end

        local bCreator = M28AssistFromCreator(oUnit)
        if bCreator ~= nil then return bCreator end

        return bStat
    end

    -- 统计一组单位的状态，返回 bAnyOn, bAnyOff, iRead。
    -- iRead 为 0 表示一个都没读到：调用方应保持按钮现状，不要画成「关」。
    local function M28AssistScan(oUnits)
        local bAnyOn, bAnyOff, iRead = false, false, 0
        if type(oUnits) ~= 'table' then return bAnyOn, bAnyOff, iRead end
        for i, oUnit in oUnits do
            -- 逐单位 pcall：某个单位正在被销毁时不该让整次刷新作废
            local bOK, bState = pcall(M28AssistReadState, oUnit)
            if bOK and bState ~= nil then
                iRead = iRead + 1
                if bState == true then
                    bAnyOn = true
                else
                    bAnyOff = true
                end
            end
        end
        return bAnyOn, bAnyOff, iRead
    end

    -- 诊断用：统计这组单位里「原始 stat 为 1」和「命中点击记忆」的数量。
    -- 只在选择日志里调用（限流 12 次），不进热路径。
    -- 下一次实机的日志就能区分两种失败：rawstat=0 说明 sim 侧没写成或没同步回来；
    -- rawstat>0 但按钮仍然暗，说明读到了却没用上。
    local function M28AssistProbe(oUnits)
        local iStat, iMem = 0, 0
        if type(oUnits) ~= 'table' then return iStat, iMem end
        for i, oUnit in oUnits do
            if M28AssistFromMemory(oUnit) ~= nil then iMem = iMem + 1 end
            if M28AssistFromStat(oUnit) == true then iStat = iStat + 1 end
        end
        return iStat, iMem
    end

    -- 把状态写到按钮上，并维护混合选择的问号图标。
    -- 复用原版的 _mixedIcon 字段，避免出现两个问号。
    local function M28AssistApply(control, bAnyOn, bAnyOff)
        if not control then return end
        control:SetCheck(bAnyOn == true)

        if bAnyOn and bAnyOff then
            if not control._mixedIcon then
                control._mixedIcon = Bitmap(control, UIUtil.UIFile('/game/orders-panel/question-mark_bmp.dds'))
                LayoutHelpers.AtRightTopIn(control._mixedIcon, control, -2, 2)
            end
        elseif control._mixedIcon then
            control._mixedIcon:Destroy()
            control._mixedIcon = nil
        end
    end

    -- 选择集变化时由框架调用一次（CreateAltOrders 里，currentSelection 已经先更新）。
    tM28AssistOrderInfo.initialStateFunc = function(control, unitList, subCheck)
        local bAnyOn, bAnyOff, iRead = M28AssistScan(unitList)
        if not subCheck then
            -- 一个都没读到就保持原样：画成「关」比留着旧值更容易误导人
            if iRead > 0 then
                M28AssistApply(control, bAnyOn, bAnyOff)
            end
            if iM28AssistSelectLogs < 12 then
                iM28AssistSelectLogs = iM28AssistSelectLogs + 1
                local iStat, iMem = M28AssistProbe(unitList)
                LOG('M28CampaignAssist: select read=' .. tostring(iRead)
                    .. ' on=' .. tostring(bAnyOn)
                    .. ' off=' .. tostring(bAnyOff)
                    .. ' rawstat=' .. tostring(iStat)
                    .. ' mem=' .. tostring(iMem))
            end
        else
            return bAnyOn, bAnyOn and bAnyOff
        end
    end

    -- 点击：按「点击之后应当处于的状态」发意图，不再用屏幕上的旧勾选值取反。
    tM28AssistOrderInfo.behavior = function(self, modifiers, subState)
        local bTarget
        if subState ~= nil then
            -- 框架以程序方式切换时才信它；玩家点击时 subState 为 nil。
            bTarget = (subState == true)
        else
            local bAnyOn, bAnyOff, iRead = M28AssistScan(currentSelection)
            local bCurrent = false
            if iRead > 0 then bCurrent = bAnyOn end
            -- 与 M28AI 原版语义一致：只要还有单位在托管就整组收回，否则整组交出。
            bTarget = not bCurrent
        end

        -- 问号图标表示「混合」，点击之后就不再混合了。
        if self._mixedIcon then
            self._mixedIcon:Destroy()
            self._mixedIcon = nil
        end

        ToggleScriptBit(currentSelection, self._data.extraInfo, bTarget)

        if controls and controls.mouseoverDisplay and controls.mouseoverDisplay.text then
            controls.mouseoverDisplay.text:SetText(self._curHelpText)
        end

        -- 记下玩家这次点出来的状态。此后无论 stat 同步得怎么样，只要单位还在，
        -- 勾选就按这里显示 —— 这是 v15 的核心：不依赖那次网络往返。
        local iRemembered = 0
        if subState == nil and type(currentSelection) == 'table' then
            for i, oUnit in currentSelection do
                if M28AssistRemember(oUnit, bTarget) then
                    iRemembered = iRemembered + 1
                end
            end
        end

        if subState == nil then
            self:SetCheck(bTarget)
        end

        -- Enable 是「点击后应处于的状态」，hook/lua/SimCallbacks.lua 会把它写成权威值。
        SimCallback({ Func = 'M28SharedArmiesCallback', Args = { Enable = bTarget } }, true)

        -- 诊断：确认这次的点击意图与记录下来的人数（限流 30 条）。
        if subState == nil and iM28AssistClickLogs < 30 then
            iM28AssistClickLogs = iM28AssistClickLogs + 1
            LOG('M28CampaignAssist: click target=' .. tostring(bTarget)
                .. ' remembered=' .. tostring(iRemembered))
        end
    end

    LOG('M28CampaignAssist: M28 toggle button bound to click memory')
end
