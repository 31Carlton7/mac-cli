import Foundation
import SQLite3
import XCTest
@testable import MailModule

/// A scratch SQLite database with the Envelope Index's own tables and indexes,
/// copied from Mail's schema (triggers left out), for running compiled queries.
final class MailQueryFixture {
    let db: OpaquePointer

    static let schema = """
    CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT COLLATE BINARY NOT NULL,
    total_count INTEGER NOT NULL DEFAULT 0,
    unread_count INTEGER NOT NULL DEFAULT 0,
    deleted_count INTEGER NOT NULL DEFAULT 0,
    unseen_count INTEGER NOT NULL DEFAULT 0,
    unread_count_adjusted_for_duplicates INTEGER NOT NULL DEFAULT 0,
    change_identifier TEXT COLLATE BINARY,
    source INTEGER,
    alleged_change_identifier TEXT COLLATE BINARY,
    UNIQUE(url) ON CONFLICT ABORT);
    CREATE INDEX mailboxes_source_index ON mailboxes(source);
    CREATE TABLE messages (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id INTEGER NOT NULL DEFAULT 0,
    global_message_id INTEGER NOT NULL,
    remote_id INTEGER,
    document_id TEXT COLLATE BINARY,
    sender INTEGER,
    subject_prefix TEXT COLLATE BINARY,
    subject INTEGER NOT NULL,
    summary INTEGER,
    date_sent INTEGER,
    date_received INTEGER,
    mailbox INTEGER NOT NULL,
    remote_mailbox INTEGER,
    flags INTEGER NOT NULL DEFAULT 0,
    read INTEGER NOT NULL DEFAULT 0,
    flagged INTEGER NOT NULL DEFAULT 0,
    deleted INTEGER NOT NULL DEFAULT 0,
    size INTEGER NOT NULL DEFAULT 0,
    conversation_id INTEGER NOT NULL DEFAULT 0,
    date_last_viewed INTEGER,
    list_id_hash INTEGER,
    unsubscribe_type INTEGER,
    searchable_message INTEGER,
    brand_indicator INTEGER,
    display_date INTEGER,
    flag_color INTEGER,
    color TEXT COLLATE BINARY,
    type INTEGER,
    fuzzy_ancestor INTEGER,
    automated_conversation INTEGER DEFAULT 0,
    root_status INTEGER DEFAULT -1, is_urgent INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX messages_message_id_mailbox_index ON messages(message_id, mailbox);
    CREATE INDEX messages_global_message_id_mailbox_index ON messages(global_message_id, mailbox);
    CREATE INDEX messages_document_id_index ON messages(document_id);
    CREATE INDEX messages_sender_index ON messages(sender);
    CREATE INDEX messages_subject_index ON messages(subject);
    CREATE INDEX messages_summary_index ON messages(summary);
    CREATE INDEX messages_date_received_index ON messages(date_received);
    CREATE INDEX messages_mailbox_date_received_index ON messages(mailbox, date_received);
    CREATE INDEX messages_mailbox_display_date_index ON messages(mailbox, display_date);
    CREATE INDEX messages_mailbox_conversation_id_date_received_deleted_index ON messages(mailbox, conversation_id, date_received, deleted);
    CREATE INDEX messages_remote_mailbox_remote_id_index ON messages(remote_mailbox, remote_id);
    CREATE INDEX messages_flagged_index ON messages(flagged);
    CREATE INDEX messages_deleted_date_received_index ON messages(deleted, date_received);
    CREATE INDEX messages_conversation_id_mailbox_read_date_received_deleted_index ON messages(conversation_id, mailbox, read, date_received, deleted);
    CREATE INDEX messages_date_last_viewed_index ON messages(date_last_viewed);
    CREATE INDEX messages_list_id_hash_index ON messages(list_id_hash);
    CREATE INDEX messages_brand_indicator_index ON messages(brand_indicator);
    CREATE INDEX messages_conversation_id_mailbox_flagged_deleted_index ON messages(conversation_id, mailbox, flagged, deleted);
    CREATE INDEX messages_conversation_id_mailbox_deleted_index ON messages(conversation_id, mailbox, deleted);
    CREATE INDEX messages_conversation_id_mailbox_sender_date_received_deleted_index ON messages(conversation_id, mailbox, sender, date_received, deleted);
    CREATE INDEX messages_conversation_id_mailbox_flags_deleted_index ON messages(conversation_id, mailbox, flags, deleted);
    CREATE INDEX messages_type_index ON messages(type);
    CREATE INDEX messages_conversation_id_index ON messages(conversation_id);
    CREATE INDEX messages_fuzzy_ancestor_index ON messages(fuzzy_ancestor);
    CREATE INDEX messages_subject_fuzzy_ancestor_index ON messages(subject, fuzzy_ancestor);
    CREATE INDEX messages_sender_subject_automated_conversation_index ON messages(sender, subject, automated_conversation);
    CREATE INDEX messages_root_status_index ON messages(root_status);
    CREATE INDEX messages_deleted_mailbox_index ON messages(deleted, mailbox);
    CREATE INDEX messages_deleted_index ON messages(deleted);
    CREATE INDEX messages_flag_color_index ON messages(flag_color);
    CREATE INDEX messages_read_deleted_global_message_id_mailbox_read0_deleted0_index ON messages(read, deleted, global_message_id, mailbox) WHERE (read = 0 AND deleted = 0);
    CREATE INDEX messages_mailbox_is_urgent_display_date_index ON messages(mailbox, is_urgent, display_date);
    CREATE INDEX messages_is_urgent_deleted_conversation_id_is_urgent_1_deleted_0_index ON messages(is_urgent, deleted, conversation_id) WHERE (is_urgent = 1 AND deleted = 0);
    CREATE INDEX messages_searchable_message_deleted_date_received_index ON messages(searchable_message, deleted, date_received);
    CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    address TEXT COLLATE NOCASE NOT NULL,
    comment TEXT COLLATE BINARY NOT NULL,
    UNIQUE(address, comment) ON CONFLICT ABORT);
    CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    message INTEGER NOT NULL REFERENCES messages(ROWID) ON DELETE CASCADE,
    attachment_id TEXT COLLATE BINARY,
    name TEXT COLLATE BINARY,
    UNIQUE(message, attachment_id) ON CONFLICT ABORT);
    CREATE INDEX attachments_message_name_index ON attachments(message, name);
    CREATE INDEX attachments_message_attachment_id_index ON attachments(message, attachment_id);
    CREATE TABLE labels (message_id INTEGER REFERENCES messages(ROWID) ON DELETE CASCADE, mailbox_id INTEGER REFERENCES mailboxes(ROWID) ON DELETE CASCADE, PRIMARY KEY(message_id, mailbox_id)) WITHOUT ROWID;
    CREATE INDEX labels_mailbox_id_index on labels(mailbox_id);
    CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id INTEGER,
    follow_up_start_date INTEGER,
    follow_up_end_date INTEGER,
    follow_up_jsonstringformodelevaluationforsuggestions TEXT COLLATE BINARY,
    read_later_date INTEGER,
    send_later_date INTEGER,
    validation_state INTEGER NOT NULL DEFAULT 0,
    model_category INTEGER,
    model_subcategory INTEGER,
    category_model_version INTEGER,
    model_analytics TEXT COLLATE BINARY,
    model_high_impact INTEGER NOT NULL DEFAULT 0,
    generated_summary INTEGER,
    urgent INTEGER, category_is_temporary INTEGER, message_id_header TEXT COLLATE BINARY, due_by INTEGER,
    UNIQUE(message_id) ON CONFLICT ABORT);
    CREATE INDEX message_global_data_follow_up_start_date_index ON message_global_data(follow_up_start_date);
    CREATE INDEX message_global_data_follow_up_end_date_index ON message_global_data(follow_up_end_date);
    CREATE INDEX message_global_data_follow_up_jsonstringformodelevaluationforsuggestions_index ON message_global_data(follow_up_jsonstringformodelevaluationforsuggestions);
    CREATE INDEX message_global_data_read_later_date_index ON message_global_data(read_later_date);
    CREATE INDEX message_global_data_send_later_date_index ON message_global_data(send_later_date);
    CREATE INDEX message_global_data_category_model_version_model_category_index ON message_global_data(category_model_version, model_category);
    CREATE INDEX message_global_data_validation_state_equals_zero_index ON message_global_data(validation_state) WHERE validation_state = 0;
    CREATE INDEX message_global_data_model_category_index ON message_global_data(model_category);
    CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY,
    message INTEGER NOT NULL,
    address INTEGER NOT NULL,
    type INTEGER,
    position INTEGER,
    UNIQUE(message, type, position) ON CONFLICT ABORT);
    CREATE INDEX recipients_message_position_type_address_index ON recipients(message, position, type, address);
    CREATE INDEX recipients_address_index ON recipients(address);
    CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    subject TEXT COLLATE RTRIM NOT NULL,
    UNIQUE(subject) ON CONFLICT ABORT);
    CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    summary TEXT COLLATE RTRIM NOT NULL,
    UNIQUE(summary) ON CONFLICT ABORT);
    """

    init() throws {
        var handle: OpaquePointer?
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "MailQueryFixture", code: 1)
        }
        db = handle
        try exec(Self.schema)
    }

    deinit {
        sqlite3_close(db)
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw NSError(domain: "MailQueryFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(message): \(sql)"])
        }
    }

    /// ROWIDs of live messages matching the fragment, the way a reader would use it.
    func matches(_ fragment: MailQuerySQL) throws -> [Int64] {
        let sql = "SELECT m.ROWID FROM messages m WHERE m.deleted = 0 AND (\(fragment.sql)) ORDER BY m.ROWID"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "MailQueryFixture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db)) + ": " + sql])
        }
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(fragment.bind(stmt), Int32(fragment.bindings.count + 1))
        XCTAssertEqual(Int(sqlite3_bind_parameter_count(stmt)), fragment.bindings.count, "placeholders and bindings disagree")
        var ids: [Int64] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
            rc = sqlite3_step(stmt)
        }
        XCTAssertEqual(rc, SQLITE_DONE, String(cString: sqlite3_errmsg(db)))
        return ids
    }
}
