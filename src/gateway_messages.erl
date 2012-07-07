-module(gateway_messages).

-compile([export_all]).

-include_lib("messages.hrl").

validate(_Field = name , Value = <<"system">>) ->
  {invalid, Value};
validate(_Field, Value) ->
  Value.

record_for_commmand(Command) ->
  Mapping = [
    {<<"CONNECT">>, {connect, ?connect_fields}},
    {<<"JOINWORKERPOOL">>, {join_workerpool, ?jwp_fields}},
    {<<"LEAVEWORKERPOOL">>, {leave_worker_pool, ?lwp_fields}},
    {<<"JOINCHANNEL">>, {join_channel, ?jc_fields}},
    {<<"GETCHANNEL">>, {get_channel, ?gc_fields}},
    {<<"GETOPS">>, {get_ops, ?get_ops_fields}},
    {<<"SEND">>, {send, ?send_fields}}
  ],
  proplists:get_value(Command, Mapping).

struct_to_record(Struct) ->
  {PropList} = Struct,
  {RecordType, Fields} = record_for_commmand(proplists:get_value( <<"command">>, PropList)), 
  {DataList} = proplists:get_value(<<"data">>, PropList),
  list_to_tuple(
    [RecordType] ++
    lists:map(
      fun(Field) ->
          FieldAtom = atom_to_binary(Field, utf8),
          validate(FieldAtom, proplists:get_value(FieldAtom, DataList))
      end,
      tuple_to_list(Fields))
  ).
