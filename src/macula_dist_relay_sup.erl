%%%-------------------------------------------------------------------
%%% @doc Top-level supervisor for the dist relay.
%%%
%%% Children:
%%%   1. Router    — ETS route table (node-name → tunnel mapping)
%%%   2. Listener  — QUIC listener accepting node connections
%%%   3. TunnelSup — simple_one_for_one for per-tunnel forwarders
%%%
%%% Router starts first so the listener can register tunnels as
%%% soon as connections arrive.
%%% @end
%%%-------------------------------------------------------------------
-module(macula_dist_relay_sup).

-behaviour(supervisor).

-export([start_link/1, init/1]).

start_link(Port) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Port).

init(Port) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    Children = [
        #{
            id => macula_dist_relay_router,
            start => {macula_dist_relay_router, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker
        },
        #{
            id => macula_dist_relay_tunnel_sup,
            start => {macula_dist_relay_tunnel_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor
        },
        #{
            id => macula_dist_relay_listener,
            start => {macula_dist_relay_listener, start_link, [Port]},
            restart => permanent,
            shutdown => 5000,
            type => worker
        }
    ],
    {ok, {SupFlags, Children}}.
