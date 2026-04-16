%%%-------------------------------------------------------------------
%%% @doc QUIC listener for dist relay.
%%%
%%% Accepts incoming connections from Erlang nodes. Each connection
%%% goes through a two-phase lifecycle:
%%%
%%% 1. **Control stream** (stream 0): MessagePack-framed handshake.
%%%    The node identifies itself (`{identify, NodeName}`) and the
%%%    relay registers it in the route table.
%%%
%%% 2. **Tunnel streams** (stream 1+): opened on demand when a node
%%%    requests a tunnel to another node. Each tunnel is a pair of
%%%    QUIC streams (one per direction) with raw byte forwarding —
%%%    no MessagePack, no pub/sub, no handler pipeline.
%%%
%%% The listener is a gen_server that owns the QUIC listener handle
%%% and accepts connections via async_accept. Each accepted
%%% connection spawns a connection handler (supervised).
%%% @end
%%%-------------------------------------------------------------------
-module(macula_dist_relay_listener).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    listener :: reference() | undefined,
    port     :: non_neg_integer()
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link(non_neg_integer()) -> {ok, pid()} | {error, term()}.
start_link(Port) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Port, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Port) ->
    %% macula_tls returns ssl-style `certfile'/`keyfile' keys, but
    %% macula_quic:listen/3 reads `cert'/`key'. Translate here so the
    %% NIF doesn't get `undefined' as the cert path.
    TlsOpts = translate_quic_tls_opts(macula_tls:quic_server_opts()),
    ListenOpts = [
        {alpn, ["macula-dist"]},
        {idle_timeout_ms, 120_000},
        {peer_bidi_stream_count, 128}
        | TlsOpts
    ],
    handle_listen_result(macula_quic:listen(Port, ListenOpts), Port).

translate_quic_tls_opts(Opts) ->
    lists:map(fun rename_cert_key/1, Opts).

rename_cert_key({certfile, V}) -> {cert, V};
rename_cert_key({keyfile, V}) -> {key, V};
rename_cert_key(Other) -> Other.

handle_listen_result({ok, Listener}, Port) ->
    register_accept(Listener),
    ?LOG_INFO("[dist_listener] Listening on UDP :~b (ALPN: macula-dist)", [Port]),
    {ok, #state{listener = Listener, port = Port}};
handle_listen_result({error, Reason}, Port) ->
    ?LOG_ERROR("[dist_listener] Failed to listen on :~b: ~p", [Port, Reason]),
    {stop, {listen_failed, Reason}}.

handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% New connection accepted
handle_info({quic, new_conn, Conn, ConnInfo}, #state{listener = Listener} = State) ->
    ?LOG_INFO("[dist_listener] New connection: ~p", [ConnInfo]),
    dispatch_connection(Conn),
    register_accept(Listener),
    {noreply, State};

handle_info(Info, State) ->
    ?LOG_DEBUG("[dist_listener] Unhandled: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{listener = Listener}) ->
    catch macula_quic:close(Listener),
    ok.

%%====================================================================
%% Internal
%%====================================================================

register_accept(Listener) ->
    log_accept_result(macula_quic:async_accept(Listener, #{})).

log_accept_result(ok) -> ok;
log_accept_result({ok, _}) -> ok;
log_accept_result({error, Reason}) ->
    ?LOG_WARNING("[dist_listener] async_accept failed: ~p", [Reason]).

dispatch_connection(Conn) ->
    handle_handshake(macula_quic:handshake(Conn), Conn).

handle_handshake(ok, Conn) -> start_conn_handler(Conn);
handle_handshake({ok, _}, Conn) -> start_conn_handler(Conn);
handle_handshake({error, Reason}, Conn) ->
    ?LOG_ERROR("[dist_listener] Handshake failed: ~p", [Reason]),
    catch macula_quic:close_connection(Conn).

start_conn_handler(Conn) ->
    handle_start_result(macula_dist_relay_conn_sup:start_handler(Conn), Conn).

handle_start_result({ok, _Pid}, _Conn) -> ok;
handle_start_result({error, Reason}, Conn) ->
    ?LOG_ERROR("[dist_listener] Failed to start conn handler: ~p", [Reason]),
    catch macula_quic:close_connection(Conn).
