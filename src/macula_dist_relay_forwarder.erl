%%%-------------------------------------------------------------------
%%% @doc Per-tunnel stream forwarder.
%%%
%%% Reads raw bytes from a source QUIC stream and writes them to a
%%% destination QUIC stream. No framing, no encoding, no decryption —
%%% just byte forwarding. QUIC guarantees per-stream ordering and
%%% TLS 1.3 encryption at the transport layer.
%%%
%%% One forwarder per direction. A bidirectional tunnel has two
%%% forwarder processes.
%%%
%%% Exits `normal' when either stream closes. The dist connection
%%% on both sides detects the stream closure and handles reconnect.
%%% @end
%%%-------------------------------------------------------------------
-module(macula_dist_relay_forwarder).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    tunnel_id :: binary(),
    source    :: reference(),
    dest      :: reference(),
    bytes_fwd :: non_neg_integer()
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link(binary(), reference(), reference()) ->
    {ok, pid()} | {error, term()}.
start_link(TunnelId, SourceStream, DestStream) ->
    gen_server:start_link(?MODULE, {TunnelId, SourceStream, DestStream}, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({TunnelId, SourceStream, DestStream}) ->
    macula_quic:setopt(SourceStream, active, true),
    ?LOG_DEBUG("[forwarder] Started for tunnel ~s", [TunnelId]),
    {ok, #state{
        tunnel_id = TunnelId,
        source = SourceStream,
        dest = DestStream,
        bytes_fwd = 0
    }}.

handle_info({quic, Data, Source, _Flags},
            #state{source = Source, dest = Dest, bytes_fwd = N} = S)
  when is_binary(Data) ->
    case macula_quic:async_send(Dest, Data) of
        ok ->
            {noreply, S#state{bytes_fwd = N + byte_size(Data)}};
        {error, Reason} ->
            ?LOG_WARNING("[forwarder] Send failed for tunnel ~s: ~p",
                         [S#state.tunnel_id, Reason]),
            {stop, {send_failed, Reason}, S}
    end;

handle_info({quic, peer_send_shutdown, Source, _}, #state{source = Source} = S) ->
    ?LOG_INFO("[forwarder] Source stream closed for tunnel ~s (~b bytes forwarded)",
              [S#state.tunnel_id, S#state.bytes_fwd]),
    {stop, normal, S};

handle_info({quic, Closed, Source, _}, #state{source = Source} = S)
  when Closed =:= closed; Closed =:= peer_send_aborted ->
    ?LOG_INFO("[forwarder] Source stream ~p for tunnel ~s",
              [Closed, S#state.tunnel_id]),
    {stop, normal, S};

handle_info(_Msg, S) ->
    {noreply, S}.

handle_call(_Msg, _From, S) -> {reply, {error, unknown_call}, S}.
handle_cast(_Msg, S) -> {noreply, S}.

terminate(_Reason, #state{tunnel_id = TunnelId, bytes_fwd = N}) ->
    ?LOG_INFO("[forwarder] Tunnel ~s terminated (~b bytes forwarded)",
              [TunnelId, N]),
    ok.
