%%%-------------------------------------------------------------------
%%% @doc Application behaviour for the dist relay.
%%% @end
%%%-------------------------------------------------------------------
-module(macula_dist_relay_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    Port = get_env_int("MACULA_DIST_PORT", 4434),
    macula_dist_relay_sup:start_link(Port).

stop(_State) ->
    ok.

get_env_int(Key, Default) ->
    case os:getenv(Key) of
        false -> Default;
        Val -> list_to_integer(Val)
    end.
