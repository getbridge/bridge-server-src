-module(gateway_metrics).

-behaviour(gen_server).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {hostname, web_port, tcp_port, redirector_url, bridgeid, server_usage}).

%% Public API

start_link() ->
  gen_server:start({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
  {ok, Hostname} = application:get_env(gateway, hostname),
  HostnameBin = list_to_binary(Hostname),
  {ok, WebPort} = application:get_env(gateway, web_port),
  {ok, TCPPort} = application:get_env(gateway, tcp_port),
  {ok, Redirector} = application:get_env(gateway, redirector_url),
  
  ets:new(meter_table, [public, named_table, {write_concurrency,true}]),
  ets:new(meter_table_public, [public, named_table, {write_concurrency,true}]),
  
  BridgeId = gateway_util:md5_hex(Hostname ++ integer_to_list(TCPPort) ++ integer_to_list(WebPort)),
  report_add_server(HostnameBin, TCPPort, WebPort),
  
  erlang:send_after(10000, self(), send_server_usage),
  
  {ok, #state{hostname = HostnameBin, web_port = WebPort, tcp_port = TCPPort, redirector_url = Redirector, bridgeid = BridgeId, server_usage = 0}}.

handle_call(stop, _From, State) ->
  {stop, normal, stopped, State};

handle_call(_Msg, _From, State) ->
  gateway_util:warn("Unknown Command: ~p~n", [_Msg]),
  {reply, unknown_command, State}.

handle_cast({send_app_usage, PrivKey, Usage}, State = #state{redirector_url = Redirector}) ->
  Report = sockjs_util:encode({[{priv_key, PrivKey}, {usage, Usage}]}),
  httpc:request(post, {Redirector ++ "meter/", [], "application/json", Report}, [], [
      {sync, false},
      {body_format, binary}, 
      {receiver, fun (Val) ->
            case Val of
              {_, {error, Reason}} ->
                gateway_util:error("Error in metering ctl request: ~p~n", [Reason]);
              {_, _} -> ok
            end
        end}
  ]),
  {noreply, State};
  
handle_cast({server_usage_update, UsageAdd}, State = #state{server_usage = Usage}) ->
  {noreply, State#state{server_usage = Usage + UsageAdd}};
  
handle_cast(_Msg, State) ->
  gateway_util:warn("Unknown Command: ~p~n", [_Msg]),
  {noreply, State}.

handle_info(send_server_usage, State = #state{bridgeid = BridgeId, redirector_url = Redirector, server_usage = Usage}) ->
  Report = sockjs_util:encode({[{bridgeId, BridgeId}, {usage, Usage}]}),
  httpc:request(post, {Redirector ++ "serverMeter/", [], "application/json", Report}, [], [
      {sync, false},
      {body_format, binary}, 
      {receiver, fun (Val) ->
            case Val of
              {_, {error, Reason}} ->
                gateway_util:error("Error in add server to redirector: ~p~n", [Reason]);
              {_, _} -> ok
            end
        end}
  ]),
  erlang:send_after(10000, self(), send_server_usage),
  {noreply, State#state{server_usage = 0}};
  
handle_info(_Info, State) ->
  gateway_util:warn("Unknown Info: Ignoring: ~p~n", [_Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

  
%% -- Functions

  
report_add_server(Hostname, TCPPort, WebPort) ->
  {ok, Redirector} = application:get_env(gateway, redirector_url),
  Report = sockjs_util:encode({[{host, Hostname}, {tcp_port, TCPPort}, {web_port, WebPort}]}),
  httpc:request(post, {Redirector ++ "addServer/", [], "application/json", Report}, [], [
      {sync, false},
      {body_format, binary}, 
      {receiver, fun (Val) ->
            case Val of
              {_, {error, Reason}} ->
                gateway_util:error("Error in add server to redirector: ~p~n", [Reason]);
              {_, {{_, 200, _}, _, RawData}} -> {ok, JSONDecoded} = sockjs_util:decode(RawData),
                                                {PropList} = JSONDecoded,
                                                {DataList} = proplists:get_value(<<"data">>, PropList),
                                                AppList = proplists:get_value(<<"applications">>, DataList),
                                                lists:map(fun ([PubKey, PrivKey]) ->
                                                            ctl_handler:add_key(PrivKey, PubKey)
                                                          end, AppList);
              {_, _} -> gateway_util:error("Error in add server to redirector")
            end
        end}
  ]).
  
