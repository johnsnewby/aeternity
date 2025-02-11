-module(aest_db_SUITE).

%=== EXPORTS ===================================================================

% Common Test exports
-export([all/0]).
-export([init_per_suite/1]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).
-export([end_per_suite/1]).

% Test cases
-export([
         node_can_reuse_db_of_other_node/1,
         roma_node_can_reuse_db_of_other_roma_node/1,
         minerva_node_with_epoch_db_can_reuse_db_of_roma_node/1,
         node_can_reuse_db_of_roma_node/1,
         node_can_reuse_db_of_minerva_node_with_epoch_db/1,
         minerva_node_with_channels_update_as_tuple_can_reuse_db_of_analogous_node/1,
         minerva_node_with_channels_update_as_tuple_can_reuse_db_of_analogous_node_with_force_progress_tx/1,
         node_can_reuse_db_of_minerva_node_with_channels_update_as_tuple_with_force_progress_tx/1
        ]).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").

%=== MACROS ====================================================================

-define(STARTUP_TIMEOUT, 20000).
-define(MINING_TIMEOUT,   3000).
-define(GRACEFUL_STOP_TIMEOUT, 60000).

%=== RECORDS ===================================================================

-record(db_reuse_test_spec, {create,     % Node spec.
                             populate =  % DB insertion.
                                 fun populate_db/2,
                             pre_reuse = % DB transformation.
                                 fun(_,_,_) -> ok end,
                             reuse,      % Node spec.
                             assert =    % DB assertion.
                                 fun assert_db_reused/3
                            }).

%=== COMMON TEST FUNCTIONS =====================================================

all() -> [
          node_can_reuse_db_of_other_node,
          roma_node_can_reuse_db_of_other_roma_node,
          minerva_node_with_epoch_db_can_reuse_db_of_roma_node,
          node_can_reuse_db_of_roma_node,
          node_can_reuse_db_of_minerva_node_with_epoch_db,
          minerva_node_with_channels_update_as_tuple_can_reuse_db_of_analogous_node,
          minerva_node_with_channels_update_as_tuple_can_reuse_db_of_analogous_node_with_force_progress_tx,
          node_can_reuse_db_of_minerva_node_with_channels_update_as_tuple_with_force_progress_tx
         ].

init_per_suite(Config) ->
    Config.

init_per_testcase(_TC, Config) ->
    aest_nodes:ct_setup(Config).

end_per_testcase(_TC, Config) ->
    aest_nodes:ct_cleanup(Config).

end_per_suite(_Config) -> ok.

%=== TEST CASES ================================================================

node_can_reuse_db_of_other_node(Cfg) ->
    Test = #db_reuse_test_spec{
              create = fun node_mining_spec/2,
              reuse = fun node_spec/2},
    node_can_reuse_db_of_other_node_(Test, Cfg).

roma_node_can_reuse_db_of_other_roma_node(Cfg) ->
    Test = #db_reuse_test_spec{
              create = fun roma_node_mining_spec/2,
              reuse = fun roma_node_spec/2},
    node_can_reuse_db_of_other_node_(Test, Cfg).

minerva_node_with_epoch_db_can_reuse_db_of_roma_node(Cfg) ->
    Test = #db_reuse_test_spec{
              create = fun roma_node_mining_spec/2,
              reuse = fun minerva_with_epoch_name_in_db_spec/2},
    node_can_reuse_db_of_other_node_(Test, Cfg).

node_can_reuse_db_of_roma_node(Cfg) ->
    Test = #db_reuse_test_spec{
              create = fun roma_node_mining_spec/2,
              pre_reuse = fun run_rename_db_script/3,
              reuse = fun node_spec/2},
    node_can_reuse_db_of_other_node_(Test, Cfg).

node_can_reuse_db_of_minerva_node_with_epoch_db(Cfg) ->
    Test = #db_reuse_test_spec{
              create = fun minerva_with_epoch_name_in_db_mining_spec/2,
              pre_reuse = fun run_rename_db_script/3,
              reuse = fun node_spec/2},
    node_can_reuse_db_of_other_node_(Test, Cfg).

minerva_node_with_channels_update_as_tuple_can_reuse_db_of_analogous_node(Cfg) ->
    Test = #db_reuse_test_spec{
              create = fun minerva_node_with_channels_update_as_tuple_mining_spec/2,
              reuse = fun minerva_node_with_channels_update_as_tuple_spec/2},
    node_can_reuse_db_of_other_node_(Test, Cfg).

minerva_node_with_channels_update_as_tuple_can_reuse_db_of_analogous_node_with_force_progress_tx(Cfg) ->
    Test = #db_reuse_test_spec{
              create = fun minerva_node_with_channels_update_as_tuple_spec/2,
              populate = fun populate_db_with_channels_force_progress_tx/2,
              reuse = fun minerva_node_with_channels_update_as_tuple_spec/2,
              assert = fun assert_db_with_tx_reused/3},
    node_can_reuse_db_of_other_node_(Test, Cfg).

node_can_reuse_db_of_minerva_node_with_channels_update_as_tuple_with_force_progress_tx(Cfg) ->
    Test = #db_reuse_test_spec{
              create = fun minerva_node_with_channels_update_as_tuple_spec/2,
              populate = fun populate_db_with_channels_force_progress_tx/2,
              reuse = fun node_spec/2,
              assert = fun assert_db_with_tx_reused/3},
    node_can_reuse_db_of_other_node_(Test, Cfg).

%=== INTERNAL FUNCTIONS ========================================================

node_can_reuse_db_of_other_node_(T = #db_reuse_test_spec{}, Cfg)
  when is_function(T#db_reuse_test_spec.create, 2),
       is_function(T#db_reuse_test_spec.populate, 2),
       is_function(T#db_reuse_test_spec.pre_reuse, 3),
       is_function(T#db_reuse_test_spec.reuse, 2),
       is_function(T#db_reuse_test_spec.assert, 3) ->
    DbHostPath = node_db_host_path(node1, Cfg),
    N1 = (T#db_reuse_test_spec.create)(node1, DbHostPath),
    aest_nodes:setup_nodes([N1], Cfg),
    start_and_wait_node(node1, ?STARTUP_TIMEOUT, Cfg),
    DbFingerprint = (T#db_reuse_test_spec.populate)(node1, Cfg),
    aest_nodes:stop_node(node1, ?GRACEFUL_STOP_TIMEOUT, Cfg),

    ok = (T#db_reuse_test_spec.pre_reuse)(node3, DbHostPath, Cfg),

    N2 = (T#db_reuse_test_spec.reuse)(node2, DbHostPath),
    aest_nodes:setup_nodes([N2], Cfg),
    start_and_wait_node(node2, ?STARTUP_TIMEOUT, Cfg),
    ok = (T#db_reuse_test_spec.assert)(node2, DbFingerprint, Cfg),
    ok.

populate_db(NodeName, Cfg) ->
    TargetHeight = 3,
    aest_nodes:wait_for_value({height, TargetHeight}, [NodeName], TargetHeight * ?MINING_TIMEOUT, Cfg),
    #{hash := BlockHash} = aest_nodes:get_block(NodeName, TargetHeight),
    _DbFingerprint = {TargetHeight, BlockHash}.

assert_db_reused(NodeName, {TargetHeight, BlockHash} = _DbFingerprint, Cfg) ->
    aest_nodes:wait_for_value({height, TargetHeight}, [NodeName], ?STARTUP_TIMEOUT, Cfg),
    ?assertMatch({ok, 200, _}, get_block_by_hash(NodeName, BlockHash)),
    ok.

get_block_by_hash(NodeName, Hash) ->
    aest_nodes:request(NodeName, 'GetKeyBlockByHash', #{hash => Hash}).

start_and_wait_node(NodeName, Timeout, Cfg) ->
    aest_nodes:start_node(NodeName, Cfg),
    aest_nodes:wait_for_value({height, 0}, [NodeName], Timeout, Cfg),
    %% Hardcode expectation that node picks user config
    #{network_id := <<"ae_system_test">>} = aest_nodes:get_status(NodeName),
    ok.

node_db_host_path(NodeName, Config) ->
    {priv_dir, PrivDir} = proplists:lookup(priv_dir, Config),
    filename:join(PrivDir, format("~s_db", [NodeName])).

format(Fmt, Args) ->
    iolist_to_binary(io_lib:format(Fmt, Args)).

run_rename_db_script(UnusedNodeName, DbHostPath, Cfg) when is_atom(UnusedNodeName) ->
    {ok, DbSchema} = file:read_file(filename:join(DbHostPath, "schema.DAT")),
    {error, _} = file:read_file(filename:join(DbHostPath, "schema.DAT.backup")),
    N3 = node_spec_custom_entrypoint(UnusedNodeName, DbHostPath),
    aest_nodes:setup_nodes([N3], Cfg),
    aest_nodes:start_node(UnusedNodeName, Cfg),

    {0, _} = aest_nodes:run_cmd_in_node_dir(UnusedNodeName, ["bin/aeternity", "rename_db", "data"], #{timeout => 5000}, Cfg),

    aest_nodes:stop_container(UnusedNodeName, ?GRACEFUL_STOP_TIMEOUT, Cfg),
    {ok, DbSchemaRenamed} = file:read_file(filename:join(DbHostPath, "schema.DAT")),
    {ok, DbSchemaBackup} = file:read_file(filename:join(DbHostPath, "schema.DAT.backup")),
    ?assertNotEqual(DbSchema, DbSchemaRenamed),
    ?assertEqual(DbSchema, DbSchemaBackup),
    ok.

node_mining_spec(Name, DbHostPath) ->
    node_spec(Name, DbHostPath, true).
node_spec(Name, DbHostPath) ->
    node_spec(Name, DbHostPath, false).
node_spec(Name, DbHostPath, Mining) ->
    DbGuestPath = "/home/aeternity/node/data/mnesia",
    aest_nodes:spec(Name, [], #{source  => {pull, "aeternity/aeternity:local"},
                                db_path => {DbHostPath, DbGuestPath},
                                mining => #{autostart => Mining},
                                genesis_accounts => genesis_accounts()}).

node_spec_custom_entrypoint(Name, DbHostPath) ->
    DbGuestPath = "/home/aeternity/node/data/mnesia",
    aest_nodes:spec(Name, [], #{source  => {pull, "aeternity/aeternity:local"},
                                db_path => {DbHostPath, DbGuestPath},
                                mining => #{autostart => false},
                                entrypoint => [<<"sleep">>],
                                custom_command => [<<"98127308917209371890273">>]}).

roma_node_mining_spec(Name, DbHostPath) ->
    roma_node_spec(Name, DbHostPath, true).
roma_node_spec(Name, DbHostPath) ->
    roma_node_spec(Name, DbHostPath, false).
%% Last Roma release.
roma_node_spec(Name, DbHostPath, Mining) ->
    DbGuestPath = "/home/aeternity/node/data/mnesia",
    aest_nodes:spec(Name, [], #{source  => {pull, "aeternity/aeternity:v1.4.0"},
                                db_path => {DbHostPath, DbGuestPath},
                                config_guest_path => "/home/aeternity/.epoch/epoch/epoch.yaml",
                                mining => #{autostart => Mining},
                                genesis_accounts => genesis_accounts()}).

minerva_with_epoch_name_in_db_mining_spec(Name, DbHostPath) ->
    minerva_with_epoch_name_in_db_spec(Name, DbHostPath, true).
minerva_with_epoch_name_in_db_spec(Name, DbHostPath) ->
    minerva_with_epoch_name_in_db_spec(Name, DbHostPath, false).
%% Minerva release using old epoch@localhost node name in the db.
minerva_with_epoch_name_in_db_spec(Name, DbHostPath, Mining) ->
    DbGuestPath = "/home/aeternity/node/data/mnesia",
    aest_nodes:spec(Name, [], #{source  => {pull, "aeternity/aeternity:v2.1.0"},
                                db_path => {DbHostPath, DbGuestPath},
                                mining => #{autostart => Mining},
                                genesis_accounts => genesis_accounts()}).

minerva_node_with_channels_update_as_tuple_mining_spec(Name, DbHostPath) ->
    minerva_node_with_channels_update_as_tuple_spec(Name, DbHostPath, true).
minerva_node_with_channels_update_as_tuple_spec(Name, DbHostPath) ->
    minerva_node_with_channels_update_as_tuple_spec(Name, DbHostPath, false).
%% https://github.com/aeternity/aeternity/blob/v2.3.0/apps/aechannel/src/aesc_offchain_update.erl#L15-L17
minerva_node_with_channels_update_as_tuple_spec(Name, DbHostPath, Mining) ->
    DbGuestPath = "/home/aeternity/node/data/mnesia",
    aest_nodes:spec(Name, [], #{source  => {pull, "aeternity/aeternity:v2.3.0"},
                                db_path => {DbHostPath, DbGuestPath},
                                mining => #{autostart => Mining},
                                genesis_accounts => genesis_accounts()}).

genesis_accounts() ->
    %% have all nodes share the same accounts_test.json
    PatronPubkey = maps:get(pubkey, patron()),
    PatronAddress = aeser_api_encoder:encode(account_pubkey, PatronPubkey),
    [{PatronAddress, 123400000000000000000000000000}].

patron() ->
    #{ pubkey => <<206,167,173,228,112,201,249,157,157,78,64,8,128,168,111,29,73,187,68,75,98,241,26,158,187,100,187,207,235,115,254,243>>,
       privkey => <<230,169,29,99,60,119,207,87,113,50,157,51,84,179,188,239,27,197,224,50,196,61,112,182,211,90,249,35,206,30,183,77,206,167,173,228,112,201,249,157,157,78,64,8,128,168,111,29,73,187,68,75,98,241,26,158,187,100,187,207,235,115,254,243>>
     }.

populate_db_with_channels_force_progress_tx(NodeName, _Cfg) ->
    #{tx_hash := TxHash} =
        aest_nodes:post_force_progress_state_channel_tx(
          NodeName,
          patron(),
          aeser_id:create(channel, <<42:32/unit:8>>),
          #{nonce => 1}),
    _DbFingerprint = TxHash.

assert_db_with_tx_reused(NodeName, TxHash = _DbFingerprint, _Cfg) ->
    aest_nodes:wait_for_value({txs_on_node, [TxHash]}, [NodeName], ?STARTUP_TIMEOUT, []), %% Uses GetTransactionByHash
    ok.
