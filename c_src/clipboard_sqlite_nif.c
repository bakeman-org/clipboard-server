/*
 * 剪贴板 SQLite NIF —— 只实现项目所需的 8 个核心函数。
 *
 * 设计原则：
 *   1. 用 ErlNifResourceType 管理 sqlite3* 生命周期，Erlang GC 时自动关闭。
 *   2. 所有 NIF 声明为 ERL_NIF_DIRTY_JOB_IO_BOUND，避免阻塞普通调度器。
 *   3. 只用预编译语句 + 参数绑定，无 SQL 注入风险。
 *   4. 结果一律用二进制返回，Erlang 侧再决定编码转换。
 */

#include <erl_nif.h>
#include <sqlite3.h>
#include <string.h>
#include <stdlib.h>

/* ------------------------------------------------------------------ */
/* 资源对象                                                            */
/* ------------------------------------------------------------------ */

static ErlNifResourceType *db_resource_type = NULL;

typedef struct {
    sqlite3 *db;
} db_resource_t;

static void
db_resource_dtor(ErlNifEnv *env, void *obj)
{
    (void)env;
    db_resource_t *res = (db_resource_t *)obj;
    if (res->db) {
        sqlite3_close(res->db);
        res->db = NULL;
    }
}

/* ------------------------------------------------------------------ */
/* 辅助函数                                                            */
/* ------------------------------------------------------------------ */

static ERL_NIF_TERM
make_ok(ErlNifEnv *env)
{
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM
make_error(ErlNifEnv *env, const char *msg)
{
    return enif_make_tuple2(
        env,
        enif_make_atom(env, "error"),
        enif_make_string(env, msg ? msg : "unknown error", ERL_NIF_UTF8));
}

static ERL_NIF_TERM
make_db_error(ErlNifEnv *env, sqlite3 *db)
{
    return make_error(env, db ? sqlite3_errmsg(db) : "database handle is NULL");
}

/* 从已执行的 stmt 读取所有行，构造 [{Id, Content, CreatedAt}, ...]。
 * 使用前插法，因此调用方的 SQL 应 ORDER BY created_at ASC，
 * 得到的结果列表即为时间倒序（最新在前）。 */
static ERL_NIF_TERM
rows_to_list(ErlNifEnv *env, sqlite3_stmt *stmt)
{
    ERL_NIF_TERM result = enif_make_list(env, 0);
    int rc;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        int id               = sqlite3_column_int(stmt, 0);
        const unsigned char *text = sqlite3_column_text(stmt, 1);
        int text_len         = sqlite3_column_bytes(stmt, 1);
        sqlite3_int64 created_at = sqlite3_column_int64(stmt, 2);

        if (text == NULL) { text_len = 0; }

        ErlNifBinary content_bin;
        if (!enif_alloc_binary((size_t)text_len, &content_bin)) {
            return make_error(env, "enif_alloc_binary failed");
        }
        if (text_len > 0) {
            memcpy(content_bin.data, text, (size_t)text_len);
        }

        ERL_NIF_TERM row = enif_make_tuple3(
            env,
            enif_make_int(env, id),
            enif_make_binary(env, &content_bin),
            enif_make_int64(env, created_at));

        result = enif_make_list_cell(env, row, result);
    }
    return result;
}

/* ------------------------------------------------------------------ */
/* NIF 实现                                                            */
/* ------------------------------------------------------------------ */

/* open(PathBin) -> {ok, DbRef} | {error, Msg} */
static ERL_NIF_TERM
nif_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ErlNifBinary path_bin;
    if (!enif_inspect_binary(env, argv[0], &path_bin)) {
        return enif_make_badarg(env);
    }

    char *path = enif_alloc(path_bin.size + 1);
    if (!path) return make_error(env, "out of memory");
    memcpy(path, path_bin.data, path_bin.size);
    path[path_bin.size] = '\0';

    db_resource_t *res = enif_alloc_resource(db_resource_type, sizeof(db_resource_t));
    if (!res) {
        enif_free(path);
        return make_error(env, "enif_alloc_resource failed");
    }
    res->db = NULL;

    int rc = sqlite3_open(path, &res->db);
    enif_free(path);

    if (rc != SQLITE_OK) {
        const char *errmsg = res->db ? sqlite3_errmsg(res->db) : "cannot open database";
        ERL_NIF_TERM err = make_error(env, errmsg);
        enif_release_resource(res);  /* dtor 会关闭已打开的句柄 */
        return err;
    }

    /* 设置 busy 超时，避免瞬时锁竞争直接报错 */
    sqlite3_busy_timeout(res->db, 5000);

    ERL_NIF_TERM term = enif_make_resource(env, res);
    enif_release_resource(res);  /* 引用计数交给 Erlang 侧 */
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), term);
}

/* close(DbRef) -> ok */
static ERL_NIF_TERM
nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    db_resource_t *res;
    if (!enif_get_resource(env, argv[0], db_resource_type, (void **)&res)) {
        return enif_make_badarg(env);
    }
    if (res->db) {
        sqlite3_close(res->db);
        res->db = NULL;
    }
    return make_ok(env);
}

/* exec(DbRef, SqlBin) -> ok | {error, Msg}
 * 用于 DDL、PRAGMA 等无参数语句。 */
static ERL_NIF_TERM
nif_exec(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    db_resource_t *res;
    if (!enif_get_resource(env, argv[0], db_resource_type, (void **)&res)) {
        return enif_make_badarg(env);
    }
    ErlNifBinary sql_bin;
    if (!enif_inspect_binary(env, argv[1], &sql_bin)) {
        return enif_make_badarg(env);
    }
    if (!res->db) return make_error(env, "database is closed");

    char *sql = enif_alloc(sql_bin.size + 1);
    if (!sql) return make_error(env, "out of memory");
    memcpy(sql, sql_bin.data, sql_bin.size);
    sql[sql_bin.size] = '\0';

    char *errmsg = NULL;
    int rc = sqlite3_exec(res->db, sql, NULL, NULL, &errmsg);
    enif_free(sql);

    if (rc != SQLITE_OK) {
        ERL_NIF_TERM err = make_error(env, errmsg ? errmsg : "exec failed");
        if (errmsg) sqlite3_free(errmsg);
        return err;
    }
    return make_ok(env);
}

/* insert(DbRef, ContentBin, Timestamp) -> ok | {error, Msg} */
static ERL_NIF_TERM
nif_insert(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    db_resource_t *res;
    if (!enif_get_resource(env, argv[0], db_resource_type, (void **)&res)) {
        return enif_make_badarg(env);
    }
    ErlNifBinary content_bin;
    if (!enif_inspect_binary(env, argv[1], &content_bin)) {
        return enif_make_badarg(env);
    }
    ErlNifSInt64 ts;
    if (!enif_get_int64(env, argv[2], &ts)) {
        return enif_make_badarg(env);
    }
    if (!res->db) return make_error(env, "database is closed");

    sqlite3_stmt *stmt = NULL;
    const char *sql = "INSERT INTO clipboard_history (content, created_at) VALUES (?, ?)";
    if (sqlite3_prepare_v2(res->db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        return make_db_error(env, res->db);
    }

    sqlite3_bind_text(stmt, 1, (const char *)content_bin.data,
                      (int)content_bin.size, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, (sqlite3_int64)ts);

    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE) return make_db_error(env, res->db);
    return make_ok(env);
}

/* list_all(DbRef) -> [{Id, ContentBin, Timestamp}, ...] */
static ERL_NIF_TERM
nif_list_all(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    db_resource_t *res;
    if (!enif_get_resource(env, argv[0], db_resource_type, (void **)&res)) {
        return enif_make_badarg(env);
    }
    if (!res->db) return make_error(env, "database is closed");

    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT id, content, created_at FROM clipboard_history "
                      "ORDER BY created_at ASC";
    if (sqlite3_prepare_v2(res->db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        return make_db_error(env, res->db);
    }
    ERL_NIF_TERM result = rows_to_list(env, stmt);
    sqlite3_finalize(stmt);
    return result;
}

/* list_limit(DbRef, N) -> [{Id, ContentBin, Timestamp}, ...]
 * 最近 N 条，最新在前。 */
static ERL_NIF_TERM
nif_list_limit(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    db_resource_t *res;
    if (!enif_get_resource(env, argv[0], db_resource_type, (void **)&res)) {
        return enif_make_badarg(env);
    }
    int limit;
    if (!enif_get_int(env, argv[1], &limit)) {
        return enif_make_badarg(env);
    }
    if (!res->db) return make_error(env, "database is closed");
    if (limit <= 0) return enif_make_list(env, 0);

    sqlite3_stmt *stmt = NULL;
    const char *sql =
        "SELECT id, content, created_at FROM ("
        "  SELECT id, content, created_at FROM clipboard_history "
        "  ORDER BY created_at DESC LIMIT ?"
        ") ORDER BY created_at ASC";
    if (sqlite3_prepare_v2(res->db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        return make_db_error(env, res->db);
    }
    sqlite3_bind_int(stmt, 1, limit);
    ERL_NIF_TERM result = rows_to_list(env, stmt);
    sqlite3_finalize(stmt);
    return result;
}

/* search(DbRef, PatternBin) -> [{Id, ContentBin, Timestamp}, ...]
 * 等价于 SQL LIKE '%Pattern%'，最新在前。 */
static ERL_NIF_TERM
nif_search(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    db_resource_t *res;
    if (!enif_get_resource(env, argv[0], db_resource_type, (void **)&res)) {
        return enif_make_badarg(env);
    }
    ErlNifBinary pattern_bin;
    if (!enif_inspect_binary(env, argv[1], &pattern_bin)) {
        return enif_make_badarg(env);
    }
    if (!res->db) return make_error(env, "database is closed");

    /* 手工拼 %pattern%，不转义 % 和 _，即用户能使用通配符 */
    size_t total = pattern_bin.size + 2;
    char *pattern = enif_alloc(total + 1);
    if (!pattern) return make_error(env, "out of memory");
    pattern[0] = '%';
    if (pattern_bin.size > 0) {
        memcpy(pattern + 1, pattern_bin.data, pattern_bin.size);
    }
    pattern[total - 1] = '%';
    pattern[total] = '\0';

    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT id, content, created_at FROM clipboard_history "
                      "WHERE content LIKE ? ORDER BY created_at ASC";
    if (sqlite3_prepare_v2(res->db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        enif_free(pattern);
        return make_db_error(env, res->db);
    }
    sqlite3_bind_text(stmt, 1, pattern, (int)total, SQLITE_TRANSIENT);
    enif_free(pattern);

    ERL_NIF_TERM result = rows_to_list(env, stmt);
    sqlite3_finalize(stmt);
    return result;
}

/* clear(DbRef) -> ok | {error, Msg} */
static ERL_NIF_TERM
nif_clear(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    db_resource_t *res;
    if (!enif_get_resource(env, argv[0], db_resource_type, (void **)&res)) {
        return enif_make_badarg(env);
    }
    if (!res->db) return make_error(env, "database is closed");

    sqlite3_stmt *stmt = NULL;
    const char *sql = "DELETE FROM clipboard_history";
    if (sqlite3_prepare_v2(res->db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        return make_db_error(env, res->db);
    }
    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) return make_db_error(env, res->db);
    return make_ok(env);
}

/* ------------------------------------------------------------------ */
/* 模块加载                                                            */
/* ------------------------------------------------------------------ */

static int
nif_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data;
    (void)load_info;
    db_resource_type = enif_open_resource_type(
        env,
        NULL,
        "clipboard_db",
        db_resource_dtor,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        NULL);
    return db_resource_type ? 0 : -1;
}

static ErlNifFunc nif_funcs[] = {
    {"open",       1, nif_open,       ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close",      1, nif_close,      ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"exec",       2, nif_exec,       ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"insert",     3, nif_insert,     ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"list_all",   1, nif_list_all,   ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"list_limit", 2, nif_list_limit, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"search",     2, nif_search,     ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"clear",      1, nif_clear,      ERL_NIF_DIRTY_JOB_IO_BOUND}
};

ERL_NIF_INIT(clipboard_sqlite_nif, nif_funcs, nif_load, NULL, NULL, NULL)