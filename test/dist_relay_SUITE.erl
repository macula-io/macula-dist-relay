%%%-------------------------------------------------------------------
%%% @doc End-to-end integration test for the dist relay.
%%%
%%% Starts a dist-relay listener in the test VM on port 14434, then
%%% spins up two `macula_dist_relay_client' instances pointing at it.
%%% Verifies the full tunnel lifecycle:
%%%
%%%   identify → identified → tunnel_request → tunnel_ok → stream match
%%%     → bidirectional byte forwarding
%%%
%%% The test process acts as a fake net_kernel for the target client:
%%% it accepts the `{accept, SetupPid, Socket, inet, macula_dist}'
%%% message, replies with a controller assignment, and takes ownership
%%% of the stream on the receiving side. This mirrors exactly what a
%%% real dist-over-relay deployment does, without actually running
%%% Erlang distribution handshake.
%%% @end
%%%-------------------------------------------------------------------
-module(dist_relay_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([identify_handshake/1, tunnel_roundtrip/1, missing_target/1,
         reidentify_kicks_stale_handler/1]).

-define(RELAY_PORT, 14434).
-define(RELAY_URL, "127.0.0.1:14434").
-define(assert_different(A, B),
        case (A) =:= (B) of
            true  -> ct:fail({expected_different, A, B});
            false -> ok
        end).

%%====================================================================
%% Common Test callbacks
%%====================================================================

all() ->
    [
        identify_handshake,
        tunnel_roundtrip,
        missing_target,
        reidentify_kicks_stale_handler
    ].

init_per_suite(Config) ->
    os:putenv("MACULA_DIST_PORT", integer_to_list(?RELAY_PORT)),
    os:putenv("MACULA_TLS_MODE", "development"),
    logger:set_primary_config(level, debug),
    %% Use a test-specific cert dir so we don't clobber anything
    TlsDir = filename:join(proplists:get_value(priv_dir, Config), "tls"),
    ok = filelib:ensure_dir(filename:join(TlsDir, "dummy")),
    application:set_env(macula, cert_path, filename:join(TlsDir, "cert.pem")),
    application:set_env(macula, key_path, filename:join(TlsDir, "key.pem")),
    {ok, _} = application:ensure_all_started(macula),
    {ok, _} = application:ensure_all_started(macula_dist_relay),
    %% Give the listener a moment to bind
    timer:sleep(500),
    Config.

end_per_suite(_Config) ->
    application:stop(macula_dist_relay),
    application:stop(macula),
    ok.

%%====================================================================
%% Tests
%%====================================================================

%% @doc Client connects + sends identify, expects identified reply +
%% appears in the relay's router.
identify_handshake(_Config) ->
    {ok, Client} = macula_dist_relay_client:start_link(
        ?RELAY_URL, <<"alice_id@test">>),
    ok = wait_for_identified(Client, 50),
    ok = wait_for_router_node(<<"alice_id@test">>, 50),
    ok = gen_server:stop(Client),
    %% Router cleanup is async — relay's conn_handler terminates in
    %% response to QUIC close, then its terminate/2 unregisters.
    ok = wait_for_router_gone(<<"alice_id@test">>, 50).

%% @doc Two clients connect; one requests a tunnel to the other;
%% bytes flow bidirectionally through the tunnel.
tunnel_roundtrip(_Config) ->
    Alice = <<"alice_rt@test">>,
    Bob = <<"bob_rt@test">>,

    {ok, AliceClient} = macula_dist_relay_client:start_link(?RELAY_URL, Alice),
    {ok, BobClient} = start_client_with_different_name(?RELAY_URL, Bob),

    ok = wait_for_identified(AliceClient, 50),
    ok = wait_for_identified(BobClient, 50),

    %% Bob's side: test process plays net_kernel for inbound accept.
    TestPid = self(),
    ok = macula_dist_relay_client:set_kernel(BobClient, TestPid),

    %% Alice's requester must OWN the resulting stream (the client
    %% transferred ownership to the caller of request_tunnel). So the
    %% requester must stay alive and behave as the stream controller.
    Parent = self(),
    AliceCtrl = spawn_link(fun() ->
        Result = macula_dist_relay_client:request_tunnel(AliceClient, Bob),
        Parent ! {alice_got, Result},
        dist_ctrl_loop(<<>>)
    end),

    %% Bob's side: receive the {accept, ...} message, reply with a fake
    %% controller, wait for stream transfer.
    BobCtrl = spawn_link(fun() -> dist_ctrl_loop(<<>>) end),
    BobStream = receive_accept_and_transfer(BobCtrl, 5_000),

    %% Alice's side: should have gotten her tunnel
    AliceStream =
        receive
            {alice_got, {ok, _AliceConn, S}} -> S
        after 5_000 ->
            ct:fail(alice_tunnel_timeout)
        end,

    %% Alice → Bob
    AliceCtrl ! {send_bytes, AliceStream, <<"hello-from-alice">>},
    ok = wait_for_ctrl_bytes(BobCtrl, <<"hello-from-alice">>, 2_000),

    %% Bob → Alice
    BobCtrl ! {send_bytes, BobStream, <<"hello-from-bob">>},
    ok = wait_for_ctrl_bytes(AliceCtrl, <<"hello-from-bob">>, 2_000),

    %% Cleanup
    AliceCtrl ! stop,
    BobCtrl ! stop,
    ok = gen_server:stop(AliceClient),
    ok = gen_server:stop(BobClient),
    ok.

%% @doc Tunnel request to a node that isn't connected returns an error
%% instead of hanging.
missing_target(_Config) ->
    {ok, Client} = macula_dist_relay_client:start_link(
        ?RELAY_URL, <<"lonely@test">>),
    ok = wait_for_identified(Client, 50),
    {error, {tunnel_error, <<"target_not_connected">>}} =
        macula_dist_relay_client:request_tunnel(Client, <<"ghost@test">>),
    ok = gen_server:stop(Client).

%% @doc Re-identify replaces the stale conn_handler instead of silently
%% overwriting the ETS row. Simulates a peer that reconnects with the
%% same -name before the previous QUIC connection has timed out:
%%
%%   1. client1 identifies as 'twin@test' — router row points at handler_1
%%   2. client2 identifies as 'twin@test' — router replaces row with handler_2
%%      and casts `{replaced_by, handler_2}' to handler_1
%%   3. handler_1 stops normally without calling unregister_node
%%   4. router row still contains handler_2 (not wiped by handler_1's terminate)
reidentify_kicks_stale_handler(_Config) ->
    Twin = <<"twin@test">>,

    {ok, Client1} = start_client_with_different_name(?RELAY_URL, Twin),
    ok = wait_for_identified(Client1, 50),
    {ok, Handler1} = macula_dist_relay_router:lookup_node(Twin),

    {ok, Client2} = start_client_with_different_name(?RELAY_URL, Twin),
    ok = wait_for_identified(Client2, 50),

    %% Router row now points at handler_2, not handler_1.
    ok = wait_for_handler_change(Twin, Handler1, 50),
    {ok, Handler2} = macula_dist_relay_router:lookup_node(Twin),
    ?assert_different(Handler1, Handler2),

    %% handler_1 has been told to stand down — it should exit normally.
    ok = wait_for_dead(Handler1, 50),

    %% The new row survives handler_1's terminate/2 — i.e. handler_1
    %% did NOT call unregister_node on its way out.
    {ok, Handler2Again} = macula_dist_relay_router:lookup_node(Twin),
    Handler2Again = Handler2,

    ok = gen_server:stop(Client2),
    ok = wait_for_router_gone(Twin, 50),
    %% Client1's gen_server is long-dead (client died when relay closed
    %% its conn), but stop/1 against a dead pid is harmless.
    catch gen_server:stop(Client1),
    ok.

wait_for_handler_change(_Name, _OldPid, 0) ->
    {error, handler_unchanged};
wait_for_handler_change(Name, OldPid, N) ->
    check_handler_changed(macula_dist_relay_router:lookup_node(Name), Name, OldPid, N).

check_handler_changed({ok, NewPid}, _Name, OldPid, _N) when NewPid =/= OldPid ->
    ok;
check_handler_changed(_, Name, OldPid, N) ->
    timer:sleep(50),
    wait_for_handler_change(Name, OldPid, N - 1).

wait_for_dead(_Pid, 0) ->
    {error, still_alive};
wait_for_dead(Pid, N) ->
    check_dead(erlang:is_process_alive(Pid), Pid, N).

check_dead(false, _Pid, _N) -> ok;
check_dead(true, Pid, N) ->
    timer:sleep(50),
    wait_for_dead(Pid, N - 1).

%%====================================================================
%% Helpers
%%====================================================================

%% The client registers a local name `macula_dist_relay_client', so we
%% can only have one per VM. For tunnel_roundtrip we need two; start the
%% second unsupervised with a gen_server:start_link call that doesn't
%% register a name.
start_client_with_different_name(Url, NodeName) ->
    gen_server:start_link(macula_dist_relay_client,
                          {Url, NodeName, #{}}, []).

wait_for_identified(_Client, 0) ->
    {error, not_identified};
wait_for_identified(Client, N) ->
    check_identified(macula_dist_relay_client:status(Client), Client, N).

check_identified(#{identified := true}, _Client, _N) ->
    ok;
check_identified(_Status, Client, N) ->
    timer:sleep(50),
    wait_for_identified(Client, N - 1).

wait_for_router_node(_Name, 0) ->
    {error, not_registered};
wait_for_router_node(Name, N) ->
    check_router(macula_dist_relay_router:lookup_node(Name), Name, N).

check_router({ok, _Pid}, _Name, _N) -> ok;
check_router({error, not_found}, Name, N) ->
    timer:sleep(50),
    wait_for_router_node(Name, N - 1).

wait_for_router_gone(_Name, 0) ->
    {error, still_registered};
wait_for_router_gone(Name, N) ->
    check_router_gone(macula_dist_relay_router:lookup_node(Name), Name, N).

check_router_gone({error, not_found}, _Name, _N) -> ok;
check_router_gone({ok, _Pid}, Name, N) ->
    timer:sleep(50),
    wait_for_router_gone(Name, N - 1).

%% Act as net_kernel: receive {accept, SetupPid, Socket, inet, macula_dist},
%% reply with controller assignment, wait for ownership transfer.
receive_accept_and_transfer(DistCtrl, Timeout) ->
    receive
        {accept, SetupPid, {_Conn, Stream}, inet, macula_dist} ->
            SetupPid ! {self(), controller, DistCtrl},
            %% Setup process will now transfer ownership to DistCtrl and
            %% re-inject leftover bytes to DistCtrl, then exit normal.
            %% Tell DistCtrl which stream it just got.
            DistCtrl ! {stream_assigned, Stream},
            Stream
    after Timeout ->
        ct:fail({accept_timeout})
    end.

%% Test's fake dist controller: owns a stream, accumulates received
%% bytes, and sends when asked. The setup process sends it the
%% {SetupPid, controller, ok} handshake completion — we ignore it.
dist_ctrl_loop(Acc) ->
    receive
        {_SetupPid, controller, ok} ->
            dist_ctrl_loop(Acc);
        {stream_assigned, _Stream} ->
            dist_ctrl_loop(Acc);
        {quic, Data, _Stream, _Flags} when is_binary(Data) ->
            dist_ctrl_loop(<<Acc/binary, Data/binary>>);
        {send_bytes, Stream, Bytes} ->
            ok = macula_quic:send(Stream, Bytes),
            dist_ctrl_loop(Acc);
        {get_bytes, From} ->
            From ! {bytes, Acc},
            dist_ctrl_loop(Acc);
        stop ->
            ok
    end.

%% Poll a dist_ctrl_loop process via get_bytes until it has accumulated
%% exactly `Expected' bytes, or fail the test after Timeout ms.
wait_for_ctrl_bytes(Ctrl, Expected, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    poll_ctrl(Ctrl, Expected, Deadline).

poll_ctrl(Ctrl, Expected, Deadline) ->
    Ctrl ! {get_bytes, self()},
    receive
        {bytes, Got} ->
            compare_bytes(Got, Expected, Ctrl, Deadline)
    after 1_000 ->
        ct:fail({get_bytes_timeout, Ctrl})
    end.

compare_bytes(Expected, Expected, _Ctrl, _Deadline) ->
    ok;
compare_bytes(Got, Expected, Ctrl, Deadline) ->
    keep_polling(erlang:monotonic_time(millisecond) < Deadline,
                 Got, Expected, Ctrl, Deadline).

keep_polling(false, Got, Expected, _Ctrl, _Deadline) ->
    ct:fail({byte_mismatch, expected, Expected, got, Got});
keep_polling(true, _Got, Expected, Ctrl, Deadline) ->
    timer:sleep(50),
    poll_ctrl(Ctrl, Expected, Deadline).
