%%%-------------------------------------------------------------------
%% @doc REST 路由处理：单一 handler 按 action 分发。
%%
%% 路由表：
%%   GET    /                       → 返回前端 HTML
%%   GET    /api/history?limit=N    → 列出最近 N 条（N=0 或省略则全部）
%%   GET    /api/history/search?q=X → 模糊搜索
%%   GET    /api/clipboard          → 读取当前系统剪贴板
%%   POST   /api/clipboard          → 写入剪贴板，body 为 {"text":"..."}
%%   DELETE /api/clear              → 清空历史
%% @end
%%%-------------------------------------------------------------------
-module(clipboard_http_handler).
-behaviour(cowboy_handler).

-export([init/2]).

%% ===================================================================
%% Cowboy 回调
%% ===================================================================

init(Req0, State) ->
    Action = maps:get(action, State),
    Method = cowboy_req:method(Req0),
    {Code, Headers, Body, Req1} = route(Action, Method, Req0),
    Req2 = cowboy_req:reply(Code, Headers, Body, Req1),
    {ok, Req2, State}.

%% ===================================================================
%% 路由分发
%% ===================================================================

%% 首页：返回静态 HTML 前端
route(index, <<"GET">>, Req) ->
    Path = filename:join(code:priv_dir(clipboard_server), "index.html"),
    case file:read_file(Path) of
        {ok, Html} ->
            {200,
             #{<<"content-type">> => <<"text/html; charset=utf-8">>},
             Html,
             Req};
        {error, Reason} ->
            {500,
             #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
             iolist_to_binary(io_lib:format("index.html 读取失败: ~p", [Reason])),
             Req}
    end;

%% GET /api/history?limit=N
route(history, <<"GET">>, Req) ->
    Limit = parse_limit(Req),
    handle_result(clipboard_server:list_history(Limit), Req);

%% GET /api/history/search?q=X
route(search, <<"GET">>, Req) ->
    Qs = cowboy_req:parse_qs(Req),
    Pattern = case lists:keyfind(<<"q">>, 1, Qs) of
        {_, V} -> binary_to_list(V);
        false  -> ""
    end,
    handle_result(clipboard_server:search_history(Pattern), Req);

%% GET /api/clipboard
route(clipboard, <<"GET">>, Req) ->
    case clipboard_server:get_text() of
        {ok, Text} ->
            json(200, #{ok => true, text => to_bin(Text)}, Req);
        {error, Reason} ->
            json(200, #{ok => false, error => to_bin(Reason)}, Req)
    end;

%% POST /api/clipboard  body: {"text":"..."}
route(clipboard, <<"POST">>, Req0) ->
    case read_json_body(Req0) of
        {ok, #{<<"text">> := Text}, Req1} when is_binary(Text) ->
            case clipboard_server:set_text(binary_to_list(Text)) of
                ok ->
                    json(200, #{ok => true}, Req1);
                {error, Reason} ->
                    json(500, #{ok => false, error => to_bin(Reason)}, Req1)
            end;
        {ok, _Other, Req1} ->
            json(400, #{ok => false, error => <<"缺少 'text' 字段或类型不对">>}, Req1);
        {error, Msg, Req1} ->
            json(400, #{ok => false, error => Msg}, Req1)
    end;

%% DELETE /api/clear
route(clear, <<"DELETE">>, Req) ->
    case clipboard_server:clear_history() of
        ok -> json(200, #{ok => true}, Req);
        {error, Reason} -> json(500, #{ok => false, error => to_bin(Reason)}, Req)
    end;

%% OPTIONS：简单 CORS 预检
route(_, <<"OPTIONS">>, Req) ->
    {204,
     #{<<"access-control-allow-origin">>  => <<"*">>,
       <<"access-control-allow-methods">> => <<"GET, POST, DELETE, OPTIONS">>,
       <<"access-control-allow-headers">> => <<"content-type">>},
     <<>>,
     Req};

%% 其他未匹配
route(_Action, _Method, Req) ->
    json(404, #{ok => false, error => <<"not found">>}, Req).

%% ===================================================================
%% 内部函数
%% ===================================================================

%% 把 {ok, [map()]} / {error, term()} 统一转成 JSON 响应
handle_result({ok, Rows}, Req) ->
    json(200, #{ok => true, data => [row_to_json(R) || R <- Rows]}, Req);
handle_result({error, Reason}, Req) ->
    json(500, #{ok => false, error => to_bin(Reason)}, Req).

%% map 的 key 是 atom，jsx 会原样输出为字符串，无需转换。
%% 唯一要注意的是 created_at 是整数，content 是字符串（可能含中文）。
row_to_json(#{id := Id, content := Content, created_at := Ts}) ->
    #{id => Id, content => to_bin(Content), created_at => Ts}.

json(Code, Map, Req) ->
    Body = jsx:encode(Map),
    {Code,
     #{<<"content-type">> => <<"application/json; charset=utf-8">>,
       <<"access-control-allow-origin">> => <<"*">>},
     Body,
     Req}.

%% 解析 ?limit=N，非法值或缺失视为 0（全部）
parse_limit(Req) ->
    Qs = cowboy_req:parse_qs(Req),
    case lists:keyfind(<<"limit">>, 1, Qs) of
        {_, V} ->
            try binary_to_integer(V) of
                N when N >= 0 -> N;
                _ -> 0
            catch
                _:_ -> 0
            end;
        false -> 0
    end.

%% 安全读取 JSON body
read_json_body(Req0) ->
    try cowboy_req:read_body(Req0, #{length => 1_000_000, period => 5000}) of
        {ok, Body, Req1} ->
            try jsx:decode(Body, [return_maps]) of
                Map -> {ok, Map, Req1}
            catch
                _:_ -> {error, <<"请求体不是合法 JSON">>, Req1}
            end
    catch
        _:_ ->
            {error, <<"读取请求体失败">>, Req0}
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A)   -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I)-> integer_to_binary(I);
to_bin(Other)               -> iolist_to_binary(io_lib:format("~p", [Other])).