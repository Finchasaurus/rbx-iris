local Types = require(script.Parent.Parent.Types)

return function(Iris: Types.Internal, widgets: Types.WidgetUtility)
    local function relocateTooltips()
        if Iris._rootInstance == nil then
            return
        end
        local PopupScreenGui = Iris._rootInstance:FindFirstChild("PopupScreenGui")
        local TooltipContainer = PopupScreenGui.TooltipContainer
        local mouseLocation: Vector2 = widgets.getMouseLocation()
        local newPosition: Vector2 = widgets.findBestWindowPosForPopup(mouseLocation, TooltipContainer.AbsoluteSize, Iris._config.DisplaySafeAreaPadding, PopupScreenGui.AbsoluteSize)
        TooltipContainer.Position = UDim2.fromOffset(newPosition.X, newPosition.Y)
    end

    widgets.registerEvent("InputChanged", function()
        if not Iris._started then
            return
        end
        relocateTooltips()
    end)

    --stylua: ignore
    Iris.WidgetConstructor("Tooltip", {
        hasState = false,
        hasChildren = false,
        Args = {
            ["Text"] = 1,
        },
        Events = {},
        Generate = function(thisWidget: Types.Widget)
            thisWidget.parentWidget = Iris._rootWidget -- only allow root as parent

            local Tooltip: Frame = Instance.new("Frame")
            Tooltip.Name = "Iris_Tooltip"
            Tooltip.Size = UDim2.new(Iris._config.ContentWidth, UDim.new(0, 0))
            Tooltip.AutomaticSize = Enum.AutomaticSize.Y
            Tooltip.BorderSizePixel = 0
            Tooltip.BackgroundTransparency = 1
            Tooltip.ZIndex = thisWidget.ZIndex + 1
            Tooltip.LayoutOrder = thisWidget.ZIndex + 1

            local TooltipText: TextLabel = Instance.new("TextLabel")
            TooltipText.Name = "TooltipText"
            TooltipText.Size = UDim2.fromOffset(0, 0)
            TooltipText.AutomaticSize = Enum.AutomaticSize.XY
            TooltipText.BackgroundColor3 = Iris._config.PopupBgColor
            TooltipText.BackgroundTransparency = Iris._config.PopupBgTransparency
            TooltipText.BorderSizePixel = Iris._config.PopupBorderSize
            TooltipText.TextWrapped = Iris._config.TextWrapped

            widgets.applyTextStyle(TooltipText)
            widgets.UIStroke(TooltipText, Iris._config.WindowBorderSize, Iris._config.BorderActiveColor, Iris._config.BorderActiveTransparency)
            widgets.UIPadding(TooltipText, Iris._config.WindowPadding)
            if Iris._config.PopupRounding > 0 then
                widgets.UICorner(TooltipText, Iris._config.PopupRounding)
            end

            TooltipText.Parent = Tooltip

            return Tooltip
        end,
        Update = function(thisWidget: Types.Widget)
            local Tooltip = thisWidget.Instance :: Frame
            local TooltipText: TextLabel = Tooltip.TooltipText
            if thisWidget.arguments.Text == nil then
                error("Iris.Text Text Argument is required", 5)
            end
            TooltipText.Text = thisWidget.arguments.Text
            relocateTooltips()
        end,
        Discard = function(thisWidget: Types.Widget)
            thisWidget.Instance:Destroy()
        end,
    } :: Types.WidgetClass)

    local windowDisplayOrder: number = 0 -- incremental count which is used for determining focused windows ZIndex
    local dragWindow: Types.Widget? -- window being dragged, may be nil
    local isDragging: boolean = false
    local moveDeltaCursorPosition: Vector2 -- cursor offset from drag origin (top left of window)

    local resizeWindow: Types.Widget? -- window being resized, may be nil
    local isResizing = false
    local isInsideResize = false -- is cursor inside of the focused window resize outer padding
    local isInsideWindow = false -- is cursor inside of the focused window
    local resizeFromTopBottom: Enum.TopBottom = Enum.TopBottom.Top
    local resizeFromLeftRight: Enum.LeftRight = Enum.LeftRight.Left

    local lastCursorPosition: Vector2

    local focusedWindow: Types.Widget? -- window with focus, may be nil
    local anyFocusedWindow: boolean = false -- is there any focused window?

    local windowWidgets: { [Types.ID]: Types.Widget } = {} -- array of widget objects of type window

    local function quickSwapWindows()
        -- ctrl + tab swapping functionality
        if Iris._config.UseScreenGUIs == false then
            return
        end

        local lowest: number = 0xFFFF
        local lowestWidget: Types.Widget

        for _, widget: Types.Widget in windowWidgets do
            if widget.state.isOpened.value and not widget.arguments.NoNav then
                if widget.Instance:IsA("ScreenGui") then
                    local value: number = widget.Instance.DisplayOrder
                    if value < lowest then
                        lowest = value
                        lowestWidget = widget
                    end
                end
            end
        end

        if not lowestWidget then
            return
        end

        if lowestWidget.state.isUncollapsed.value == false then
            lowestWidget.state.isUncollapsed:set(true)
        end
        Iris.SetFocusedWindow(lowestWidget)
    end

    local function fitSizeToWindowBounds(thisWidget: Types.Widget, intentedSize: Vector2): Vector2
        local windowSize: Vector2 = Vector2.new(thisWidget.state.position.value.X, thisWidget.state.position.value.Y)
        local minWindowSize: number = (Iris._config.TextSize + 2 * Iris._config.FramePadding.Y) * 2
        local usableSize: Vector2 = widgets.getScreenSizeForWindow(thisWidget)
        local safeAreaPadding: Vector2 = Vector2.new(Iris._config.WindowBorderSize + Iris._config.DisplaySafeAreaPadding.X, Iris._config.WindowBorderSize + Iris._config.DisplaySafeAreaPadding.Y)

        local maxWindowSize: Vector2 = (usableSize - windowSize - safeAreaPadding)
        return Vector2.new(math.clamp(intentedSize.X, minWindowSize, math.max(maxWindowSize.X, minWindowSize)), math.clamp(intentedSize.Y, minWindowSize, math.max(maxWindowSize.Y, minWindowSize)))
    end

    local function fitPositionToWindowBounds(thisWidget: Types.Widget, intendedPosition: Vector2): Vector2
        local thisWidgetInstance = thisWidget.Instance
        local usableSize: Vector2 = widgets.getScreenSizeForWindow(thisWidget)
        local safeAreaPadding: Vector2 = Vector2.new(Iris._config.WindowBorderSize + Iris._config.DisplaySafeAreaPadding.X, Iris._config.WindowBorderSize + Iris._config.DisplaySafeAreaPadding.Y)

        return Vector2.new(
            math.clamp(intendedPosition.X, safeAreaPadding.X, math.max(safeAreaPadding.X, usableSize.X - thisWidgetInstance.WindowButton.AbsoluteSize.X - safeAreaPadding.X)),
            math.clamp(intendedPosition.Y, safeAreaPadding.Y, math.max(safeAreaPadding.Y, usableSize.Y - thisWidgetInstance.WindowButton.AbsoluteSize.Y - safeAreaPadding.Y))
        )
    end

    Iris.SetFocusedWindow = function(thisWidget: Types.Widget?)
        if focusedWindow == thisWidget then
            return
        end

        if anyFocusedWindow and focusedWindow ~= nil then
            if windowWidgets[focusedWindow.ID] then
                local Window = focusedWindow.Instance :: Frame
                local WindowButton = Window.WindowButton :: TextButton
                local Content = WindowButton.Content :: Frame
                local TitleBar: Frame = Content.TitleBar
                -- update appearance to unfocus
                if focusedWindow.state.isUncollapsed.value then
                    TitleBar.BackgroundColor3 = Iris._config.TitleBgColor
                    TitleBar.BackgroundTransparency = Iris._config.TitleBgTransparency
                else
                    TitleBar.BackgroundColor3 = Iris._config.TitleBgCollapsedColor
                    TitleBar.BackgroundTransparency = Iris._config.TitleBgCollapsedTransparency
                end
                WindowButton.UIStroke.Color = Iris._config.BorderColor
            end

            anyFocusedWindow = false
            focusedWindow = nil
        end

        if thisWidget ~= nil then
            -- update appearance to focus
            anyFocusedWindow = true
            focusedWindow = thisWidget
            local Window = thisWidget.Instance :: Frame
            local WindowButton = Window.WindowButton :: TextButton
            local Content = WindowButton.Content :: Frame
            local TitleBar: Frame = Content.TitleBar

            TitleBar.BackgroundColor3 = Iris._config.TitleBgActiveColor
            TitleBar.BackgroundTransparency = Iris._config.TitleBgActiveTransparency
            WindowButton.UIStroke.Color = Iris._config.BorderActiveColor

            windowDisplayOrder += 1
            if thisWidget.usesScreenGUI then
                Window.DisplayOrder = windowDisplayOrder + Iris._config.DisplayOrderOffset
            else
                Window.ZIndex = windowDisplayOrder + Iris._config.DisplayOrderOffset
            end

            if thisWidget.state.isUncollapsed.value == false then
                thisWidget.state.isUncollapsed:set(true)
            end

            local firstSelectedObject: GuiObject? = widgets.GuiService.SelectedObject
            if firstSelectedObject then
                if TitleBar.Visible then
                    widgets.GuiService:Select(TitleBar)
                else
                    widgets.GuiService:Select(thisWidget.ChildContainer)
                end
            end
        end
    end

    widgets.registerEvent("InputBegan", function(input: InputObject)
        if not Iris._started then
            return
        end
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            local inWindow: boolean = false
            local position: Vector2 = widgets.getMouseLocation()
            for _, window in windowWidgets do
                local ResizeBorder: TextButton = window.Instance and window.Instance.WindowButton.ResizeBorder
                if ResizeBorder and widgets.isPosInsideRect(position, ResizeBorder.AbsolutePosition - widgets.GuiOffset, ResizeBorder.AbsolutePosition - widgets.GuiOffset + ResizeBorder.AbsoluteSize) then
                    inWindow = true
                    break
                end
            end

            if not inWindow then
                Iris.SetFocusedWindow(nil)
            end
        end

        if input.KeyCode == Enum.KeyCode.Tab and (widgets.UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or widgets.UserInputService:IsKeyDown(Enum.KeyCode.RightControl)) then
            quickSwapWindows()
        end

        if input.UserInputType == Enum.UserInputType.MouseButton1 and isInsideResize and not isInsideWindow and anyFocusedWindow and focusedWindow then
            local midWindow: Vector2 = focusedWindow.state.position.value + (focusedWindow.state.size.value / 2)
            local cursorPosition: Vector2 = widgets.getMouseLocation() - midWindow

            -- check which axis its closest to, then check which side is closest with math.sign
            if math.abs(cursorPosition.X) * focusedWindow.state.size.value.Y >= math.abs(cursorPosition.Y) * focusedWindow.state.size.value.X then
                resizeFromTopBottom = Enum.TopBottom.Center
                resizeFromLeftRight = if math.sign(cursorPosition.X) == -1 then Enum.LeftRight.Left else Enum.LeftRight.Right
            else
                resizeFromLeftRight = Enum.LeftRight.Center
                resizeFromTopBottom = if math.sign(cursorPosition.Y) == -1 then Enum.TopBottom.Top else Enum.TopBottom.Bottom
            end
            isResizing = true
            resizeWindow = focusedWindow
        end
    end)

    widgets.registerEvent("TouchTapInWorld", function(_, gameProcessedEvent: boolean)
        if not Iris._started then
            return
        end
        if not gameProcessedEvent then
            Iris.SetFocusedWindow(nil)
        end
    end)

    widgets.registerEvent("InputChanged", function(input: InputObject)
        if not Iris._started then
            return
        end
        if isDragging and dragWindow then
            local mouseLocation: Vector2
            if input.UserInputType == Enum.UserInputType.Touch then
                local location: Vector3 = input.Position
                mouseLocation = Vector2.new(location.X, location.Y)
            else
                mouseLocation = widgets.getMouseLocation()
            end
            local Window = dragWindow.Instance :: Frame
            local dragInstance: TextButton = Window.WindowButton
            local intendedPosition: Vector2 = mouseLocation - moveDeltaCursorPosition
            local newPos: Vector2 = fitPositionToWindowBounds(dragWindow, intendedPosition)

            -- state shouldnt be used like this, but calling :set would run the entire UpdateState function for the window, which is slow.
            dragInstance.Position = UDim2.fromOffset(newPos.X, newPos.Y)
            dragWindow.state.position.value = newPos
        end
        if isResizing and resizeWindow and resizeWindow.arguments.NoResize ~= true then
            local Window = resizeWindow.Instance :: Frame
            local resizeInstance: TextButton = Window.WindowButton
            local windowPosition: Vector2 = Vector2.new(resizeInstance.Position.X.Offset, resizeInstance.Position.Y.Offset)
            local windowSize: Vector2 = Vector2.new(resizeInstance.Size.X.Offset, resizeInstance.Size.Y.Offset)

            local mouseDelta: Vector2 | Vector3
            if input.UserInputType == Enum.UserInputType.Touch then
                mouseDelta = input.Delta
            else
                mouseDelta = widgets.getMouseLocation() - lastCursorPosition
            end

            local intendedPosition: Vector2 = windowPosition + Vector2.new(if resizeFromLeftRight == Enum.LeftRight.Left then mouseDelta.X else 0, if resizeFromTopBottom == Enum.TopBottom.Top then mouseDelta.Y else 0)

            local intendedSize: Vector2 = windowSize
                + Vector2.new(
                    if resizeFromLeftRight == Enum.LeftRight.Left then -mouseDelta.X elseif resizeFromLeftRight == Enum.LeftRight.Right then mouseDelta.X else 0,
                    if resizeFromTopBottom == Enum.TopBottom.Top then -mouseDelta.Y elseif resizeFromTopBottom == Enum.TopBottom.Bottom then mouseDelta.Y else 0
                )

            local newSize: Vector2 = fitSizeToWindowBounds(resizeWindow, intendedSize)
            local newPosition: Vector2 = fitPositionToWindowBounds(resizeWindow, intendedPosition)

            resizeInstance.Size = UDim2.fromOffset(newSize.X, newSize.Y)
            resizeWindow.state.size.value = newSize
            resizeInstance.Position = UDim2.fromOffset(newPosition.X, newPosition.Y)
            resizeWindow.state.position.value = newPosition
        end

        lastCursorPosition = widgets.getMouseLocation()
    end)

    widgets.registerEvent("InputEnded", function(input, _)
        if not Iris._started then
            return
        end
        if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) and isDragging and dragWindow then
            local Window = dragWindow.Instance :: Frame
            local dragInstance: TextButton = Window.WindowButton
            isDragging = false
            dragWindow.state.position:set(Vector2.new(dragInstance.Position.X.Offset, dragInstance.Position.Y.Offset))
        end
        if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) and isResizing and resizeWindow then
            local Window = resizeWindow.Instance :: Frame
            isResizing = false
            resizeWindow.state.size:set(Window.WindowButton.AbsoluteSize)
        end

        if input.KeyCode == Enum.KeyCode.ButtonX then
            quickSwapWindows()
        end
    end)

    --stylua: ignore
    Iris.WidgetConstructor("Window", {
        hasState = true,
        hasChildren = true,
        Args = {
            ["Title"] = 1,
            ["NoTitleBar"] = 2,
            ["NoBackground"] = 3,
            ["NoCollapse"] = 4,
            ["NoClose"] = 5,
            ["NoMove"] = 6,
            ["NoScrollbar"] = 7,
            ["NoResize"] = 8,
            ["NoNav"] = 9,
            ["NoMenu"] = 10,
        },
        Events = {
            ["closed"] = {
                ["Init"] = function(_thisWidget: Types.Widget) end,
                ["Get"] = function(thisWidget: Types.Widget)
                    return thisWidget.lastClosedTick == Iris._cycleTick
                end,
            },
            ["opened"] = {
                ["Init"] = function(_thisWidget: Types.Widget) end,
                ["Get"] = function(thisWidget: Types.Widget)
                    return thisWidget.lastOpenedTick == Iris._cycleTick
                end,
            },
            ["collapsed"] = {
                ["Init"] = function(_thisWidget: Types.Widget) end,
                ["Get"] = function(thisWidget: Types.Widget)
                    return thisWidget.lastCollapsedTick == Iris._cycleTick
                end,
            },
            ["uncollapsed"] = {
                ["Init"] = function(_thisWidget: Types.Widget) end,
                ["Get"] = function(thisWidget: Types.Widget)
                    return thisWidget.lastUncollapsedTick == Iris._cycleTick
                end,
            },
            ["hovered"] = widgets.EVENTS.hover(function(thisWidget: Types.Widget)
                local Window = thisWidget.Instance :: Frame
                return Window.WindowButton
            end),
        },
        Generate = function(thisWidget: Types.Widget)
            thisWidget.parentWidget = Iris._rootWidget -- only allow root as parent

            thisWidget.usesScreenGUI = Iris._config.UseScreenGUIs
            windowWidgets[thisWidget.ID] = thisWidget

            local Window
            if thisWidget.usesScreenGUI then
                Window = Instance.new("ScreenGui")
                Window.ResetOnSpawn = false
                Window.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
                Window.DisplayOrder = Iris._config.DisplayOrderOffset
                Window.IgnoreGuiInset = Iris._config.IgnoreGuiInset
            else
                Window = Instance.new("Frame")
                Window.AnchorPoint = Vector2.new(0.5, 0.5)
                Window.Position = UDim2.new(0.5, 0, 0.5, 0)
                Window.Size = UDim2.new(1, 0, 1, 0)
                Window.BackgroundTransparency = 1
                Window.ZIndex = Iris._config.DisplayOrderOffset
            end
            Window.Name = "Iris_Window"

            local WindowButton: TextButton = Instance.new("TextButton")
            WindowButton.Name = "WindowButton"
            WindowButton.Size = UDim2.fromOffset(0, 0)
            WindowButton.BackgroundTransparency = 1
            WindowButton.BorderSizePixel = 0
            WindowButton.Text = ""
            WindowButton.ClipsDescendants = false
            WindowButton.AutoButtonColor = false
            WindowButton.Selectable = false
            WindowButton.SelectionImageObject = Iris.SelectionImageObject

            WindowButton.SelectionGroup = true
            WindowButton.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
            WindowButton.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
            WindowButton.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
            WindowButton.SelectionBehaviorRight = Enum.SelectionBehavior.Stop

            widgets.UIStroke(WindowButton, Iris._config.WindowBorderSize, Iris._config.BorderColor, Iris._config.BorderTransparency)

            WindowButton.Parent = Window

            widgets.applyInputBegan(thisWidget, WindowButton, function(input: InputObject)
                if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Keyboard then
                    return
                end
                if thisWidget.state.isUncollapsed.value then
                    Iris.SetFocusedWindow(thisWidget)
                end
                if not thisWidget.arguments.NoMove and input.UserInputType == Enum.UserInputType.MouseButton1 then
                    dragWindow = thisWidget
                    isDragging = true
                    moveDeltaCursorPosition = widgets.getMouseLocation() - thisWidget.state.position.value
                end
            end)

            local Content: Frame = Instance.new("Frame")
            Content.Name = "Content"
            Content.AnchorPoint = Vector2.new(0.5, 0.5)
            Content.Position = UDim2.fromScale(0.5, 0.5)
            Content.Size = UDim2.fromScale(1, 1)
            Content.BackgroundTransparency = 1
            Content.ClipsDescendants = true
            Content.Parent = WindowButton

            local UIListLayout: UIListLayout = widgets.UIListLayout(Content, Enum.FillDirection.Vertical, UDim.new(0, 0))
            UIListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
            UIListLayout.VerticalAlignment = Enum.VerticalAlignment.Top

            local ChildContainer: ScrollingFrame = Instance.new("ScrollingFrame")
            ChildContainer.Name = "WindowContainer"
            ChildContainer.Size = UDim2.fromScale(1, 1)
            ChildContainer.Position = UDim2.fromOffset(0, 0)
            ChildContainer.BackgroundColor3 = Iris._config.WindowBgColor
            ChildContainer.BackgroundTransparency = Iris._config.WindowBgTransparency
            ChildContainer.BorderSizePixel = 0

            ChildContainer.AutomaticCanvasSize = Enum.AutomaticSize.Y
            ChildContainer.ScrollBarImageTransparency = Iris._config.ScrollbarGrabTransparency
            ChildContainer.ScrollBarImageColor3 = Iris._config.ScrollbarGrabColor
            ChildContainer.CanvasSize = UDim2.fromScale(0, 0)
            ChildContainer.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar

            ChildContainer.LayoutOrder = thisWidget.ZIndex + 0xFFFF
            ChildContainer.ClipsDescendants = true

            widgets.UIPadding(ChildContainer, Iris._config.WindowPadding)

            ChildContainer.Parent = Content

            local UIFlexItem: UIFlexItem = Instance.new("UIFlexItem")
            UIFlexItem.FlexMode = Enum.UIFlexMode.Fill
            UIFlexItem.ItemLineAlignment = Enum.ItemLineAlignment.End
            UIFlexItem.Parent = ChildContainer

            ChildContainer:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
                -- "wrong" use of state here, for optimization
                thisWidget.state.scrollDistance.value = ChildContainer.CanvasPosition.Y
            end)

            widgets.applyInputBegan(thisWidget, ChildContainer, function(input: InputObject)
                if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Keyboard then
                    return
                end
                if thisWidget.state.isUncollapsed.value then
                    Iris.SetFocusedWindow(thisWidget)
                end
            end)

            local TerminatingFrame: Frame = Instance.new("Frame")
            TerminatingFrame.Name = "TerminatingFrame"
            TerminatingFrame.Size = UDim2.fromOffset(0, Iris._config.WindowPadding.Y + Iris._config.FramePadding.Y)
            TerminatingFrame.BackgroundTransparency = 1
            TerminatingFrame.BorderSizePixel = 0
            TerminatingFrame.LayoutOrder = 0x7FFFFFF0

            local ChildContainerUIListLayout: UIListLayout = widgets.UIListLayout(ChildContainer, Enum.FillDirection.Vertical, UDim.new(0, Iris._config.ItemSpacing.Y))
            ChildContainerUIListLayout.VerticalAlignment = Enum.VerticalAlignment.Top

            TerminatingFrame.Parent = ChildContainer

            local TitleBar: Frame = Instance.new("Frame")
            TitleBar.Name = "TitleBar"
            TitleBar.AutomaticSize = Enum.AutomaticSize.Y
            TitleBar.Size = UDim2.fromScale(1, 0)
            TitleBar.BorderSizePixel = 0
            TitleBar.ClipsDescendants = true

            TitleBar.Parent = Content

            widgets.UIPadding(TitleBar, Vector2.xAxis * Iris._config.FramePadding.X)
            widgets.UIListLayout(TitleBar, Enum.FillDirection.Horizontal, UDim.new(0, Iris._config.FramePadding.X)).VerticalAlignment = Enum.VerticalAlignment.Center
            widgets.applyInputBegan(thisWidget, TitleBar, function(input: InputObject)
                if input.UserInputType == Enum.UserInputType.Touch then
                    if not thisWidget.arguments.NoMove then
                        dragWindow = thisWidget
                        isDragging = true
                        local location: Vector3 = input.Position
                        moveDeltaCursorPosition = Vector2.new(location.X, location.Y) - thisWidget.state.position.value
                    end
                end
            end)

            local TitleButtonSize: number = Iris._config.TextSize + ((Iris._config.FramePadding.Y - 1) * 2)

            local CollapseButton: TextButton = Instance.new("TextButton")
            CollapseButton.Name = "CollapseButton"
            CollapseButton.AnchorPoint = Vector2.new(0, 0.5)
            CollapseButton.Size = UDim2.fromOffset(TitleButtonSize, TitleButtonSize)
            CollapseButton.Position = UDim2.new(0, 0, 0.5, 0)
            CollapseButton.AutomaticSize = Enum.AutomaticSize.None
            CollapseButton.BackgroundTransparency = 1
            CollapseButton.BorderSizePixel = 0
            CollapseButton.AutoButtonColor = false
            CollapseButton.Text = ""

            widgets.UICorner(CollapseButton)

            CollapseButton.Parent = TitleBar

            widgets.applyButtonClick(thisWidget, CollapseButton, function()
                thisWidget.state.isUncollapsed:set(not thisWidget.state.isUncollapsed.value)
            end)

            widgets.applyInteractionHighlights(thisWidget, CollapseButton, CollapseButton, {
                ButtonColor = Iris._config.ButtonColor,
                ButtonTransparency = 1,
                ButtonHoveredColor = Iris._config.ButtonHoveredColor,
                ButtonHoveredTransparency = Iris._config.ButtonHoveredTransparency,
                ButtonActiveColor = Iris._config.ButtonActiveColor,
                ButtonActiveTransparency = Iris._config.ButtonActiveTransparency,
            })

            local CollapseArrow: ImageLabel = Instance.new("ImageLabel")
            CollapseArrow.Name = "Arrow"
            CollapseArrow.AnchorPoint = Vector2.new(0.5, 0.5)
            CollapseArrow.Size = UDim2.fromOffset(math.floor(0.7 * TitleButtonSize), math.floor(0.7 * TitleButtonSize))
            CollapseArrow.Position = UDim2.fromScale(0.5, 0.5)
            CollapseArrow.BackgroundTransparency = 1
            CollapseArrow.BorderSizePixel = 0
            CollapseArrow.Image = widgets.ICONS.MULTIPLICATION_SIGN
            CollapseArrow.ImageColor3 = Iris._config.TextColor
            CollapseArrow.ImageTransparency = Iris._config.TextTransparency
            CollapseArrow.Parent = CollapseButton

            local CloseButton: TextButton = Instance.new("TextButton")
            CloseButton.Name = "CloseButton"
            CloseButton.AnchorPoint = Vector2.new(1, 0.5)
            CloseButton.Size = UDim2.fromOffset(TitleButtonSize, TitleButtonSize)
            CloseButton.Position = UDim2.new(1, 0, 0.5, 0)
            CloseButton.AutomaticSize = Enum.AutomaticSize.None
            CloseButton.BackgroundTransparency = 1
            CloseButton.BorderSizePixel = 0
            CloseButton.Text = ""
            CloseButton.LayoutOrder = 2
            CloseButton.AutoButtonColor = false

            widgets.UICorner(CloseButton)

            widgets.applyButtonClick(thisWidget, CloseButton, function()
                thisWidget.state.isOpened:set(false)
            end)

            widgets.applyInteractionHighlights(thisWidget, CloseButton, CloseButton, {
                ButtonColor = Iris._config.ButtonColor,
                ButtonTransparency = 1,
                ButtonHoveredColor = Iris._config.ButtonHoveredColor,
                ButtonHoveredTransparency = Iris._config.ButtonHoveredTransparency,
                ButtonActiveColor = Iris._config.ButtonActiveColor,
                ButtonActiveTransparency = Iris._config.ButtonActiveTransparency,
            })

            CloseButton.Parent = TitleBar

            local CloseIcon: ImageLabel = Instance.new("ImageLabel")
            CloseIcon.Name = "Icon"
            CloseIcon.AnchorPoint = Vector2.new(0.5, 0.5)
            CloseIcon.Size = UDim2.fromOffset(math.floor(0.7 * TitleButtonSize), math.floor(0.7 * TitleButtonSize))
            CloseIcon.Position = UDim2.fromScale(0.5, 0.5)
            CloseIcon.BackgroundTransparency = 1
            CloseIcon.BorderSizePixel = 0
            CloseIcon.Image = widgets.ICONS.MULTIPLICATION_SIGN
            CloseIcon.ImageColor3 = Iris._config.TextColor
            CloseIcon.ImageTransparency = Iris._config.TextTransparency
            CloseIcon.Parent = CloseButton

            -- allowing fractional titlebar title location dosent seem useful, as opposed to Enum.LeftRight.

            local Title: TextLabel = Instance.new("TextLabel")
            Title.Name = "Title"
            Title.AutomaticSize = Enum.AutomaticSize.XY
            Title.BorderSizePixel = 0
            Title.BackgroundTransparency = 1
            Title.LayoutOrder = 1
            Title.ClipsDescendants = true
            
            widgets.UIPadding(Title, Vector2.yAxis * Iris._config.FramePadding.Y)
            widgets.applyTextStyle(Title)
            Title.TextXAlignment = Enum.TextXAlignment[Iris._config.WindowTitleAlign.Name] :: Enum.TextXAlignment

            local TitleFlexItem: UIFlexItem = Instance.new("UIFlexItem")
            TitleFlexItem.FlexMode = Enum.UIFlexMode.Fill
            TitleFlexItem.ItemLineAlignment = Enum.ItemLineAlignment.Center

            TitleFlexItem.Parent = Title

            Title.Parent = TitleBar

            local ResizeButtonSize: number = Iris._config.TextSize + Iris._config.FramePadding.X

            local ResizeGrip = Instance.new("ImageButton")
            ResizeGrip.Name = "ResizeGrip"
            ResizeGrip.AnchorPoint = Vector2.new(1, 1)
            ResizeGrip.Size = UDim2.fromOffset(ResizeButtonSize, ResizeButtonSize)
            ResizeGrip.Position = UDim2.fromScale(1, 1)
            ResizeGrip.Rotation = 90
            ResizeGrip.AutoButtonColor = false
            ResizeGrip.BorderSizePixel = 0
            ResizeGrip.BackgroundTransparency = 1
            ResizeGrip.Image = widgets.ICONS.BOTTOM_RIGHT_CORNER
            ResizeGrip.ImageColor3 = Iris._config.ButtonColor
            ResizeGrip.ImageTransparency = Iris._config.ButtonTransparency
            ResizeGrip.Selectable = false
            ResizeGrip.ZIndex = 3
            ResizeGrip.Parent = WindowButton

            widgets.applyImageInteractionHighlights(thisWidget, ResizeGrip, ResizeGrip, {
                ButtonColor = Iris._config.ButtonColor,
                ButtonTransparency = Iris._config.ButtonTransparency,
                ButtonHoveredColor = Iris._config.ButtonHoveredColor,
                ButtonHoveredTransparency = Iris._config.ButtonHoveredTransparency,
                ButtonActiveColor = Iris._config.ButtonActiveColor,
                ButtonActiveTransparency = Iris._config.ButtonActiveTransparency,
            })

            widgets.applyButtonDown(thisWidget, ResizeGrip, function()
                if not anyFocusedWindow or not (focusedWindow == thisWidget) then
                    Iris.SetFocusedWindow(thisWidget)
                    -- mitigating wrong focus when clicking on buttons inside of a window without clicking the window itself
                end
                isResizing = true
                resizeFromTopBottom = Enum.TopBottom.Bottom
                resizeFromLeftRight = Enum.LeftRight.Right
                resizeWindow = thisWidget
            end)

            local ResizeBorder: Frame = Instance.new("Frame")
            ResizeBorder.Name = "ResizeBorder"
            ResizeBorder.Size = UDim2.new(1, Iris._config.WindowResizePadding.X * 2, 1, Iris._config.WindowResizePadding.Y * 2)
            ResizeBorder.Position = UDim2.fromOffset(-Iris._config.WindowResizePadding.X, -Iris._config.WindowResizePadding.Y)
            ResizeBorder.BackgroundTransparency = 1
            ResizeBorder.BorderSizePixel = 0
            ResizeBorder.Active = false
            ResizeBorder.Selectable = false
            ResizeBorder.ClipsDescendants = false
            ResizeBorder.Parent = WindowButton

            widgets.applyMouseEnter(thisWidget, ResizeBorder, function()
                if focusedWindow == thisWidget then
                    isInsideResize = true
                end
            end)
            widgets.applyMouseLeave(thisWidget, ResizeBorder, function()
                if focusedWindow == thisWidget then
                    isInsideResize = false
                end
            end)

            widgets.applyMouseEnter(thisWidget, WindowButton, function()
                if focusedWindow == thisWidget then
                    isInsideWindow = true
                end
            end)
            widgets.applyMouseLeave(thisWidget, WindowButton, function()
                if focusedWindow == thisWidget then
                    isInsideWindow = false
                end
            end)

            thisWidget.ChildContainer = ChildContainer
            return Window
        end,
        Update = function(thisWidget: Types.Widget)
            local Window = thisWidget.Instance :: GuiObject
            local ChildContainer = thisWidget.ChildContainer :: ScrollingFrame
            local WindowButton = Window.WindowButton :: TextButton
            local Content = WindowButton.Content :: Frame
            local TitleBar = Content.TitleBar :: Frame
            local Title: TextLabel = TitleBar.Title
            local MenuBar: Frame? = Content:FindFirstChild("MenuBar")
            local ResizeGrip: TextButton = WindowButton.ResizeGrip

            if thisWidget.arguments.NoResize ~= true then
                ResizeGrip.Visible = true
            else
                ResizeGrip.Visible = false
            end
            if thisWidget.arguments.NoScrollbar then
                ChildContainer.ScrollBarThickness = 0
            else
                ChildContainer.ScrollBarThickness = Iris._config.ScrollbarSize
            end
            if thisWidget.arguments.NoTitleBar then
                TitleBar.Visible = false
            else
                TitleBar.Visible = true
            end
            if MenuBar then
                if thisWidget.arguments.NoMenu then
                    MenuBar.Visible = false
                else
                    MenuBar.Visible = true
                end
            end
            if thisWidget.arguments.NoBackground then
                ChildContainer.BackgroundTransparency = 1
            else
                ChildContainer.BackgroundTransparency = Iris._config.WindowBgTransparency
            end

            -- TitleBar buttons
            if thisWidget.arguments.NoCollapse then
                TitleBar.CollapseButton.Visible = false
            else
                TitleBar.CollapseButton.Visible = true
            end
            if thisWidget.arguments.NoClose then
                TitleBar.CloseButton.Visible = false
            else
                TitleBar.CloseButton.Visible = true
            end

            Title.Text = thisWidget.arguments.Title or ""
        end,
        Discard = function(thisWidget: Types.Widget)
            if focusedWindow == thisWidget then
                focusedWindow = nil
                anyFocusedWindow = false
            end
            if dragWindow == thisWidget then
                dragWindow = nil
                isDragging = false
            end
            if resizeWindow == thisWidget then
                resizeWindow = nil
                isResizing = false
            end
            windowWidgets[thisWidget.ID] = nil
            thisWidget.Instance:Destroy()
            widgets.discardState(thisWidget)
        end,
        ChildAdded = function(thisWidget: Types.Widget, thisChid: Types.Widget)
            local Window = thisWidget.Instance :: Frame
            local WindowButton = Window.WindowButton :: TextButton
            local Content = WindowButton.Content :: Frame
            if thisChid.type == "MenuBar" then
                local ChildContainer = thisWidget.ChildContainer :: ScrollingFrame
                thisChid.Instance.ZIndex = ChildContainer.ZIndex + 1
                thisChid.Instance.LayoutOrder = ChildContainer.LayoutOrder - 1
                return Content
            end
            return thisWidget.ChildContainer
        end,
        UpdateState = function(thisWidget: Types.Widget)
            local stateSize: Vector2 = thisWidget.state.size.value
            local statePosition: Vector2 = thisWidget.state.position.value
            local stateIsUncollapsed: boolean = thisWidget.state.isUncollapsed.value
            local stateIsOpened: boolean = thisWidget.state.isOpened.value
            local stateScrollDistance: number = thisWidget.state.scrollDistance.value

            local Window = thisWidget.Instance :: Frame
            local ChildContainer = thisWidget.ChildContainer :: ScrollingFrame
            local WindowButton = Window.WindowButton :: TextButton
            local Content = WindowButton.Content :: Frame
            local TitleBar = Content.TitleBar :: Frame
            local MenuBar: Frame? = Content:FindFirstChild("MenuBar")
            local ResizeGrip: TextButton = WindowButton.ResizeGrip

            WindowButton.Size = UDim2.fromOffset(stateSize.X, stateSize.Y)
            WindowButton.Position = UDim2.fromOffset(statePosition.X, statePosition.Y)

            if stateIsOpened then
                if thisWidget.usesScreenGUI then
                    Window.Enabled = true
                    WindowButton.Visible = true
                else
                    Window.Visible = true
                    WindowButton.Visible = true
                end
                thisWidget.lastOpenedTick = Iris._cycleTick + 1
            else
                if thisWidget.usesScreenGUI then
                    Window.Enabled = false
                    WindowButton.Visible = false
                else
                    Window.Visible = false
                    WindowButton.Visible = false
                end
                thisWidget.lastClosedTick = Iris._cycleTick + 1
            end

            if stateIsUncollapsed then
                TitleBar.CollapseButton.Arrow.Image = widgets.ICONS.DOWN_POINTING_TRIANGLE
                if MenuBar then
                    MenuBar.Visible = not thisWidget.arguments.NoMenu
                end
                ChildContainer.Visible = true
                if thisWidget.arguments.NoResize ~= true then
                    ResizeGrip.Visible = true
                end
                WindowButton.AutomaticSize = Enum.AutomaticSize.None
                thisWidget.lastUncollapsedTick = Iris._cycleTick + 1
            else
                local collapsedHeight: number = TitleBar.AbsoluteSize.Y -- Iris._config.TextSize + Iris._config.FramePadding.Y * 2
                TitleBar.CollapseButton.Arrow.Image = widgets.ICONS.RIGHT_POINTING_TRIANGLE

                if MenuBar then
                    MenuBar.Visible = false
                end
                ChildContainer.Visible = false
                ResizeGrip.Visible = false
                WindowButton.Size = UDim2.fromOffset(stateSize.X, collapsedHeight)
                thisWidget.lastCollapsedTick = Iris._cycleTick + 1
            end

            if stateIsOpened and stateIsUncollapsed then
                Iris.SetFocusedWindow(thisWidget)
            else
                TitleBar.BackgroundColor3 = Iris._config.TitleBgCollapsedColor
                TitleBar.BackgroundTransparency = Iris._config.TitleBgCollapsedTransparency
                WindowButton.UIStroke.Color = Iris._config.BorderColor

                Iris.SetFocusedWindow(nil)
            end

            -- cant update canvasPosition in this cycle because scrollingframe isint ready to be changed
            if stateScrollDistance and stateScrollDistance ~= 0 then
                local callbackIndex: number = #Iris._postCycleCallbacks + 1
                local desiredCycleTick: number = Iris._cycleTick + 1
                Iris._postCycleCallbacks[callbackIndex] = function()
                    if Iris._cycleTick >= desiredCycleTick then
						if thisWidget.lastCycleTick ~= -1 then
                        	ChildContainer.CanvasPosition = Vector2.new(0, stateScrollDistance)
						end
                        Iris._postCycleCallbacks[callbackIndex] = nil
                    end
                end
            end
        end,
        GenerateState = function(thisWidget: Types.Widget)
            if thisWidget.state.size == nil then
                thisWidget.state.size = Iris._widgetState(thisWidget, "size", Vector2.new(400, 300))
            end
            if thisWidget.state.position == nil then
                thisWidget.state.position = Iris._widgetState(thisWidget, "position", if anyFocusedWindow and focusedWindow then focusedWindow.state.position.value + Vector2.new(15, 45) else Vector2.new(150, 250))
            end
            thisWidget.state.position.value = fitPositionToWindowBounds(thisWidget, thisWidget.state.position.value)
            thisWidget.state.size.value = fitSizeToWindowBounds(thisWidget, thisWidget.state.size.value)

            if thisWidget.state.isUncollapsed == nil then
                thisWidget.state.isUncollapsed = Iris._widgetState(thisWidget, "isUncollapsed", true)
            end
            if thisWidget.state.isOpened == nil then
                thisWidget.state.isOpened = Iris._widgetState(thisWidget, "isOpened", true)
            end
            if thisWidget.state.scrollDistance == nil then
                thisWidget.state.scrollDistance = Iris._widgetState(thisWidget, "scrollDistance", 0)
            end
        end,
    } :: Types.WidgetClass)
end
