%%%=============================================================================
%%% @copyright (C) 2018, Aeternity Anstalt
%%% @doc
%%%    CT test suite for AE Naming System
%%% @end
%%%=============================================================================

-module(aens_SUITE).

%% common_test exports
-export([all/0,
         groups/0,
         init_per_suite/1,
         end_per_suite/1]).

%% test case exports
-export([preclaim/1,
         prune_claim/1,
         preclaim_negative/1,
         claim/1,
         claim_locked_coins_holder_gets_locked_fee/1,
         claim_negative/1,
         claim_race_negative/1,
         update/1,
         update_negative/1,
         transfer/1,
         transfer_negative/1,
         revoke/1,
         revoke_negative/1,
         prune_preclaim/1,
         subdomain_claim/1]).

-include_lib("common_test/include/ct.hrl").

-include("../../aecore/include/blocks.hrl").

%%%===================================================================
%%% Common test framework
%%%===================================================================

all() ->
    [{group, all_tests}].

groups() ->
    [
     {all_tests, [sequence], [{group, transactions}]},
     {transactions, [sequence],

      [prune_preclaim,
       prune_claim,
       preclaim,
       preclaim_negative,
       claim,
       claim_locked_coins_holder_gets_locked_fee,
       claim_negative,
       claim_race_negative,
       update,
       update_negative,
       transfer,
       transfer_negative,
       revoke,
       revoke_negative,
       subdomain_claim
      ]}
    ].

-define(NAME, <<"詹姆斯詹姆斯.test"/utf8>>).
-define(PRE_CLAIM_HEIGHT, 1).

%%%===================================================================
%%% Init & fini
%%%===================================================================

init_per_suite(Cfg) ->
    [{name, ?NAME} | Cfg].

end_per_suite(_) ->
    [].

%%%===================================================================
%%% Preclaim
%%%===================================================================

preclaim(Cfg) ->
    <<Name/binary>> = proplists:get_value(name, Cfg),
    State = case proplists:get_value(state, Cfg) of
                undefined -> aens_test_utils:new_state();
                State0 -> State0
            end,
    {PubKey, S1} = aens_test_utils:setup_new_account(State),
    PrivKey = aens_test_utils:priv_key(PubKey, S1),
    Trees = aens_test_utils:trees(S1),
    Height = ?PRE_CLAIM_HEIGHT,
    %% Name = ?NAME,
    NameSalt = rand:uniform(10000),
    {ok, NameAscii} = aens_utils:to_ascii(Name),
    CHash = aens_hash:commitment_hash(NameAscii, NameSalt),

    %% Create Preclaim tx and apply it on trees
    TxSpec = aens_test_utils:preclaim_tx_spec(PubKey, CHash, S1),
    {ok, Tx} = aens_preclaim_tx:new(TxSpec),
    SignedTx = aec_test_utils:sign_tx(Tx, PrivKey),
    Env      = aetx_env:tx_env(Height),
    {ok, [SignedTx], Trees1, _} =
        aec_block_micro_candidate:apply_block_txs([SignedTx], Trees, Env),
    S2 = aens_test_utils:set_trees(Trees1, S1),

    %% Check commitment created
    Trees2 = aens_test_utils:trees(S2),
    {value, C} = aens_state_tree:lookup_commitment(CHash, aec_trees:ns(Trees2)),
    CHash      = aens_commitments:hash(C),
    PubKey     = aens_commitments:owner_pubkey(C),

    {PubKey, Name, NameSalt, S2}.

preclaim_negative(Cfg) ->
    {PubKey, S1} = aens_test_utils:setup_new_account(aens_test_utils:new_state()),
    Trees = aens_test_utils:trees(S1),
    Height = 1,
    Env = aetx_env:tx_env(Height),

    {ok, NameAscii} = aens_utils:to_ascii(<<"詹姆斯詹姆斯.test"/utf8>>),
    CHash = aens_hash:commitment_hash(NameAscii, 123),

    %% Test bad account key
    BadPubKey = <<42:32/unit:8>>,
    TxSpec1 = aens_test_utils:preclaim_tx_spec(BadPubKey, CHash, S1),
    {ok, Tx1} = aens_preclaim_tx:new(TxSpec1),
    {error, account_not_found} = aetx:process(Tx1, Trees, Env),

    %% Insufficient funds
    S2 = aens_test_utils:set_account_balance(PubKey, 0, S1),
    Trees2 = aens_test_utils:trees(S2),
    TxSpec2 = aens_test_utils:preclaim_tx_spec(PubKey, CHash, S1),
    {ok, Tx2} = aens_preclaim_tx:new(TxSpec2),
    {error, insufficient_funds} = aetx:process(Tx2, Trees2, Env),

    %% Test too high account nonce
    TxSpec3 = aens_test_utils:preclaim_tx_spec(PubKey, CHash, #{nonce => 0}, S1),
    {ok, Tx3} = aens_preclaim_tx:new(TxSpec3),
    {error, account_nonce_too_high} = aetx:process(Tx3, Trees, Env),

    %% Test commitment already present
    {PubKey2, Name, NameSalt, S3} = preclaim(Cfg),
    {ok, NameAscii} = aens_utils:to_ascii(Name),
    CHash2 = aens_hash:commitment_hash(NameAscii, NameSalt),
    Trees3 = aens_test_utils:trees(S3),
    TxSpec4 = aens_test_utils:preclaim_tx_spec(PubKey2, CHash2, S3),
    {ok, Tx4} = aens_preclaim_tx:new(TxSpec4),
    {error, commitment_already_present} = aetx:process(Tx4, Trees3, Env),
    ok.

%%%===================================================================
%%% Claim
%%%===================================================================

claim(Cfg) ->
    {PubKey, Name, NameSalt, S1} = preclaim(Cfg),
    Trees = aens_test_utils:trees(S1),
    Height = ?PRE_CLAIM_HEIGHT + 1,
    PrivKey = aens_test_utils:priv_key(PubKey, S1),
    {ok, NameAscii} = aens_utils:to_ascii(Name),
    CHash = aens_hash:commitment_hash(NameAscii, NameSalt),
    NHash = aens_hash:name_hash(NameAscii),

    %% Check commitment present
    {value, C} = aens_state_tree:lookup_commitment(CHash, aec_trees:ns(Trees)),
    CHash      = aens_commitments:hash(C),

    %% Create Claim tx and apply it on trees
    TxSpec = aens_test_utils:claim_tx_spec(PubKey, Name, NameSalt, S1),
    {ok, Tx} = aens_claim_tx:new(TxSpec),
    SignedTx = aec_test_utils:sign_tx(Tx, PrivKey),
    Env      = aetx_env:tx_env(Height),

    {ok, [SignedTx], Trees1, _} =
        aec_block_micro_candidate:apply_block_txs([SignedTx], Trees, Env),
    S2 = aens_test_utils:set_trees(Trees1, S1),

    %% Check commitment removed and name entry added
    Trees2 = aens_test_utils:trees(S2),
    NTrees = aec_trees:ns(Trees2),
    none       = aens_state_tree:lookup_commitment(CHash, NTrees),
    {value, N} = aens_state_tree:lookup_name(NHash, NTrees),
    NHash   = aens_names:hash(N),
    PubKey  = aens_names:owner_pubkey(N),
    claimed = aens_names:status(N),
    {PubKey, NHash, S2}.

claim_locked_coins_holder_gets_locked_fee(Cfg) ->
    {PubKey, Name, NameSalt, S1} = preclaim(Cfg),
    Trees = aens_test_utils:trees(S1),
    Height = ?PRE_CLAIM_HEIGHT + 1,
    PrivKey = aens_test_utils:priv_key(PubKey, S1),

    %% Create Claim tx and apply it on trees
    TxSpec = aens_test_utils:claim_tx_spec(PubKey, Name, NameSalt, S1),
    {ok, Tx} = aens_claim_tx:new(TxSpec),
    SignedTx = aec_test_utils:sign_tx(Tx, PrivKey),
    Env      = aetx_env:tx_env(Height),

    LockedCoinsHolderPubKey = aec_governance:locked_coins_holder_account(),
    LockedCoinsFee          = aec_governance:name_claim_locked_fee(),

    %% Locked coins holder is not present in state tree
    none = aec_accounts_trees:lookup(LockedCoinsHolderPubKey, aec_trees:accounts(Trees)),

    %% Apply claim tx, and verify locked coins holder got locked coins
    {ok, [SignedTx], Trees1, _} =
        aec_block_micro_candidate:apply_block_txs([SignedTx], Trees, Env),
    {value, Account1} = aec_accounts_trees:lookup(LockedCoinsHolderPubKey, aec_trees:accounts(Trees1)),
    LockedCoinsFee    = aec_accounts:balance(Account1),

    %% Locked coins holder has some funds
    S2 = aens_test_utils:set_account_balance(LockedCoinsHolderPubKey, 500, S1),
    Trees2 = aens_test_utils:trees(S2),
    {value, Account2} = aec_accounts_trees:lookup(LockedCoinsHolderPubKey, aec_trees:accounts(Trees2)),

    %% Apply claim tx, and verify locked coins holder got locked coins
    {ok, [SignedTx], Trees3, _} =
        aec_block_micro_candidate:apply_block_txs([SignedTx], Trees2, Env),
    {value, Account3} = aec_accounts_trees:lookup(LockedCoinsHolderPubKey, aec_trees:accounts(Trees3)),
    LockedCoinsFee = aec_accounts:balance(Account3) - aec_accounts:balance(Account2),
    ok.

claim_negative(Cfg) ->
    {PubKey, Name, NameSalt, S1} = preclaim(Cfg),
    Trees = aens_test_utils:trees(S1),
    Height = ?PRE_CLAIM_HEIGHT,
    Env = aetx_env:tx_env(Height),

    %% Test commitment delta too small
    TxSpec = aens_test_utils:claim_tx_spec(PubKey, Name, NameSalt, S1),
    {ok, Tx0} = aens_claim_tx:new(TxSpec),
    {error, commitment_delta_too_small} = aetx:process(Tx0, Trees, Env),

    %% Test bad account key
    BadPubKey = <<42:32/unit:8>>,
    TxSpec1 = aens_test_utils:claim_tx_spec(BadPubKey, Name, NameSalt, S1),
    {ok, Tx1} = aens_claim_tx:new(TxSpec1),
    {error, account_not_found} = aetx:process(Tx1, Trees, Env),

    %% Insufficient funds
    S2 = aens_test_utils:set_account_balance(PubKey, 0, S1),
    Trees2 = aens_test_utils:trees(S2),
    TxSpec2 = aens_test_utils:claim_tx_spec(PubKey, Name, NameSalt, S1),
    {ok, Tx2} = aens_claim_tx:new(TxSpec2),
    {error, insufficient_funds} = aetx:process(Tx2, Trees2, Env),

    %% Test too high account nonce
    TxSpec3 = aens_test_utils:claim_tx_spec(PubKey, Name, NameSalt, #{nonce => 0}, S1),
    {ok, Tx3} = aens_claim_tx:new(TxSpec3),
    {error, account_nonce_too_high} = aetx:process(Tx3, Trees, Env),

    %% Test commitment not found
    TxSpec4 = aens_test_utils:claim_tx_spec(PubKey, Name, NameSalt + 1, S1),
    {ok, Tx4} = aens_claim_tx:new(TxSpec4),
    {error, name_not_preclaimed} = aetx:process(Tx4, Trees, Env),

    %% Test commitment not owned
    {PubKey2, S3} = aens_test_utils:setup_new_account(S1),
    Trees3 = aens_test_utils:trees(S3),
    TxSpec5 = aens_test_utils:claim_tx_spec(PubKey2, Name, NameSalt, S3),
    {ok, Tx5} = aens_claim_tx:new(TxSpec5),
    {error, commitment_not_owned} = aetx:process(Tx5, Trees3, Env),

    %% Test bad name
    TxSpec6 = aens_test_utils:claim_tx_spec(PubKey, <<"abcdefghi">>, NameSalt, S1),
    {ok, Tx6} = aens_claim_tx:new(TxSpec6),
    {error, no_registrar} = aetx:process(Tx6, Trees, Env),
    ok.

claim_race_negative(_Cfg) ->
    %% The first claim
    {_PubKey, _NHash, S1} = claim([{name, ?NAME}]),

    %% The second claim of the same name (hardcoded in preclaim) decomposed
    {PubKey2, Name2, NameSalt2, S2} = preclaim([{name, ?NAME}, {state, S1}]),
    Trees = aens_test_utils:trees(S2),
    Height = ?PRE_CLAIM_HEIGHT + 1,

    %% Test bad account key
    TxSpec1 = aens_test_utils:claim_tx_spec(PubKey2, Name2, NameSalt2, S2),
    {ok, Tx1} = aens_claim_tx:new(TxSpec1),
    Env = aetx_env:tx_env(Height),
    {error, name_already_taken} = aetx:process(Tx1, Trees, Env).

%%%===================================================================
%%% Update
%%%===================================================================

update(Cfg) ->
    {PubKey, NHash, S1} = claim(Cfg),
    Trees = aens_test_utils:trees(S1),
    Height = ?PRE_CLAIM_HEIGHT+1,
    PrivKey = aens_test_utils:priv_key(PubKey, S1),

    %% Check name present, but neither pointers nor name TTL set
    {value, N} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees)),
    [] = aens_names:pointers(N),
    0  = aens_names:client_ttl(N),

    %% Create Update tx and apply it on trees
    Pointers = [aens_pointer:new(<<"account_pubkey">>, aeser_id:create(account, <<1:256>>))],
    NameTTL  = 40000,
    TxSpec = aens_test_utils:update_tx_spec(
               PubKey, NHash, #{pointers => Pointers, name_ttl => NameTTL}, S1),
    {ok, Tx} = aens_update_tx:new(TxSpec),
    SignedTx = aec_test_utils:sign_tx(Tx, PrivKey),
    Env      = aetx_env:tx_env(Height),
    {ok, [SignedTx], Trees1, _} =
        aec_block_micro_candidate:apply_block_txs([SignedTx], Trees, Env),

    %% Check name present, with both pointers and TTL set
    {value, N1} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees1)),
    Pointers = aens_names:pointers(N1),
    NameTTL  = aens_names:ttl(N1) - Height,
    ok.

update_negative(Cfg) ->
    {PubKey, NHash, S1} = claim(Cfg),
    Trees = aens_test_utils:trees(S1),
    Height = ?PRE_CLAIM_HEIGHT + 1,
    Env = aetx_env:tx_env(Height),

    %% Test TX TTL too low
    MaxTTL = aec_governance:name_claim_max_expiration(),
    TxSpec0 = aens_test_utils:update_tx_spec(PubKey, NHash, #{ttl => Height - 1}, S1),
    {ok, Tx0} = aens_update_tx:new(TxSpec0),
    {error, ttl_expired} = aetx:process(Tx0, Trees, Env),

    %% Test name TTL too high
    MaxTTL = aec_governance:name_claim_max_expiration(),
    TxSpec1 = aens_test_utils:update_tx_spec(PubKey, NHash, #{name_ttl => MaxTTL + 1}, S1),
    {ok, Tx1} = aens_update_tx:new(TxSpec1),
    {error, ttl_too_high} = aetx:process(Tx1, Trees, Env),

    %% Test bad account key
    BadPubKey = <<42:32/unit:8>>,
    TxSpec2 = aens_test_utils:update_tx_spec(BadPubKey, NHash, S1),
    {ok, Tx2} = aens_update_tx:new(TxSpec2),
    {error, account_not_found} = aetx:process(Tx2, Trees, Env),

    %% Insufficient funds
    S2 = aens_test_utils:set_account_balance(PubKey, 0, S1),
    Trees2 = aens_test_utils:trees(S2),
    TxSpec3 = aens_test_utils:update_tx_spec(PubKey, NHash, S1),
    {ok, Tx3} = aens_update_tx:new(TxSpec3),
    {error, insufficient_funds} = aetx:process(Tx3, Trees2, Env),

    %% Test too high account nonce
    TxSpec4 = aens_test_utils:update_tx_spec(PubKey, NHash, #{nonce => 0}, S1),
    {ok, Tx4} = aens_update_tx:new(TxSpec4),
    {error, account_nonce_too_high} = aetx:process(Tx4, Trees, Env),

    %% Test name not present
    {ok, NHash2} = aens:get_name_hash(<<"othername.test">>),
    TxSpec5 = aens_test_utils:update_tx_spec(PubKey, NHash2, S1),
    {ok, Tx5} = aens_update_tx:new(TxSpec5),
    {error, name_does_not_exist} = aetx:process(Tx5, Trees, Env),

    %% Test name not owned
    {PubKey2, S3} = aens_test_utils:setup_new_account(S1),
    Trees3 = aens_test_utils:trees(S3),
    TxSpec6 = aens_test_utils:update_tx_spec(PubKey2, NHash, S3),
    {ok, Tx6} = aens_update_tx:new(TxSpec6),
    {error, name_not_owned} = aetx:process(Tx6, Trees3, Env),

    %% Test name revoked
    {value, N} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees)),
    S4 = aens_test_utils:revoke_name(N, S1),

    TxSpec7 = aens_test_utils:update_tx_spec(PubKey, NHash, S4),
    {ok, Tx7} = aens_update_tx:new(TxSpec7),
    {error, name_revoked} =
        aetx:process(Tx7, aens_test_utils:trees(S4), Env),
    ok.

%%%===================================================================
%%% Transfer
%%%===================================================================

transfer(Cfg) ->
    {PubKey, NHash, S1} = claim(Cfg),
    Trees = aens_test_utils:trees(S1),
    Height = ?PRE_CLAIM_HEIGHT+1,
    PrivKey = aens_test_utils:priv_key(PubKey, S1),

    %% Check name present
    {value, N} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees)),
    PubKey = aens_names:owner_pubkey(N),

    %% Create Transfer tx and apply it on trees
    {PubKey2, S2} = aens_test_utils:setup_new_account(S1),
    Trees1 = aens_test_utils:trees(S2),
    TxSpec = aens_test_utils:transfer_tx_spec(
               PubKey, NHash, PubKey2, S1),
    {ok, Tx} = aens_transfer_tx:new(TxSpec),
    SignedTx = aec_test_utils:sign_tx(Tx, PrivKey),
    Env      = aetx_env:tx_env(Height),
    {ok, [SignedTx], Trees2, _} =
        aec_block_micro_candidate:apply_block_txs([SignedTx], Trees1, Env),

    %% Check name new owner
    {value, N1} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees2)),
    PubKey2 = aens_names:owner_pubkey(N1),
    ok.

transfer_negative(Cfg) ->
    {PubKey, NHash, S1} = claim(Cfg),
    Trees = aens_test_utils:trees(S1),
    Height = ?PRE_CLAIM_HEIGHT+1,
    Env = aetx_env:tx_env(Height),

    %% Test bad account key
    BadPubKey = <<42:32/unit:8>>,
    TxSpec1 = aens_test_utils:transfer_tx_spec(BadPubKey, NHash, PubKey, S1),
    {ok, Tx1} = aens_transfer_tx:new(TxSpec1),
    {error, account_not_found} = aetx:process(Tx1, Trees, Env),

    %% Insufficient funds
    S2 = aens_test_utils:set_account_balance(PubKey, 0, S1),
    Trees2 = aens_test_utils:trees(S2),
    TxSpec2 = aens_test_utils:transfer_tx_spec(PubKey, NHash, PubKey, S1),
    {ok, Tx2} = aens_transfer_tx:new(TxSpec2),
    {error, insufficient_funds} = aetx:process(Tx2, Trees2, Env),

    %% Test too high account nonce
    TxSpec3 = aens_test_utils:transfer_tx_spec(PubKey, NHash, PubKey, #{nonce => 0}, S1),
    {ok, Tx3} = aens_transfer_tx:new(TxSpec3),
    {error, account_nonce_too_high} = aetx:process(Tx3, Trees, Env),

    %% Test name not present
    {ok, NHash2} = aens:get_name_hash(<<"othername.test">>),
    TxSpec4 = aens_test_utils:transfer_tx_spec(PubKey, NHash2, PubKey, S1),
    {ok, Tx4} = aens_transfer_tx:new(TxSpec4),
    {error, name_does_not_exist} = aetx:process(Tx4, Trees, Env),

    %% Test name not owned
    {PubKey2, S3} = aens_test_utils:setup_new_account(S1),
    Trees3 = aens_test_utils:trees(S3),
    TxSpec5 = aens_test_utils:transfer_tx_spec(PubKey2, NHash, PubKey, S3),
    {ok, Tx5} = aens_transfer_tx:new(TxSpec5),
    {error, name_not_owned} = aetx:process(Tx5, Trees3, Env),

    %% Test name revoked
    {value, N} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees)),
    S4 = aens_test_utils:revoke_name(N, S1),

    TxSpec6 = aens_test_utils:transfer_tx_spec(PubKey, NHash, PubKey, S4),
    {ok, Tx6} = aens_transfer_tx:new(TxSpec6),
    {error, name_revoked} =
        aetx:process(Tx6, aens_test_utils:trees(S4), Env),
    ok.

%%%===================================================================
%%% Revoke
%%%===================================================================

revoke(Cfg) ->
    {PubKey, NHash, S1} = claim(Cfg),
    Trees = aens_test_utils:trees(S1),
    Height = ?PRE_CLAIM_HEIGHT+1,
    PrivKey = aens_test_utils:priv_key(PubKey, S1),

    %% Check name present
    {value, N} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees)),
    claimed = aens_names:status(N),

    %% Create Transfer tx and apply it on trees
    TxSpec = aens_test_utils:revoke_tx_spec(PubKey, NHash, S1),
    {ok, Tx} = aens_revoke_tx:new(TxSpec),
    SignedTx = aec_test_utils:sign_tx(Tx, PrivKey),
    Env      = aetx_env:tx_env(Height),
    {ok, [SignedTx], Trees1, _} =
        aec_block_micro_candidate:apply_block_txs([SignedTx], Trees, Env),

    %% Check name revoked
    {value, N1} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees1)),
    revoked = aens_names:status(N1),
    ok.

revoke_negative(Cfg) ->
    {PubKey, NHash, S1} = claim(Cfg),
    Trees = aens_test_utils:trees(S1),
    Height = ?PRE_CLAIM_HEIGHT+1,
    Env = aetx_env:tx_env(Height),

    %% Test bad account key
    BadPubKey = <<42:32/unit:8>>,
    TxSpec1 = aens_test_utils:revoke_tx_spec(BadPubKey, NHash, S1),
    {ok, Tx1} = aens_revoke_tx:new(TxSpec1),
    {error, account_not_found} = aetx:process(Tx1, Trees, Env),

    %% Insufficient funds
    S2 = aens_test_utils:set_account_balance(PubKey, 0, S1),
    Trees2 = aens_test_utils:trees(S2),
    TxSpec2 = aens_test_utils:revoke_tx_spec(PubKey, NHash, S1),
    {ok, Tx2} = aens_revoke_tx:new(TxSpec2),
    {error, insufficient_funds} = aetx:process(Tx2, Trees2, Env),

    %% Test too high account nonce
    TxSpec3 = aens_test_utils:revoke_tx_spec(PubKey, NHash, #{nonce => 0}, S1),
    {ok, Tx3} = aens_revoke_tx:new(TxSpec3),
    {error, account_nonce_too_high} = aetx:process(Tx3, Trees, Env),

    %% Test name not present
    {ok, NHash2} = aens:get_name_hash(<<"othername.test">>),
    TxSpec4 = aens_test_utils:revoke_tx_spec(PubKey, NHash2, S1),
    {ok, Tx4} = aens_revoke_tx:new(TxSpec4),
    {error, name_does_not_exist} = aetx:process(Tx4, Trees, Env),

    %% Test name not owned
    {PubKey2, S3} = aens_test_utils:setup_new_account(S1),
    Trees3 = aens_test_utils:trees(S3),
    TxSpec5 = aens_test_utils:revoke_tx_spec(PubKey2, NHash, S3),
    {ok, Tx5} = aens_revoke_tx:new(TxSpec5),
    {error, name_not_owned} = aetx:process(Tx5, Trees3, Env),

    %% Test name already revoked
    {value, N} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees)),
    S4 = aens_test_utils:revoke_name(N, S1),

    TxSpec6 = aens_test_utils:revoke_tx_spec(PubKey, NHash, S4),
    {ok, Tx6} = aens_revoke_tx:new(TxSpec6),
    {error, name_revoked} =
        aetx:process(Tx6, aens_test_utils:trees(S4), Env),
    ok.

%%%===================================================================
%%% Prune names and commitments
%%%===================================================================

prune_preclaim(Cfg) ->
    {PubKey, Name, NameSalt, S1} = preclaim(Cfg),
    {ok, NameAscii} = aens_utils:to_ascii(Name),
    CHash = aens_hash:commitment_hash(NameAscii, NameSalt),
    Trees2 = aens_test_utils:trees(S1),
    {value, C} = aens_state_tree:lookup_commitment(CHash, aec_trees:ns(Trees2)),
    CHash      = aens_commitments:hash(C),
    PubKey     = aens_commitments:owner_pubkey(C),

    TTL = aens_commitments:ttl(C),
    GenesisHeight = aec_block_genesis:height(),
    NSTree = do_prune_until(GenesisHeight, TTL + 1, aec_trees:ns(Trees2)),
    none = aens_state_tree:lookup_commitment(CHash, NSTree),
    ok.

prune_claim(Cfg) ->
    {PubKey, NHash, S2} = claim(Cfg),

    %% Re-pull values for this test
    Trees2 = aens_test_utils:trees(S2),
    NTrees = aec_trees:ns(Trees2),
    {value, N} = aens_state_tree:lookup_name(NHash, NTrees),

    NHash    = aens_names:hash(N),
    PubKey   = aens_names:owner_pubkey(N),
    claimed  = aens_names:status(N),
    TTL1     = aens_names:ttl(N),


    NTree2 = aens_state_tree:prune(TTL1+1, NTrees),
    {value, N2} = aens_state_tree:lookup_name(NHash, NTree2),
    NHash    = aens_names:hash(N2),
    PubKey   = aens_names:owner_pubkey(N2),
    revoked  = aens_names:status(N2),
    TTL2     = aens_names:ttl(N2),

    NTree3 = aens_state_tree:prune(TTL2+1, NTree2),
    none = aens_state_tree:lookup_name(NHash, NTree3),

    {PubKey, NHash, S2}.

do_prune_until(N1, N1, OTree) ->
    aens_state_tree:prune(N1, OTree);
do_prune_until(N1, N2, OTree) ->
    do_prune_until(N1 + 1, N2, aens_state_tree:prune(N1, OTree)).


%%%===================================================================
%%% Subdomain
%%%===================================================================

-define(TOPNAME, <<"姆.test"/utf8>>).
-define(SNAME1, <<"斯1.姆.test"/utf8>>).
-define(SNAME2, <<"姆2.姆.test"/utf8>>).
-define(SNAME21, <<"姆2.斯1.姆.test"/utf8>>).
-define(SNAME54321, <<"詹5.斯4.詹3.姆2.斯1.姆.test"/utf8>>).

-define(SNAME321, <<"詹3.姆2.斯1.姆.test"/utf8>>).
-define(SNAME4321, <<"斯4.詹3.姆2.斯1.姆.test"/utf8>>).

subdomain_claim(_Cfg) ->
    Name = ?TOPNAME,
    {PubKey, NHash, S1} = claim([{name, Name}]),
    Trees = aens_test_utils:trees(S1),
    PrivKey = aens_test_utils:priv_key(PubKey, S1),

    {value, _N} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees)),

    SomePK = <<120,245,0,157,97,46,5,228,60,175,19,76,43,124,69,10,211,
               83,150,252,193,30,36,223,45,221,175,102,48,84,118,31>>,
    SomeId = aeser_id:create(account, SomePK),

    SubnamesDef =
        #{?SNAME1 => #{<<"sub1_acc">> => SomeId},
          ?SNAME2 => #{},
          ?SNAME21 => #{},
          ?SNAME54321 => #{<<"sub54321_acc">> => SomeId}},

    SubnameTxSpec = aens_test_utils:subname_tx_spec(PubKey, Name, SubnamesDef, S1),
    {ok, SubnameTx} = aens_subname_tx:new(SubnameTxSpec),

    SignedSubnameTx = aec_test_utils:sign_tx(SubnameTx, PrivKey),

    Env = aetx_env:tx_env(2),

    {ok, [SignedSubnameTx], Trees1, _} =
        aec_block_micro_candidate:apply_block_txs([SignedSubnameTx], Trees, Env),
    S2 = aens_test_utils:set_trees(Trees1, S1),

    NTrees1 = aec_trees:ns(Trees1),

    %% these were defined:
    {ok, SNameAscii1} = aens_utils:name_to_ascii(?SNAME1),
    SNameHash1 = aens_hash:name_hash(SNameAscii1),
    {value, SName1} = aens_state_tree:lookup_name(SNameHash1, NTrees1),
    [Ptr1] = aens_subnames:pointers(SName1),
    <<"sub1_acc">> = aens_pointer:key(Ptr1),
    SomeId = aens_pointer:id(Ptr1),

    {ok, SNameAscii2} = aens_utils:name_to_ascii(?SNAME2),
    SNameHash2 = aens_hash:name_hash(SNameAscii2),
    {value, SName2} = aens_state_tree:lookup_name(SNameHash2, NTrees1),
    [] = aens_subnames:pointers(SName2),

    {ok, SNameAscii21} = aens_utils:name_to_ascii(?SNAME21),
    SNameHash21 = aens_hash:name_hash(SNameAscii21),
    {value, SName21} = aens_state_tree:lookup_name(SNameHash21, NTrees1),
    [] = aens_subnames:pointers(SName21),

    {ok, SNameAscii54321} = aens_utils:name_to_ascii(?SNAME54321),
    SNameHash54321 = aens_hash:name_hash(SNameAscii54321),
    {value, SName54321} = aens_state_tree:lookup_name(SNameHash54321, NTrees1),
    [Ptr54321] = aens_subnames:pointers(SName54321),
    <<"sub54321_acc">> = aens_pointer:key(Ptr54321),
    SomeId = aens_pointer:id(Ptr54321),

    %% these were added to subname tree:
    {ok, SNameAscii321} = aens_utils:name_to_ascii(?SNAME321),
    SNameHash321 = aens_hash:name_hash(SNameAscii321),
    {value, SName321} = aens_state_tree:lookup_name(SNameHash321, NTrees1),
    [] = aens_subnames:pointers(SName321),

    {ok, SNameAscii4321} = aens_utils:name_to_ascii(?SNAME4321),
    SNameHash4321 = aens_hash:name_hash(SNameAscii4321),
    {value, SName4321} = aens_state_tree:lookup_name(SNameHash4321, NTrees1),
    [] = aens_subnames:pointers(SName4321),

    {SNameHashes, false} = aens_state_tree:subnames_hashes(NHash, NTrees1, all),

    [] = SNameHashes -- [SNameHash1, SNameHash2, SNameHash21, SNameHash54321, SNameHash321, SNameHash4321],


    %%%%%%%%%% empty Subnames TX

    EmptyDef = #{},

    SubnameTxSpec1 = aens_test_utils:subname_tx_spec(PubKey, Name, EmptyDef, S2),
    {ok, SubnameTx1} = aens_subname_tx:new(SubnameTxSpec1),

    SignedSubnameTx1 = aec_test_utils:sign_tx(SubnameTx1, PrivKey),

    Env1 = aetx_env:tx_env(3),

    {ok, [SignedSubnameTx1], Trees2, _} =
        aec_block_micro_candidate:apply_block_txs([SignedSubnameTx1], Trees1, Env1),
    _S3 = aens_test_utils:set_trees(Trees2, S2),

    NTrees2 = aec_trees:ns(Trees2),

    {[], false} = aens_state_tree:subnames_hashes(NHash, NTrees2, all),

    ok.




%% subdomain_claim(_Cfg) ->
%%     Name = <<"name.test">>,
%%     {PubKey, NHash, S1} = claim([{name, Name}]),
%%     Trees = aens_test_utils:trees(S1),
%%     PrivKey = aens_test_utils:priv_key(PubKey, S1),

%%     %% Check name present, but neither pointers nor name TTL set
%%     {value, _N} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees)),

%%     SomePK = <<120,245,0,157,97,46,5,228,60,175,19,76,43,124,69,10,211,
%%                83,150,252,193,30,36,223,45,221,175,102,48,84,118,31>>,
%%     SomeId = aeser_id:create(account, SomePK),

%%     SubnamesDef =
%%         #{<<"sub1.name.test">> => #{<<"sub1_acc">> => SomeId},
%%           <<"sub2.name.test">> => #{},
%%           <<"sub2.sub1.name.test">> => #{},
%%           <<"sub5.sub4.sub3.sub2.sub1.name.test">> => #{<<"sub54321_acc">> => SomeId}},

%%     SubnameTxSpec = aens_test_utils:subname_tx_spec(PubKey, Name, SubnamesDef, S1),
%%     {ok, SubnameTx} = aens_subname_tx:new(SubnameTxSpec),

%%     SignedSubnameTx = aec_test_utils:sign_tx(SubnameTx, PrivKey),

%%     Env = aetx_env:tx_env(2),

%%     {ok, [SignedSubnameTx], Trees1, _} =
%%         aec_block_micro_candidate:apply_block_txs([SignedSubnameTx], Trees, Env),
%%     _S2 = aens_test_utils:set_trees(Trees1, S1),

%%     NTrees1 = aec_trees:ns(Trees1),

%%     %% these were defined:
%%     {ok, SNameAscii1} = aens_utils:name_to_ascii(<<"sub1.name.test">>),
%%     SNameHash1 = aens_hash:name_hash(SNameAscii1),
%%     {value, SName1} = aens_state_tree:lookup_name(SNameHash1, NTrees1),
%%     [Ptr1] = aens_subnames:pointers(SName1),
%%     <<"sub1_acc">> = aens_pointer:key(Ptr1),
%%     SomeId = aens_pointer:id(Ptr1),

%%     {ok, SNameAscii2} = aens_utils:name_to_ascii(<<"sub2.name.test">>),
%%     SNameHash2 = aens_hash:name_hash(SNameAscii2),
%%     {value, SName2} = aens_state_tree:lookup_name(SNameHash2, NTrees1),
%%     [] = aens_subnames:pointers(SName2),

%%     {ok, SNameAscii21} = aens_utils:name_to_ascii(<<"sub2.sub1.name.test">>),
%%     SNameHash21 = aens_hash:name_hash(SNameAscii21),
%%     {value, SName21} = aens_state_tree:lookup_name(SNameHash21, NTrees1),
%%     [] = aens_subnames:pointers(SName21),

%%     {ok, SNameAscii54321} = aens_utils:name_to_ascii(<<"sub5.sub4.sub3.sub2.sub1.name.test">>),
%%     SNameHash54321 = aens_hash:name_hash(SNameAscii54321),
%%     {value, SName54321} = aens_state_tree:lookup_name(SNameHash54321, NTrees1),
%%     [Ptr54321] = aens_subnames:pointers(SName54321),
%%     <<"sub54321_acc">> = aens_pointer:key(Ptr54321),
%%     SomeId = aens_pointer:id(Ptr54321),

%%     %% these were added to subname tree:
%%     {ok, SNameAscii321} = aens_utils:name_to_ascii(<<"sub3.sub2.sub1.name.test">>),
%%     SNameHash321 = aens_hash:name_hash(SNameAscii321),
%%     {value, SName321} = aens_state_tree:lookup_name(SNameHash321, NTrees1),
%%     [] = aens_subnames:pointers(SName321),

%%     {ok, SNameAscii4321} = aens_utils:name_to_ascii(<<"sub4.sub3.sub2.sub1.name.test">>),
%%     SNameHash4321 = aens_hash:name_hash(SNameAscii4321),
%%     {value, SName4321} = aens_state_tree:lookup_name(SNameHash4321, NTrees1),
%%     [] = aens_subnames:pointers(SName4321),

%%     {SNameHashes, false} = aens_state_tree:subnames_hashes(NHash, NTrees1, all),

%%     [] = SNameHashes -- [SNameHash1, SNameHash2, SNameHash21, SNameHash54321, SNameHash321, SNameHash4321],

%%     ok.




















%% subdomain_claim_with_preclaim(_Cfg) ->
%%     {PubKey, NHash, S1} = claim([{name, ?NAME2}]),
%%     Trees = aens_test_utils:trees(S1),
%%     PrivKey = aens_test_utils:priv_key(PubKey, S1),

%%     %% Check name present, but neither pointers nor name TTL set
%%     {value, N} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees)),
%%     [] = aens_names:pointers(N),
%%     0  = aens_names:client_ttl(N),

%%     %% Preclaim Subdomain
%%     SName = ?SUBNAME2,
%%     SNameSalt = rand:uniform(10000),
%%     {ok, SNameAscii} = aens_utils:to_ascii(SName),
%%     SubCHash = aens_hash:commitment_hash(SNameAscii, SNameSalt),

%%     PreclaimTxSpec = aens_test_utils:preclaim_tx_spec(PubKey, SubCHash, S1),
%%     {ok, PreclaimTx} = aens_preclaim_tx:new(PreclaimTxSpec),
%%     PreclaimSignedTx = aec_test_utils:sign_tx(PreclaimTx, PrivKey),
%%     Env2 = aetx_env:tx_env(?PRE_CLAIM_HEIGHT + 1),
%%     {ok, [PreclaimSignedTx], Trees1, _} =
%%         aec_block_micro_candidate:apply_block_txs([PreclaimSignedTx], Trees, Env2),
%%     S2 = aens_test_utils:set_trees(Trees1, S1),

%%     %% Check commitment created
%%     Trees2 = aens_test_utils:trees(S2),
%%     {value, SC} = aens_state_tree:lookup_commitment(SubCHash, aec_trees:ns(Trees2)),
%%     SubCHash   = aens_commitments:hash(SC),
%%     PubKey     = aens_commitments:owner_pubkey(SC),

%%     %% Claim Subdomain
%%     ClaimTxSpec = aens_test_utils:claim_tx_spec(PubKey, SName, SNameSalt, S2),
%%     {ok, ClaimTx} = aens_claim_tx:new(ClaimTxSpec),
%%     ClaimSignedTx = aec_test_utils:sign_tx(ClaimTx, PrivKey),
%%     Env3      = aetx_env:tx_env(?PRE_CLAIM_HEIGHT + 2),

%%     {ok, [ClaimSignedTx], Trees3, _} =
%%         aec_block_micro_candidate:apply_block_txs([ClaimSignedTx], Trees2, Env3),
%%     S3 = aens_test_utils:set_trees(Trees3, S2),

%%     %% Check commitment removed and name entry added
%%     Trees3 = aens_test_utils:trees(S3),
%%     NTrees3 = aec_trees:ns(Trees3),
%%     none      = aens_state_tree:lookup_commitment(SubCHash, NTrees3),
%%     SNameHash = aens_hash:name_hash(SNameAscii),
%%     {value, _NameRec} = aens_state_tree:lookup_name(SNameHash, NTrees3),
%%     [_] = aens_state_tree:subname_list(NTrees3),
%%     {PubKey, NHash, SNameHash, S3}.

%% prune_subdomain_claim_with_preclaim(Cfg) ->
%%     {_PubKey, NHash, SHash, S} = subdomain_claim_with_preclaim(Cfg),
%%     Trees = aens_test_utils:trees(S),
%%     NTrees = aec_trees:ns(Trees),
%%     {value, N} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees)),
%%     DomainTTL = aens_names:ttl(N),

%%     NTrees1 = aens_state_tree:prune(DomainTTL + 1, NTrees),

%%     {value, N1} = aens_state_tree:lookup_name(NHash, NTrees1),

%%     revoked = aens_names:status(N1),
%%     RevokeTTL = aens_names:ttl(N1),

%%     NTrees2 = aens_state_tree:prune(RevokeTTL + 1, NTrees1),

%%     none = aens_state_tree:lookup_name(NHash, NTrees2),
%%     none = aens_state_tree:lookup_name(SHash, NTrees2).

%% revoke_domain_with_subdomains(Cfg) ->
%%     {PubKey, NHash, SHash, S} = subdomain_claim_with_preclaim(Cfg),
%%     Height = ?PRE_CLAIM_HEIGHT + 1,
%%     PrivKey = aens_test_utils:priv_key(PubKey, S),
%%     Trees = aens_test_utils:trees(S),
%%     NTrees = aec_trees:ns(Trees),

%%     %% Check name present
%%     {value, N} = aens_state_tree:lookup_name(NHash, NTrees),
%%     claimed = aens_names:status(N),

%%     %% Create Revoke tx and apply it on trees
%%     TxSpec = aens_test_utils:revoke_tx_spec(PubKey, NHash, S),
%%     {ok, Tx} = aens_revoke_tx:new(TxSpec),
%%     SignedTx = aec_test_utils:sign_tx(Tx, PrivKey),
%%     Env      = aetx_env:tx_env(Height),
%%     {ok, [SignedTx], Trees1, _} =
%%         aec_block_micro_candidate:apply_block_txs([SignedTx], Trees, Env),

%%     %% Check name revoked
%%     NTrees1 = aec_trees:ns(Trees1),
%%     {value, N1} = aens_state_tree:lookup_name(NHash, NTrees1),
%%     revoked = aens_names:status(N1),

%%     {error, name_revoked} = aens:name_hash_to_name_entry(SHash, NTrees1),

%%     RevokeTTL = aens_names:ttl(N1),
%%     NTrees2 = aens_state_tree:prune(RevokeTTL + 1, NTrees1),
%%     none = aens_state_tree:lookup_name(NHash, NTrees2),
%%     none = aens_state_tree:lookup_name(SHash, NTrees2).


%% subdomains_claim_without_preclaim(_Cfg) ->
%%     {PubKey, NHash, S} = claim([{name, ?NAME3}]),
%%     Trees = aens_test_utils:trees(S),
%%     PrivKey = aens_test_utils:priv_key(PubKey, S),

%%     %% Check name present, but neither pointers nor name TTL set
%%     {value, N} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees)),
%%     [] = aens_names:pointers(N),
%%     0  = aens_names:client_ttl(N),

%%     SNameA = ?SUBNAME3A,
%%     {ok, SNameAsciiA} = aens_utils:to_ascii(SNameA),

%%     %% Claim Subdomain SUBNAME3A
%%     ClaimTxSpecA = aens_test_utils:claim_tx_spec(PubKey, SNameA, 0, S),
%%     {ok, ClaimTxA} = aens_claim_tx:new(ClaimTxSpecA),
%%     ClaimSignedTxA = aec_test_utils:sign_tx(ClaimTxA, PrivKey),
%%     Env1 = aetx_env:tx_env(1),

%%     {ok, [ClaimSignedTxA], Trees1, _} =
%%         aec_block_micro_candidate:apply_block_txs([ClaimSignedTxA], Trees, Env1),
%%     S1 = aens_test_utils:set_trees(Trees1, S),

%%     %% Check entry added for SUBNAME3A
%%     Trees1 = aens_test_utils:trees(S1),
%%     NTrees1 = aec_trees:ns(Trees1),
%%     SNameHashA = aens_hash:name_hash(SNameAsciiA),
%%     {value, _} = aens_state_tree:lookup_name(SNameHashA, NTrees1),
%%     [_] = aens_state_tree:subname_list(NTrees1),


%%     SNameA2 = ?SUBNAME3A2,
%%     {ok, SNameAsciiA2} = aens_utils:to_ascii(SNameA2),

%%     %% Claim Nested Subdomain SUBNAME3A2
%%     ClaimTxSpecA2 = aens_test_utils:claim_tx_spec(PubKey, SNameA2, 0, S1),
%%     {ok, ClaimTxA2} = aens_claim_tx:new(ClaimTxSpecA2),
%%     ClaimSignedTxA2 = aec_test_utils:sign_tx(ClaimTxA2, PrivKey),
%%     Env2 = aetx_env:tx_env(2),

%%     {ok, [ClaimSignedTxA2], Trees2, _} =
%%         aec_block_micro_candidate:apply_block_txs([ClaimSignedTxA2], Trees1, Env2),
%%     S2 = aens_test_utils:set_trees(Trees2, S1),

%%     %% Check entry added for SUBNAME3A2
%%     Trees2 = aens_test_utils:trees(S2),
%%     NTrees2 = aec_trees:ns(Trees2),
%%     SNameHashA2 = aens_hash:name_hash(SNameAsciiA2),
%%     {value, _} = aens_state_tree:lookup_name(SNameHashA2, NTrees2),
%%     [_, _] = aens_state_tree:subname_list(NTrees2),


%%     SNameB = ?SUBNAME3B,
%%     {ok, SNameAsciiB} = aens_utils:to_ascii(SNameB),

%%     %% Claim Subdomain SUBNAME3B
%%     ClaimTxSpecB = aens_test_utils:claim_tx_spec(PubKey, SNameB, 0, S2),
%%     {ok, ClaimTxB} = aens_claim_tx:new(ClaimTxSpecB),
%%     ClaimSignedTxB = aec_test_utils:sign_tx(ClaimTxB, PrivKey),
%%     Env3 = aetx_env:tx_env(3),

%%     {ok, [ClaimSignedTxB], Trees3, _} =
%%         aec_block_micro_candidate:apply_block_txs([ClaimSignedTxB], Trees2, Env3),
%%     S3 = aens_test_utils:set_trees(Trees3, S2),

%%     %% Check entry added for SUBNAME3B
%%     Trees3 = aens_test_utils:trees(S3),
%%     NTrees3 = aec_trees:ns(Trees3),
%%     SNameHashB = aens_hash:name_hash(SNameAsciiB),
%%     {value, _} = aens_state_tree:lookup_name(SNameHashB, NTrees3),
%%     [_, _, _] = aens_state_tree:subname_list(NTrees3),

%%     {PubKey, NHash, SNameHashA, SNameHashA2, SNameHashB, S3}.

%% prune_subdomains_claim_without_preclaim(Cfg) ->
%%     {_PubKey, NHash, SHashA, SHashA2, SHashB, S} = subdomains_claim_without_preclaim(Cfg),

%%     Trees = aens_test_utils:trees(S),
%%     NTrees = aec_trees:ns(Trees),
%%     {value, N} = aens_state_tree:lookup_name(NHash, aec_trees:ns(Trees)),
%%     DomainTTL = aens_names:ttl(N),

%%     NTrees1 = aens_state_tree:prune(DomainTTL + 1, NTrees),

%%     {value, N1} = aens_state_tree:lookup_name(NHash, NTrees1),

%%     revoked = aens_names:status(N1),
%%     RevokeTTL = aens_names:ttl(N1),

%%     NTrees2 = aens_state_tree:prune(RevokeTTL + 1, NTrees1),

%%     none = aens_state_tree:lookup_name(NHash, NTrees2),
%%     none = aens_state_tree:lookup_name(SHashA, NTrees2),
%%     none = aens_state_tree:lookup_name(SHashA2, NTrees2),
%%     none = aens_state_tree:lookup_name(SHashB, NTrees2).
