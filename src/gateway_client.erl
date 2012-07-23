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
-include_lib("messages.hrl").

start_link() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
  {ok, #state{}}.

% Utility methods
invoke_rpc(Ref, Args, #state{rabbit_handler = Router, sessionid = SessionId}) ->
  Message = [{<<"destination">>, Ref }, {<<"args">>, Args }],
  gen_server:cast(Router, {publish_message, SessionId, Message}).


invoke_cast(Ref, Args, SessionId, #state{rabbit_handler = Router}) ->
  Message = [{<<"destination">>, Ref}, {<<"cast">>, Args}],
  gen_server:cast(Router, {publish_message, SessionId, Message}).


call_callback(undefined, _ , _) ->
  ok;

call_callback(CBRef, Args, State) ->
  CBRef2 = gateway_reference:set_method(CBRef, <<"callback">>),
  invoke_rpc(CBRef2, Args, State).


make_hookchannel_reference(ClientRef) ->
  SessionId = gateway_reference:get_destination_id(ClientRef),
  SystemRef = gateway_reference:client_reference(SessionId, <<"system">>),
  gateway_reference:set_method(SystemRef, <<"hookChannelHandler">>).


append_callback_to_args(Args, undefined) ->
  Args;

append_callback_to_args(Args, Callback) ->
  Args ++ [Callback].


% API handlers

handle_command(#join_workerpool{}, State = #state{privilege = unpriv}) ->
  gateway_error:no_publish_perms(),
  State;

handle_command(#join_workerpool{name = {invalid, Name}}, State) ->
  gateway_error:invalid_service_name(Name),
  State;

handle_command(#join_workerpool{name = Name, callback = Callback}, State) ->
  gen_server:cast(State#state.rabbit_handler, {join_workerpool, Name}),
  call_callback(Callback, [Name], State),
  State;

handle_command(#leave_workerpool{}, State = #state{privilege = unpriv}) ->
  gateway_error:no_unpublish_perms(),
  State;

handle_command(#leave_workerpool{name = {invalid, Name}}, State) ->
  gateway_error:invalid_service_name(Name),
  State;

handle_command(#leave_workerpool{name = Name, callback = Callback}, State) ->
  gen_server:cast(State#state.rabbit_handler, {leave_workerpool, Name}),
  call_callback(Callback, [Name], State),
  State;

handle_command(#get_ops{callback = undefined}, State) ->
  State;

handle_command(#get_ops{client = undefined, name = Name, callback = Callback}, State) ->
  DestRef =  gateway_reference:service_reference(Name, <<"system">>),
  DestRef2 = gateway_reference:set_method(DestRef, <<"getService">>),
  invoke_rpc(DestRef2, [Name, Callback], State),
  State;

handle_command(#get_ops{client = Client, name = Name, callback = Callback}, State) ->
  DestRef =  gateway_reference:client_reference(Client, <<"system">>),
  DestRef2 = gateway_reference:set_method(DestRef, <<"getService">>),
  invoke_rpc(DestRef2, [Name, Callback], State),
  State;

handle_command(#join_channel{}, State = #state{privilege = unpriv}) ->
  gateway_error:no_join_perms(),
  State;

handle_command(#join_channel{name = {invalid, Name}}, State) ->
  gateway_error:invalid_channel_name(Name),
  State;

handle_command(#join_channel{name = Name, handler = Handler, callback = Callback, writeable = Writeable}, State) ->
  ClientRef = make_hookchannel_reference(Handler),
  gen_server:cast(State#state.rabbit_handler, {join_channel, Name, gateway_reference:get_destination_id(ClientRef), Writeable}),
  % invoke_cast(ClientRef, ["join_workerpool", <<"channel:", Name/binary>>], SessionId, State),
  Args = append_callback_to_args([Name, Handler], Callback),
  invoke_rpc(ClientRef, Args, State),
  State;


handle_command(#get_channel{}, State = #state{privilege = unpriv}) ->
  gateway_error:no_getchannel_perms(),
  State;

handle_command(#get_channel{name = {invalid, Name}}, State) ->
  gateway_error:invalid_channel_name(Name),
  State;

handle_command(#get_channel{name = Name, callback = Callback},
               State = #state{sessionid = SessionId,
                              rabbit_handler = RabbitHandler}) ->
  gen_server:cast(RabbitHandler, {get_channel, Name, SessionId}),
  handle_command(#get_ops{name = <<"channel:", Name/binary>>, callback = Callback}, State);

handle_command(#leave_channel{}, State = #state{privilege = unpriv}) ->
  gateway_error:no_leavechannel_perms(),
  State;

handle_command(#leave_channel{name = {invalid, Name}}, State) ->
  gateway_error:invalid_channel_name(Name),
  State;

handle_command(#leave_channel{name = Name,
                              handler = Handler,
                              callback = Callback}, State ) ->
  HandlerSessionId = gateway_reference:get_destination_id(Handler),
  gen_server:cast(State#state.rabbit_handler,
                  {leave_channel, Name, binary_to_list(HandlerSessionId)}),
  call_callback(Callback, [Name], State),
  State;


handle_command(Data = #send{destination = Destination}, State) ->
  SystemCall = gateway_reference:get_object_id(Destination) == <<"system">>,
  send0(Data, SystemCall, State);

handle_command(#connect{session = Session, api_key = ApiKey},
               State = #state{outbound_connection = OutboundConnection}) ->
  [Id, Secret] = verify_secret(Session),
  IsValidKey = ctl_handler:lookup_priv(ApiKey),
  initialize_state(IsValidKey, Id, Secret,  State).


send0(_, true, State) ->
  gateway_error:system_service(),
  State;

send0(#send{destination = Destination, args = Args}, _, State) ->
  invoke_rpc(Destination, Args, State),
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

initialize_state(ApiKey = false, Id, _, State) ->
  gateway_error:no_valid_api_key(),
  State#state{sessionid = Id};

initialize_state({Privilege, ApiKey}, Id, Secret, State) ->
  gen_server:cast(self(), {send, list_to_binary(lists:concat([Id, "|", Secret]))}),
  IsReconnect =  ets:lookup(rabbithandlers, Id),
  Router = initialize_routing(IsReconnect, Id, ApiKey),
  State#state{sessionid = Id, rabbit_handler = Router, api_key = ApiKey, privilege = Privilege}.

initialize_routing(_IsReconnect = [], Id, ApiKey) ->
  {ok, Router} = gateway_rabbit_sup:start_child(),
  gen_server:call(Router, {ready, self(), Id, ApiKey}),
  Router;

initialize_routing([{Id, {Timer, Router}}], Id, ApiKey) ->
   erlang:cancel_timer(Timer),
   gen_server:cast(Router, resume_subs),
   gen_server:cast(Router, {change_protocol, self()}),
   ets:delete(rabbithandlers, Id),
   Router.

handle_cast({msg, RawData}, State) ->
  {ok, Struct} = gateway_util:decode(RawData),
  Command = gateway_messages:struct_to_record(Struct),
  {noreply, handle_command(Command, State)};

handle_cast({send, Data},
            State = #state{outbound_connection = OutboundConnection = #gateway_connection{callback_module = Mod},
            api_key = ApiKey}) ->
  case ctl_handler:update_metering(ApiKey) of
    ok ->
      Mod:send(OutboundConnection, Data);
    {timeout, Left}  ->
      gen_server:cast(self(), {error, 112, "API limit reached. Disabled for (seconds) " ++ integer_to_list(Left)});
    _ ->
      gen_server:cast(self(), {error, 303, "Unknown API management internal error"})
  end,
  {noreply, State};
handle_cast({force_send, Data},
            State = #state{outbound_connection = OutboundConnection = #gateway_connection{callback_module = Mod}}) ->
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

terminate(_, #state{sessionid = Id, 
                    rabbit_handler=RabbitHandler,
                    outbound_connection = OutConn = #gateway_connection{callback_module = Mod}}) ->
  {ok, ReconnectTimeout} = application:get_env(gateway, reconnect_timeout),
  Ref = erlang:send_after(ReconnectTimeout, RabbitHandler, close),
  gen_server:cast(RabbitHandler, pause_subs),
  ets:insert(rabbithandlers, {Id , {Ref, RabbitHandler}}),
  Mod:close(OutConn),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
