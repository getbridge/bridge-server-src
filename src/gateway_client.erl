% Per-Connection Logic. Receive Messages from/to NowProtocol.
% Logic to alter Queues and Exchanges.

-module(gateway_client).
-behaviour(gen_server).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {sessionid, outbound_connection, rabbit_handler, api_key, privilege}).

-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("gateway.hrl").
-include_lib("metering.hrl").

start_link() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
  {ok, #state{}}.

handle_join_worker_pool(_, State = #state{privilege = unpriv}) ->
  gen_server:cast(self(), {error, 102, "Publish service permissions denied"}),
  State;
handle_join_worker_pool(DataList, State = #state{rabbit_handler = RabbitHandler
                                                 , sessionid = SessionId
                                                 , privilege = priv}) ->
  Callback = proplists:get_value(<<"callback">>, DataList),
  Name = proplists:get_value(<<"name">>, DataList),

  case gateway_util:validate_name(Name) of
    true -> gen_server:cast(RabbitHandler, {join_workerpool, Name}),
            case Callback of
              undefined -> State;
              _ -> ServicePathChain = gateway_util:extract_binpathchain_from_nowref(Callback),
                   MethodPathChain  = lists:append(ServicePathChain, [<<"callback">>]),
                   Message =   [
                     {<<"destination">>, gateway_util:binpathchain_to_nowref(MethodPathChain) },
                     {<<"args">>, [Name] }
                   ],
                   gen_server:cast(RabbitHandler, {publish_message, SessionId, Message})
            end;
    false -> gen_server:cast(self(), {error, 103, <<"Invalid service name: ", Name/binary>>})
  end,
  State.

handle_leave_worker_pool(_, State = #state{privilege = unpriv}) ->
  gen_server:cast(self(), {error, 113, "Unpublish service permissions denied"}),
  State;
handle_leave_worker_pool(DataList, State = #state{rabbit_handler = RabbitHandler
                                                 , sessionid = SessionId
                                                 , privilege = priv}) ->
  Callback = proplists:get_value(<<"callback">>, DataList),
  Name = proplists:get_value(<<"name">>, DataList),
  
  case gateway_util:validate_name(Name) of
    true -> gen_server:cast(RabbitHandler, {leave_workerpool, Name}),
            case Callback of
              undefined -> State;
              _ -> ServicePathChain = gateway_util:extract_binpathchain_from_nowref(Callback),
                   MethodPathChain  = lists:append(ServicePathChain, [<<"callback">>]),
                   Message =   [
                     {<<"destination">>, gateway_util:binpathchain_to_nowref(MethodPathChain) },
                     {<<"args">>, [Name] }
                   ],
                   gen_server:cast(RabbitHandler, {publish_message, SessionId, Message})
            end;
    false -> gen_server:cast(self(), {error, 114, <<"Invalid service name: ", Name/binary>>})
  end,
  State.
  
handle_getops(DataList, State = #state{rabbit_handler = RabbitHandler, sessionid = SessionId}) ->
  Callback = proplists:get_value(<<"callback">>, DataList),
  Name = proplists:get_value(<<"name">>, DataList),
  Client = proplists:get_value(<<"client">>, DataList),
  DestPath = case Client of
    undefined -> [ <<"named">>, Name, <<"system">>, <<"getService">> ];
            _ -> [ <<"client">>, Client, <<"system">>, <<"getService">> ]
  end,
  DestRef = gateway_util:binpathchain_to_nowref(DestPath),
  Message =   [
                {<<"destination">>,  DestRef},
                {<<"args">>, [Name, Callback]}
              ],
  gen_server:cast(RabbitHandler, {publish_message, SessionId, Message}),
  State.

handle_join_channel(_, State = #state{privilege = unpriv}) ->
  gen_server:cast(self(), {error, 104, "Join channel permissions denied"}),
  State;
handle_join_channel(DataList, State = #state{rabbit_handler = RabbitHandler, privilege = priv}) ->
  Callback = proplists:get_value(<<"callback">>, DataList),
  Handler = proplists:get_value(<<"handler">>, DataList),
  Name = proplists:get_value(<<"name">>, DataList),

  case gateway_util:validate_name(Name) of
    true -> HandlerBinPathChain = gateway_util:extract_binpathchain_from_nowref(Handler),
            HandlerSessionId = lists:nth(2, HandlerBinPathChain),

            HookBinPath = [ <<"client">>, HandlerSessionId, <<"system">>, <<"hookChannelHandler">> ],
            HookRef = gateway_util:binpathchain_to_nowref(HookBinPath),

            gen_server:cast(RabbitHandler, {join_channel, Name, binary_to_list(HandlerSessionId)}),
            %% Create a dummy workerpool so GETOPS can work
            WorkerPoolMessage = [
                                  {<<"destination">>, HookRef },
                                  {<<"cast">>, ["join_workerpool", <<"channel:", Name/binary>>] }
                                ],
            gen_server:cast(RabbitHandler, {publish_message, HandlerSessionId, WorkerPoolMessage}),
            Message = case Callback of 
              undefined -> [
                            {<<"destination">>, HookRef },
                            {<<"args">>, [Name, Handler] }
                           ];
                      _ -> [
                            {<<"destination">>, HookRef },
                            {<<"args">>, [Name, Handler, Callback] }
                           ]
            end,
            gen_server:cast(RabbitHandler, {publish_message, HandlerSessionId, Message});
    false -> gen_server:cast(self(), {error, 105, <<"Invalid channel name: ", Name/binary>>})
  end,
  State.

handle_get_channel(_, State = #state{privilege = unpriv}) ->
  gen_server:cast(self(), {error, 106, "Get channel permissions denied"}),
  State;
handle_get_channel(DataList, State = #state{rabbit_handler = RabbitHandler
                                            , sessionid = SessionId
                                            , privilege = priv}) ->
  Callback = proplists:get_value(<<"callback">>, DataList),
  Name = proplists:get_value(<<"name">>, DataList),
  case gateway_util:validate_name(Name) of
    true -> %% Ensure links are made
            gen_server:cast(RabbitHandler, {get_channel, Name, SessionId}),
            case Callback of 
              undefined -> State;
                      _ -> handle_getops([{<<"name">>, <<"channel:", Name/binary>>}, {<<"callback">>, Callback}], State)
            end;
    false -> gen_server:cast(self(), {error, 107, <<"Invalid channel name: ", Name/binary>>}),
             State
  end,
  State.

handle_leave_channel(_, State = #state{privilege = unpriv}) ->
  gen_server:cast(self(), {error, 108, "Leave channel permissions denied"}),
  State;
handle_leave_channel(DataList, State = #state{rabbit_handler = RabbitHandler
                                              , sessionid = SessionId
                                              , privilege = priv}) ->
  Callback = proplists:get_value(<<"callback">>, DataList),
  Handler = proplists:get_value(<<"handler">>, DataList),
  Name = proplists:get_value(<<"name">>, DataList),

  case gateway_util:validate_name(Name) of
    true -> HandlerBinPathChain = gateway_util:extract_binpathchain_from_nowref(Handler),
            HandlerSessionId = lists:nth(2, HandlerBinPathChain),

            gen_server:cast(RabbitHandler, {leave_channel, Name, binary_to_list(HandlerSessionId)}),
            Message = [
                {<<"destination">>, Callback },
                {<<"args">>, [Name] }
              ],

            gen_server:cast(RabbitHandler, {publish_message, SessionId, Message});
    false -> gen_server:cast(self(), {error, 109, <<"Invalid channel name: ", Name/binary>>})
  end,
  State.

handle_send(Data, State = #state{sessionid = SessionId, rabbit_handler = RabbitHandler}) ->
  {DataList} = proplists:get_value(<<"destination">>,Data),
  Pathchain = proplists:get_value(<<"ref">>, DataList),
  
  %% Erlang does not allow expression as guards, so store these booleans
  SystemCall = lists:nth(3, Pathchain) == <<"system">>,
  
  if
    SystemCall ->
      gen_server:cast(self(), {error, 111, "System service calls are not allowed"});
    true ->
      gen_server:cast(RabbitHandler, {publish_message, SessionId, Data})
  end,
  State.

verify_secret([null, null]) ->
  Session = [gateway_util:gen_id(), gateway_util:gen_id()],
  true = ets:insert(secret, {lists:nth(1, Session), lists:nth(2, Session)}),
  Session;
verify_secret(Session) ->
  [SessionId, Secret] = SessionList = lists:map(fun binary_to_list/1, Session),
  case ets:lookup(secret, SessionId) of
    [{SessionId, Secret}] -> SessionList;
        _     -> verify_secret([null, null])
  end.

handle_connect(DataList, State = #state{outbound_connection = OutboundConnection}) ->
  [Id, Secret] = verify_secret(proplists:get_value(<<"session">>, DataList)),
  ApiKey = proplists:get_value(<<"api_key">>, DataList),

  OutConn = OutboundConnection#gateway_connection{session_id = Id},
  Mod = OutConn#gateway_connection.callback_module,
  
  case ctl_handler:lookup_priv(ApiKey) of
    false ->
      gen_server:cast(self(), {error, 220, "No valid api key provided."}),
      State#state{sessionid = Id, outbound_connection = OutConn};
    {Privilege, BinApiKey} ->
      Mod:send(OutConn, list_to_binary(lists:concat([Id, "|", Secret]))),
      %% Try to find old rabbit handler
      case ets:lookup(rabbithandlers, Id) of
        [{Id, {Ref, RabbitHandler}}] -> erlang:cancel_timer(Ref),
                                        gen_server:cast(RabbitHandler, resume_subs),
                                        gen_server:cast(RabbitHandler, {change_protocol, self()}),
                                        ets:delete(rabbithandlers, Id);
                             _       -> {ok, RabbitHandler} = gateway_rabbit_sup:start_child(),
                                        gen_server:call(RabbitHandler, {ready, self(), Id, BinApiKey})
      end,
      State#state{sessionid = Id, outbound_connection = OutConn, rabbit_handler = RabbitHandler, api_key = BinApiKey, privilege = Privilege}
  end.

handle_cast({msg, RawData}, State) ->
  try
    {ok, JSONDecoded} = gateway_util:decode(RawData),
    {PropList} = JSONDecoded,
    Command = proplists:get_value(<<"command">>, PropList),
    Data = proplists:get_value(<<"data">>, PropList),
    {DataList} = Data,
    {noreply, case Command of
      <<"SEND">> ->
        handle_send(DataList, State);
      <<"JOINWORKERPOOL">> ->
        handle_join_worker_pool(DataList, State);
      <<"LEAVEWORKERPOOL">> ->
        handle_leave_worker_pool(DataList, State);
      <<"JOINCHANNEL">> ->
        handle_join_channel(DataList, State);
      <<"GETCHANNEL">> ->
        handle_get_channel(DataList, State);
      <<"LEAVECHANNEL">> ->
        handle_leave_channel(DataList, State);
      <<"CONNECT">> ->
        handle_connect(DataList, State);
      <<"GETOPS">> ->
        handle_getops(DataList, State);
      _ ->
        gen_server:cast(self(), {error, 221, ["Unrecognized Command", Command]}),
        State
    end}
  catch
    _:Reason -> gen_server:cast(self(), {error, 222, ["Error handling messaged", Reason, erlang:get_stacktrace()]}),
    {noreply, State}
  end;

handle_cast({send, Data}, State = #state{outbound_connection = OutboundConnection = #gateway_connection{callback_module = Mod}, api_key = ApiKey}) ->
  case ctl_handler:update_metering(ApiKey) of
    ok ->
      Mod:send(OutboundConnection, Data);
    {timeout, Left}  ->
      gen_server:cast(self(), {error, 112, "API limit reached. Disabled for (seconds) " ++ integer_to_list(Left)});
    _ ->
      gen_server:cast(self(), {error, 303, "Unknown API management internal error"})
  end,
  {noreply, State};
handle_cast({force_send, Data}, State = #state{outbound_connection = OutboundConnection = #gateway_connection{callback_module = Mod}}) ->
  Mod:send(OutboundConnection, Data),
  {noreply, State};

handle_cast({error, ErrorId, Message}, State = #state{sessionid = SessionId}) ->  
  ErrorMessage = io_lib:format("Error #~p [~p] : ~p", [ErrorId, SessionId, Message]),
  gateway_util:error(string:concat(ErrorMessage, "~n")),

  case SessionId of
    undefined -> BinSessionId = <<"undefined">>;
            _ -> BinSessionId = list_to_binary(SessionId)
  end,

  DestinationPath = [ <<"client">>, BinSessionId, <<"system">>, <<"remoteError">> ],
  Destination = gateway_util:binpathchain_to_nowref(DestinationPath),

  Payload = gateway_util:encode({[
              {<<"destination">>, Destination },
              {<<"args">>, [list_to_binary(ErrorMessage)] }
            ]}),
  gen_server:cast(self(), {force_send, Payload}),

  {noreply, State};

handle_cast(stop, State) ->
  {stop, normal, State};
handle_cast(_Msg, State) ->
  gateway_util:warn("Error #223 : Unknown Command: ~p~n", [_Msg]),
  {noreply, State}.

handle_call({ready, OutConn}, _From, State) ->
  {reply, ok, State#state{outbound_connection = OutConn}};

handle_call(_Msg, _From, State) ->
  gateway_util:warn("Error #224 : Unknown Command: ~p~n", [_Msg]),
  {reply, unknown_command, State}.

handle_info(_Info, State) ->
  gateway_util:warn("Error #225 : Unknown Info: Ignoring: ~p~n", [_Info]),
  {noreply, State}.

terminate(_, #state{sessionid = Id, rabbit_handler=RabbitHandler, outbound_connection = OutConn = #gateway_connection{callback_module = Mod}}) ->
  {ok, ReconnectTimeout} = application:get_env(gateway, reconnect_timeout),
  Ref = erlang:send_after(ReconnectTimeout, RabbitHandler, close),
  gen_server:cast(RabbitHandler, pause_subs),
  ets:insert(rabbithandlers, {Id , {Ref, RabbitHandler}}),
  Mod:close(OutConn),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
