-module(bh_route_accounts_SUITE).

-compile([nowarn_export_all, export_all]).

-include("bh_route_handler.hrl").

-include("ct_utils.hrl").

all() ->
    [
        get_test,
        not_found_test,
        activity_result_test,
        activity_low_block_test,
        activity_filter_no_result_test,
        hotspots_test,
        stats_test,
        rewards_test,
        rewards_sum_test,
        rich_list_test
    ].

init_per_suite(Config) ->
    ?init_bh(Config).

end_per_suite(Config) ->
    ?end_bh(Config).

get_test(_Config) ->
    FetchAddress = "1122ZQigQfeeyfSmH2i4KM4XMQHouBqK4LsTp33ppP3W2Knqh8gY",
    {ok, {_, _, Json}} = ?json_request(["/v1/accounts/", FetchAddress]),
    #{
        <<"data">> := #{
            <<"address">> := Address
        }
    } = Json,
    ?assertEqual(FetchAddress, binary_to_list(Address)),
    ok.

not_found_test(_Config) ->
    ?assertMatch({error, {_, 404, _}}, ?json_request("/v1/accounts/no_account/no_path")),
    ok.

activity_result_test(_Config) ->
    %% Test activity for an account. This may or may not have data
    %% returned. Expect a maybe empty array with a start and end block
    %% and a cursor to a next block range
    {ok, {_, _, Json}} = ?json_request(
        "/v1/accounts/1122ZQigQfeeyfSmH2i4KM4XMQHouBqK4LsTp33ppP3W2Knqh8gY/activity"
    ),
    #{
        <<"data">> := Data,
        <<"cursor">> := Cursor
    } = Json,
    {ok, #{<<"block">> := _}} = ?CURSOR_DECODE(Cursor),
    ?assert(length(Data) =< ?TXN_LIST_LIMIT).

activity_low_block_test(_Config) ->
    GetCursor = #{block => 50},
    {ok, {_, _, Json}} = ?json_request(
        [
            "/v1/accounts/1122ZQigQfeeyfSmH2i4KM4XMQHouBqK4LsTp33ppP3W2Knqh8gY/activity",
            "?cursor=",
            binary_to_list(?CURSOR_ENCODE(GetCursor))
        ]
    ),
    #{<<"data">> := Data} = Json,
    %% This account has just one coinebase transaction in block 1
    ?assertEqual(1, length(Data)),
    ?assertEqual(undefined, maps:get(<<"cursor">>, Json, undefined)).

activity_filter_no_result_test(_Config) ->
    %% We know this account has only a coinbase transaction in block 1 over that block range
    %% so filtering for rewards should return no data.
    GetCursor = #{
        block => 50,
        types => <<"rewards_v1">>
    },
    {ok, {_, _, Json}} = ?json_request(
        [
            "/v1/accounts/1122ZQigQfeeyfSmH2i4KM4XMQHouBqK4LsTp33ppP3W2Knqh8gY/activity",
            "?cursor=",
            binary_to_list(?CURSOR_ENCODE(GetCursor))
        ]
    ),
    #{<<"data">> := Data} = Json,
    ?assertEqual(0, length(Data)),
    ok.

hotspots_test(_Config) ->
    Account = "13YuCz3mZ55HZ6hJJvQHCZXGgE8ooe2CSvbtSHQR3m5vZ1EVCNZ",
    {ok, {_, _, Json}} = ?json_request(["/v1/accounts/", Account, "/hotspots"]),
    #{<<"data">> := Data} = Json,
    ?assert(length(Data) > 0),

    ok.

stats_test(_Config) ->
    Account = "13YuCz3mZ55HZ6hJJvQHCZXGgE8ooe2CSvbtSHQR3m5vZ1EVCNZ",
    {ok, {_, _, Json}} = ?json_request(["/v1/accounts/", Account, "/stats"]),
    #{<<"data">> := Data} = Json,
    lists:foreach(
        fun(Key) ->
            Entry = maps:get(Key, Data),
            ?assert(length(Entry) > 0)
        end,
        [
            <<"last_day">>,
            <<"last_week">>,
            <<"last_month">>
        ]
    ).

rewards_test(_Config) ->
    Account = "13YuCz3mZ55HZ6hJJvQHCZXGgE8ooe2CSvbtSHQR3m5vZ1EVCNZ",
    {ok, {_, _, Json}} = ?json_request([
        "/v1/accounts/",
        Account,
        "/rewards?max_time=2020-08-27&min_time=2019-01-01"
    ]),
    #{<<"data">> := Data} = Json,
    ?assert(length(Data) >= 0),

    case maps:get(<<"cursor">>, Json, undefined) of
        undefined ->
            ok;
        Cursor ->
            {ok, {_, _, CursorJson}} = ?json_request([
                "/v1/accounts/",
                Account,
                "/rewards?cursor=",
                Cursor
            ]),
            #{<<"data">> := CursorData} = CursorJson,
            ?assert(length(CursorData) >= 0)
    end,

    ok.

rewards_sum_test(_Config) ->
    Account = "13YuCz3mZ55HZ6hJJvQHCZXGgE8ooe2CSvbtSHQR3m5vZ1EVCNZ",
    {ok, {_, _, Json}} = ?json_request([
        "/v1/accounts/",
        Account,
        "/rewards/sum/?max_time=2020-08-27&min_time=2019-01-01"
    ]),
    #{<<"data">> := #{<<"sum">> := Sum}} = Json,
    ?assert(Sum >= 0),

    ok.

rich_list_test(_Config) ->
    {ok, {_, _, Json}} = ?json_request("/v1/accounts/rich"),
    #{<<"data">> := List} = Json,
    ?assert(length(List) > 0),

    {ok, {_, _, LimitJson}} = ?json_request("/v1/accounts/rich?limit=10"),
    #{<<"data">> := LimitList} = LimitJson,
    ?assert(length(LimitList) > 0),
    ?assert(length(LimitList) =< 10),

    ok.
