protocol IMDatabaseColumn: CaseIterable, Hashable, RawRepresentable where RawValue == String {}

extension IMDatabaseColumn {
    var sqlName: String { rawValue }
}

protocol IMDatabaseTable {
    associatedtype Column: IMDatabaseColumn
    static var databaseTableName: String { get }
}

extension IMDatabaseTable {
    static var sqlName: String {
        databaseTableName
    }
}

struct TableSchema<Table: IMDatabaseTable> {
    let columns: [String]

    private let columnNames: Set<String>

    init(columns: [String]) {
        self.columns = columns
        columnNames = Set(columns)
    }

    func has(_ column: Table.Column) -> Bool {
        columnNames.contains(column.sqlName)
    }
}

struct IMDatabaseSchema {
    let sqliteSequence: TableSchema<SQLiteSequenceTable>
    let message: TableSchema<MessageTable>
    let chat: TableSchema<ChatTable>
    let handle: TableSchema<HandleTable>
    let attachment: TableSchema<AttachmentTable>
    let chatMessageJoin: TableSchema<ChatMessageJoinTable>
    let chatHandleJoin: TableSchema<ChatHandleJoinTable>
    let messageAttachmentJoin: TableSchema<MessageAttachmentJoinTable>

    init(columnsFor: (String) throws -> [String]) throws {
        sqliteSequence = try TableSchema(columns: columnsFor(SQLiteSequenceTable.sqlName))
        message = try TableSchema(columns: columnsFor(MessageTable.sqlName))
        chat = try TableSchema(columns: columnsFor(ChatTable.sqlName))
        handle = try TableSchema(columns: columnsFor(HandleTable.sqlName))
        attachment = try TableSchema(columns: columnsFor(AttachmentTable.sqlName))
        chatMessageJoin = try TableSchema(columns: columnsFor(ChatMessageJoinTable.sqlName))
        chatHandleJoin = try TableSchema(columns: columnsFor(ChatHandleJoinTable.sqlName))
        messageAttachmentJoin = try TableSchema(columns: columnsFor(MessageAttachmentJoinTable.sqlName))
    }
}

extension IMDatabase {
    func schema() throws -> IMDatabaseSchema {
        if let schemaCache {
            return schemaCache
        }

        let loaded = try IMDatabaseSchema { tableName in
            try tableColumns(tableName)
        }
        schemaCache = loaded
        return loaded
    }
}
