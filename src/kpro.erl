
-module(kpro).

-export([ decode_response/1
        , encode_request/1
        ]).

%% exported for internal use
-export([ decode/2
        , decode_fields/3
        , encode/1
        ]).

-include("kpro.hrl").

-define(INT, signed-integer).

%% @doc Encode #kpro_Request{} records into kafka wire format.
-spec encode_request(kpro_Request()) -> iodata().
encode_request(#kpro_Request{ apiVersion     = ApiVersion0
                            , correlationId  = CorrId0
                            , clientId       = ClientId
                            , requestMessage = RequestMessage
                            }) ->
  true = (CorrId0 =< ?MAX_CORR_ID), %% assert
  ApiKey = req_to_api_key(RequestMessage),
  CorrId = (ApiKey bsl ?CORR_ID_BITS) bor CorrId0,
  ApiVersion = case ApiVersion0 of
                 undefined -> ?KPRO_API_VERSION;
                 _         -> ApiVersion0
               end,
  IoData =
    [ encode({int16, ApiKey})
    , encode({int16, ApiVersion})
    , encode({int32, CorrId})
    , encode({string, ClientId})
    , encode(RequestMessage)
    ],
  Size = data_size(IoData),
  [encode({int32, Size}), IoData].

%% @doc Decode responses received from kafka.
%% {incomplete, TheOriginalBinary} is returned if this is not a complete packet.
%% @end
-spec decode_response(binary()) -> {incomplete | #kpro_Response{}, binary()}.
decode_response(<<Size:32/?INT, Bin/binary>>) when size(Bin) >= Size ->
  <<I:32/integer, Rest0/binary>> = Bin,
  ApiKey = I bsr ?CORR_ID_BITS,
  CorrId = I band ?MAX_CORR_ID,
  Type = ?API_KEY_TO_RSP(ApiKey),
  {Message, Rest} =
    try
      decode(Type, Rest0)
    catch error : E ->
      Context = [ {api_key, ApiKey}
                , {corr_id, CorrId}
                , {payload, Rest0}
                ],
      erlang:error({E, Context, erlang:get_stacktrace()})
    end,
  Result =
    #kpro_Response{ correlationId   = CorrId
                  , responseMessage = Message
                  },
  {Result, Rest};
decode_response( Bin) ->
  {incomplete, Bin}.

%%%_* Internal functions =======================================================

encode({int8,  I}) when is_integer(I) -> <<I:8/?INT>>;
encode({int16, I}) when is_integer(I) -> <<I:16/?INT>>;
encode({int32, I}) when is_integer(I) -> <<I:32/?INT>>;
encode({int64, I}) when is_integer(I) -> <<I:64/?INT>>;
encode({string, undefined}) ->
  <<-1:16/?INT>>;
encode({string, L}) when is_list(L) ->
  encode({string, iolist_to_binary(L)});
encode({string, <<>>}) ->
  <<-1:16/?INT>>;
encode({string, B}) when is_binary(B) ->
  Length = size(B),
  <<Length:16/?INT, B/binary>>;
encode({bytes, undefined}) ->
  <<-1:32/?INT>>;
encode({bytes, <<>>}) ->
  <<-1:32/?INT>>;
encode({bytes, B}) when is_binary(B) ->
  Length = size(B),
  <<Length:32/?INT, B/binary>>;
encode({{array, T}, L}) when is_list(L) ->
  true = ?is_kafka_primitive(T), %% assert
  Length = length(L),
  [<<Length:32/?INT>>, [encode({T, I}) || I <- L]];
encode({array, L}) when is_list(L) ->
  Length = length(L),
  [<<Length:32/?INT>>, [encode(I) || I <- L]];
encode(#kpro_PartitionMessageSet{} = R) ->
  %% messages in messageset is a stream, not an array
  MessageSet = [encode(M) || M <- R#kpro_PartitionMessageSet.message_L],
  Size = data_size(MessageSet),
  [encode({int32, R#kpro_PartitionMessageSet.partition}),
   encode({int32, Size}),
   MessageSet
  ];
encode(#kpro_Message{} = R) ->
  MagicByte = case R#kpro_Message.magicByte of
                undefined            -> ?KPRO_MAGIC_BYTE;
                M when is_integer(M) -> M
              end,
  Attributes = case R#kpro_Message.attributes of
                 undefined            -> ?KPRO_ATTRIBUTES;
                 A when is_integer(A) -> A
               end,
  Body =
    [encode({int8, MagicByte}),
     encode({int8, Attributes}),
     encode({bytes, R#kpro_Message.key}),
     encode({bytes, R#kpro_Message.value})],
  Crc  = encode({int32, erlang:crc32(Body)}),
  Size = data_size([Crc, Body]),
  [encode({int64, -1}),
   encode({int32, Size}),
   Crc, Body
  ];
encode(Struct) when is_tuple(Struct) ->
  kpro_structs:encode(Struct).

decode(int8, Bin) ->
  <<Value:8/?INT, Rest/binary>> = Bin,
  {Value, Rest};
decode(int16, Bin) ->
  <<Value:16/?INT, Rest/binary>> = Bin,
  {Value, Rest};
decode(int32, Bin) ->
  <<Value:32/?INT, Rest/binary>> = Bin,
  {Value, Rest};
decode(int64, Bin) ->
  <<Value:64/?INT, Rest/binary>> = Bin,
  {Value, Rest};
decode(string, Bin) ->
  <<Size:16/?INT, Rest/binary>> = Bin,
  copy_bytes(Size, Rest);
decode(bytes, Bin) ->
  <<Size:32/?INT, Rest/binary>> = Bin,
  copy_bytes(Size, Rest);
decode({array, Type}, Bin) ->
  <<Length:32/?INT, Rest/binary>> = Bin,
  decode_array_elements(Length, Type, Rest, _Acc = []);
decode(kpro_FetchResponsePartition, Bin) ->
  %% special treat since message sets may get partially delivered
  <<Partition:32/?INT,
    ErrorCode:16/?INT,
    HighWmOffset:64/?INT,
    MessageSetSize:32/?INT,
    MsgsBin:MessageSetSize/binary,
    Rest/binary>> = Bin,
  %% messages in messageset are not array elements, but stream
  Messages = decode_message_stream(MsgsBin, []),
  PartitionMessages =
    #kpro_FetchResponsePartition{ partition           = Partition
                                , errorCode           = ErrorCode
                                , highWatermarkOffset = HighWmOffset
                                , messageSetSize      = MessageSetSize
                                , message_L           = Messages
                                },
  {PartitionMessages, Rest};
decode(StructName, Bin) when is_atom(StructName) ->
  kpro_structs:decode(StructName, Bin).

decode_message_stream(Bin, Acc) ->
  try decode(kpro_Message, Bin) of
    {Msg, Rest} ->
      decode_message_stream(Rest, [Msg | Acc])
  catch error : {badmatch, _} ->
    case Acc =:= [] andalso Bin =/= <<>> of
      true  -> ?incomplete_message_set;
      false -> lists:reverse(Acc)
    end
  end.

decode_fields(RecordName, Fields, Bin) ->
  {FieldValues, BinRest} = do_decode_fields(RecordName, Fields, Bin, _Acc = []),
  %% make the record.
  {list_to_tuple([RecordName | FieldValues]), BinRest}.

do_decode_fields(_RecordName, _Fields = [], Bin, Acc) ->
  {lists:reverse(Acc), Bin};
do_decode_fields(RecordName, [{FieldName, FieldType} | Rest], Bin, Acc) ->
  {FieldValue0, BinRest} = decode(FieldType, Bin),
  FieldValue = maybe_translate(RecordName, FieldName, FieldValue0),
  do_decode_fields(RecordName, Rest, BinRest, [FieldValue | Acc]).

%% Translate specific values to human readable format.
%% e.g. error codes.
maybe_translate(_RecordName, errorCode, Code) ->
  kpro_errorCode:decode(Code);
maybe_translate(_RecordName, _FieldName, RawValue) ->
  RawValue.

copy_bytes(-1, Bin) ->
  {undefined, Bin};
copy_bytes(Size, Bin) ->
  <<Bytes:Size/binary, Rest/binary>> = Bin,
  {binary:copy(Bytes), Rest}.

decode_array_elements(0, _Type, Bin, Acc) ->
  {lists:reverse(Acc), Bin};
decode_array_elements(N, Type, Bin, Acc) ->
  {Element, Rest} = decode(Type, Bin),
  decode_array_elements(N-1, Type, Rest, [Element | Acc]).

-define(IS_BYTE(I), (I>=0 andalso I<256)).

data_size(IoData) ->
  data_size(IoData, 0).

data_size([], Size) -> Size;
data_size(<<>>, Size) -> Size;
data_size(I, Size) when ?IS_BYTE(I) -> Size + 1;
data_size(B, Size) when is_binary(B) -> Size + size(B);
data_size([H | T], Size0) ->
  Size1 = data_size(H, Size0),
  data_size(T, Size1).

-spec req_to_api_key(atom()) -> integer().
req_to_api_key(Req) when is_tuple(Req) ->
  req_to_api_key(element(1, Req));
req_to_api_key(Req) when is_atom(Req) ->
  ?REQ_TO_API_KEY(Req).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
