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
%%%
%%% == Tunnel stream identification ==
%%%
%%% When the relay opens a tunnel stream on a node's connection, it writes
%%% the 32-byte hex tunnel_id as the first bytes. The node's client must
%%% read this prefix to identify which tunnel the new_stream belongs to
%%% (since a node may request multiple tunnels concurrently and receive
%%% new_stream events with no inherent ordering guarantee relative to
%%% tunnel_ok/tunnel_notify messages on the control stream).
%%%
%%% After the prefix, raw dist bytes flow bidirectionally through the
%%% forwarder pair.
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

%% Called by source handler to open a tunnel stream on THIS node's connection.
%% We write the 32-byte hex tunnel_id prefix so the target node can identify
%% which tunnel this incoming stream belongs to.
handle_call({open_tunnel_stream, TunnelId, SourceNode}, _From,
            #state{conn = Conn, control = Ctrl} = State)
  when Ctrl =/= undefined ->
    handle_open_tunnel_stream(open_and_prefix(Conn, TunnelId), TunnelId, SourceNode, State);

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
    lists:foreach(fun macula_dist_relay_router:unregister_tunnel/1, Tunnels),
    unregister_node(Name),
    catch macula_quic:close_connection(Conn),
    ok.

unregister_node(undefined) -> ok;
unregister_node(Name) -> macula_dist_relay_router:unregister_node(Name).

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
                   #state{node_name = Source, conn = SrcConn} = State)
  when Source =/= undefined ->
    handle_tunnel_lookup(macula_dist_relay_router:lookup_node(Target),
                         Source, SrcConn, Target, State);

handle_control_msg(#{type := tunnel_request}, State) ->
    %% Not identified yet
    reply_tunnel_error(<<"not_identified">>, State),
    State;

handle_control_msg(#{type := tunnel_close, tunnel_id := TId}, State) ->
    ?LOG_INFO("[conn_handler] Tunnel close: ~s", [TId]),
    macula_dist_relay_router:unregister_tunnel(TId),
    State#state{tunnels = lists:delete(TId, State#state.tunnels)};

handle_control_msg(Msg, State) ->
    ?LOG_WARNING("[conn_handler] Unknown control message: ~p", [Msg]),
    State.

%% Flat clauses — one per lookup/tunnel-creation outcome.
handle_tunnel_lookup({ok, TargetPid}, Source, SrcConn, Target, State) ->
    TunnelId = generate_tunnel_id(),
    finalize_tunnel(create_tunnel(TunnelId, Source, SrcConn, Target, TargetPid),
                    TunnelId, State);
handle_tunnel_lookup({error, not_found}, _Source, _SrcConn, _Target, State) ->
    reply_tunnel_error(<<"target_not_connected">>, State),
    State.

finalize_tunnel(ok, TunnelId, #state{tunnels = Tunnels} = State) ->
    reply_tunnel_ok(TunnelId, State),
    State#state{tunnels = [TunnelId | Tunnels]};
finalize_tunnel({error, Reason}, _TunnelId, State) ->
    ReasonBin = iolist_to_binary(io_lib:format("~p", [Reason])),
    reply_tunnel_error(ReasonBin, State),
    State.

reply_tunnel_ok(TunnelId, #state{control = Ctrl}) ->
    Frame = macula_dist_relay_protocol:encode(#{type => tunnel_ok, tunnel_id => TunnelId}),
    macula_quic:send(Ctrl, Frame).

reply_tunnel_error(Reason, #state{control = Ctrl}) ->
    Frame = macula_dist_relay_protocol:encode(#{type => tunnel_error, reason => Reason}),
    macula_quic:send(Ctrl, Frame).

%%====================================================================
%% Tunnel creation
%%====================================================================

%% Open source stream + write tunnel_id prefix, then ask target handler to
%% do the same, then spawn bidirectional forwarders. Each step pattern-matches
%% in its own function clause — no nested case.
create_tunnel(TunnelId, SourceName, SrcConn, _TargetName, TargetPid) ->
    with_source_stream(open_and_prefix(SrcConn, TunnelId), TunnelId, SourceName, TargetPid).

with_source_stream({ok, SrcStream}, TunnelId, SourceName, TargetPid) ->
    with_target_stream(
        gen_server:call(TargetPid, {open_tunnel_stream, TunnelId, SourceName}, 5000),
        TunnelId, SrcStream);
with_source_stream({error, Reason}, _TunnelId, _SourceName, _TargetPid) ->
    {error, {source_stream_failed, Reason}}.

with_target_stream({ok, TargetStream}, TunnelId, SrcStream) ->
    start_forwarder_pair(TunnelId, SrcStream, TargetStream),
    macula_dist_relay_router:register_tunnel(TunnelId, SrcStream, TargetStream),
    ok;
with_target_stream({error, Reason}, _TunnelId, SrcStream) ->
    catch macula_quic:close_stream(SrcStream),
    {error, {target_stream_failed, Reason}}.

start_forwarder_pair(TunnelId, SrcStream, TargetStream) ->
    FwdId1 = <<TunnelId/binary, ":s2t">>,
    FwdId2 = <<TunnelId/binary, ":t2s">>,
    {ok, _} = macula_dist_relay_tunnel_sup:start_forwarder(FwdId1, SrcStream, TargetStream),
    {ok, _} = macula_dist_relay_tunnel_sup:start_forwarder(FwdId2, TargetStream, SrcStream),
    ok.

%% Open a new stream on Conn and write the 32-byte hex tunnel_id as prefix.
%% Returns {ok, Stream} on success, {error, Reason} on failure. Closes the
%% stream on prefix-write failure.
open_and_prefix(Conn, TunnelId) ->
    prefix_stream(macula_quic:open_stream(Conn), TunnelId).

prefix_stream({ok, Stream}, TunnelId) ->
    write_prefix(macula_quic:send(Stream, TunnelId), Stream);
prefix_stream({error, _} = Err, _TunnelId) ->
    Err.

write_prefix(ok, Stream) ->
    {ok, Stream};
write_prefix({error, Reason}, Stream) ->
    catch macula_quic:close_stream(Stream),
    {error, {prefix_write_failed, Reason}}.

%% Handle result of open_and_prefix from the target-side open_tunnel_stream call.
handle_open_tunnel_stream({ok, Stream}, TunnelId, SourceNode, #state{tunnels = Tunnels} = State) ->
    gen_server:cast(self(), {tunnel_notify, TunnelId, SourceNode}),
    {reply, {ok, Stream}, State#state{tunnels = [TunnelId | Tunnels]}};
handle_open_tunnel_stream({error, _} = Err, _TunnelId, _SourceNode, State) ->
    {reply, Err, State}.

%%====================================================================
%% Internal
%%====================================================================

accept_stream(Conn) ->
    log_accept_result(macula_quic:async_accept_stream(Conn)).

log_accept_result(ok) -> ok;
log_accept_result({ok, _}) -> ok;
log_accept_result({error, Reason}) ->
    ?LOG_WARNING("[conn_handler] async_accept_stream failed: ~p", [Reason]).

generate_tunnel_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    binary:encode_hex(Bytes).

node_label(#state{node_name = undefined}) -> <<"unknown">>;
node_label(#state{node_name = Name}) -> Name.
