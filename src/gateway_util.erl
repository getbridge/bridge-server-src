% Various Helpers.

-module(gateway_util).

-export([info/1, warn/1, error/1, info/2, warn/2, error/2, gen_id/0, now_decode/1, now_decode_helper/2,
         extract_pathchain_from_nowref/1, string_join/2, extract_pathstring_from_nowref/1,
         extract_binpathchain_from_nowref/1, binpathchain_to_nowref/1, current_time/0, validate_name/1, md5_hex/1, timestamp/0, display_log/1]).

info(A) ->
    error_logger:info_msg(A).

warn(A) ->
    error_logger:warning_msg(A).

error(A) ->
    error_logger:error_msg(A).

info(A, B) ->
    error_logger:info_msg(A, B).

warn(A, B) ->
    error_logger:warning_msg(A, B).

error(A, B) ->
    error_logger:error_msg(A, B).


current_time() ->
  calendar:datetime_to_gregorian_seconds(calendar:universal_time()).

gen_id() ->
  unicode:characters_to_list(random_str(8, {"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n"})).

random_str(0, _) -> [];
random_str(Len, Chars) -> [random_char(Chars)|random_str(Len-1, Chars)].
random_char(Chars) -> element(crypto:rand_uniform(1, tuple_size(Chars) + 1), Chars).

decode_nowref(NowRef) ->
  {NowData} = NowRef,
  Ref = proplists:get_value(<<"ref">>, NowData),
  Operations = proplists:get_value(<<"operations">>, NowData),
  {Ref, Operations}.

extract_binpathchain_from_nowref(NowRef) ->
    {Ref, _Operations} = decode_nowref(NowRef),
    Ref.

binpathchain_to_nowref(BinPath) ->
  {[{<<"ref">>, BinPath}]}.

extract_pathchain_from_nowref(NowRef) ->
  case extract_binpathchain_from_nowref(NowRef) of
    fail ->
      {fail, {not_spec, NowRef}};
    BinPathChain ->
      try lists:map( fun(Elem) -> binary_to_list(Elem) end, BinPathChain ) of
        Result ->
          {ok, Result}
      catch
        error:Error ->
          {fail, Error}
      end
  end.

extract_pathstring_from_nowref(NowRef) ->
  case extract_pathchain_from_nowref(NowRef) of
    {fail, _} = Error ->
      Error;
    {ok, Result} ->
      {ok, list_to_bitstring( gateway_util:string_join(".", Result))}
  end.

string_join(Join, L) ->
  string:join(L, Join).

now_decode(Thing) ->
  now_decode_helper(Thing, []).

now_decode_helper(Thing, Links) ->
  case Thing of
    List when is_list(Thing) ->
      lists:foldl(fun gateway_util:now_decode_helper/2, Links, List);
    {KeyValuePairs} when is_list(KeyValuePairs) ->
      case element(1, hd(KeyValuePairs)) of
        <<"ref">> -> 
          [{KeyValuePairs} | Links];
        _         ->
          lists:foldl(fun ({_Key, Value}, Acc) -> now_decode_helper(Value, Acc) end, Links, KeyValuePairs)
      end;
    _ -> Links
  end.

validate_name(Name) ->
  bin_does_not_contain(Name, <<"#">>) andalso 
  bin_does_not_contain(Name, <<".">>) andalso 
  bin_does_not_contain(Name, <<"*">>) andalso 
  bin_does_not_contain(Name, <<"channel:">>) andalso 
  Name /= <<"system">>.
  
bin_does_not_contain(Val, Pattern) ->
  case binary:match(Val, Pattern) of
    nomatch -> true;
          _ -> false
  end.
  
md5_hex(S) ->
   list_to_binary(lists:flatten([io_lib:format("~.16b",[N]) || <<N:4>> <= erlang:md5(S)])).
  
timestamp() ->
  {Mega, Secs, _} = now(),
  Mega*1000000 + Secs.
  
display_log(Val) ->
  error_logger:tty(Val).
  