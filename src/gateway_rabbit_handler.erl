%% Keep track of one client's connection to AMQP - by however many channels neccesary
%% When done, help clean up.

-module(gateway_rabbit_handler).
-behaviour(gen_server).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {channel, protocol, subscriptions=[], exchanges=[], queues=[], sessionid, api_key}).
-record(bridge_resource, {name, rabbit_name, rabbit_type, bridge_type}).

-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("gateway.hrl").
-include_lib("metering.hrl").

start_link() ->
  gen_server:start_link(?MODULE, [], []).

%% gen_server
init([]) ->
  Channel = gen_server:call(gateway_gamqp, get_new_channel),
  {ok, #state{channel=Channel}}.


handle_call({ready, Protocol, SessionId, ApiKey}, _From, State = #state{channel = Channel}) ->
  {ok, ClientExchange} = declare(client_exchange, SessionId, ApiKey, Channel),
  {ok, ClientQueue} = declare(client_queue, SessionId, ApiKey, Channel),
  Namespace = get_resource(namespace, <<"NAMED">>, ApiKey),
  bind(ClientExchange, Namespace, ApiKey, Channel),
  bind(ClientExchange, ClientQueue, ApiKey, Channel),
  amqp_channel:register_return_handler(Channel, self()),

  {ok, Tag} = consume_resource(ClientQueue, Channel),

  {reply, ok,
    State#state{
      protocol=Protocol,
      queues=[ClientQueue|State#state.queues],
      exchanges=[ClientExchange|State#state.exchanges],
      sessionid=SessionId,
      api_key = ApiKey
    }
  };
  
handle_call(_Msg, _From, State) ->
  gateway_util:warn("Error #213 : Unknown Command: ~p~n", [_Msg]),
  {reply, unknown_command, State}.

handle_cast({change_protocol, Protocol}, State) ->
  {noreply, State#state{protocol=Protocol}};

handle_cast({join_workerpool, Name}, 
            State = #state{channel = Channel,
                           subscriptions=Subscriptions,
                           api_key = ApiKey}) ->
  {ok, Service} = declare(service, Name, ApiKey, Channel),
  DefaultNamespace = get_resource(namespace, <<"NAMED">>, ApiKey),
  bind(Service, DefaultNamespace, Channel, ApiKey),
  {ok, Tag} = consume_resource(Service, Channel),
  {noreply, State#state{subscriptions=[{Service#bridge_resource.name, Tag}|Subscriptions]}};

handle_cast({leave_workerpool, Name},  State = #state{subscriptions=Subscriptions}) ->
  QueueName = list_to_binary([<<"W_">>, Name, <<"_">>, State#state.api_key]),
  NewSubs = case lists:keytake(QueueName, 1, Subscriptions) of
    {value, {QueueName, Tag}, NewList} -> 
       amqp_channel:call(State#state.channel, #'basic.cancel'{consumer_tag = Tag}),
       NewList;
     false -> 
       gen_server:cast(State#state.protocol,
                      {error, 115, ["Cannot unpublish service that was not published", Name]}),
       Subscriptions
  end,
  {noreply, State#state{subscriptions=NewSubs}};

handle_cast({join_channel, Name, HandlerSessionId, Writeable},
             State = #state{channel = Channel, api_key = ApiKey}) ->
 {ok, Chan} = declare(channel, Name, ApiKey, Channel),
 ClientQueue = get_resource(client_queue, HandlerSessionId, ApiKey),
 ClientExchange = get_resource(client_exchange, HandlerSessionId, ApiKey),
 bind(Chan, ClientQueue, ApiKey, Channel),
  if
    Writeable -> bind(ClientExchange, Chan, ApiKey, Channel);
    true -> ok
  end,
  {noreply, State};

handle_cast({get_channel, Name, HandlerSessionId},
            State = #state{channel = Channel, api_key = ApiKey}) ->
  {ok, Chan} = declare(channel, Name, ApiKey, Channel) ,
  ClientExchange =  get_resource(client_exchange, HandlerSessionId, ApiKey),
  bind(ClientExchange, Chan, ApiKey, Channel),
  {noreply, State};

handle_cast({leave_channel, Name, HandlerSessionId},
            State = #state{channel = Channel, api_key = ApiKey}) ->
  ChannelExchange = get_resource(channel, Name, ApiKey),
  ClientExchange = get_resource(client_exchange, HandlerSessionId, ApiKey),
  ClientQueue = get_resource(client_queue, HandlerSessionId, ApiKey),
  unbind(ClientExchange, ChannelExchange, ApiKey, Channel),
  unbind(ChannelExchange, ClientQueue, ApiKey, Channel),
  {noreply, State};

handle_cast({publish_message, SessionId, Message},
           State = #state{channel = Channel,
                          api_key = ApiKey,
                          protocol = Protocol}) ->
  Destination = proplists:get_value(<<"destination">>, Message),

  case gateway_util:extract_pathstring_from_nowref(Destination) of
    {ok, RoutingKey} ->
      case ctl_handler:update_metering(ApiKey) of
        ok ->
          BasicPublish = #'basic.publish'{
                                          exchange = list_to_binary(["T_", SessionId]),
                                          routing_key = <<ApiKey/binary, ".", RoutingKey/binary>>,
                                          immediate = true
                                        },
          BinSessionId = if
            is_binary(SessionId) ->
              SessionId;
            true ->
              list_to_binary(SessionId)
          end,

          Src = {<<"source">>, BinSessionId},
          Payload = gateway_util:encode( {[Src|Message]} ),
          Content = #amqp_msg{payload = Payload},

          amqp_channel:call(Channel, BasicPublish, Content),
          {noreply, State};
        {timeout, Left} ->
          gen_server:cast(Protocol, {error, 101, "API limit reached. Disabled for (seconds) " ++ integer_to_list(Left)}),
          {noreply, State};
        _ ->
          gen_server:cast(Protocol, {error, 301, "Unknown API management internal error"}),
          {noreply, State}
      end;
    {fail, Reason} ->
      gen_server:cast(Protocol, {error, 204, ["Failed parse message destination", Reason]}),
      {noreply, State}
  end;

handle_cast(stop, State) ->
  {stop, normal, State};


%% Pause listening on service bindings
handle_cast(pause_subs, State = #state{channel = Channel, subscriptions = Subscriptions}) ->
  lists:foreach( fun({_QueueName, Tag}) ->
                amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = Tag})
              end, Subscriptions ),
  {noreply, State};

%% Resume listening on service bindings
handle_cast(resume_subs, State = #state{channel = Channel, subscriptions = Subscriptions}) ->
  Subs = lists:map(fun({QueueName, _Tag}) ->
              Sub = #'basic.consume'{queue = QueueName, no_ack = true},
              #'basic.consume_ok'{consumer_tag = NewTag} = amqp_channel:subscribe(Channel, Sub, self()),
              {QueueName, NewTag}
            end, Subscriptions ),
  {noreply, State#state{subscriptions=Subs}};

handle_cast(_Msg, State) ->
  gateway_util:warn("Error #212 : Unknown Command: ~p~n", [_Msg]),
  {noreply, State}.

handle_info(close, State = #state{sessionid = Id}) ->
  ets:delete(rabbithandlers, Id),
  ets:delete(secret, Id),
  gen_server:cast(self(), stop),
  {noreply, State};
handle_info(#'basic.consume_ok'{}, State = #state{channel = _Channel}) ->
  {noreply, State};
handle_info(#'basic.cancel_ok'{}, State = #state{channel = _Channel}) ->
  {noreply, State};
handle_info({#'basic.return'{exchange = Exchange, routing_key = Key}, _Content}, State = #state{protocol = Protocol}) ->
  {ErrorCode, ErrorMsg} = gateway_util:basic_return_error(Key, Exchange),
  gen_server:cast(Protocol, {error, ErrorCode, ErrorMsg}),
  {noreply, State};

handle_info({#'basic.deliver'{}, Content},
            State = #state{protocol = Protocol}) ->
  #amqp_msg{payload = Payload} = Content,
  try
    {ok, Message} = gateway_util:decode(Payload),
    {DataList} = Message,
    case proplists:is_defined(<<"source">>, DataList) of
      true ->
        bind_refs({[{<<"ref">>, [<<"client">>, proplists:get_value(<<"source">>, DataList)]}]}, State);
      _ ->
        ok
    end,
    case proplists:is_defined(<<"args">>, DataList) of
      %% Rabbit handler system call
      false -> [CastHead | CastArgs] = proplists:get_value(<<"cast">>, DataList),
	       Cast = list_to_tuple([list_to_atom(CastHead) | CastArgs]),
	       gen_server:cast(self(), Cast);
       true -> Links = gateway_util:now_decode(Message),
	       case Links of
           undefined -> ok;
           _ ->  lists:foreach(fun(Link) -> 
                   bind_refs(Link, State)
                 end, Links),
                 gen_server:cast(Protocol, {send, Payload})
	       end
    end
  catch
    Reason -> gen_server:cast(Protocol, {error, 205, ["Could not parse message delivery", Reason, erlang:get_stacktrace()]})
  end,
  {noreply, State};
  
handle_info(_Info, State) ->
  gateway_util:warn("Error #214 : Unknown Info: Ignoring: ~p~n", [_Info]),
  {noreply, State}.

bind_refs(Link, #state{channel = Channel, sessionid = SessionId, api_key = ApiKey})->
  case hd(proplists:get_value(<<"ref">>, element(1, Link))) of
    <<"client">> -> case gateway_util:extract_binpathchain_from_nowref(Link) of
                      Pathchain ->
                        QueueDeclare = #'queue.declare'{
                                          queue = list_to_binary(["C_", lists:nth(2,Pathchain)])
                                       },
                                      #'queue.declare_ok'{queue = QueueName} = amqp_channel:call(Channel, QueueDeclare),
                        RoutingKey = list_to_binary([ApiKey, <<".">>, lists:nth(1, Pathchain), <<".">>, lists:nth(2, Pathchain), <<".#">>]),
                        QueueBinding = #'queue.bind'{queue = QueueName,
                                        exchange = list_to_binary(["T_", SessionId]),
                                        routing_key = RoutingKey},
                        #'queue.bind_ok'{} = amqp_channel:call(Channel, QueueBinding),
                        true
                     end;
               _ -> ok
  end.

terminate(_, #state{channel = Channel}) ->
  amqp_channel:close(Channel),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


%% RabbitMQ command generators

get_resource(client_exchange, SessionId, _ApiKey) ->
  #bridge_resource{
            name = SessionId,
            rabbit_name = list_to_binary(["T_", SessionId]),
            bridge_type = client_exchange,
            rabbit_type = {exchange, <<"topic">>}};

get_resource(client_queue, SessionId, _ApiKey) ->
  #bridge_resource{
            name = SessionId,
            rabbit_name = list_to_binary(["C_", SessionId]),
            bridge_type = client_queue,
            rabbit_type = queue};

get_resource(namespace, Namespace, _ApiKey) ->
  #bridge_resource{
            name = Namespace,
            rabbit_name = list_to_binary(["T_", Namespace]),
            bridge_type = namespace,
            rabbit_type = {exchange, <<"topic">>}};

get_resource(service, Service, ApiKey) ->
  #bridge_resource{
            name = Service,
            rabbit_name = list_to_binary([<<"W_">>, Service, <<"_">>, ApiKey]),
            bridge_type = service,
            rabbit_type = queue};

get_resource(channel, Channel, ApiKey) ->
  #bridge_resource{
            name = Channel,
            rabbit_name = list_to_binary([<<"F_">>, Channel, <<"_">>, ApiKey]),
            bridge_type = channel,
            rabbit_type = {exchange, <<"fanout">>}}.

declare(ResourceType, ResourceName, ApiKey, AMQPChannel) ->
  Resource = get_resource(ResourceType, ResourceName, ApiKey),
  case Resource of
    #bridge_resource{rabbit_name = Name, rabbit_type = queue} ->
      QueueDeclare = #'queue.declare'{queue = Name},
      #'queue.declare_ok'{queue = QueueName} = amqp_channel:call(AMQPChannel, QueueDeclare);

    #bridge_resource{rabbit_name = Name, rabbit_type = {exchange, ExchangeType}} ->
      ExchangeDeclare = #'exchange.declare'{exchange = Name, type = ExchangeType},
      #'exchange.declare_ok'{} = amqp_channel:call(AMQPChannel, ExchangeDeclare)

  end,
  {ok, Resource}.

get_routing_key(_Sink = #bridge_resource{bridge_type = namespace, name = Name}, ApiKey) ->
  list_to_binary([ApiKey, <<".named.#">>]);

get_routing_key(#bridge_resource{bridge_type = client_queue, name = SessionId}, ApiKey) ->
  list_to_binary( [ApiKey, <<".client.">>, SessionId, <<".#">>] );

get_routing_key(#bridge_resource{bridge_type = service, name = Name}, ApiKey) ->
  list_to_binary([ApiKey, <<".named.">>, Name, <<".#">>]);

get_routing_key(#bridge_resource{bridge_type = channel, name = Name}, ApiKey) ->
  list_to_binary([ApiKey, <<".channel.">>, Name, <<".#">>]);

get_routing_key(_, _) ->
  <<"">>.

bind(Source = #bridge_resource{rabbit_type = {exchange, _}},
     Sink = #bridge_resource{rabbit_type = queue}, ApiKey, Channel
    ) ->
  QueueBinding = #'queue.bind'{queue = Sink#bridge_resource.rabbit_name,
                               exchange = Source#bridge_resource.rabbit_name,
                               routing_key = get_routing_key(Sink, ApiKey)},
  #'queue.bind_ok'{} = amqp_channel:call(Channel, QueueBinding),
  ok;

bind(Source = #bridge_resource{rabbit_type = {exchange, _}},
     Sink = #bridge_resource{rabbit_type = {exchange, _}}, ApiKey, Channel
    ) ->
  ExchangeBinding = #'exchange.bind'{source      = Source#bridge_resource.rabbit_name,
                             destination = Sink#bridge_resource.rabbit_name,
                             routing_key = get_routing_key(Sink, ApiKey)},
  #'exchange.bind_ok'{} = amqp_channel:call(Channel, ExchangeBinding),
  ok.

unbind(Source = #bridge_resource{rabbit_type = {exchange, _}},
       Sink = #bridge_resource{rabbit_type = queue}, ApiKey, Channel
      ) ->
  QueueBinding = #'queue.unbind'{queue = Sink#bridge_resource.rabbit_name,
                               exchange = Source#bridge_resource.rabbit_name,
                               routing_key = get_routing_key(Sink, ApiKey)},
  #'queue.unbind_ok'{} = amqp_channel:call(Channel, QueueBinding),
  ok;

unbind(Source = #bridge_resource{rabbit_type = {exchange, _}},
       Sink = #bridge_resource{rabbit_type = {exchange, _}},ApiKey, Channel
      ) ->
  ExchangeBinding = #'exchange.unbind'{source      = Source#bridge_resource.rabbit_name,
                             destination = Sink#bridge_resource.rabbit_name,
                             routing_key = get_routing_key(Sink, ApiKey)},
  #'exchange.unbind_ok'{} = amqp_channel:call(Channel, ExchangeBinding),
  ok.


consume_resource(#bridge_resource{rabbit_type = queue, rabbit_name = Name}, Channel) ->
  Sub = #'basic.consume'{queue = Name, no_ack = true},
  #'basic.consume_ok'{consumer_tag = Tag} = amqp_channel:subscribe(Channel, Sub, self()),
  {ok, Tag}.
