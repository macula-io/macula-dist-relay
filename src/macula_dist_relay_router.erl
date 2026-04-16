%%%-------------------------------------------------------------------
%%% @doc Route table for dist tunnels.
%%%
%%% Maps node names to their connections and active tunnel streams.
%%% When alice requests a tunnel to bob, the router:
%%%   1. Looks up bob's connection
%%%   2. Creates a route entry: {TunnelId, AliceStream, BobStream}
%%%   3. Notifies the tunnel forwarder to start byte-forwarding
%%%
%%% ETS table `dist_routes' is public for fast reads from tunnel
%%% forwarder processes. Writes go through the gen_server to
%%% serialize registration.
%%% @end
%%%-------------------------------------------------------------------
-module(macula_dist_relay_router).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0]).
-export([register_node/3, unregister_node/1, lookup_node/1]).
-export([register_tunnel/3, unregister_tunnel/1, lookup_tunnel/1]).
-export([list_nodes/0, list_tunnels/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(NODES_TAB, dist_relay_nodes).
-define(TUNNELS_TAB, dist_relay_tunnels).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register_node(binary(), pid(), reference()) -> ok.
register_node(NodeName, ConnPid, ConnRef) ->
    gen_server:call(?MODULE, {register_node, NodeName, ConnPid, ConnRef}).

-spec unregister_node(binary()) -> ok.
unregister_node(NodeName) ->
    gen_server:cast(?MODULE, {unregister_node, NodeName}).

-spec lookup_node(binary()) -> {ok, pid()} | {error, not_found}.
lookup_node(NodeName) ->
    case ets:lookup(?NODES_TAB, NodeName) of
        [{_, ConnPid, _}] ->
            case is_process_alive(ConnPid) of
                true -> {ok, ConnPid};
                false -> {error, not_found}
            end;
        [] ->
            {error, not_found}
    end.

-spec register_tunnel(binary(), pid(), pid()) -> ok.
register_tunnel(TunnelId, SourceStream, DestStream) ->
    gen_server:call(?MODULE, {register_tunnel, TunnelId, SourceStream, DestStream}).

-spec unregister_tunnel(binary()) -> ok.
unregister_tunnel(TunnelId) ->
    gen_server:cast(?MODULE, {unregister_tunnel, TunnelId}).

-spec lookup_tunnel(binary()) -> {ok, pid(), pid()} | {error, not_found}.
lookup_tunnel(TunnelId) ->
    case ets:lookup(?TUNNELS_TAB, TunnelId) of
        [{_, Source, Dest}] -> {ok, Source, Dest};
        [] -> {error, not_found}
    end.

-spec list_nodes() -> [{binary(), pid()}].
list_nodes() ->
    [{Name, Pid} || {Name, Pid, _} <- ets:tab2list(?NODES_TAB)].

-spec list_tunnels() -> [{binary(), pid(), pid()}].
list_tunnels() ->
    ets:tab2list(?TUNNELS_TAB).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    ets:new(?NODES_TAB, [named_table, public, set, {read_concurrency, true}]),
    ets:new(?TUNNELS_TAB, [named_table, public, set, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({register_node, NodeName, ConnPid, ConnRef}, _From, State) ->
    ets:insert(?NODES_TAB, {NodeName, ConnPid, ConnRef}),
    ?LOG_INFO("[router] Node registered: ~s (~p)", [NodeName, ConnPid]),
    {reply, ok, State};

handle_call({register_tunnel, TunnelId, Source, Dest}, _From, State) ->
    ets:insert(?TUNNELS_TAB, {TunnelId, Source, Dest}),
    ?LOG_INFO("[router] Tunnel registered: ~s", [TunnelId]),
    {reply, ok, State};

handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({unregister_node, NodeName}, State) ->
    ets:delete(?NODES_TAB, NodeName),
    ?LOG_INFO("[router] Node unregistered: ~s", [NodeName]),
    {noreply, State};

handle_cast({unregister_tunnel, TunnelId}, State) ->
    ets:delete(?TUNNELS_TAB, TunnelId),
    ?LOG_INFO("[router] Tunnel unregistered: ~s", [TunnelId]),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, Reason}, State) ->
    %% Clean up any nodes/tunnels owned by the dead process.
    Nodes = ets:match_object(?NODES_TAB, {'_', Pid, '_'}),
    lists:foreach(fun({Name, _, _}) ->
        ?LOG_INFO("[router] Node ~s disconnected: ~p", [Name, Reason]),
        ets:delete(?NODES_TAB, Name)
    end, Nodes),
    {noreply, State};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
