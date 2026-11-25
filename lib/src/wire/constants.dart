// Constants of the Firebird remote (wire) protocol and of the parameter
// blocks it carries. Numeric values come from the public Firebird headers
// (ibase.h, iberror.h, protocol.h).

// ignore_for_file: constant_identifier_names

// ---------------------------------------------------------------------------
// Operation codes (protocol.h, enum P_OP).
// ---------------------------------------------------------------------------
const int op_void = 0;
const int op_connect = 1;
const int op_exit = 2;
const int op_accept = 3;
const int op_reject = 4;
const int op_protocol = 5;
const int op_disconnect = 6;
const int op_response = 9;
const int op_attach = 19;
const int op_create = 20;
const int op_detach = 21;
const int op_transaction = 29;
const int op_commit = 30;
const int op_rollback = 31;
const int op_prepare = 32;
const int op_create_blob = 34;
const int op_open_blob = 35;
const int op_get_segment = 36;
const int op_put_segment = 37;
const int op_cancel_blob = 38;
const int op_close_blob = 39;
const int op_info_database = 40;
const int op_info_request = 41;
const int op_info_transaction = 42;
const int op_info_blob = 43;
const int op_batch_segments = 44;
const int op_que_events = 48;
const int op_cancel_events = 49;
const int op_commit_retaining = 50;
const int op_prepare2 = 51;
const int op_event = 52;
const int op_connect_request = 53;
const int op_aux_connect = 54;
const int op_open_blob2 = 56;
const int op_create_blob2 = 57;
const int op_seek_blob = 61;
const int op_allocate_statement = 62;
const int op_execute = 63;
const int op_exec_immediate = 64;
const int op_fetch = 65;
const int op_fetch_response = 66;
const int op_free_statement = 67;
const int op_prepare_statement = 68;
const int op_set_cursor = 69;
const int op_info_sql = 70;
const int op_dummy = 71;
const int op_response_piggyback = 72;
const int op_execute2 = 76;
const int op_sql_response = 78;
const int op_drop_database = 81;
const int op_service_attach = 82;
const int op_service_detach = 83;
const int op_service_info = 84;
const int op_service_start = 85;
const int op_rollback_retaining = 86;
const int op_partial = 89;
const int op_trusted_auth = 90;
const int op_cancel = 91;
const int op_cont_auth = 92;
const int op_ping = 93;
const int op_accept_data = 94;
const int op_abort_aux_connection = 95;
const int op_crypt = 96;
const int op_crypt_key_callback = 97;
const int op_cond_accept = 98;

// ---------------------------------------------------------------------------
// Connection negotiation.
// ---------------------------------------------------------------------------
const int CONNECT_VERSION3 = 3;
const int arch_generic = 1;

const int ptype_rpc = 2;
const int ptype_batch_send = 3;
const int ptype_out_of_band = 4;
const int ptype_lazy_send = 5;
const int ptype_MASK = 0xFF;
const int pflag_compress = 0x100;

const int FB_PROTOCOL_FLAG = 0x8000;
const int FB_PROTOCOL_MASK = ~FB_PROTOCOL_FLAG & 0xFFFF;

const int PROTOCOL_VERSION10 = 10;
const int PROTOCOL_VERSION11 = FB_PROTOCOL_FLAG | 11;
const int PROTOCOL_VERSION12 = FB_PROTOCOL_FLAG | 12;
const int PROTOCOL_VERSION13 = FB_PROTOCOL_FLAG | 13;

// User identification tags sent in op_connect.
const int CNCT_user = 1;
const int CNCT_passwd = 2;
const int CNCT_host = 4;
const int CNCT_group = 5;
const int CNCT_user_verification = 6;
const int CNCT_specific_data = 7;
const int CNCT_plugin_name = 8;
const int CNCT_login = 9;
const int CNCT_plugin_list = 10;
const int CNCT_client_crypt = 11;

// ---------------------------------------------------------------------------
// Database parameter block (DPB).
// ---------------------------------------------------------------------------
const int isc_dpb_version1 = 1;
const int isc_dpb_page_size = 4;
const int isc_dpb_no_garbage_collect = 16;
const int isc_dpb_user_name = 28;
const int isc_dpb_password = 29;
const int isc_dpb_password_enc = 30;
const int isc_dpb_lc_ctype = 48;
const int isc_dpb_connect_timeout = 57;
const int isc_dpb_dummy_packet_interval = 58;
const int isc_dpb_sql_role_name = 60;
const int isc_dpb_sql_dialect = 63;
const int isc_dpb_set_db_charset = 68;
const int isc_dpb_process_id = 71;
const int isc_dpb_process_name = 74;
const int isc_dpb_utf8_filename = 77;
const int isc_dpb_specific_auth_data = 84;
const int isc_dpb_auth_plugin_list = 85;
const int isc_dpb_auth_plugin_name = 86;

// ---------------------------------------------------------------------------
// Transaction parameter block (TPB).
// ---------------------------------------------------------------------------
const int isc_tpb_version3 = 3;
const int isc_tpb_consistency = 1;
const int isc_tpb_shared = 3;
const int isc_tpb_protected = 4;
const int isc_tpb_exclusive = 5;
const int isc_tpb_lock_read = 10;
const int isc_tpb_lock_write = 11;
const int isc_tpb_ignore_limbo = 14;
const int isc_tpb_concurrency = 2;
const int isc_tpb_wait = 6;
const int isc_tpb_nowait = 7;
const int isc_tpb_read = 8;
const int isc_tpb_write = 9;
const int isc_tpb_read_committed = 15;
const int isc_tpb_rec_version = 17;
const int isc_tpb_no_rec_version = 18;
const int isc_tpb_no_auto_undo = 20;
const int isc_tpb_lock_timeout = 21;

// ---------------------------------------------------------------------------
// Blob parameter block (BPB).
// ---------------------------------------------------------------------------
const int isc_bpb_version1 = 1;
const int isc_bpb_source_type = 1;
const int isc_bpb_target_type = 2;
const int isc_bpb_type = 3;
const int isc_bpb_type_segmented = 0;
const int isc_bpb_type_stream = 1;

// ---------------------------------------------------------------------------
// Information items.
// ---------------------------------------------------------------------------
const int isc_info_end = 1;
const int isc_info_truncated = 2;
const int isc_info_error = 3;
const int isc_info_data_not_ready = 4;

const int isc_info_db_id = 4;
const int isc_info_implementation = 11;
const int isc_info_isc_version = 12;
const int isc_info_base_level = 13;
const int isc_info_page_size = 14;
const int isc_info_ods_version = 32;
const int isc_info_ods_minor_version = 33;
const int isc_info_db_sql_dialect = 62;
const int isc_info_firebird_version = 103;

const int isc_info_req_select_count = 13;
const int isc_info_req_insert_count = 14;
const int isc_info_req_update_count = 15;
const int isc_info_req_delete_count = 16;

const int isc_info_sql_select = 4;
const int isc_info_sql_bind = 5;
const int isc_info_sql_num_variables = 6;
const int isc_info_sql_describe_vars = 7;
const int isc_info_sql_describe_end = 8;
const int isc_info_sql_sqlda_seq = 9;
const int isc_info_sql_message_seq = 10;
const int isc_info_sql_type = 11;
const int isc_info_sql_sub_type = 12;
const int isc_info_sql_scale = 13;
const int isc_info_sql_length = 14;
const int isc_info_sql_null_ind = 15;
const int isc_info_sql_field = 16;
const int isc_info_sql_relation = 17;
const int isc_info_sql_owner = 18;
const int isc_info_sql_alias = 19;
const int isc_info_sql_sqlda_start = 20;
const int isc_info_sql_stmt_type = 21;
const int isc_info_sql_get_plan = 22;
const int isc_info_sql_records = 23;
const int isc_info_sql_batch_fetch = 24;

const int isc_info_sql_stmt_select = 1;
const int isc_info_sql_stmt_insert = 2;
const int isc_info_sql_stmt_update = 3;
const int isc_info_sql_stmt_delete = 4;
const int isc_info_sql_stmt_ddl = 5;
const int isc_info_sql_stmt_get_segment = 6;
const int isc_info_sql_stmt_put_segment = 7;
const int isc_info_sql_stmt_exec_procedure = 8;
const int isc_info_sql_stmt_start_trans = 9;
const int isc_info_sql_stmt_commit = 10;
const int isc_info_sql_stmt_rollback = 11;
const int isc_info_sql_stmt_select_for_upd = 12;
const int isc_info_sql_stmt_set_generator = 13;
const int isc_info_sql_stmt_savepoint = 14;

// ---------------------------------------------------------------------------
// Statement release options.
// ---------------------------------------------------------------------------
const int DSQL_close = 1;
const int DSQL_drop = 2;
const int DSQL_unprepare = 4;

// Cancel kinds (fb_cancel_operation).
const int fb_cancel_disable = 1;
const int fb_cancel_enable = 2;
const int fb_cancel_raise = 3;
const int fb_cancel_abort = 4;

// ---------------------------------------------------------------------------
// SQL data types (XSQLVAR.sqltype without the nullable bit).
// ---------------------------------------------------------------------------
const int SQL_TEXT = 452;
const int SQL_VARYING = 448;
const int SQL_SHORT = 500;
const int SQL_LONG = 496;
const int SQL_FLOAT = 482;
const int SQL_DOUBLE = 480;
const int SQL_D_FLOAT = 530;
const int SQL_TIMESTAMP = 510;
const int SQL_BLOB = 520;
const int SQL_ARRAY = 540;
const int SQL_QUAD = 550;
const int SQL_TYPE_TIME = 560;
const int SQL_TYPE_DATE = 570;
const int SQL_INT64 = 580;
const int SQL_TIMESTAMP_TZ_EX = 32748;
const int SQL_TIME_TZ_EX = 32750;
const int SQL_INT128 = 32752;
const int SQL_TIMESTAMP_TZ = 32754;
const int SQL_TIME_TZ = 32756;
const int SQL_DEC16 = 32760;
const int SQL_DEC34 = 32762;
const int SQL_BOOLEAN = 32764;
const int SQL_NULL = 32766;

// ---------------------------------------------------------------------------
// BLR (binary language representation) used to describe messages.
// ---------------------------------------------------------------------------
const int blr_text = 14;
const int blr_text2 = 15;
const int blr_short = 7;
const int blr_long = 8;
const int blr_quad = 9;
const int blr_float = 10;
const int blr_double = 27;
const int blr_d_float = 11;
const int blr_timestamp = 35;
const int blr_varying = 37;
const int blr_varying2 = 38;
const int blr_cstring = 40;
const int blr_sql_date = 12;
const int blr_sql_time = 13;
const int blr_int64 = 16;
const int blr_bool = 23;
const int blr_dec64 = 24;
const int blr_dec128 = 25;
const int blr_int128 = 26;
const int blr_sql_time_tz = 28;
const int blr_timestamp_tz = 29;
const int blr_version5 = 5;
const int blr_begin = 2;
const int blr_message = 4;
const int blr_end = 255;
const int blr_eoc = 76;

// ---------------------------------------------------------------------------
// Status vector argument kinds (iberror.h).
// ---------------------------------------------------------------------------
const int isc_arg_end = 0;
const int isc_arg_gds = 1;
const int isc_arg_string = 2;
const int isc_arg_cstring = 3;
const int isc_arg_number = 4;
const int isc_arg_interpreted = 5;
const int isc_arg_warning = 18;
const int isc_arg_sql_state = 19;

// Selected status codes the driver reacts to.
const int isc_arith_except = 335544321;
const int isc_segment = 335544366;
const int isc_segstr_eof = 335544367;
const int isc_sqlerr = 335544436;
const int isc_login = 335544472;
const int isc_network_error = 335544721;
const int isc_net_read_err = 335544726;
const int isc_net_write_err = 335544727;
const int isc_cancelled = 335544794;
const int isc_dsql_cursor_close_err = 335544577;
const int isc_dsql_cursor_open_err = 335544576;

/// Invalid object handle used by the server for "no object".
const int INVALID_OBJECT = 0xFFFF;
