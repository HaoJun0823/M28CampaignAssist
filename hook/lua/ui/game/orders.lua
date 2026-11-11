-- M28CampaignAssist（M28AI 附属 mod）
-- hook/lua/ui/game/orders.lua  -- v13
--
-- 这个文件只做一件事：让 M28 托管按钮的勾选状态与「真实的托管状态」一致。
--
-- ============ 原版为什么会有开有关 ============
-- M28AI 的按钮实现在 mods/M28AI/hook/lua/ui/game/orders.lua，它对屏幕上的勾选值
-- 过于信任，有两个窗口会失配：
--   1) M28ScriptButtonInitFunction 只在「选择单位的那一刻」按 stat 算一次勾选。
--      选中期间不动鼠标，若 sim 侧对账把某单位的托管状态改了（例如刚建好的工厂
--      完成定案、或 M28AI 自己清了 stat），按钮不会重新计算，就这么一直显示旧值。
--   2) M28AIToggle 点击时用 self:IsChecked() 取反当作玩家意图。屏幕上那个值可能
--      是几十秒前的：显示「勾着」而实际已关 → 点一下发出去的是「关」，看上去
--      毫无反应；显示「没勾」而实际开着 → 点一下发的还是「开」。用户看到的就是
--      「这按钮有开有关、点两下才对」。
-- 本 mod 把 M28Active 变成权威托管的投影之后，这两个窗口被放大，必须补上。
--
-- ============ 做法（不改 M28AI 一个字节） ============
--   * 接管 initialStateFunc：按传入的 unitList 算初始勾选（与原版等价，多一层
--     空值保护）。
--   * 加 onframe：引擎自带的按钮刷新钩子（AddOrder 里对带 onframe 的按钮调了
--     checkbox:SetNeedsFrameUpdate(true)），按 currentSelection 重算勾选，
--     顺带维护混合选择的问号图标。节流到约 0.1 秒一次，不需要自己起线程。
--   * 接管 behavior：点击时不信 IsChecked()，当场重读 stat 算出「点击之后应当
--     处于的状态」，把这个状态直接发给宿主回调；视觉上也立刻置成同一状态。
--
-- 为什么 stat 'M28Active' 在这里可以当唯一真值：已定案单位的该 stat 由
-- hook/lua/sim/Unit.lua 的 M28AssistProject 投影；未定案单位（ACU、剧本生成）
-- 也在同一个函数里跟着 M28AI 的字段同步，所以它永远等于 sim 侧的真实状态。
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
    -- 读一个单位当前的托管状态：true / false；读不到返回 nil（不参与统计）。
    local function M28AssistReadState(oUnit)
        if not oUnit then return nil end
        if type(oUnit.GetStat) ~= 'function' then return nil end
        if oUnit.Dead == true then return nil end
        local vStat = oUnit:GetStat('M28Active', 0)
        if vStat == nil then return nil end
        local iValue = 0
        if type(vStat) == 'table' then
            iValue = tonumber(vStat.Value or 0) or 0
        elseif type(vStat) == 'number' then
            iValue = vStat
        else
            return nil
        end
        return iValue ~= 0
    end

    -- 统计一组单位的托管状态，提前退出。返回 bAnyOn, bAnyOff。
    local function M28AssistScan(oUnits)
        local bAnyOn, bAnyOff = false, false
        if type(oUnits) ~= 'table' then return bAnyOn, bAnyOff end
        for i, oUnit in oUnits do
            local bState = M28AssistReadState(oUnit)
            if bState == true then
                bAnyOn = true
            elseif bState == false then
                bAnyOff = true
            end
            if bAnyOn and bAnyOff then break end
        end
        return bAnyOn, bAnyOff
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

    -- 选择集变化时由框架调用一次。
    --
    -- 同时把 AddOrder 为 onframe 按钮挂上的脉冲光效关掉：那个 EnableEffect 在
    -- OnEnable 时会一直呼吸（alpha 在 0/1 间循环），而 M28 按钮几乎一直是启用
    -- 状态，会变成永久的闪动。我们只需要 OnFrame 来刷新勾选，不要这个装饰。
    tM28AssistOrderInfo.initialStateFunc = function(control, unitList, subCheck)
        if not control.M28AssistEffectMuted then
            control.M28AssistEffectMuted = true
            if control.EnableEffect then
                control.EnableEffect:SetNeedsFrameUpdate(false)
                control.EnableEffect:SetAlpha(0)
            end
            control.OnEnable = function(self)
                if self.EnableEffect then
                    self.EnableEffect:SetNeedsFrameUpdate(false)
                    self.EnableEffect:SetAlpha(0)
                end
                Checkbox.OnEnable(self)
            end
            control.OnDisable = function(self)
                if self.EnableEffect then
                    self.EnableEffect:SetNeedsFrameUpdate(false)
                    self.EnableEffect:SetAlpha(0)
                end
                Checkbox.OnDisable(self)
            end
        end

        local bAnyOn, bAnyOff = M28AssistScan(unitList)
        if not subCheck then
            M28AssistApply(control, bAnyOn, bAnyOff)
        else
            return bAnyOn, bAnyOn and bAnyOff
        end
    end

    -- 每帧刷新。M28AI 原版只在选中那一刻算一次，选着不动就会长期显示旧值。
    -- 节流到 0.1 秒：几十个单位的 GetStat 不值得每帧跑，而人的反应也快不过它。
    local fM28AssistAccum = 0
    tM28AssistOrderInfo.onframe = function(control, deltaTime)
        fM28AssistAccum = fM28AssistAccum + (deltaTime or 0)
        if fM28AssistAccum < 0.1 then return end
        fM28AssistAccum = 0
        if type(currentSelection) ~= 'table' then return end

        local bAnyOn, bAnyOff = M28AssistScan(currentSelection)
        local bMixed = (bAnyOn and bAnyOff) == true
        if control:IsChecked() ~= bAnyOn or (control._mixedIcon ~= nil) ~= bMixed then
            M28AssistApply(control, bAnyOn, bAnyOff)
        end
    end

    -- 点击：按「点击之后应当处于的状态」发意图，不再用屏幕上的旧勾选值取反。
    tM28AssistOrderInfo.behavior = function(self, modifiers, subState)
        local bTarget
        if subState ~= nil then
            -- 框架以程序方式切换时才信它；玩家点击时 subState 为 nil。
            bTarget = (subState == true)
        else
            local bAnyOn = M28AssistScan(currentSelection)
            -- 与 M28AI 原版语义一致：只要还有单位在托管就整组收回，否则整组交出。
            bTarget = not bAnyOn
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

        -- 立刻给出视觉反馈，不用等下一帧 onframe。
        if subState == nil then
            self:SetCheck(bTarget)
        end

        -- Enable 是「点击后应处于的状态」，hook/lua/SimCallbacks.lua 会把它写成权威值。
        SimCallback({ Func = 'M28SharedArmiesCallback', Args = { Enable = bTarget } }, true)
    end

    LOG('M28CampaignAssist: M28 toggle button bound to authoritative state')
end
