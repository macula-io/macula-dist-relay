-module(macula_dist_relay_protocol_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Round-trip tests — encode then decode
%%====================================================================

identify_roundtrip_test() ->
    Msg = #{type => identify, node_name => <<"alice@host00.lab">>},
    Encoded = macula_dist_relay_protocol:encode(Msg),
    {[Decoded], <<>>} = macula_dist_relay_protocol:decode_buffer(Encoded),
    ?assertEqual(Msg, Decoded).

identified_roundtrip_test() ->
    Msg = #{type => identified, status => ok},
    Encoded = macula_dist_relay_protocol:encode(Msg),
    {[Decoded], <<>>} = macula_dist_relay_protocol:decode_buffer(Encoded),
    ?assertEqual(Msg, Decoded).

tunnel_request_roundtrip_test() ->
    Msg = #{type => tunnel_request, target => <<"bob@host01.lab">>},
    Encoded = macula_dist_relay_protocol:encode(Msg),
    {[Decoded], <<>>} = macula_dist_relay_protocol:decode_buffer(Encoded),
    ?assertEqual(Msg, Decoded).

tunnel_ok_roundtrip_test() ->
    Msg = #{type => tunnel_ok, tunnel_id => <<"abc123def456">>},
    Encoded = macula_dist_relay_protocol:encode(Msg),
    {[Decoded], <<>>} = macula_dist_relay_protocol:decode_buffer(Encoded),
    ?assertEqual(Msg, Decoded).

tunnel_error_roundtrip_test() ->
    Msg = #{type => tunnel_error, reason => <<"target_not_connected">>},
    Encoded = macula_dist_relay_protocol:encode(Msg),
    {[Decoded], <<>>} = macula_dist_relay_protocol:decode_buffer(Encoded),
    ?assertEqual(Msg, Decoded).

tunnel_close_roundtrip_test() ->
    Msg = #{type => tunnel_close, tunnel_id => <<"abc123def456">>},
    Encoded = macula_dist_relay_protocol:encode(Msg),
    {[Decoded], <<>>} = macula_dist_relay_protocol:decode_buffer(Encoded),
    ?assertEqual(Msg, Decoded).

tunnel_notify_roundtrip_test() ->
    Msg = #{type => tunnel_notify, tunnel_id => <<"tid001">>, source => <<"alice@host00.lab">>},
    Encoded = macula_dist_relay_protocol:encode(Msg),
    {[Decoded], <<>>} = macula_dist_relay_protocol:decode_buffer(Encoded),
    ?assertEqual(Msg, Decoded).

%%====================================================================
%% Buffer tests — multiple frames, partial frames
%%====================================================================

multiple_frames_test() ->
    Msg1 = #{type => identify, node_name => <<"alice@host">>},
    Msg2 = #{type => tunnel_request, target => <<"bob@host">>},
    Msg3 = #{type => tunnel_close, tunnel_id => <<"t001">>},
    Buf = <<(macula_dist_relay_protocol:encode(Msg1))/binary,
            (macula_dist_relay_protocol:encode(Msg2))/binary,
            (macula_dist_relay_protocol:encode(Msg3))/binary>>,
    {Decoded, <<>>} = macula_dist_relay_protocol:decode_buffer(Buf),
    ?assertEqual(3, length(Decoded)),
    ?assertEqual(Msg1, lists:nth(1, Decoded)),
    ?assertEqual(Msg2, lists:nth(2, Decoded)),
    ?assertEqual(Msg3, lists:nth(3, Decoded)).

partial_frame_test() ->
    Msg = #{type => identify, node_name => <<"alice@host00.lab">>},
    Full = macula_dist_relay_protocol:encode(Msg),
    %% Cut off the last 3 bytes
    PartialLen = byte_size(Full) - 3,
    <<Partial:PartialLen/binary, _Rest/binary>> = Full,
    {Decoded, Remaining} = macula_dist_relay_protocol:decode_buffer(Partial),
    ?assertEqual([], Decoded),
    ?assertEqual(Partial, Remaining).

empty_buffer_test() ->
    {Decoded, Remaining} = macula_dist_relay_protocol:decode_buffer(<<>>),
    ?assertEqual([], Decoded),
    ?assertEqual(<<>>, Remaining).

frame_with_trailing_partial_test() ->
    Msg1 = #{type => identified, status => ok},
    Msg2 = #{type => tunnel_ok, tunnel_id => <<"tid">>},
    Full1 = macula_dist_relay_protocol:encode(Msg1),
    Full2 = macula_dist_relay_protocol:encode(Msg2),
    %% Only first 2 bytes of second frame
    <<Partial2:2/binary, _/binary>> = Full2,
    Buf = <<Full1/binary, Partial2/binary>>,
    {Decoded, Remaining} = macula_dist_relay_protocol:decode_buffer(Buf),
    ?assertEqual(1, length(Decoded)),
    ?assertEqual(Msg1, hd(Decoded)),
    ?assertEqual(Partial2, Remaining).

%%====================================================================
%% Direct decode tests
%%====================================================================

decode_unknown_type_test() ->
    Payload = msgpack:pack(#{<<"t">> => <<"unknown">>}, [{map_format, map}]),
    ?assertMatch({error, {unknown_message, _}},
                 macula_dist_relay_protocol:decode(iolist_to_binary(Payload))).

decode_invalid_msgpack_test() ->
    ?assertMatch({error, {msgpack_decode, _}},
                 macula_dist_relay_protocol:decode(<<255, 255, 0>>)).
