%% Implements the bridge cloud interface; api key management.

-module(ctl_handler).
-behaviour(cowboy_http_handler).
-export([init/3, handle/2, terminate/2, update_metering/1, lookup_priv/1, add_key/3]).

-include("metering.hrl").

init({tcp, http}, Req, []) ->  
  {ok, Req, undefined}.

handle(Req, State) ->
  try
    {ok, Body, Req2} = cowboy_http_req:body(Req),
    req_handler(State, Body, Req2)
  catch
    _:Reason ->
      gateway_util:error("Error #218 : Error in ctl_handler handling cowboy request: ~p~n", [Reason]),
      {ok, Req3} = cowboy_http_req:reply(400, [], <<"badarg">>, Req),
      {ok, Req3, State}
  end.

req_handler(State, Body, Req2) ->
  {ok, JSONDecoded} = gateway_util:decode(Body),
  {Json} = JSONDecoded,
  PrivKey = proplists:get_value(<<"priv_key">>, Json),
  true = valid_key(PrivKey),
  PubKey = proplists:get_value(<<"pub_key">>, Json),
  NewLimit = proplists:get_value(<<"new_limit">>, Json),
  {Cmd, Req3} = cowboy_http_req:binding(cmd, Req2),
  Status = case Cmd of
    <<"addKey">> ->
      case valid_key(PubKey) of
        true ->
          add_key(PrivKey, PubKey, NewLimit);
        _ ->
          error
      end;
    <<"deleteKey">> ->
      delete_key(PrivKey);
    <<"setLimit">> when is_number(NewLimit) ->
      set_limit(PrivKey, NewLimit)
    end,
  case Status of
    ok ->
      {ok, Resp} = cowboy_http_req:reply(200, [], <<"ok">>, Req3);
    error ->
      {ok, Resp} = cowboy_http_req:reply(400, [], <<"error">>, Req3)
  end,
  {ok, Resp, State}.

valid_key(BinApiKey) ->
  is_binary(BinApiKey) andalso bit_size(BinApiKey) / 8 == 8.

add_key(PrivKey, PubKey, Limit) ->
  % meter_table[api_key] -> {is_expired, when_expired, #calls, limit, public_api_key}
  ets:insert(meter_table, {PrivKey, {false, gateway_util:current_time(), 0, Limit, PubKey}}),
  ets:insert(meter_table_public, {PubKey, PrivKey}),
  ok.

delete_key(PrivKey) ->
  {_, _, _, _, PubKey} = ets:lookup_element(meter_table, PrivKey, 2),
  ets:delete(meter_table, PrivKey),
  ets:delete(meter_table_public, PubKey),
  ok.

set_limit(PrivKey, NewLimit) ->
  {IsExpired, WhenExpired, _Usage, _, PubKey} = ets:lookup_element(meter_table, PrivKey, 2),
  ets:update_element(meter_table, PrivKey, {2, {IsExpired, WhenExpired, 1, NewLimit, PubKey}}),
  ok.

terminate(_Req, _State) ->
  ok.

update_metering(PrivKey) ->
  try
    {IsExpired, WhenExpired, Usage, Limit, PubKey} = ets:lookup_element(meter_table, PrivKey, 2),
    Now = gateway_util:current_time(),
    Delta = Now - WhenExpired,

    if
      IsExpired ->
        % We can re-enable after TIMEOUT has passed.
        if
          Delta > ?TIMEOUT ->
            % A clean slate.
            ets:update_element(meter_table, PrivKey, {2, {false, Now, 0, Limit, PubKey}}),
            ok;
          true ->
            {timeout, ?TIMEOUT - Delta}
        end;
      
      Usage < Limit ->
        Result = case Delta < ?RESET_INTERVAL of
                   true -> (Usage + 1) rem Limit;
                   false -> 1
                 end,
        
        case (Usage + 1) rem ?UPDATE_GRANULARITY of
          0 -> gen_server:cast(gateway_metrics, {server_usage_update, ?UPDATE_GRANULARITY});
          _ -> ok
        end,
        if
          Result > 0 ->
            ets:update_element(meter_table, PrivKey, {2, {false, Now, Result, Limit, PubKey}}),
            ok;

          true ->
            gen_server:cast(gateway_metrics, {send_app_usage, PrivKey, Limit}),
            ets:update_element(meter_table, PrivKey, {2, {true, Now, 0, Limit, PubKey}}),
            ok
        end;
      true ->
        {timeout, other}
    end
  catch
    _:Reason ->
      gateway_util:error("Error #219 : Error in ctl_handler:update_metering/1: ~p, ~p~n", [Reason, erlang:get_stacktrace()]),
      error
  end.

lookup_priv(Key) ->
  case ets:member(meter_table, Key) of
    true   -> {priv, Key};
    false  -> case ets:lookup(meter_table_public, Key) of
                []     -> false;
                [{_, ApiKey}] -> {unpriv, ApiKey}
              end
  end.
