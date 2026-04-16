-module(macula_dist_relay_router_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test fixture — start/stop router gen_server
%%====================================================================

router_test_() ->
    {setup,
     fun() ->
         {ok, Pid} = macula_dist_relay_router:start_link(),
         Pid
     end,
     fun(Pid) ->
         gen_server:stop(Pid)
     end,
     fun(_Pid) ->
         [
          {"register and lookup node", fun register_lookup_node/0},
          {"lookup missing node", fun lookup_missing_node/0},
          {"unregister node", fun unregister_node/0},
          {"register and lookup tunnel", fun register_lookup_tunnel/0},
          {"unregister tunnel", fun unregister_tunnel/0},
          {"list nodes", fun list_nodes/0},
          {"list tunnels", fun list_tunnels/0},
          {"dead process cleanup", fun dead_process_cleanup/0}
         ]
     end}.

%%====================================================================
%% Node tests
%%====================================================================

register_lookup_node() ->
    ok = macula_dist_relay_router:register_node(<<"alice@host">>, self(), make_ref()),
    ?assertEqual({ok, self()}, macula_dist_relay_router:lookup_node(<<"alice@host">>)),
    %% Cleanup
    macula_dist_relay_router:unregister_node(<<"alice@host">>).

lookup_missing_node() ->
    ?assertEqual({error, not_found}, macula_dist_relay_router:lookup_node(<<"nonexistent">>)).

unregister_node() ->
    ok = macula_dist_relay_router:register_node(<<"bob@host">>, self(), make_ref()),
    macula_dist_relay_router:unregister_node(<<"bob@host">>),
    %% Cast is async, give it a moment
    timer:sleep(10),
    ?assertEqual({error, not_found}, macula_dist_relay_router:lookup_node(<<"bob@host">>)).

%%====================================================================
%% Tunnel tests
%%====================================================================

register_lookup_tunnel() ->
    Src = self(),
    Dest = self(),
    ok = macula_dist_relay_router:register_tunnel(<<"tun001">>, Src, Dest),
    ?assertEqual({ok, Src, Dest}, macula_dist_relay_router:lookup_tunnel(<<"tun001">>)),
    macula_dist_relay_router:unregister_tunnel(<<"tun001">>).

unregister_tunnel() ->
    ok = macula_dist_relay_router:register_tunnel(<<"tun002">>, self(), self()),
    macula_dist_relay_router:unregister_tunnel(<<"tun002">>),
    timer:sleep(10),
    ?assertEqual({error, not_found}, macula_dist_relay_router:lookup_tunnel(<<"tun002">>)).

%%====================================================================
%% List tests
%%====================================================================

list_nodes() ->
    ok = macula_dist_relay_router:register_node(<<"n1@h">>, self(), make_ref()),
    ok = macula_dist_relay_router:register_node(<<"n2@h">>, self(), make_ref()),
    Nodes = macula_dist_relay_router:list_nodes(),
    ?assert(lists:keymember(<<"n1@h">>, 1, Nodes)),
    ?assert(lists:keymember(<<"n2@h">>, 1, Nodes)),
    %% Cleanup
    macula_dist_relay_router:unregister_node(<<"n1@h">>),
    macula_dist_relay_router:unregister_node(<<"n2@h">>).

list_tunnels() ->
    ok = macula_dist_relay_router:register_tunnel(<<"t1">>, self(), self()),
    ok = macula_dist_relay_router:register_tunnel(<<"t2">>, self(), self()),
    Tunnels = macula_dist_relay_router:list_tunnels(),
    ?assert(length(Tunnels) >= 2),
    %% Cleanup
    macula_dist_relay_router:unregister_tunnel(<<"t1">>),
    macula_dist_relay_router:unregister_tunnel(<<"t2">>).

%%====================================================================
%% Process DOWN cleanup
%%====================================================================

dead_process_cleanup() ->
    %% Spawn a process, register it, then kill it
    Pid = spawn(fun() -> receive stop -> ok end end),
    ok = macula_dist_relay_router:register_node(<<"dying@host">>, Pid, make_ref()),
    ?assertEqual({ok, Pid}, macula_dist_relay_router:lookup_node(<<"dying@host">>)),
    %% Kill the process
    exit(Pid, kill),
    timer:sleep(50),
    %% lookup_node checks is_process_alive, so should return not_found
    ?assertEqual({error, not_found}, macula_dist_relay_router:lookup_node(<<"dying@host">>)).
