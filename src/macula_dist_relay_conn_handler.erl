%%%-------------------------------------------------------------------
%%% @doc Per-connection handler for dist relay.
%%%
%%% One handler per accepted QUIC connection. Owns:
%%%   - The QUIC connection reference
%%%   - Stream 0 (control channel)
%%%   - List of active tunnel IDs for cleanup on disconnect
%%%
%%% Lifecycle:
%%%   1. Listener accepts connection, starts this handler
%%%   2. Handler accepts stream 0 and waits for identify message
%%%   3. On identify: registers node in router, replies identified
%%%   4. Handles tunnel_request/tunnel_close on stream 0
%%%   5. On connection loss: cleans up all tunnels + router entry
%%% @end
%%%-------------------------------------------------------------------
-module(macula_dist_relay_conn_handler).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    conn         :: reference(),
    control      :: reference() | undefined,
    node_name    :: binary() | undefined,
    tunnels = [] :: [binary()],
    recv_buf = <<>> :: binary()
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link(reference()) -> {ok, pid()} | {error, term()}.
start_link(Conn) ->
    gen_server:start_link(?MODULE, Conn, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Conn) ->
    %% Take ownership of the connection
    ok = macula_quic:controlling_process(Conn, self()),
    %% Accept the first stream (control stream 0)
    accept_stream(Conn),
    {ok, #state{conn = Conn}}.

%% Called by source handler to open a tunnel stream on THIS node's connection
handle_call({open_tunnel_stream, TunnelId, SourceNode}, _From,
            #state{conn = Conn, control = Ctrl, tunnels = Tunnels} = State)
  when Ctrl =/= undefined ->
    case macula_quic:open_stream(Conn) of
        {ok, Stream} ->
            %% Notify the target node about incoming tunnel
            gen_server:cast(self(), {tunnel_notify, TunnelId, SourceNode}),
            {reply, {ok, Stream}, State#state{tunnels = [TunnelId | Tunnels]}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({open_tunnel_stream, _TunnelId, _SourceNode}, _From, State) ->
    {reply, {error, not_identified}, State};

handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({tunnel_notify, TunnelId, SourceNode}, #state{control = Ctrl} = State)
  when Ctrl =/= undefined ->
    %% Relay telling this node about an incoming tunnel
    Frame = macula_dist_relay_protocol:encode(
        #{type => tunnel_notify, tunnel_id => TunnelId, source => SourceNode}
    ),
    macula_quic:send(Ctrl, Frame),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% New stream on this connection
handle_info({quic, new_stream, Stream, _Props}, #state{control = undefined} = State) ->
    %% First stream = control channel
    ok = macula_quic:setopt(Stream, active, true),
    ?LOG_DEBUG("[conn_handler] Control stream accepted"),
    {noreply, State#state{control = Stream}};

handle_info({quic, new_stream, _Stream, _Props}, State) ->
    %% Additional streams are tunnel data streams opened by us or peer.
    %% Tunnel streams are managed by forwarder processes, not here.
    {noreply, State};

%% Data on control stream
handle_info({quic, Data, Stream, _Flags}, #state{control = Stream, recv_buf = Buf} = State)
  when is_binary(Data) ->
    NewBuf = <<Buf/binary, Data/binary>>,
    {Msgs, Remaining} = macula_dist_relay_protocol:decode_buffer(NewBuf),
    State2 = lists:foldl(fun handle_control_msg/2, State, Msgs),
    {noreply, State2#state{recv_buf = Remaining}};

%% Connection/stream lifecycle
handle_info({quic, peer_send_shutdown, _Stream, _}, State) ->
    ?LOG_INFO("[conn_handler] Peer shutdown, node=~s", [node_label(State)]),
    {stop, normal, State};

handle_info({quic, Closed, _Ref, _}, State)
  when Closed =:= closed; Closed =:= shutdown; Closed =:= transport_shutdown ->
    ?LOG_INFO("[conn_handler] Connection ~p, node=~s", [Closed, node_label(State)]),
    {stop, normal, State};

handle_info(Info, State) ->
    ?LOG_DEBUG("[conn_handler] Unhandled: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{node_name = Name, tunnels = Tunnels, conn = Conn}) ->
    %% Clean up tunnels
    lists:foreach(fun(TId) ->
        macula_dist_relay_router:unregister_tunnel(TId)
    end, Tunnels),
    %% Unregister node
    case Name of
        undefined -> ok;
        _ -> macula_dist_relay_router:unregister_node(Name)
    end,
    catch macula_quic:close_connection(Conn),
    ok.

%%====================================================================
%% Control message handling
%%====================================================================

handle_control_msg(#{type := identify, node_name := Name}, #state{control = Ctrl} = State) ->
    ?LOG_INFO("[conn_handler] Node identified: ~s", [Name]),
    macula_dist_relay_router:register_node(Name, self(), make_ref()),
    Reply = macula_dist_relay_protocol:encode(#{type => identified, status => ok}),
    macula_quic:send(Ctrl, Reply),
    State#state{node_name = Name};

handle_control_msg(#{type := tunnel_request, target := Target},
                   #state{node_name = Source, conn = SrcConn, control = Ctrl} = State)
  when Source =/= undefined ->
    case macula_dist_relay_router:lookup_node(Target) of
        {ok, TargetPid} ->
            TunnelId = generate_tunnel_id(),
            case create_tunnel(TunnelId, Source, SrcConn, Target, TargetPid) of
                ok ->
                    Reply = macula_dist_relay_protocol:encode(
                        #{type => tunnel_ok, tunnel_id => TunnelId}
                    ),
                    macula_quic:send(Ctrl, Reply),
                    State#state{tunnels = [TunnelId | State#state.tunnels]};
                {error, Reason} ->
                    ErrReply = macula_dist_relay_protocol:encode(
                        #{type => tunnel_error,
                          reason => iolist_to_binary(io_lib:format("~p", [Reason]))}
                    ),
                    macula_quic:send(Ctrl, ErrReply),
                    State
            end;
        {error, not_found} ->
            ErrReply = macula_dist_relay_protocol:encode(
                #{type => tunnel_error, reason => <<"target_not_connected">>}
            ),
            macula_quic:send(Ctrl, ErrReply),
            State
    end;

handle_control_msg(#{type := tunnel_request}, #state{control = Ctrl} = State) ->
    %% Not identified yet
    ErrReply = macula_dist_relay_protocol:encode(
        #{type => tunnel_error, reason => <<"not_identified">>}
    ),
    macula_quic:send(Ctrl, ErrReply),
    State;

handle_control_msg(#{type := tunnel_close, tunnel_id := TId}, State) ->
    ?LOG_INFO("[conn_handler] Tunnel close: ~s", [TId]),
    macula_dist_relay_router:unregister_tunnel(TId),
    State#state{tunnels = lists:delete(TId, State#state.tunnels)};

handle_control_msg(Msg, State) ->
    ?LOG_WARNING("[conn_handler] Unknown control message: ~p", [Msg]),
    State.

%%====================================================================
%% Tunnel creation
%%====================================================================

create_tunnel(TunnelId, SourceName, SrcConn, _TargetName, TargetPid) ->
    %% Open a stream on the source connection (relay → source node, for receiving tunnel data FROM target)
    case macula_quic:open_stream(SrcConn) of
        {ok, SrcStream} ->
            %% Ask the target's connection handler to open a stream on its connection
            case gen_server:call(TargetPid, {open_tunnel_stream, TunnelId, SourceName}, 5000) of
                {ok, TargetStream} ->
                    %% Start two forwarders: source→target and target→source
                    FwdId1 = <<TunnelId/binary, ":s2t">>,
                    FwdId2 = <<TunnelId/binary, ":t2s">>,
                    {ok, _} = macula_dist_relay_tunnel_sup:start_forwarder(
                        FwdId1, SrcStream, TargetStream),
                    {ok, _} = macula_dist_relay_tunnel_sup:start_forwarder(
                        FwdId2, TargetStream, SrcStream),
                    macula_dist_relay_router:register_tunnel(TunnelId, SrcStream, TargetStream),
                    ok;
                {error, Reason} ->
                    catch macula_quic:close_stream(SrcStream),
                    {error, {target_stream_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {source_stream_failed, Reason}}
    end.

%%====================================================================
%% Internal
%%====================================================================

accept_stream(Conn) ->
    case macula_quic:async_accept_stream(Conn) of
        ok -> ok;
        {ok, _} -> ok;
        {error, Reason} ->
            ?LOG_WARNING("[conn_handler] async_accept_stream failed: ~p", [Reason])
    end.

generate_tunnel_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    binary:encode_hex(Bytes).

node_label(#state{node_name = undefined}) -> <<"unknown">>;
node_label(#state{node_name = Name}) -> Name.
