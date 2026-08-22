import XCTest
import GModEngine
@testable import GModGameSession

final class GModSpawnMenuInteractionTests: XCTestCase {
    func testStrictStockSpawnMenuInteraction() throws {
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct),
            logger: { _, _ in }
        )
        defer { _ = try? session.close() }

        try session.setSpawnMenuOpen(true)
        defer { try? session.setSpawnMenuOpen(false) }

        var timerFailures: [GMLuaSourceTimerFailure] = []
        var weaponsContentReady = false
        for _ in 0..<16 {
            let tick = try session.runFixedTick()
            timerFailures.append(contentsOf: tick.client.timerFailures)
            let ready = try session.clientRuntime.executeReturningValues(
                """
                local sheet = g_SpawnMenu:GetCreationMenu():GetCreationTab(
                    "#spawnmenu.category.weapons")
                return sheet != nil and IsValid(sheet.Panel) and
                    IsValid(sheet.ContentPanel)
                """,
                sourceName: "=(strict stock weapons initialization readiness)"
            ).first
            if case .boolean(true) = ready {
                weaponsContentReady = true
                break
            }
        }
        XCTAssertTrue(weaponsContentReady)
        // Native spawnlist loading, Lua 5.1 iterator roots, and DHTML bridge
        // registration are engine boundaries now. The stock asynchronous Q
        // initialization must not leave any accepted timer failures behind.
        XCTAssertEqual(timerFailures, [])
        let registry = try XCTUnwrap(session.clientRuntime.vguiRegistry)
        for _ in 0..<8 {
            _ = try session.renderClientVGUIFrame()
        }
        let viewport = try XCTUnwrap(session.clientRuntime.screenMetrics?.viewport)
        let tree = registry.renderTree(
            viewportWidth: viewport.width,
            viewportHeight: viewport.height
        )
        XCTAssertFalse(tree.isEmpty)

        let drawingMenu = try XCTUnwrap(tree.first(where: {
            $0.requestedClassName == "DButton" &&
                $0.text.utf8String == "#menubar.drawing"
        }))
        let drawingHover = try session.dispatchClientVGUIPointerEvent(
            x: drawingMenu.frame.x + drawingMenu.frame.width / 2,
            y: drawingMenu.frame.y + drawingMenu.frame.height / 2,
            phase: .moved,
            timestamp: 1
        )
        XCTAssertEqual(drawingHover.hitPanelIdentifier, drawingMenu.identifier)
        XCTAssertTrue(drawingHover.callbackNames.contains("OnCursorEntered"))

        let weaponsTab = try XCTUnwrap(tree.first(where: {
            $0.requestedClassName == "DTab" &&
                $0.text.utf8String == "#spawnmenu.category.weapons"
        }))
        let weaponsX = weaponsTab.frame.x + weaponsTab.frame.width / 2
        let weaponsY = weaponsTab.frame.y + weaponsTab.frame.height / 2
        let weaponsHover = try session.dispatchClientVGUIPointerEvent(
            x: weaponsX,
            y: weaponsY,
            phase: .moved,
            timestamp: 2
        )
        XCTAssertEqual(weaponsHover.hitPanelIdentifier, weaponsTab.identifier)
        XCTAssertTrue(weaponsHover.callbackNames.contains("OnCursorEntered"))
        let weaponsPress = try session.dispatchClientVGUIPointerEvent(
            x: weaponsX,
            y: weaponsY,
            phase: .began,
            timestamp: 2.1
        )
        XCTAssertEqual(weaponsPress.hitPanelIdentifier, weaponsTab.identifier)
        XCTAssertTrue(weaponsPress.callbackNames.contains("OnMousePressed"))
        let weaponsRelease = try session.dispatchClientVGUIPointerEvent(
            x: weaponsX,
            y: weaponsY,
            phase: .ended,
            timestamp: 2.2
        )
        XCTAssertEqual(weaponsRelease.hitPanelIdentifier, weaponsTab.identifier)
        XCTAssertTrue(weaponsRelease.callbackNames.contains("OnMouseReleased"))
        try session.clientRuntime.execute(
            """
            assert(g_SpawnMenu:GetCreationMenu():GetActiveTab():GetText() ==
                "#spawnmenu.category.weapons")
            """,
            sourceName: "=(strict stock weapons tab selected through pointer)"
        )

        for _ in 0..<8 {
            _ = try session.renderClientVGUIFrame()
        }
        let weaponsTree = registry.renderTree(
            viewportWidth: viewport.width,
            viewportHeight: viewport.height
        )

        let spawnMenu = try XCTUnwrap(weaponsTree.first(where: {
            $0.requestedClassName == "SpawnMenu" && $0.isPopup
        }))
        let panelsByIdentifier = Dictionary(
            uniqueKeysWithValues: weaponsTree.map { ($0.identifier, $0) }
        )
        func isDescendantOfStockSpawnMenu(_ panel: GMLuaPanelRenderSnapshot) -> Bool {
            var parentIdentifier = panel.parentIdentifier
            var visited: Set<Int> = []
            while let identifier = parentIdentifier,
                  visited.insert(identifier).inserted,
                  let parent = panelsByIdentifier[identifier] {
                if identifier == spawnMenu.identifier { return true }
                parentIdentifier = parent.parentIdentifier
            }
            return false
        }

        let halfLifeCategory = try XCTUnwrap(weaponsTree.first(where: {
            $0.requestedClassName == "DTree_Node_Button" &&
                $0.text.utf8String == "Half-Life 2" &&
                isDescendantOfStockSpawnMenu($0)
        }))
        let categoryX = halfLifeCategory.clipRect.x +
            halfLifeCategory.clipRect.width * 0.75
        let categoryY = halfLifeCategory.clipRect.y +
            halfLifeCategory.clipRect.height / 2
        let categoryHover = try session.dispatchClientVGUIPointerEvent(
            x: categoryX,
            y: categoryY,
            phase: .moved,
            timestamp: 3
        )
        XCTAssertEqual(categoryHover.hitPanelIdentifier, halfLifeCategory.identifier)
        XCTAssertTrue(categoryHover.callbackNames.contains("OnCursorEntered"))
        let categoryPress = try session.dispatchClientVGUIPointerEvent(
            x: categoryX,
            y: categoryY,
            phase: .began,
            timestamp: 3.1
        )
        XCTAssertEqual(categoryPress.hitPanelIdentifier, halfLifeCategory.identifier)
        XCTAssertTrue(categoryPress.callbackNames.contains("OnMousePressed"))
        let categoryRelease = try session.dispatchClientVGUIPointerEvent(
            x: categoryX,
            y: categoryY,
            phase: .ended,
            timestamp: 3.2
        )
        XCTAssertEqual(categoryRelease.hitPanelIdentifier, halfLifeCategory.identifier)
        XCTAssertTrue(categoryRelease.callbackNames.contains("OnMouseReleased"))

        try session.clientRuntime.execute(
            """
            local sheet = g_SpawnMenu:GetCreationMenu():GetCreationTab(
                "#spawnmenu.category.weapons")
            local content = sheet.ContentPanel
            local tree = content.ContentNavBar.Tree
            local node = tree.Categories["Half-Life 2"]
            assert(tree:GetSelectedItem() == node)
            assert(IsValid(node.PropPanel))
            assert(content.SelectedPanel == node.PropPanel)
            assert(node.PropPanel:GetCount() == 13)
            """,
            sourceName: "=(strict stock weapon category selected through pointer)"
        )

        let categoryTree = registry.renderTree(
            viewportWidth: viewport.width,
            viewportHeight: viewport.height
        )
        let categoryPanelsByIdentifier = Dictionary(
            uniqueKeysWithValues: categoryTree.map { ($0.identifier, $0) }
        )
        func isCurrentDescendantOfStockSpawnMenu(
            _ panel: GMLuaPanelRenderSnapshot
        ) -> Bool {
            var parentIdentifier = panel.parentIdentifier
            var visited: Set<Int> = []
            while let identifier = parentIdentifier,
                  visited.insert(identifier).inserted,
                  let parent = categoryPanelsByIdentifier[identifier] {
                if identifier == spawnMenu.identifier { return true }
                parentIdentifier = parent.parentIdentifier
            }
            return false
        }
        let weaponIcon = try XCTUnwrap(categoryTree.first(where: { candidate in
            guard candidate.requestedClassName == "ContentIcon",
                  candidate.clipRect.width > 0,
                  candidate.clipRect.height > 0,
                  isCurrentDescendantOfStockSpawnMenu(candidate) else { return false }
            let x = candidate.clipRect.x + candidate.clipRect.width / 2
            let y = candidate.clipRect.y + candidate.clipRect.height / 2
            return categoryTree.reversed().first(where: {
                $0.mouseInputEnabled && $0.clipRect.contains(x: x, y: y)
            })?.identifier == candidate.identifier
        }))
        let weaponIconX = weaponIcon.clipRect.x + weaponIcon.clipRect.width / 2
        let weaponIconY = weaponIcon.clipRect.y + weaponIcon.clipRect.height / 2
        let weaponHover = try session.dispatchClientVGUIPointerEvent(
            x: weaponIconX,
            y: weaponIconY,
            phase: .moved,
            timestamp: 3.3
        )
        XCTAssertEqual(weaponHover.hitPanelIdentifier, weaponIcon.identifier)
        XCTAssertTrue(weaponHover.callbackNames.contains("OnCursorEntered"))
        let weaponIconProbe = try session.clientRuntime.executeReturningValues(
            """
            STOCK_WEAPON_CONTENT_ICON = assert(vgui.GetHoveredPanel())
            assert(STOCK_WEAPON_CONTENT_ICON:GetName() == "ContentIcon")
            assert(STOCK_WEAPON_CONTENT_ICON:GetContentType() == "weapon")
            return STOCK_WEAPON_CONTENT_ICON:GetSpawnName()
            """,
            sourceName: "=(strict stock topmost hovered weapon icon identity)"
        )
        guard case let .string(weaponSpawnName) = weaponIconProbe.first else {
            return XCTFail("stock hovered weapon ContentIcon has no spawn name")
        }
        let weaponPress = try session.dispatchClientVGUIPointerEvent(
            x: weaponIconX,
            y: weaponIconY,
            phase: .began,
            timestamp: 3.4
        )
        XCTAssertEqual(weaponPress.hitPanelIdentifier, weaponIcon.identifier)
        XCTAssertTrue(weaponPress.callbackNames.contains("OnMousePressed"))
        let surfaceState = try XCTUnwrap(session.clientRuntime.surfaceCommandState)
        _ = surfaceState.drainSoundRequestReport()
        let pendingBeforeWeaponRelease = session.sharedSession.netTransport.pendingDeliveryCount
        let weaponRelease = try session.dispatchClientVGUIPointerEvent(
            x: weaponIconX,
            y: weaponIconY,
            phase: .ended,
            timestamp: 3.5
        )
        XCTAssertEqual(weaponRelease.hitPanelIdentifier, weaponIcon.identifier)
        XCTAssertTrue(weaponRelease.callbackNames.contains("OnMouseReleased"))
        XCTAssertEqual(
            session.sharedSession.netTransport.pendingDeliveryCount,
            pendingBeforeWeaponRelease + 1
        )
        let weaponSoundReport = surfaceState.drainSoundRequestReport()
        XCTAssertEqual(
            weaponSoundReport.requests.map(\.soundPath),
            ["ui/buttonclickrelease.wav"]
        )
        XCTAssertFalse(weaponSoundReport.requests[0].hasAudioBacking)
        XCTAssertFalse(weaponSoundReport.diagnostics.overflowed)
        let weaponActionTick = try session.runFixedTick()
        XCTAssertEqual(weaponActionTick.actionFailures, [])
        XCTAssertEqual(weaponActionTick.server.timerFailures, [])
        XCTAssertEqual(weaponActionTick.client.timerFailures, [])
        let canonicalPlayer = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .player
            }
        )
        XCTAssertTrue(canonicalPlayer.motion.isAlive)
        let canonicalWeaponRecord = try XCTUnwrap(
            canonicalPlayer.weaponInventory.weapon(
                className: weaponSpawnName.utf8String
            )
        )
        XCTAssertEqual(
            canonicalPlayer.weaponInventory.activeWeapon,
            canonicalWeaponRecord.identity
        )
        let canonicalWeapon = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.identity == canonicalWeaponRecord.identity
            }
        )
        XCTAssertEqual(canonicalWeapon.kind, .weapon)
        XCTAssertEqual(canonicalWeapon.className, weaponSpawnName.utf8String)
        XCTAssertEqual(canonicalWeapon.creator, canonicalPlayer.identity)
        XCTAssertEqual(canonicalWeapon.lifecycle, .active)
        XCTAssertEqual(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == canonicalWeapon.identity
            },
            canonicalWeapon
        )
        XCTAssertFalse(session.isClosed)
        XCTAssertFalse(session.clientRuntime.isClosed)
        XCTAssertFalse(session.serverRuntime.isClosed)

        let toolButton = try XCTUnwrap(categoryTree.first(where: {
            $0.requestedClassName == "DButton" &&
                $0.text.utf8String == "#tool.button.name" &&
                $0.clipRect.width > 0 && $0.clipRect.height > 0
        }))
        let toolButtonX = toolButton.clipRect.x + toolButton.clipRect.width / 2
        let toolButtonY = toolButton.clipRect.y + toolButton.clipRect.height / 2
        let toolHover = try session.dispatchClientVGUIPointerEvent(
            x: toolButtonX,
            y: toolButtonY,
            phase: .moved,
            timestamp: 4
        )
        XCTAssertEqual(toolHover.hitPanelIdentifier, toolButton.identifier)
        XCTAssertTrue(toolHover.callbackNames.contains("OnCursorEntered"))
        let toolPress = try session.dispatchClientVGUIPointerEvent(
            x: toolButtonX,
            y: toolButtonY,
            phase: .began,
            timestamp: 4.1
        )
        XCTAssertEqual(toolPress.hitPanelIdentifier, toolButton.identifier)
        XCTAssertTrue(toolPress.callbackNames.contains("OnMousePressed"))
        let toolRelease = try session.dispatchClientVGUIPointerEvent(
            x: toolButtonX,
            y: toolButtonY,
            phase: .ended,
            timestamp: 4.2
        )
        XCTAssertEqual(toolRelease.hitPanelIdentifier, toolButton.identifier)
        XCTAssertTrue(toolRelease.callbackNames.contains("OnMouseReleased"))
        try session.clientRuntime.execute(
            """
            local panel = g_SpawnMenu:GetToolMenu():GetToolPanel( 1 )
            assert(IsValid(panel))
            assert(panel.ActiveCPName == "button")
            local cp = controlpanel.Get("button")
            assert(IsValid(cp) and cp:GetInitialized())
            """,
            sourceName: "=(strict stock button tool selected through pointer)"
        )

        for _ in 0..<8 {
            _ = try session.renderClientVGUIFrame()
        }
        let toolTree = registry.renderTree(
            viewportWidth: viewport.width,
            viewportHeight: viewport.height
        )

        let toolPanelsByIdentifier = Dictionary(
            uniqueKeysWithValues: toolTree.map { ($0.identifier, $0) }
        )
        func isCurrentToolDescendantOfStockSpawnMenu(
            _ panel: GMLuaPanelRenderSnapshot
        ) -> Bool {
            var parentIdentifier = panel.parentIdentifier
            var visited: Set<Int> = []
            while let identifier = parentIdentifier,
                  visited.insert(identifier).inserted,
                  let parent = toolPanelsByIdentifier[identifier] {
                if identifier == spawnMenu.identifier { return true }
                parentIdentifier = parent.parentIdentifier
            }
            return false
        }
        let buttonSpawnIcon = try XCTUnwrap(toolTree.first(where: { candidate in
            guard candidate.requestedClassName == "SpawnIcon",
                  candidate.clipRect.width > 0,
                  candidate.clipRect.height > 0,
                  isCurrentToolDescendantOfStockSpawnMenu(candidate) else { return false }
            let x = candidate.clipRect.x + candidate.clipRect.width / 2
            let y = candidate.clipRect.y + candidate.clipRect.height / 2
            return toolTree.reversed().first(where: {
                $0.mouseInputEnabled && $0.clipRect.contains(x: x, y: y)
            })?.identifier == candidate.identifier
        }))
        let buttonSpawnIconX = buttonSpawnIcon.clipRect.x +
            buttonSpawnIcon.clipRect.width / 2
        let buttonSpawnIconY = buttonSpawnIcon.clipRect.y +
            buttonSpawnIcon.clipRect.height / 2
        let buttonIconHover = try session.dispatchClientVGUIPointerEvent(
            x: buttonSpawnIconX,
            y: buttonSpawnIconY,
            phase: .moved,
            timestamp: 4.3
        )
        XCTAssertEqual(buttonIconHover.hitPanelIdentifier, buttonSpawnIcon.identifier)
        XCTAssertTrue(buttonIconHover.callbackNames.contains("OnCursorEntered"))
        let buttonIconIdentity = try session.clientRuntime.executeReturningValues(
            """
            STOCK_BUTTON_SPAWN_ICON = assert(vgui.GetHoveredPanel())
            assert(STOCK_BUTTON_SPAWN_ICON:GetName() == "SpawnIcon")
            local cp = assert(controlpanel.Get("button"))
            local current = STOCK_BUTTON_SPAWN_ICON
            while IsValid(current) and current != cp do
                current = current:GetParent()
            end
            assert(current == cp)
            return STOCK_BUTTON_SPAWN_ICON.Model,
                STOCK_BUTTON_SPAWN_ICON.Value,
                STOCK_BUTTON_SPAWN_ICON:GetModelName(),
                STOCK_BUTTON_SPAWN_ICON:GetSkinID()
            """,
            sourceName: "=(strict stock topmost hovered button SpawnIcon identity)"
        )
        guard case let .string(buttonModel) = buttonIconIdentity.first else {
            return XCTFail("stock hovered button SpawnIcon has no model")
        }
        guard case let .string(buttonValue) = buttonIconIdentity[1],
              case let .string(buttonModelName) = buttonIconIdentity[2],
              case let .number(buttonSkin) = buttonIconIdentity[3] else {
            return XCTFail("stock hovered button SpawnIcon returned invalid model state")
        }
        XCTAssertEqual(buttonValue.utf8String, buttonModel.utf8String)
        XCTAssertEqual(buttonModelName.utf8String, buttonModel.utf8String)
        XCTAssertEqual(buttonSkin, 0)

        let buttonIconPress = try session.dispatchClientVGUIPointerEvent(
            x: buttonSpawnIconX,
            y: buttonSpawnIconY,
            phase: .began,
            timestamp: 4.4
        )
        XCTAssertEqual(buttonIconPress.hitPanelIdentifier, buttonSpawnIcon.identifier)
        XCTAssertTrue(buttonIconPress.callbackNames.contains("OnMousePressed"))
        let buttonIconPressState = try session.clientRuntime.executeReturningValues(
            """
            return STOCK_BUTTON_SPAWN_ICON.Depressed == true,
                STOCK_BUTTON_SPAWN_ICON.Hovered == true,
                STOCK_BUTTON_SPAWN_ICON:IsEnabled(),
                STOCK_BUTTON_SPAWN_ICON:IsHovered(),
                vgui.GetHoveredPanel() == STOCK_BUTTON_SPAWN_ICON,
                not dragndrop.IsDragging()
            """,
            sourceName: "=(strict stock button SpawnIcon press state)"
        )
        XCTAssertTrue(
            buttonIconPressState.allSatisfy {
                if case .boolean(true) = $0 { return true }
                return false
            },
            "unexpected stock SpawnIcon press state: \(buttonIconPressState)"
        )
        let consoleDispatcher = try XCTUnwrap(
            session.clientRuntime.consoleCommandDispatcher
        )
        _ = consoleDispatcher.drainPlayerConsoleCommandRequestReport()
        let buttonIconRelease = try session.dispatchClientVGUIPointerEvent(
            x: buttonSpawnIconX,
            y: buttonSpawnIconY,
            phase: .ended,
            timestamp: 4.5
        )
        XCTAssertEqual(buttonIconRelease.hitPanelIdentifier, buttonSpawnIcon.identifier)
        XCTAssertTrue(buttonIconRelease.callbackNames.contains("OnMouseReleased"))
        let buttonIconReleaseState = try session.clientRuntime.executeReturningValues(
            """
            local selectedOwner = STOCK_BUTTON_SPAWN_ICON
            while IsValid(selectedOwner) do
                if selectedOwner.SelectedIcon == STOCK_BUTTON_SPAWN_ICON and
                    selectedOwner.CurrentValue == STOCK_BUTTON_SPAWN_ICON.Value then
                    break
                end
                selectedOwner = selectedOwner:GetParent()
            end
            return IsValid(selectedOwner),
                STOCK_BUTTON_SPAWN_ICON.Depressed == nil,
                STOCK_BUTTON_SPAWN_ICON.Hovered == true,
                not dragndrop.IsDragging()
            """,
            sourceName: "=(strict stock button SpawnIcon selected through pointer)"
        )
        XCTAssertTrue(
            buttonIconReleaseState.allSatisfy {
                if case .boolean(true) = $0 { return true }
                return false
            },
            "unexpected stock SpawnIcon release state: \(buttonIconReleaseState)"
        )
        let buttonCommandTick = try session.runFixedTick()
        XCTAssertEqual(buttonCommandTick.actionFailures, [])
        XCTAssertEqual(buttonCommandTick.server.timerFailures, [])
        XCTAssertEqual(buttonCommandTick.client.timerFailures, [])
        XCTAssertEqual(
            session.clientRuntime.conVarRegistry?.stringValue(for: "gmod_toolmode"),
            "button"
        )
        let postToolSelectionPlayer = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.identity == canonicalPlayer.identity
            }
        )
        XCTAssertEqual(
            postToolSelectionPlayer.weaponInventory.activeWeapon,
            canonicalWeaponRecord.identity
        )
        XCTAssertEqual(
            postToolSelectionPlayer.weaponInventory.weapon(
                className: weaponSpawnName.utf8String
            )?.identity,
            canonicalWeaponRecord.identity
        )
        XCTAssertFalse(session.isClosed)
        XCTAssertFalse(session.clientRuntime.isClosed)
        XCTAssertFalse(session.serverRuntime.isClosed)
        let buttonCommandReport = consoleDispatcher
            .drainPlayerConsoleCommandRequestReport()
        XCTAssertEqual(buttonCommandReport.attemptedRequestCount, 1)
        XCTAssertEqual(buttonCommandReport.droppedRequestCount, 0)
        XCTAssertEqual(buttonCommandReport.requests.count, 1)
        XCTAssertEqual(
            buttonCommandReport.requests[0].rawCommand,
            "button_model \"\(buttonModel.utf8String)\"\n"
        )
        XCTAssertEqual(buttonCommandReport.requests[0].parsedCommands, [
            GMLuaConsoleCommandInvocation(
                realm: .client,
                command: "button_model",
                arguments: [buttonModel.utf8String]
            )
        ])
        XCTAssertEqual(
            buttonCommandReport.requests[0].outcome,
            .dispatched(commandCount: 1)
        )
        let buttonCommandProbe = try session.clientRuntime.executeReturningValues(
            "return GetConVarString('button_model')",
            sourceName: "=(strict stock button model convar after icon click)"
        )
        guard case let .string(selectedButtonModel) = buttonCommandProbe.first else {
            return XCTFail("stock button_model did not return a string")
        }
        XCTAssertEqual(selectedButtonModel.utf8String, buttonModel.utf8String)

        let balloonButton = try XCTUnwrap(categoryTree.first(where: {
            $0.requestedClassName == "DButton" &&
                $0.text.utf8String == "#tool.balloon.name" &&
                $0.clipRect.width > 0 && $0.clipRect.height > 0
        }))
        let balloonButtonX = balloonButton.clipRect.x + balloonButton.clipRect.width / 2
        let balloonButtonY = balloonButton.clipRect.y + balloonButton.clipRect.height / 2
        let balloonHover = try session.dispatchClientVGUIPointerEvent(
            x: balloonButtonX,
            y: balloonButtonY,
            phase: .moved,
            timestamp: 5
        )
        XCTAssertEqual(balloonHover.hitPanelIdentifier, balloonButton.identifier)
        XCTAssertTrue(balloonHover.callbackNames.contains("OnCursorEntered"))
        let balloonPress = try session.dispatchClientVGUIPointerEvent(
            x: balloonButtonX,
            y: balloonButtonY,
            phase: .began,
            timestamp: 5.1
        )
        XCTAssertEqual(balloonPress.hitPanelIdentifier, balloonButton.identifier)
        XCTAssertTrue(balloonPress.callbackNames.contains("OnMousePressed"))
        let balloonRelease = try session.dispatchClientVGUIPointerEvent(
            x: balloonButtonX,
            y: balloonButtonY,
            phase: .ended,
            timestamp: 5.2
        )
        XCTAssertEqual(balloonRelease.hitPanelIdentifier, balloonButton.identifier)
        XCTAssertTrue(balloonRelease.callbackNames.contains("OnMouseReleased"))
        for _ in 0..<8 {
            _ = try session.renderClientVGUIFrame()
        }
        let balloonTree = registry.renderTree(
            viewportWidth: viewport.width,
            viewportHeight: viewport.height
        )

        let balloonTreeByIdentifier = Dictionary(
            uniqueKeysWithValues: balloonTree.map { ($0.identifier, $0) }
        )
        let balloonControlPanel = try XCTUnwrap(balloonTree.first(where: {
            $0.requestedClassName == "ControlPanel" && $0.frame.height > 600
        }))
        func isDescendant(
            _ candidate: GMLuaPanelRenderSnapshot,
            of ancestorIdentifier: Int,
            in panelsByIdentifier: [Int: GMLuaPanelRenderSnapshot]
        ) -> Bool {
            var current = candidate.parentIdentifier
            var visited: Set<Int> = []
            while let identifier = current,
                  visited.insert(identifier).inserted,
                  let parent = panelsByIdentifier[identifier] {
                if identifier == ancestorIdentifier { return true }
                current = parent.parentIdentifier
            }
            return false
        }
        let balloonPropSelect = try XCTUnwrap(balloonTree.first(where: {
            $0.requestedClassName == "PropSelect" &&
                isDescendant(
                    $0,
                    of: balloonControlPanel.identifier,
                    in: balloonTreeByIdentifier
                )
        }))

        // At the ordinary desktop height the genuine Balloon control fits.
        // Narrow the live viewport so the same stock panel really overflows.
        XCTAssertTrue(try session.updateViewport(width: 1_280, height: 480))
        for _ in 0..<8 {
            _ = try session.renderClientVGUIFrame()
        }
        let compactViewport = try XCTUnwrap(session.clientRuntime.screenMetrics?.viewport)
        XCTAssertEqual(compactViewport, GMLuaViewportSize(width: 1_280, height: 480))
        let compactGeometryBefore = try session.clientRuntime.executeReturningValues(
            """
            local panel = g_SpawnMenu:GetToolMenu():GetToolPanel(1)
            local cp = assert(controlpanel.Get("balloon"))
            assert(panel.ActiveCPName == "balloon")
            return panel.Content:GetTall(), panel.Content:GetCanvas():GetTall(),
                panel.Content.VBar.Enabled, panel.Content.VBar:GetScroll(),
                panel.Content.VBar:GetOffset(), cp:GetTall(), cp:GetY()
            """,
            sourceName: "=(strict stock balloon compact overflow before wheel)"
        )
        guard case let .number(compactContentHeight) = compactGeometryBefore[0],
              case let .number(compactCanvasHeight) = compactGeometryBefore[1],
              case .boolean(true) = compactGeometryBefore[2],
              case let .number(compactScrollBefore) = compactGeometryBefore[3],
              case let .number(compactOffsetBefore) = compactGeometryBefore[4] else {
            return XCTFail("stock Balloon panel did not expose overflowing scroll geometry")
        }
        XCTAssertLessThan(compactContentHeight, compactCanvasHeight)
        XCTAssertEqual(compactScrollBefore, 0)
        XCTAssertEqual(compactOffsetBefore, 0)

        let compactTreeBefore = registry.renderTree(
            viewportWidth: compactViewport.width,
            viewportHeight: compactViewport.height
        )
        let compactTreeByIdentifier = Dictionary(
            uniqueKeysWithValues: compactTreeBefore.map { ($0.identifier, $0) }
        )
        let compactControlPanelBefore = try XCTUnwrap(
            compactTreeByIdentifier[balloonControlPanel.identifier]
        )
        var scrollPanelIdentifier = compactControlPanelBefore.parentIdentifier
        var visitedScrollAncestors: Set<Int> = []
        var balloonScrollPanel: GMLuaPanelRenderSnapshot?
        while let identifier = scrollPanelIdentifier,
              visitedScrollAncestors.insert(identifier).inserted,
              let ancestor = compactTreeByIdentifier[identifier] {
            if ancestor.requestedClassName == "DCategoryList" {
                balloonScrollPanel = ancestor
                break
            }
            scrollPanelIdentifier = ancestor.parentIdentifier
        }
        let stockBalloonScrollPanel = try XCTUnwrap(balloonScrollPanel)
        let stockBalloonVBar = try XCTUnwrap(compactTreeBefore.first(where: {
            $0.parentIdentifier == stockBalloonScrollPanel.identifier &&
                $0.requestedClassName == "DVScrollBar" &&
                $0.clipRect.width > 0 && $0.clipRect.height > 0
        }))
        // Apple and Windows can disagree by one boundary pixel after the
        // stock Derma layout is rounded. Either fully clipped or a one-pixel
        // sliver still establishes the pre-scroll state without weakening
        // the later assertion that scrolling reveals more of PropSelect.
        let compactPropSelectHeightBefore =
            compactTreeByIdentifier[balloonPropSelect.identifier]?.clipRect.height ?? 0
        XCTAssertLessThanOrEqual(compactPropSelectHeightBefore, 1)

        let wheelX = stockBalloonVBar.clipRect.x + stockBalloonVBar.clipRect.width / 2
        var wheelPoint: (x: Double, y: Double)?
        let firstWheelRow = Int(ceil(stockBalloonVBar.clipRect.y))
        let lastWheelRow = Int(floor(
            stockBalloonVBar.clipRect.y + stockBalloonVBar.clipRect.height
        ))
        if firstWheelRow < lastWheelRow {
            for row in firstWheelRow..<lastWheelRow {
                let candidateY = Double(row) + 0.5
                let topmost = compactTreeBefore.reversed().first(where: {
                    $0.mouseInputEnabled && $0.clipRect.contains(x: wheelX, y: candidateY)
                })
                if topmost?.identifier == stockBalloonVBar.identifier {
                    wheelPoint = (wheelX, candidateY)
                    break
                }
            }
        }
        let realWheelPoint = try XCTUnwrap(
            wheelPoint,
            "stock Balloon scrollbar has no visible topmost track coordinate"
        )
        let wheelHover = try session.dispatchClientVGUIPointerEvent(
            x: realWheelPoint.x,
            y: realWheelPoint.y,
            phase: .moved,
            timestamp: 6
        )
        XCTAssertEqual(wheelHover.hitPanelIdentifier, stockBalloonVBar.identifier)
        try session.clientRuntime.execute(
            """
            local panel = g_SpawnMenu:GetToolMenu():GetToolPanel(1)
            assert(vgui.GetHoveredPanel() == panel.Content.VBar)
            """,
            sourceName: "=(strict stock Balloon visible scrollbar hover identity)"
        )
        let wheel = try session.dispatchClientVGUIPointerEvent(
            x: realWheelPoint.x,
            y: realWheelPoint.y,
            phase: .scroll(delta: -1),
            timestamp: 6.1
        )
        XCTAssertEqual(wheel.hitPanelIdentifier, stockBalloonVBar.identifier)
        XCTAssertTrue(wheel.callbackNames.contains("OnMouseWheeled"))
        for _ in 0..<2 {
            _ = try session.renderClientVGUIFrame()
        }

        let compactGeometryAfter = try session.clientRuntime.executeReturningValues(
            """
            local panel = g_SpawnMenu:GetToolMenu():GetToolPanel(1)
            return panel.Content.VBar:GetScroll(), panel.Content.VBar:GetOffset(),
                panel.Content:GetCanvas():GetY()
            """,
            sourceName: "=(strict stock Balloon compact overflow after wheel)"
        )
        guard case let .number(compactScrollAfter) = compactGeometryAfter[0],
              case let .number(compactOffsetAfter) = compactGeometryAfter[1],
              case let .number(compactCanvasYAfter) = compactGeometryAfter[2] else {
            return XCTFail("stock Balloon wheel did not return scroll state")
        }
        XCTAssertGreaterThan(compactScrollAfter, compactScrollBefore)
        XCTAssertLessThan(compactOffsetAfter, compactOffsetBefore)
        XCTAssertEqual(compactOffsetAfter, -compactScrollAfter)
        XCTAssertEqual(compactCanvasYAfter, compactOffsetAfter)

        let compactTreeAfter = registry.renderTree(
            viewportWidth: compactViewport.width,
            viewportHeight: compactViewport.height
        )
        let compactControlPanelAfter = try XCTUnwrap(compactTreeAfter.first(where: {
            $0.identifier == balloonControlPanel.identifier
        }))
        XCTAssertEqual(
            compactControlPanelAfter.frame.y - compactControlPanelBefore.frame.y,
            compactOffsetAfter - compactOffsetBefore
        )
        XCTAssertNotEqual(
            compactControlPanelAfter.clipRect,
            compactControlPanelBefore.clipRect
        )
        let revealedPropSelect = try XCTUnwrap(compactTreeAfter.first(where: {
            $0.identifier == balloonPropSelect.identifier
        }))
        XCTAssertGreaterThan(
            revealedPropSelect.clipRect.height,
            compactPropSelectHeightBefore
        )
        XCTAssertLessThan(revealedPropSelect.clipRect.height, revealedPropSelect.frame.height)

        try session.setSpawnMenuOpen(false)
        _ = try session.renderClientVGUIFrame()
        try session.clientRuntime.execute(
            "assert(IsValid(g_SpawnMenu) and not g_SpawnMenu:IsVisible())",
            sourceName: "=(strict stock spawn menu closed cleanly)"
        )
        let closedTree = registry.renderTree(
            viewportWidth: compactViewport.width,
            viewportHeight: compactViewport.height
        )
        XCTAssertFalse(closedTree.contains(where: { $0.identifier == spawnMenu.identifier }))
        XCTAssertFalse(session.isClosed)
        XCTAssertFalse(session.clientRuntime.isClosed)
        XCTAssertFalse(session.serverRuntime.isClosed)
        let closeReport = try session.close()
        XCTAssertEqual(closeReport.clientFinalizerErrors, [])
        XCTAssertEqual(closeReport.serverFinalizerErrors, [])
        XCTAssertTrue(session.isClosed)
    }
}
