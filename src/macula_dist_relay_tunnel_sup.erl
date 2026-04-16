%%%-------------------------------------------------------------------
%%% @doc Supervisor for per-tunnel stream forwarder processes.
%%%
%%% One child per active tunnel. Each forwarder owns one direction
%%% of the byte stream (source → dest). Tunnels are bidirectional,
%%% so each tunnel has TWO forwarder children.
%%%
%%% Children are `temporary' — a crashed forwarder means a broken
%%% tunnel; the dist connection will drop and the nodes reconnect.
%%% @end
%%%-------------------------------------------------------------------
-module(macula_dist_relay_tunnel_sup).

-behaviour(supervisor).

-export([start_link/0, start_forwarder/3]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_forwarder(binary(), reference(), reference()) ->
    {ok, pid()} | {error, term()}.
start_forwarder(TunnelId, SourceStream, DestStream) ->
    supervisor:start_child(?MODULE, [TunnelId, SourceStream, DestStream]).

init([]) ->
    SupFlags = #{
        strategy  => simple_one_for_one,
        intensity => 10,
        period    => 10
    },
    ChildSpec = #{
        id       => macula_dist_relay_forwarder,
        start    => {macula_dist_relay_forwarder, start_link, []},
        restart  => temporary,
        shutdown => 5000,
        type     => worker
    },
    {ok, {SupFlags, [ChildSpec]}}.
