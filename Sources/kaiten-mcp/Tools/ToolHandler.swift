import Foundation
import KaitenSDK
import MCP

@Sendable
func handleToolCall(_ params: CallTool.Parameters) async -> CallTool.Result {
  let startedAt = Date()
  let argumentKeys = formatArgumentKeys(params.arguments.map { Array($0.keys) } ?? [])
  log("Tool call started: \(params.name) keys=[\(argumentKeys)]")
  do {
    let json: String = try await {
      if params.name == "kaiten_get_preferences" {
        let currentConfig = Config.load()
        let currentPreferences = Preferences.load()
        let response = PreferencesResponse(
          url: currentConfig.url,
          myBoards: currentPreferences.myBoards,
          mySpaces: currentPreferences.mySpaces
        )
        return toJSON(response)
      }

      if params.name == "kaiten_configure" {
        let action = try requireString(params, key: "action")
        var prefs = Preferences.load()

        switch action {
        case "get":
          return toJSON(prefs)

        case "set_boards":
          let ids = try requireIntArray(params, key: "ids")
          prefs.myBoards = ids.map { Preferences.BoardRef(id: $0) }
          try prefs.save()
          return toJSON(prefs)

        case "set_spaces":
          let ids = try requireIntArray(params, key: "ids")
          prefs.mySpaces = ids.map { Preferences.SpaceRef(id: $0) }
          try prefs.save()
          return toJSON(prefs)

        case "add_board":
          let id = try requireInt(params, key: "id")
          let alias = optionalString(params, key: "alias")
          var boards = prefs.myBoards ?? []
          if !boards.contains(where: { $0.id == id }) {
            boards.append(Preferences.BoardRef(id: id, alias: alias))
          }
          prefs.myBoards = boards
          try prefs.save()
          return toJSON(prefs)

        case "remove_board":
          let id = try requireInt(params, key: "id")
          prefs.myBoards?.removeAll(where: { $0.id == id })
          try prefs.save()
          return toJSON(prefs)

        case "add_space":
          let id = try requireInt(params, key: "id")
          let alias = optionalString(params, key: "alias")
          var spaces = prefs.mySpaces ?? []
          if !spaces.contains(where: { $0.id == id }) {
            spaces.append(Preferences.SpaceRef(id: id, alias: alias))
          }
          prefs.mySpaces = spaces
          try prefs.save()
          return toJSON(prefs)

        case "remove_space":
          let id = try requireInt(params, key: "id")
          prefs.mySpaces?.removeAll(where: { $0.id == id })
          try prefs.save()
          return toJSON(prefs)

        default:
          throw ToolError.invalidType(
            key: "action",
            expected:
              "one of: get, set_boards, set_spaces, add_board, remove_board, add_space, remove_space"
          )
        }
      }

      if params.name == "kaiten_login" {
        let rawURL = try requireString(params, key: "url")
        let rawToken = try requireString(params, key: "token")
        try validateLoginInput(url: rawURL, token: rawToken)

        var currentConfig = Config.load()
        currentConfig.url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        currentConfig.token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        try currentConfig.save()
        log("kaiten_login: credentials saved to \(Config.filePath.path)")
        return toJSON(currentConfig)
      }

      if params.name == "kaiten_read_logs" {
        let tailLines = optionalInt(params, key: "tail_lines")
        if let tailLines, tailLines <= 0 {
          throw ToolError.invalidType(key: "tail_lines", expected: "positive integer")
        }
        let response = LogReadResponse(
          path: logFilePath,
          content: try readLogContent(path: logFilePath, tailLines: tailLines)
        )
        log(
          "kaiten_read_logs: returned log content from \(logFilePath), tail_lines=\(tailLines?.description ?? "all")"
        )
        return toJSON(response)
      }

      let kaiten = try makeConfiguredKaitenClient()

      switch params.name {
      case "kaiten_list_cards":
        let boardId = optionalInt(params, key: "board_id")
        let columnId = optionalInt(params, key: "column_id")
        let laneId = optionalInt(params, key: "lane_id")
        let offset = optionalInt(params, key: "offset") ?? 0
        let limit = optionalInt(params, key: "limit") ?? 100

        // Date parsing helper
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        func parseDate(_ key: String) -> Date? {
          guard let s = optionalString(params, key: key) else { return nil }
          return iso.date(from: s) ?? iso2.date(from: s)
        }

        let filter = KaitenClient.CardFilter(
          createdBefore: parseDate("created_before"),
          createdAfter: parseDate("created_after"),
          updatedBefore: parseDate("updated_before"),
          updatedAfter: parseDate("updated_after"),
          firstMovedInProgressAfter: parseDate("first_moved_in_progress_after"),
          firstMovedInProgressBefore: parseDate("first_moved_in_progress_before"),
          lastMovedToDoneAtAfter: parseDate("last_moved_to_done_at_after"),
          lastMovedToDoneAtBefore: parseDate("last_moved_to_done_at_before"),
          dueDateAfter: parseDate("due_date_after"),
          dueDateBefore: parseDate("due_date_before"),
          query: optionalString(params, key: "query"),
          searchFields: optionalString(params, key: "search_fields"),
          tag: optionalString(params, key: "tag"),
          tagIds: optionalString(params, key: "tag_ids"),
          typeId: optionalInt(params, key: "type_id"),
          typeIds: optionalString(params, key: "type_ids"),
          memberIds: optionalString(params, key: "member_ids"),
          ownerId: optionalInt(params, key: "owner_id"),
          ownerIds: optionalString(params, key: "owner_ids"),
          responsibleId: optionalInt(params, key: "responsible_id"),
          responsibleIds: optionalString(params, key: "responsible_ids"),
          columnIds: optionalString(params, key: "column_ids"),
          spaceId: optionalInt(params, key: "space_id"),
          externalId: optionalString(params, key: "external_id"),
          organizationsIds: optionalString(params, key: "organizations_ids"),
          excludeBoardIds: optionalString(params, key: "exclude_board_ids"),
          excludeLaneIds: optionalString(params, key: "exclude_lane_ids"),
          excludeColumnIds: optionalString(params, key: "exclude_column_ids"),
          excludeOwnerIds: optionalString(params, key: "exclude_owner_ids"),
          excludeCardIds: optionalString(params, key: "exclude_card_ids"),
          condition: optionalInt(params, key: "condition").flatMap { CardCondition(rawValue: $0) },
          states: optionalString(params, key: "states").map {
            $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
              .compactMap { CardState(rawValue: $0) }
          },
          archived: optionalBool(params, key: "archived") ?? false,
          asap: optionalBool(params, key: "asap"),
          overdue: optionalBool(params, key: "overdue"),
          doneOnTime: optionalBool(params, key: "done_on_time"),
          withDueDate: optionalBool(params, key: "with_due_date"),
          isRequest: optionalBool(params, key: "is_request"),
          orderBy: optionalString(params, key: "order_by"),
          orderDirection: optionalString(params, key: "order_direction"),
          orderSpaceId: optionalInt(params, key: "order_space_id"),
          additionalCardFields: optionalString(params, key: "additional_card_fields")
        )

        let page = try await kaiten.listCards(
          boardId: boardId, columnId: columnId, laneId: laneId, offset: offset, limit: limit,
          filter: filter)

        let summary = optionalBool(params, key: "summary") ?? true
        if summary {
          let summaryPage = Page(
            items: page.items.map { CardSummary(card: $0) },
            offset: page.offset,
            limit: page.limit,
            hasMore: page.hasMore
          )
          return toJSON(summaryPage)
        }
        return toJSON(page)

      case "kaiten_get_card":
        let id = try requireInt(params, key: "id")
        let card = try await kaiten.getCard(id: id)
        let summary = optionalBool(params, key: "summary") ?? true
        if summary {
          return toJSON(CardDetailSummary(card: card))
        }
        return toJSON(card)

      case "kaiten_update_card":
        let id = try requireInt(params, key: "id")
        var options = CardUpdateOptions()
        options.title = optionalString(params, key: "title")
        options.description = normalizeOptionalEscapedNewlines(optionalString(params, key: "description"))
        options.asap = optionalBool(params, key: "asap")
        options.dueDate = optionalString(params, key: "due_date")
        options.dueDateTimePresent = optionalBool(params, key: "due_date_time_present")
        options.sortOrder = optionalDouble(params, key: "sort_order")
        options.expiresLater = optionalBool(params, key: "expires_later")
        options.sizeText = optionalString(params, key: "size_text")
        options.boardId = optionalInt(params, key: "board_id")
        options.columnId = optionalInt(params, key: "column_id")
        options.laneId = optionalInt(params, key: "lane_id")
        options.ownerId = optionalInt(params, key: "owner_id")
        options.typeId = optionalInt(params, key: "type_id")
        options.serviceId = optionalInt(params, key: "service_id")
        options.blocked = optionalBool(params, key: "blocked")
        options.condition = optionalInt(params, key: "condition").flatMap {
          CardCondition(rawValue: $0)
        }
        options.externalId = optionalString(params, key: "external_id")
        options.textFormatTypeId = optionalInt(params, key: "text_format_type_id").flatMap {
          TextFormatType(rawValue: $0)
        }
        options.sdNewComment = optionalBool(params, key: "sd_new_comment")
        options.ownerEmail = optionalString(params, key: "owner_email")
        options.prevCardId = optionalInt(params, key: "prev_card_id")
        options.estimateWorkload = optionalDouble(params, key: "estimate_workload")
        options.plannedStart = optionalString(params, key: "planned_start")
        options.plannedEnd = optionalString(params, key: "planned_end")
        let card = try await kaiten.updateCard(id: id, options)
        return toJSON(card)

      case "kaiten_get_card_members":
        let cardId = try requireInt(params, key: "card_id")
        let members = try await kaiten.getCardMembers(cardId: cardId)
        return toJSON(members)

      case "kaiten_get_card_comments":
        let cardId = try requireInt(params, key: "card_id")
        let comments = try await kaiten.getCardComments(cardId: cardId)
        return toJSON(comments)

      case "kaiten_create_card":
        let title = try requireString(params, key: "title")
        let boardId = try requireInt(params, key: "board_id")
        var options = CardCreateOptions(title: title, boardId: boardId)
        options.columnId = optionalInt(params, key: "column_id")
        options.laneId = optionalInt(params, key: "lane_id")
        options.description = normalizeOptionalEscapedNewlines(optionalString(params, key: "description"))
        options.asap = optionalBool(params, key: "asap")
        options.dueDate = optionalString(params, key: "due_date")
        options.dueDateTimePresent = optionalBool(params, key: "due_date_time_present")
        options.sortOrder = optionalDouble(params, key: "sort_order")
        options.expiresLater = optionalBool(params, key: "expires_later")
        options.sizeText = optionalString(params, key: "size_text")
        options.ownerId = optionalInt(params, key: "owner_id")
        options.responsibleId = optionalInt(params, key: "responsible_id")
        options.ownerEmail = optionalString(params, key: "owner_email")
        options.position = optionalInt(params, key: "position").flatMap { CardPosition(rawValue: $0) }
        options.typeId = optionalInt(params, key: "type_id")
        options.externalId = optionalString(params, key: "external_id")
        let card = try await kaiten.createCard(options)
        return toJSON(card)

      case "kaiten_create_comment":
        let cardId = try requireInt(params, key: "card_id")
        let text = normalizeEscapedNewlines(try requireString(params, key: "text"))
        let comment = try await kaiten.createComment(cardId: cardId, text: text)
        return toJSON(comment)

      case "kaiten_list_spaces":
        let spaces = try await kaiten.listSpaces()
        return toJSON(spaces)

      case "kaiten_list_boards":
        let spaceId = try requireInt(params, key: "space_id")
        let boards = try await kaiten.listBoards(spaceId: spaceId)
        return toJSON(boards)

      case "kaiten_get_board":
        let id = try requireInt(params, key: "id")
        let board = try await kaiten.getBoard(id: id)
        return toJSON(board)

      case "kaiten_get_board_columns":
        let boardId = try requireInt(params, key: "board_id")
        let columns = try await kaiten.getBoardColumns(boardId: boardId)
        return toJSON(columns)

      case "kaiten_get_board_lanes":
        let boardId = try requireInt(params, key: "board_id")
        let condition = optionalInt(params, key: "condition").flatMap {
          LaneCondition(rawValue: $0)
        }
        let lanes = try await kaiten.getBoardLanes(boardId: boardId, condition: condition)
        return toJSON(lanes)

      case "kaiten_list_custom_properties":
        let offset = optionalInt(params, key: "offset") ?? 0
        let limit = optionalInt(params, key: "limit") ?? 100
        let query = optionalString(params, key: "query")
        let includeValues = optionalBool(params, key: "include_values")
        let includeAuthor = optionalBool(params, key: "include_author")
        let compact = optionalBool(params, key: "compact")
        let loadByIds = optionalBool(params, key: "load_by_ids")
        let ids: [Int]? =
          (params.arguments?["ids"]?.arrayValue != nil)
          ? try requireIntArray(params, key: "ids") : nil
        let orderBy = optionalString(params, key: "order_by")
        let orderDirection = optionalString(params, key: "order_direction")
        let props = try await kaiten.listCustomProperties(
          offset: offset, limit: limit, query: query, includeValues: includeValues,
          includeAuthor: includeAuthor, compact: compact, loadByIds: loadByIds, ids: ids,
          orderBy: orderBy, orderDirection: orderDirection)
        return toJSON(props)

      case "kaiten_get_custom_property":
        let id = try requireInt(params, key: "id")
        let prop = try await kaiten.getCustomProperty(id: id)
        return toJSON(prop)

      case "kaiten_get_custom_property_select_values":
        let propertyId = try requireInt(params, key: "property_id")
        let query = optionalString(params, key: "query")
        let offset = optionalInt(params, key: "offset") ?? 0
        let limit = optionalInt(params, key: "limit") ?? 100
        let values = try await kaiten.listCustomPropertySelectValues(
          propertyId: propertyId,
          query: query,
          offset: offset,
          limit: limit
        )
        return toJSON(values)

      case "kaiten_update_card_properties":
        let cardId = try requireInt(params, key: "card_id")
        guard let propsValue = params.arguments?["properties"],
          let propsObject = propsValue.objectValue
        else {
          throw ToolError.invalidType(key: "properties", expected: "object")
        }
        // Convert MCP Value dict to JSON data, then decode as propertiesPayload
        let propsData = try JSONSerialization.data(
          withJSONObject: propsObject.mapValues { jsonValueToAny($0) })
        let properties = try JSONDecoder().decode(
          Components.Schemas.UpdateCardRequest.propertiesPayload.self, from: propsData)
        var options = CardUpdateOptions()
        options.properties = properties
        let card = try await kaiten.updateCard(id: cardId, options)
        return toJSON(card)

      // Sprint
      case "kaiten_get_sprint_summary":
        let id = try requireInt(params, key: "id")
        let excludeDeletedCards = optionalBool(params, key: "exclude_deleted_cards")
        let summary = try await kaiten.getSprintSummary(
          id: id, excludeDeletedCards: excludeDeletedCards)
        return toJSON(summary)

      // Spaces CRUD
      case "kaiten_create_space":
        let title = try requireString(params, key: "title")
        let externalId = optionalString(params, key: "external_id")
        let sortOrder = optionalDouble(params, key: "sort_order")
        let space = try await kaiten.createSpace(
          title: title, externalId: externalId, sortOrder: sortOrder)
        return toJSON(space)

      case "kaiten_get_space":
        let id = try requireInt(params, key: "id")
        let space = try await kaiten.getSpace(id: id)
        return toJSON(space)

      case "kaiten_update_space":
        let id = try requireInt(params, key: "id")
        let space = try await kaiten.updateSpace(
          id: id,
          title: optionalString(params, key: "title"),
          externalId: optionalString(params, key: "external_id"),
          sortOrder: optionalDouble(params, key: "sort_order"),
          access: optionalString(params, key: "access"),
          parentEntityUid: optionalString(params, key: "parent_entity_uid")
        )
        return toJSON(space)

      // Boards CRUD
      case "kaiten_create_board":
        let spaceId = try requireInt(params, key: "space_id")
        let title = try requireString(params, key: "title")
        let board = try await kaiten.createBoard(
          spaceId: spaceId,
          title: title,
          description: normalizeOptionalEscapedNewlines(optionalString(params, key: "description")),
          sortOrder: optionalDouble(params, key: "sort_order"),
          externalId: optionalString(params, key: "external_id")
        )
        return toJSON(board)

      case "kaiten_update_board":
        let spaceId = try requireInt(params, key: "space_id")
        let id = try requireInt(params, key: "id")
        let board = try await kaiten.updateBoard(
          spaceId: spaceId,
          id: id,
          title: optionalString(params, key: "title"),
          description: normalizeOptionalEscapedNewlines(optionalString(params, key: "description")),
          sortOrder: optionalDouble(params, key: "sort_order"),
          externalId: optionalString(params, key: "external_id")
        )
        return toJSON(board)

      // Columns CRUD
      case "kaiten_create_column":
        let boardId = try requireInt(params, key: "board_id")
        let title = try requireString(params, key: "title")
        let column = try await kaiten.createColumn(
          boardId: boardId,
          title: title,
          sortOrder: optionalDouble(params, key: "sort_order"),
          type: optionalInt(params, key: "type").flatMap { ColumnType(rawValue: $0) },
          wipLimit: optionalInt(params, key: "wip_limit"),
          wipLimitType: optionalInt(params, key: "wip_limit_type").flatMap {
            WipLimitType(rawValue: $0)
          },
          colCount: optionalInt(params, key: "col_count")
        )
        return toJSON(column)

      case "kaiten_update_column":
        let boardId = try requireInt(params, key: "board_id")
        let id = try requireInt(params, key: "id")
        let column = try await kaiten.updateColumn(
          boardId: boardId,
          id: id,
          title: optionalString(params, key: "title"),
          sortOrder: optionalDouble(params, key: "sort_order"),
          type: optionalInt(params, key: "type").flatMap { ColumnType(rawValue: $0) },
          wipLimit: optionalInt(params, key: "wip_limit"),
          wipLimitType: optionalInt(params, key: "wip_limit_type").flatMap {
            WipLimitType(rawValue: $0)
          },
          colCount: optionalInt(params, key: "col_count")
        )
        return toJSON(column)

      case "kaiten_delete_column":
        let boardId = try requireInt(params, key: "board_id")
        let id = try requireInt(params, key: "id")
        let deletedId = try await kaiten.deleteColumn(boardId: boardId, id: id)
        return toJSON(["id": deletedId])

      // Subcolumns
      case "kaiten_list_subcolumns":
        let columnId = try requireInt(params, key: "column_id")
        let subcolumns = try await kaiten.listSubcolumns(columnId: columnId)
        return toJSON(subcolumns)

      case "kaiten_create_subcolumn":
        let columnId = try requireInt(params, key: "column_id")
        let title = try requireString(params, key: "title")
        let subcolumn = try await kaiten.createSubcolumn(
          columnId: columnId,
          title: title,
          sortOrder: optionalDouble(params, key: "sort_order"),
          type: optionalInt(params, key: "type").flatMap { ColumnType(rawValue: $0) }
        )
        return toJSON(subcolumn)

      case "kaiten_update_subcolumn":
        let columnId = try requireInt(params, key: "column_id")
        let id = try requireInt(params, key: "id")
        let subcolumn = try await kaiten.updateSubcolumn(
          columnId: columnId,
          id: id,
          title: optionalString(params, key: "title"),
          sortOrder: optionalDouble(params, key: "sort_order"),
          type: optionalInt(params, key: "type").flatMap { ColumnType(rawValue: $0) }
        )
        return toJSON(subcolumn)

      case "kaiten_delete_subcolumn":
        let columnId = try requireInt(params, key: "column_id")
        let id = try requireInt(params, key: "id")
        let deletedId = try await kaiten.deleteSubcolumn(columnId: columnId, id: id)
        return toJSON(["id": deletedId])

      // Lanes CRUD
      case "kaiten_create_lane":
        let boardId = try requireInt(params, key: "board_id")
        let title = try requireString(params, key: "title")
        let lane = try await kaiten.createLane(
          boardId: boardId,
          title: title,
          sortOrder: optionalDouble(params, key: "sort_order"),
          wipLimit: optionalInt(params, key: "wip_limit"),
          wipLimitType: optionalInt(params, key: "wip_limit_type").flatMap {
            WipLimitType(rawValue: $0)
          },
          rowCount: optionalInt(params, key: "row_count")
        )
        return toJSON(lane)

      case "kaiten_update_lane":
        let boardId = try requireInt(params, key: "board_id")
        let id = try requireInt(params, key: "id")
        let lane = try await kaiten.updateLane(
          boardId: boardId,
          id: id,
          title: optionalString(params, key: "title"),
          sortOrder: optionalDouble(params, key: "sort_order"),
          wipLimit: optionalInt(params, key: "wip_limit"),
          wipLimitType: optionalInt(params, key: "wip_limit_type").flatMap {
            WipLimitType(rawValue: $0)
          },
          rowCount: optionalInt(params, key: "row_count"),
          condition: optionalInt(params, key: "condition").flatMap { LaneCondition(rawValue: $0) }
        )
        return toJSON(lane)

      // Card Baselines
      case "kaiten_get_card_baselines":
        let cardId = try requireInt(params, key: "card_id")
        let baselines = try await kaiten.getCardBaselines(cardId: cardId)
        return toJSON(baselines)

      // External Links
      case "kaiten_list_external_links":
        let cardId = try requireInt(params, key: "card_id")
        let links = try await kaiten.listExternalLinks(cardId: cardId)
        return toJSON(links)

      case "kaiten_add_external_link":
        let cardId = try requireInt(params, key: "card_id")
        let url = try requireString(params, key: "url")
        let title = optionalString(params, key: "title")
        let link = try await kaiten.createExternalLink(cardId: cardId, url: url, description: title)
        return toJSON(link)

      case "kaiten_remove_external_link":
        let cardId = try requireInt(params, key: "card_id")
        let linkId = try requireInt(params, key: "link_id")
        let deletedId = try await kaiten.removeExternalLink(cardId: cardId, linkId: linkId)
        return toJSON(["id": deletedId])

      // Checklists
      case "kaiten_create_checklist":
        let cardId = try requireInt(params, key: "card_id")
        let name = try requireString(params, key: "name")
        let sortOrder = optionalDouble(params, key: "sort_order")
        let checklist = try await kaiten.createChecklist(
          cardId: cardId, name: name, sortOrder: sortOrder)
        return toJSON(checklist)

      case "kaiten_get_checklist":
        let cardId = try requireInt(params, key: "card_id")
        let checklistId = try requireInt(params, key: "checklist_id")
        let checklist = try await kaiten.getChecklist(cardId: cardId, checklistId: checklistId)
        return toJSON(checklist)

      case "kaiten_update_checklist":
        let cardId = try requireInt(params, key: "card_id")
        let checklistId = try requireInt(params, key: "checklist_id")
        let name = optionalString(params, key: "name")
        let sortOrder = optionalDouble(params, key: "sort_order")
        let moveToCardId = optionalInt(params, key: "move_to_card_id")
        let checklist = try await kaiten.updateChecklist(
          cardId: cardId, checklistId: checklistId, name: name, sortOrder: sortOrder,
          moveToCardId: moveToCardId)
        return toJSON(checklist)

      case "kaiten_remove_checklist":
        let cardId = try requireInt(params, key: "card_id")
        let checklistId = try requireInt(params, key: "checklist_id")
        let deletedId = try await kaiten.removeChecklist(cardId: cardId, checklistId: checklistId)
        return toJSON(["id": deletedId])

      case "kaiten_create_checklist_item":
        let cardId = try requireInt(params, key: "card_id")
        let checklistId = try requireInt(params, key: "checklist_id")
        let text = normalizeEscapedNewlines(try requireString(params, key: "text"))
        let sortOrder = optionalDouble(params, key: "sort_order")
        let checked = optionalBool(params, key: "checked")
        let dueDate = optionalString(params, key: "due_date")
        let responsibleId = optionalInt(params, key: "responsible_id")
        let item = try await kaiten.createChecklistItem(
          cardId: cardId, checklistId: checklistId, text: text, sortOrder: sortOrder,
          checked: checked, dueDate: dueDate, responsibleId: responsibleId)
        return toJSON(item)

      case "kaiten_update_checklist_item":
        let cardId = try requireInt(params, key: "card_id")
        let checklistId = try requireInt(params, key: "checklist_id")
        let itemId = try requireInt(params, key: "item_id")
        let text = normalizeOptionalEscapedNewlines(optionalString(params, key: "text"))
        let sortOrder = optionalDouble(params, key: "sort_order")
        let moveToChecklistId = optionalInt(params, key: "move_to_checklist_id")
        let checked = optionalBool(params, key: "checked")
        let dueDate = optionalString(params, key: "due_date")
        let responsibleId = optionalInt(params, key: "responsible_id")
        let item = try await kaiten.updateChecklistItem(
          cardId: cardId, checklistId: checklistId, itemId: itemId, text: text,
          sortOrder: sortOrder, moveToChecklistId: moveToChecklistId, checked: checked,
          dueDate: dueDate, responsibleId: responsibleId)
        return toJSON(item)

      case "kaiten_remove_checklist_item":
        let cardId = try requireInt(params, key: "card_id")
        let checklistId = try requireInt(params, key: "checklist_id")
        let itemId = try requireInt(params, key: "item_id")
        let deletedId = try await kaiten.removeChecklistItem(
          cardId: cardId, checklistId: checklistId, itemId: itemId)
        return toJSON(["id": deletedId])

      // Delete Card
      case "kaiten_delete_card":
        let cardId = try requireInt(params, key: "card_id")
        let card = try await kaiten.deleteCard(id: cardId)
        return toJSON(card)

      // Card Members
      case "kaiten_add_card_member":
        let cardId = try requireInt(params, key: "card_id")
        let userId = try requireInt(params, key: "user_id")
        let member = try await kaiten.addCardMember(cardId: cardId, userId: userId)
        return toJSON(member)

      case "kaiten_update_card_member_role":
        let cardId = try requireInt(params, key: "card_id")
        let userId = try requireInt(params, key: "user_id")
        let typeValue = try requireInt(params, key: "type")
        let roleType = CardMemberRoleType(rawValue: typeValue)
        guard CardMemberRoleType.allCases.contains(roleType) else {
          throw ToolError.invalidType(key: "type", expected: "1 (member) or 2 (responsible)")
        }
        let role = try await kaiten.updateCardMemberRole(
          cardId: cardId, userId: userId, type: roleType)
        return toJSON(role)

      case "kaiten_remove_card_member":
        let cardId = try requireInt(params, key: "card_id")
        let userId = try requireInt(params, key: "user_id")
        let deletedId = try await kaiten.removeCardMember(cardId: cardId, userId: userId)
        return toJSON(["id": deletedId])

      // Comments
      case "kaiten_update_comment":
        let cardId = try requireInt(params, key: "card_id")
        let commentId = try requireInt(params, key: "comment_id")
        let text = normalizeEscapedNewlines(try requireString(params, key: "text"))
        let comment = try await kaiten.updateComment(
          cardId: cardId, commentId: commentId, text: text)
        return toJSON(comment)

      case "kaiten_delete_comment":
        let cardId = try requireInt(params, key: "card_id")
        let commentId = try requireInt(params, key: "comment_id")
        let deletedId = try await kaiten.deleteComment(cardId: cardId, commentId: commentId)
        return toJSON(["id": deletedId])

      // Card Tags
      case "kaiten_list_card_tags":
        let cardId = try requireInt(params, key: "card_id")
        let tags = try await kaiten.listCardTags(cardId: cardId)
        return toJSON(tags)

      case "kaiten_add_card_tag":
        let cardId = try requireInt(params, key: "card_id")
        let name = try requireString(params, key: "name")
        let tag = try await kaiten.addCardTag(cardId: cardId, name: name)
        return toJSON(tag)

      case "kaiten_remove_card_tag":
        let cardId = try requireInt(params, key: "card_id")
        let tagId = try requireInt(params, key: "tag_id")
        let deletedId = try await kaiten.removeCardTag(cardId: cardId, tagId: tagId)
        return toJSON(["id": deletedId])

      // Card Children
      case "kaiten_list_card_children":
        let cardId = try requireInt(params, key: "card_id")
        let children = try await kaiten.listCardChildren(cardId: cardId)
        return toJSON(children)

      case "kaiten_add_card_child":
        let cardId = try requireInt(params, key: "card_id")
        let childCardId = try requireInt(params, key: "child_card_id")
        let child = try await kaiten.addCardChild(cardId: cardId, childCardId: childCardId)
        return toJSON(child)

      case "kaiten_remove_card_child":
        let cardId = try requireInt(params, key: "card_id")
        let childId = try requireInt(params, key: "child_id")
        let deletedId = try await kaiten.removeCardChild(cardId: cardId, childCardId: childId)
        return toJSON(["id": deletedId])

      // Users
      case "kaiten_list_users":
        let type = optionalString(params, key: "type")
        let query = optionalString(params, key: "query")
        let ids = optionalString(params, key: "ids")
        let limit = optionalInt(params, key: "limit")
        let offset = optionalInt(params, key: "offset")
        let includeInactive = optionalBool(params, key: "include_inactive")
        let users = try await kaiten.listUsers(
          type: type, query: query, ids: ids, limit: limit, offset: offset,
          includeInactive: includeInactive)
        return toJSON(users)

      case "kaiten_get_current_user":
        let user = try await kaiten.getCurrentUser()
        return toJSON(user)

      // Card Blockers
      case "kaiten_list_card_blockers":
        let cardId = try requireInt(params, key: "card_id")
        let blockers = try await kaiten.listCardBlockers(cardId: cardId)
        return toJSON(blockers)

      case "kaiten_create_card_blocker":
        let cardId = try requireInt(params, key: "card_id")
        let reason = optionalString(params, key: "reason")
        let blockerCardId = optionalInt(params, key: "blocker_card_id")
        let blocker = try await kaiten.createCardBlocker(
          cardId: cardId, reason: reason, blockerCardId: blockerCardId)
        return toJSON(blocker)

      case "kaiten_update_card_blocker":
        let cardId = try requireInt(params, key: "card_id")
        let blockerId = try requireInt(params, key: "blocker_id")
        let reason = optionalString(params, key: "reason")
        let blockerCardId = optionalInt(params, key: "blocker_card_id")
        let blocker = try await kaiten.updateCardBlocker(
          cardId: cardId, blockerId: blockerId, reason: reason, blockerCardId: blockerCardId)
        return toJSON(blocker)

      case "kaiten_delete_card_blocker":
        let cardId = try requireInt(params, key: "card_id")
        let blockerId = try requireInt(params, key: "blocker_id")
        let blocker = try await kaiten.deleteCardBlocker(cardId: cardId, blockerId: blockerId)
        return toJSON(blocker)

      // Card Types
      case "kaiten_list_card_types":
        let limit = optionalInt(params, key: "limit")
        let offset = optionalInt(params, key: "offset")
        let types = try await kaiten.listCardTypes(limit: limit, offset: offset)
        return toJSON(types)

      // Sprints
      case "kaiten_list_sprints":
        let active = optionalBool(params, key: "active")
        let limit = optionalInt(params, key: "limit")
        let offset = optionalInt(params, key: "offset")
        let sprints = try await kaiten.listSprints(active: active, limit: limit, offset: offset)
        return toJSON(sprints)

      // Card Location History
      case "kaiten_get_card_location_history":
        let cardId = try requireInt(params, key: "card_id")
        let history = try await kaiten.getCardLocationHistory(cardId: cardId)
        return toJSON(history)

      // Update External Link
      case "kaiten_update_external_link":
        let cardId = try requireInt(params, key: "card_id")
        let linkId = try requireInt(params, key: "link_id")
        let url = optionalString(params, key: "url")
        let title = optionalString(params, key: "title")
        let link = try await kaiten.updateExternalLink(
          cardId: cardId, linkId: linkId, url: url, description: title)
        return toJSON(link)

      default:
        throw ToolError.unknownTool(params.name)
      }
    }()
    log("Tool call succeeded: \(params.name) in \(elapsedMilliseconds(since: startedAt))ms")
    return .init(content: [.text(json)], isError: false)
  } catch let error as ToolError {
    log(
      "Tool call failed: \(params.name) in \(elapsedMilliseconds(since: startedAt))ms, error=\(error.description)"
    )
    return .init(content: [.text(error.description)], isError: true)
  } catch {
    log(
      "Tool call failed: \(params.name) in \(elapsedMilliseconds(since: startedAt))ms, unexpected=\(error)"
    )
    return .init(content: [.text("Error: \(error)")], isError: true)
  }
}
