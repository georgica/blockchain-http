-module(bh_route_txns).

-behavior(bh_route_handler).
-behavior(bh_db_worker).

-include("bh_route_handler.hrl").

-export([prepare_conn/1, handle/3]).
%% Utilities
-export([get_txn/1,
         get_txn_list/1,
         get_txn_list_cache_time/1,
         get_actor_txn_list/2,
         get_activity_list/2,
         txn_to_json/1,
         txn_list_to_json/1,
         filter_types/1]).

-define(S_TXN, "txn").
-define(S_TXN_LIST, "txn_list").
-define(S_BLOCK_REM_TXN_LIST, "block_rem_txn_list").
-define(S_ACTOR_TXN_LIST, "actor_txn_list").
-define(S_OWNED_ACTOR_TXN_LIST, "owned_actor_txn_list").
-define(S_ACCOUNT_ACTIVITY_LIST, "account_activity_list").
-define(S_ACCOUNT_ACTIVITY_LIST_BEFORE, "account_activity_list_before").
-define(S_HOTSPOT_ACTIVITY_LIST, "hotspot_activity_list").
-define(S_HOTSPOT_ACTIVITY_LIST_BEFORE, "hotspot_activity_list_before").

-define(SELECT_TXN_LIST,
       [?SELECT_TXN_BASE,
        "from transactions t ",
        "where t.type = ANY($1)",
        " and block >= $2 and block < $3"
        " order by t.block desc, t.hash"
       ]).

-define(SELECT_BLOCK_REM_TXN_LIST,
        [?SELECT_TXN_BASE,
         "from (select * from transactions tr",
         "      where tr.type = ANY($1)",
         "      and tr.block = $2 order by tr.hash) t ",
         "where t.hash > $3"
        ]
       ).

-define(SELECT_ACTOR_TXN_LIST_BASE(F, E),
        [?SELECT_TXN_FIELDS(F),
         "from (select tr.*, a.actor ",
         "from transaction_actors a inner join transactions tr on a.transaction_hash = tr.hash ",
         " where a.block >= $3 and a.block < $4 and a.actor = $1 ", (E),
         " and tr.type = ANY($2) order by tr.block desc, tr.hash) as t "
        ]).

-define(SELECT_OWNED_ACTOR_TXN_LIST_BASE(F, E),
        [?SELECT_TXN_FIELDS(F),
         "from (select tr.*, a.actor ",
         "from transaction_actors a inner join transactions tr on a.transaction_hash = tr.hash ",
         " where a.block >= $3 and a.block < $4",
         " and a.actor in (select address from gateway_inventory where owner = $1) ", (E),
         " and tr.type = ANY($2) order by tr.block desc, tr.hash) as t "
        ]).

-define(SELECT_ACTOR_TXN_LIST, ?SELECT_ACTOR_TXN_LIST_BASE("t.fields", "")).
-define(SELECT_OWNED_ACTOR_TXN_LIST, ?SELECT_OWNED_ACTOR_TXN_LIST_BASE("t.fields", "")).

-define(SELECT_ACCOUNT_ACTIVITY_LIST,
        %% For account activity we limit the actor roles to just a few.
        ?SELECT_ACTOR_TXN_LIST_BASE(
           "txn_filter_actor_activity(t.actor, t.type, t.fields) as fields",
           "and a.actor_role in ('payer', 'payee', 'owner')")).

-define(SELECT_HOTSPOT_ACTIVITY_LIST,
        %% Filter out gateway roles that should be in accounts
        ?SELECT_ACTOR_TXN_LIST_BASE(
           "txn_filter_actor_activity(t.actor, t.type, t.fields) as fields",
           "and a.actor_role not in ('payer', 'payee', 'owner')")).

-define(FILTER_TYPES,
        [<<"coinbase_v1">>,
         <<"security_coinbase_v1">>,
         <<"oui_v1">>,
         <<"state_channel_open_v1">>,
         <<"state_channel_close_v1">>,
         <<"gen_gateway_v1">>,
         <<"routing_v1">>,
         <<"payment_v1">>,
         <<"security_exchange_v1">>,
         <<"consensus_group_v1">>,
         <<"add_gateway_v1">>,
         <<"assert_location_v1">>,
         <<"create_htlc_v1">>,
         <<"redeem_htlc_v1">>,
         <<"poc_request_v1">>,
         <<"poc_receipts_v1">>,
         <<"vars_v1">>,
         <<"rewards_v1">>,
         <<"token_burn_v1">>,
         <<"dc_coinbase_v1">>,
         <<"token_burn_exchange_rate_v1">>,
         <<"payment_v2">>,
         <<"price_oracle_v1">>
        ]).

prepare_conn(Conn) ->
    {ok, S1} = epgsql:parse(Conn, ?S_TXN,
                            [?SELECT_TXN_BASE,
                             "from transactions t ",
                             "where t.hash = $1"],
                            []),

    {ok, S2} = epgsql:parse(Conn, ?S_TXN_LIST, ?SELECT_TXN_LIST,
                            []),

    {ok, S3} = epgsql:parse(Conn, ?S_ACTOR_TXN_LIST, ?SELECT_ACTOR_TXN_LIST,
                            []),

    {ok, S4} = epgsql:parse(Conn, ?S_OWNED_ACTOR_TXN_LIST, ?SELECT_OWNED_ACTOR_TXN_LIST,
                            []),

    {ok, S5} = epgsql:parse(Conn, ?S_ACCOUNT_ACTIVITY_LIST, ?SELECT_ACCOUNT_ACTIVITY_LIST,
                            []),

    {ok, S6} = epgsql:parse(Conn, ?S_HOTSPOT_ACTIVITY_LIST, ?SELECT_HOTSPOT_ACTIVITY_LIST,
                            []),

    {ok, S7} = epgsql:parse(Conn, ?S_BLOCK_REM_TXN_LIST, ?SELECT_BLOCK_REM_TXN_LIST,
                            []),

    #{
      ?S_TXN => S1,
      ?S_TXN_LIST => S2,
      ?S_ACTOR_TXN_LIST => S3,
      ?S_OWNED_ACTOR_TXN_LIST => S4,
      ?S_ACCOUNT_ACTIVITY_LIST => S5,
      ?S_HOTSPOT_ACTIVITY_LIST => S6,
      ?S_BLOCK_REM_TXN_LIST => S7
     }.

handle('GET', [TxnHash], _Req) ->
    ?MK_RESPONSE(get_txn(TxnHash), infinity);

handle(_, _, _Req) ->
    ?RESPONSE_404.

-spec get_txn(Key::binary()) -> {ok, jiffy:json_object()} | {error, term()}.
get_txn(Key) ->
    case ?PREPARED_QUERY(?S_TXN, [Key]) of
        {ok, _, [Result]} ->
            {ok, txn_to_json(Result)};
        _ ->
            {error, not_found}
    end.

get_txn_list(Args=[{cursor, _}, {filter_types, _}]) ->
    get_txn_list([], ?S_TXN_LIST, Args).

get_actor_txn_list({actor, Address}, Args=[{cursor, _}, {filter_types, _}]) ->
    get_txn_list([Address], ?S_ACTOR_TXN_LIST, Args);
get_actor_txn_list({owned, Address}, Args=[{cursor, _}, {filter_types, _}]) ->
    get_txn_list([Address], ?S_OWNED_ACTOR_TXN_LIST, Args).

get_activity_list({account, Account}, Args) ->
    get_txn_list([Account], ?S_ACCOUNT_ACTIVITY_LIST, Args);
get_activity_list({hotspot, Address}, Args) ->
    get_txn_list([Address], ?S_HOTSPOT_ACTIVITY_LIST, Args).


-define(TXN_LIST_BLOCK_ALIGN, 100).

-record(state, {
                anchor_block=undefined :: pos_integer() | undefined,

                high_block :: pos_integer(),
                low_block :: pos_integer(),

                args :: list(term()),
                types :: iolist(),
                results=[] :: list(term())
               }).

%% Grows a txn list with the given queru until it's the txn list limit
%% size. We 10x the search space every time we find we don't have
%% enough transactions.
grow_txn_list(_Query, State=#state{results=Results}) when length(Results) >= ?TXN_LIST_LIMIT ->
    State;
grow_txn_list(_Query, State=#state{low_block = 1}) ->
    State;
grow_txn_list(_Query, #state{low_block=LowBlock, high_block=HighBlock}) when LowBlock == HighBlock ->
    error(bad_arg);
grow_txn_list(Query, State=#state{low_block=LowBlock, high_block=HighBlock}) ->
    NewState = execute_query(Query, State#state{
                                      high_block = LowBlock,
                                      low_block = max(1, LowBlock - (HighBlock - LowBlock) * 10)
                                     }),
    grow_txn_list(Query, NewState).

calc_low_block(HighBlock) ->
    case HighBlock - (HighBlock rem ?TXN_LIST_BLOCK_ALIGN) of
        HighBlock -> max(1, HighBlock - ?TXN_LIST_BLOCK_ALIGN);
        Other -> max(1, Other)
    end.

execute_query(Query, State) ->
    AddedArgs = [filter_types(State#state.types), State#state.low_block, State#state.high_block],
    {ok, _, Results} = ?PREPARED_QUERY(Query, State#state.args ++ AddedArgs),
    State#state{results = State#state.results ++ Results}.


get_txn_list(Args, Query, [{cursor, undefined}, {filter_types, Types}]) ->
    {ok, #{height := CurrentBlock}} = bh_route_blocks:get_block_height(),
    %% High block is exclusive so start past the tip
    HighBlock = CurrentBlock + 1,
    State = #state {
               high_block = HighBlock,
               %% Aim for block alignment
               low_block = calc_low_block(HighBlock),

               args = Args,
               types = Types
              },
    mk_txn_list_result(execute_query(Query, State));
get_txn_list(Args, Query, [{cursor, Cursor}, {filter_types, _}]) ->
    case ?CURSOR_DECODE(Cursor) of
        {ok, C=#{ <<"block">> := HighBlock}} ->
            Types = maps:get(<<"types">>, C, undefined),
            %% Construct the a partial list of results if we were
            %% partway into the block
            StartList = case maps:get(<<"address">>, C, undefined) of
                            undefind -> [];
                            BeforeAddr ->
                                {ok, _, L} = ?PREPARED_QUERY(?S_BLOCK_REM_TXN_LIST,
                                                             [filter_types(Types), HighBlock, BeforeAddr]),
                                L
                        end,
            State = #state {
                       high_block = HighBlock,
                       anchor_block = maps:get(<<"anchor_block">>, C, undefined),
                       low_block = calc_low_block(HighBlock),

                       args = Args,
                       types = Types,
                       results = StartList
                      },
            %% Collect the initial set of results before the highblock
            %% annd start growing from there
            mk_txn_list_result(grow_txn_list(Query, execute_query(Query, State)));
        _ ->
            {error, badarg}
    end.

mk_txn_list_result(State=#state{results=Results}) when length(Results) > ?TXN_LIST_LIMIT ->
    {Trimmed, _Remainder} = lists:split(?TXN_LIST_LIMIT, Results),
    {Height, _Time, Hash, _Type, _Fields} = lists:last(Trimmed),
    {ok,
     txn_list_to_json(Trimmed),
     mk_txn_list_cursor(Height, Hash, State)
    };
mk_txn_list_result(State=#state{results=Results}) ->
    {ok,
     txn_list_to_json(Results),
     mk_txn_list_cursor(State#state.low_block, undefined, State)
    }.


mk_txn_list_cursor(1, undefined, #state{}) ->
    undefined;
mk_txn_list_cursor(BeforeBlock, BeforeAddr, State=#state{}) ->
    %% Check if we didn't have an anchor block before and we've reached an anchor point
    AnchorBlock =
        case (State#state.anchor_block == undefined) and ((BeforeBlock rem ?TXN_LIST_BLOCK_ALIGN) == 0) of
            true -> BeforeBlock;
            false -> State#state.anchor_block
        end,
    lists:foldl(fun({_Key, undefined}, Acc) -> Acc;
                   ({Key, Value}, Acc) -> Acc#{Key => Value}
                end, #{},
                [{block, BeforeBlock},
                 {address, BeforeAddr},
                 {anchor_block, AnchorBlock},
                 {types, State#state.types}]).

get_txn_list_cache_time({ok, _,  undefined}) ->
    %% Undefined cursor means we're at block 1. Technically we could
    %% store these for a longer time since head realignment would
    %% create new cache entries, but we try to be nice to the cache.
    {block_time, ?TXN_LIST_BLOCK_ALIGN};
get_txn_list_cache_time({ok, _, Cursor=#{ block := BeforeBlock }}) ->
    %% If we're on an aligned block we can cache for a longer time
    %% since it's likely to be more stable (at least for the next
    %% ?TXN_LIST_BLOCK_ALIGN blocks).
    %% If not we cache for one block time
    case maps:get(anchor_block, Cursor, undefined) of
        undefined -> block_time;
        AnchorBlock when BeforeBlock == AnchorBlock -> block_time;
        _AnchorBlock -> {block_time, ?TXN_LIST_BLOCK_ALIGN}
    end;
get_txn_list_cache_time(_) ->
    never.



%%
%% to_jaon
%%

txn_list_to_json(Results) ->
    lists:map(fun txn_to_json/1, Results).

txn_to_json({Height, Time, Hash, Type, Fields}) ->
    Json = txn_to_json({Type, Fields}),
    Json#{
          <<"type">> => Type,
          <<"hash">> => Hash,
          <<"height">> => Height,
          <<"time">> => Time
         };

txn_to_json({<<"poc_request_v1">>,
             #{ <<"location">> := Location } = Fields}) ->
    ?INSERT_LAT_LON(Location, Fields);
txn_to_json({<<"poc_receipts_v1">>,
             #{ <<"challenger_location">> := ChallengerLoc } = Fields}) ->
    ?INSERT_LAT_LON(ChallengerLoc, {<<"challenger_lat">>, <<"challenger_lon">>}, Fields);
txn_to_json({<<"gen_gateway_v1">>, Fields}) ->
    txn_to_json({<<"add_gateway_v1">>, Fields});
txn_to_json({<<"add_gateway_v1">>, Fields}) ->
    Fields#{
            <<"payer">> => maps:get(<<"payer">>, Fields, undefined),
            <<"fee">> => maps:get(<<"fee">>, Fields, 0),
            <<"staking_fee">> => maps:get(<<"staking_fee">>, Fields, 1)
           };
txn_to_json({<<"assert_location_v1">>,
             #{
               <<"location">> := Location
              } = Fields}) ->
    ?INSERT_LAT_LON(Location, Fields);
txn_to_json({_, Fields}) ->
    Fields.

%% txn_to_json({Type, _Fields}) ->
%%     lager:error("Unhandled transaction type ~p", [Type]),
%%     error({unhandled_txn_type, Type}).

-spec filter_types(undefined | [binary()] | binary()) -> iolist().
filter_types(undefined) ->
    filter_types(?FILTER_TYPES);
filter_types(Bin) when is_binary(Bin) ->
    SplitTypes = binary:split(Bin, <<",">>, [global]),
    Types = lists:filter(fun(T) -> lists:member(T, ?FILTER_TYPES) end, SplitTypes),
    filter_types(Types);
filter_types(Types) when is_list(Types) ->
    [<<"{">>, lists:join(<<",">>, Types), <<"}">>].
