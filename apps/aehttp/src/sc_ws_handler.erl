-module(sc_ws_handler).

%% WS API
-export([init/2]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).
-export([terminate/3]).

-record(handler, {fsm_pid            :: pid() | undefined,
                  fsm_mref           :: reference() | undefined,
                  channel_id         :: aesc_channels:id() | undefined,
                  enc_channel_id     :: aeser_api_encoder:encoded() | undefined,
                  job_id             :: term(),
                  protocol           :: sc_ws_api:protocol(), 
                  role               :: initiator | responder | undefined,
                  host               :: binary() | undefined,
                  port               :: non_neg_integer() | undefined}).

-opaque handler() :: #handler{}.
-export_type([handler/0]).

-define(ERROR_TO_CLIENT(Err), {?MODULE, send_to_client, {error, Err}}).


init(Req, _Opts) ->
    lager:debug("init(~p, ~p)", [Req, _Opts]),
    process_flag(trap_exit, true),
    {cowboy_websocket, Req,
     maps:from_list(cowboy_req:parse_qs(Req))}.

-spec websocket_init(map()) -> {ok, handler()} | {stop, undefined}.
websocket_init(#{ <<"reconnect_tx">> := _ } = Params) ->
    case jobs_ask() of
        {ok, JobId} ->
            websocket_init_reconnect(Params#{ job_id => JobId });
        {error, _} ->
            {error, too_many_ws_sockets}
    end;
websocket_init(Params) ->
    case {prepare_handler(Params), read_channel_options(Params)} of
        {{error, Err}, _} ->
            lager:info("Channel WS failed to start because of ~p; params ~p",
                       [Err, Params]),
            {stop, undefined};
        {_, {error, Err}} ->
            lager:info("Channel WS failed to start because of ~p; params ~p",
                       [Err, Params]),
            {stop, undefined};
        {Handler, ChannelOpts} ->
            lager:debug("Starting Channel WS with params ~p", [Params]),
            case start_link_fsm(Handler, ChannelOpts) of
                {ok, FsmPid} ->
                    MRef = erlang:monitor(process, FsmPid),
                    {ok, Handler#handler{fsm_pid = FsmPid, fsm_mref = MRef}};
                {error, Err} ->
                    handler_init_error(Err, Handler)
            end
    end.

websocket_init_reconnect(#{ <<"reconnect_tx">> := ReconnectTx } = Params) ->
    lager:debug("ReconnectTx = ~p", [ReconnectTx]),
    case check_reconnect_tx(ReconnectTx) of
        {ok, #{ channel_id := ChanId
              , role       := Role
              , pub_key    := Pubkey
              , signed_tx  := SignedTx } = Opts} ->
            Handler = reconnect_opts_to_handler(maps:merge(Params, Opts)),
            case aesc_fsm:where(ChanId, Role) of
                undefined ->
                    lager:debug("where(~p, ~p) -> undefined", [ChanId, Role]),
                    handler_init_error(not_found, Handler);
                #{ fsm_pid := Fsm, pub_key := Pubkey } ->
                    %% At this point, we haven't verified the signature.
                    %% This is done by the fsm.
                    lager:debug("Found FSM = ~p", [Fsm]),
                    case aesc_fsm:reconnect_client(Fsm, self(), SignedTx) of
                        ok ->
                            MRef = erlang:monitor(process, Fsm),
                            { ok, Handler#handler{ fsm_pid  = Fsm
                                                 , fsm_mref = MRef } };
                        {error, Err} ->
                            handler_init_error(Err, Handler)
                    end
            end;
        {error, CheckError} ->
            lager:debug("CheckError = ~p", [CheckError]),
            {stop, undefined}
    end.

handler_init_error(Err, Handler) ->
    HandledErrors =[{not_found, participant_not_found},
                    {insufficient_initiator_amount, value_too_low},
                    {insufficient_responder_amount, value_too_low},
                    {insufficient_amounts, value_too_low},
                    {channel_reserve_too_low, value_too_low},
                    {push_amount_too_low, value_too_low},
                    {lock_period_too_low, value_too_low}
                   ],
    case proplists:get_value(Err, HandledErrors, not_handled_error) of
        not_handled_error ->
            lager:info("Failed to start because of unhandled error ~p", [Err]),
            {stop, undefined};
        ErrKey ->
            %% because of tests' subscription mechanism, we
            %% might have to give some time tolerance in order
            %% to avoid race conditions
            After = 0,
            timer:send_after(After, ?ERROR_TO_CLIENT(ErrKey)),
            timer:send_after(After + 1, stop),
            {ok, Handler#handler{fsm_pid  = undefined,
                                 fsm_mref = undefined}}
    end.


-spec websocket_handle(term(), handler()) -> {ok, handler()}.
websocket_handle({text, MsgBin}, #handler{fsm_pid = undefined} = H) ->
    %% the FSM has not been started, the connection is to die any moment now
    %% do not respond
    lager:debug("Not processing message ~p", [MsgBin]),
    {ok, H};
websocket_handle({text, MsgBin}, #handler{protocol = Protocol,
                                          enc_channel_id = ChannelId,
                                          fsm_pid  = FsmPid} = H) ->
    case sc_ws_api:process_from_client(Protocol, MsgBin, FsmPid, ChannelId) of
        no_reply          -> {ok, H};
        {reply, Resp}     -> {reply, {text, jsx:encode(Resp)}, H};
        stop              -> {stop, H}
    end;
websocket_handle(_Data, H) ->
    {ok, H}.

websocket_info(?ERROR_TO_CLIENT(Err), #handler{protocol = Protocol} = H) ->
    {reply, Resp} = sc_ws_api:error_response(Protocol, Err),
    timer:sleep(1000),
    lager:info("Handler critical error: ~p", [Err]),
    {reply, {text, jsx:encode(Resp)}, H};
websocket_info(stop, #handler{} = H) ->
    {stop, H};
websocket_info({aesc_fsm, FsmPid, Msg}, #handler{fsm_pid = FsmPid,
                                                 enc_channel_id = ChannelId,
                                                 protocol = Protocol} = H) ->
    H1 = set_channel_id(Msg, H),
    case sc_ws_api:process_from_fsm(Protocol, Msg, ChannelId) of
        no_reply          -> {ok, H1};
        {reply, Resp}     -> {reply, {text, jsx:encode(Resp)}, H1};
        stop              -> {stop, H1}
    end;
websocket_info({'DOWN', MRef, _, _, _}, #handler{fsm_mref = MRef} = H) ->
    {stop, H#handler{fsm_pid = undefined,
                     fsm_mref = undefined}};
websocket_info(_Info, State) ->
    {ok, State}.

set_channel_id(Msg, H) ->
    Res = set_channel_id_(Msg, H),
    lager:debug("Msg=~p (Id0=~p) -> ~p", [Msg, H#handler.channel_id,
                                          Res#handler.channel_id]),
    Res.

set_channel_id_(#{channel_id := Id},
               #handler{channel_id = undefined} = H) when Id =/= undefined ->
    H#handler{channel_id = Id,
              enc_channel_id = aeser_api_encoder:encode(channel, Id)};
set_channel_id_(#{channel_id := A}, #handler{channel_id = B})
  when A =/= undefined, A =/= B ->
    erlang:error({channel_id_mismatch, [A, B]});
set_channel_id_(_Msg, H) ->
    H.

terminate(Reason, _PartialReq, #{} = _H) ->
    lager:debug("WebSocket dying because of ~p", [Reason]),
    % not initialized yet
    ok;
terminate(Reason, _PartialReq, State) ->
    lager:debug("WebSocket dying because of ~p/~p", [Reason, erlang:get_stacktrace()]),
    case fsm_pid(State) of
        undefined -> pass;
        FsmPid ->
            true = unlink(FsmPid)
    end,
    case job_id(State) of
        undefined -> pass;
        JobId -> jobs:done(JobId)
    end,
    ok.

-spec job_id(handler() | undefined) -> term().
job_id(undefined) -> undefined;
job_id(#handler{job_id = JobId}) ->
    JobId.

-spec fsm_pid(handler() | undefined) -> pid() | undefined.
fsm_pid(undefined) -> undefined;
fsm_pid(#handler{fsm_pid = Pid}) ->
    Pid.

-spec start_link_fsm(handler(), map()) -> {ok, pid()} | {error, atom()}.
start_link_fsm(#handler{role = initiator, host=Host, port=Port}, Opts) ->
    aesc_fsm:initiate(Host, Port, Opts);
start_link_fsm(#handler{role = responder, port=Port}, Opts) ->
    aesc_fsm:respond(Port, Opts).

check_reconnect_tx(Tx0) ->
    case aeser_api_encoder:safe_decode(transaction, Tx0) of
        {ok, SignedTxBin} ->
            lager:debug("Decoded (bin): ~p", [SignedTxBin]),
            SignedTx = aetx_sign:deserialize_from_binary(SignedTxBin),
            case aetx:specialize_callback(aetx_sign:tx(SignedTx)) of
                {aesc_client_reconnect_tx = Mod, Tx} ->
                    %% Successful deserialization implies proper tx structure
                    lager:debug("Is reconnect tx", []),
                    {ok, lists:foldl(
                           fun({Key, Method}, Acc) ->
                                   Acc#{Key => Mod:Method(Tx)}
                           end, #{ signed_tx => SignedTx },
                           [ {channel_id, channel_pubkey}
                           , {role      , role}
                           , {pub_key   , origin} ])};
                _Other ->
                    lager:debug("Wrong type tx: ~p", [_Other]),
                    {error, invalid_tx}
            end;
        _DecErr ->
            lager:debug("Decode error: ~p", [_DecErr]),
            {error, invalid_tx}
    end.

set_field(H, host, Val)         -> H#handler{host = Val};
set_field(H, role, Val)         -> H#handler{role = Val};
set_field(H, port, Val)         -> H#handler{port = Val}.

-spec read_param(binary(), atom(), map()) -> fun((map()) -> {ok, term()} |
                                                            not_set |
                                                            {error, {atom(), atom()}}).
read_param(ParamName, RecordField, Options) ->
    fun(Params) ->
        Mandatory = maps:get(mandatory, Options, true),
        case maps:get(ParamName, Params, undefined) of
            undefined when Mandatory ->
                {error, {RecordField, missing}};
            undefined when not Mandatory ->
                not_set;
            Val ->
                check_type(Options, Val, RecordField)
        end
    end.

check_type(Options, Val0, RecordField) ->
    Type = maps:get(type, Options, binary),
    try parse_by_type(Type, Val0, RecordField) of
        {error, _} = Err -> Err;
        {ok, Val} ->
            case maps:get(enum, Options, undefined) of
                undefined ->  {ok, Val};
                AllowedVals when is_list(AllowedVals) ->
                    case lists:member(Val, AllowedVals) of
                        true -> {ok, Val};
                        false ->
                            {error, {RecordField, invalid}}
                    end
            end
    catch
        error:_ -> {error, {RecordField, invalid}}
    end.

parse_by_type(binary, V, _) when is_binary(V) ->
    {ok, V};
parse_by_type(boolean, V, _) when is_binary(V) ->
    case V of
        <<"true">>  -> {ok, true};
        <<"false">> -> {ok, false};
        _           -> {error, not_bool}
    end;
parse_by_type(string, V, _) when is_binary(V) ->
    {ok, binary_to_list(V)};
parse_by_type(atom, V, _) when is_binary(V) ->
    {ok, binary_to_existing_atom(V, utf8)};
parse_by_type(integer, V, _) when is_binary(V) ->
    {ok, list_to_integer(binary_to_list(V))};
parse_by_type(integer, V, _) when is_integer(V) ->
    {ok, V};
parse_by_type({hash, Type}, V, RecordField) when is_binary(V) ->
    case aeser_api_encoder:safe_decode(Type, V) of
        {error, _} ->
            {error, {RecordField, broken_encoding}};
        {ok, _} = OK -> OK
    end;
parse_by_type({alt, L}, V, RecordField) when is_list(L) ->
    lists:foldl(
      fun(_, {ok,_} = Ok) -> Ok;
         (Alt, Acc) when is_map(Alt) ->
              case check_type(Alt, V, RecordField) of
                  {ok, _} = Ok -> Ok;
                  {error,_} -> Acc
              end
      end, {error, {RecordField, invalid}}, L);
parse_by_type(serialized_tx, V, RecordField) when is_binary(V) ->
    case aeser_api_encoder:safe_decode(transaction, V) of
        {ok, TxBin} ->
            try {ok, aetx_sign:deserialize_from_binary(TxBin)}
            catch
                error:_ ->
                    {error, {RecordField, invalid_tx_serialization}}
            end;
        {error, _} ->
            {error, {RecordField, broken_encoding}}
    end.

reconnect_opts_to_handler(#{ <<"protocol">> := Protocol
                           , channel_id     := ChId
                           , job_id         := JobId } = Params) ->
    lager:debug("Params = ~p", [Params]),
    %% We don't fill in values like host, port, etc. since we don't
    %% have them, and they aren't needed afaict.
    #handler{ protocol       = sc_ws_api:protocol(Protocol)
            , channel_id     = ChId
            , enc_channel_id = aeser_api_encoder:encode(channel, ChId)
            , job_id         = JobId }.

prepare_handler(#{<<"protocol">> := Protocol} = Params) ->
    lager:debug("prepare_handler() Params = ~p", [Params]),
    Read =
        fun(Key, RecordField, Opts) ->
            fun(H) ->
                case (read_param(Key, RecordField, Opts))(Params) of
                    not_set -> H;
                    {ok, Val} -> set_field(H, RecordField, Val);
                    {error, _} = Err -> Err
                end
            end
        end,
    Validators =
        [fun(H) ->
            case jobs_ask() of
                {ok, JobId} ->
                    H#handler{job_id = JobId};
                {error, _} ->
                    {error, too_many_ws_sockets}
            end
        end,
        Read(<<"role">>, role, #{type => atom,
                                 enum => [responder, initiator]}),
        fun(#handler{role = Role} = H) ->
            case Role of
                initiator -> % require having a host only for initiator
                    F = Read(<<"host">>, host, #{type => string}),
                    F(H);
                responder -> H
            end
        end,
        Read(<<"port">>, port, #{type => integer})
        ],
    lists:foldl(
        fun(_, {error, _} = Err) -> Err;
            (Fun, Accum) -> Fun(Accum)
        end,
        #handler{protocol    = sc_ws_api:protocol(Protocol)}, Validators).

read_channel_options(Params) ->
    Read =
        fun(KeyBin, Key, Opts) ->
            fun(M) ->
                case (read_param(KeyBin, Key, Opts))(Params) of
                    not_set -> M;
                    {ok, Val} -> maps:put(Key, Val, M);
                    {error, _} = Err -> Err
                end
            end
        end,
    Put =
        fun(K, V) ->
            fun(M) -> maps:put(K, V, M) end
        end,
    Error =
        fun({error, _} = Err) ->
            fun(_M) ->
                Err
            end
        end,
    ReadInitiator =
        fun(M) ->
                IType = #{type => {hash, account_pubkey}},
                Type = case maps:get(role, M) of
                           responder -> #{type => {alt, [#{type => atom, enum => [any]},
                                                         IType]}};
                           initiator -> IType
                       end,
                (Read(<<"initiator_id">>, initiator, Type))(M)
        end,
    ReadMap =
        fun(MapName, Prefix, Opts) ->
            fun(Name) ->
                NameBin = atom_to_binary(Name, utf8),
                Key = <<Prefix/binary, "_", NameBin/binary>>,
                fun(M) ->
                    OldVal = maps:get(MapName, M, #{}),
                    case (read_param(Key, Name, Opts))(Params) of
                        not_set -> M;
                        {ok, Val} -> maps:put(MapName, maps:put(Name, Val, OldVal), M);
                        {error, _} = Err -> Err
                    end
                end
            end
        end,
    ReadTimeout = ReadMap(timeouts, <<"timeout">>, #{type => integer,
                                                     mandatory => false}),
    ReadReport = ReadMap(report, <<"report">>, #{type => boolean,
                                                     mandatory => false}),
    OnChainOpts =
        case (read_param(<<"existing_channel_id">>, existing_channel_id,
                         #{type => {hash, channel}, mandatory => false}))(Params) of
            not_set ->  %Channel open scenario
                [Read(<<"role">>, role, #{type => atom, enum => [responder, initiator]}),
                 Read(<<"push_amount">>, push_amount, #{type => integer}),
                 %% Read(<<"initiator_id">>, initiator, #{type => {hash, account_pubkey}}),
                 ReadInitiator,
                 Read(<<"responder_id">>, responder, #{type => {hash, account_pubkey}}),
                 Read(<<"lock_period">>, lock_period, #{type => integer}),
                 Read(<<"channel_reserve">>, channel_reserve, #{type => integer}),
                 Read(<<"initiator_amount">>, initiator_amount, #{type => integer}),
                 Read(<<"responder_amount">>, responder_amount, #{type => integer})];
            {ok, ExistingID} ->  %Channel reestablish (already opened) scenario
                case aec_chain:get_channel(ExistingID) of
                    {ok, Channel} ->
                        [Put(existing_channel_id, ExistingID),
                         Read(<<"offchain_tx">>, offchain_tx, #{type => serialized_tx}),
                         % push_amount is only used in open and is not preserved.
                         % 0 guarantees passing checks (executed amount check is the
                         % same as onchain check)
                         Put(push_amount, 0),
                         Put(initiator, aesc_channels:initiator_pubkey(Channel)),
                         Put(responder, aesc_channels:responder_pubkey(Channel)),
                         Put(lock_period, aesc_channels:lock_period(Channel)),
                         Put(channel_reserve, aesc_channels:channel_reserve(Channel)),
                         Put(initiator_amount, aesc_channels:initiator_amount(Channel)),
                         Put(responder_amount, aesc_channels:responder_amount(Channel))];
                    {error, _} = Err ->
                        [Error(Err)]
                end;
            {error, _} = Err ->
                [Error(Err)]
        end,
    lists:foldl(
        fun(_, {error, _} = Err) -> Err;
            (Fun, Accum) -> Fun(Accum)
        end,
        #{},
        [Read(<<"minimum_depth">>, minimum_depth, #{type => integer, mandatory => false}),
         Read(<<"ttl">>, ttl, #{type => integer, mandatory => false}),
         Put(noise, [{noise, <<"Noise_NN_25519_ChaChaPoly_BLAKE2b">>}])
        ] ++ OnChainOpts
          ++ lists:map(ReadTimeout, aesc_fsm:timeouts() ++ [awaiting_open,
                                                            initialized])
          ++ lists:map(ReadReport, aesc_fsm:report_tags())
     ).

jobs_ask() ->
    jobs:ask(ws_handlers).
