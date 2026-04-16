%%%-------------------------------------------------------------------
%%% @doc Supervisor for per-connection handler processes.
%%%
%%% One child per accepted QUIC connection. Children are `temporary'
%%% because a crashed connection handler means the node disconnected;
%%% it will reconnect and get a new handler.
%%% @end
%%%-------------------------------------------------------------------
-module(macula_dist_relay_conn_sup).

-behaviour(supervisor).

-export([start_link/0, start_handler/1]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_handler(reference()) -> {ok, pid()} | {error, term()}.
start_handler(Conn) ->
    supervisor:start_child(?MODULE, [Conn]).

init([]) ->
    SupFlags = #{
        strategy  => simple_one_for_one,
        intensity => 20,
        period    => 10
    },
    ChildSpec = #{
        id       => macula_dist_relay_conn_handler,
        start    => {macula_dist_relay_conn_handler, start_link, []},
        restart  => temporary,
        shutdown => 5000,
        type     => worker
    },
    {ok, {SupFlags, [ChildSpec]}}.
