%% Keep track of one client's connection to AMQP - by however many channels neccesary
%% When done, help clean up.

-module(gateway_rabbit_handler).
-behaviour(gen_server).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {channel, protocol, subscriptions=[], exchanges=[], queues=[], sessionid, api_key}).

-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("gateway.hrl").
-include_lib("metering.hrl").

start_link() ->
  gen_server:start_link(?MODULE, [], []).

%% gen_server
init([]) ->
  Channel = gen_server:call(gateway_gamqp, get_new_channel),
  {ok, #state{channel=Channel}}.

handle_call({ready, Protocol, SessionId, ApiKey}, _From,
    State = #state{
      channel = Channel, queues=Queues, exchanges=Exchanges
    }
  ) ->
  ExchangeName = list_to_binary(["T_", SessionId]),
  ExchangeDeclare = #'exchange.declare'{exchange = ExchangeName,
                                        type = <<"topic">>
                                        % , arguments = [{"alternate-exchange", longstr, "F_ERROR"}]
                                       },
  #'exchange.declare_ok'{} = amqp_channel:call(Channel, ExchangeDeclare),

  QueueName = list_to_binary(["C_", SessionId]),
  QueueDeclare = #'queue.declare'{queue = QueueName},
  #'queue.declare_ok'{queue = QueueName} = amqp_channel:call(Channel, QueueDeclare),

  ExchangeBinding = #'exchange.bind'{source      = ExchangeName,
                             destination = <<"T_NAMED">>,
                             routing_key = list_to_binary([ApiKey, <<".named.#">>])},
  #'exchange.bind_ok'{} = amqp_channel:call(Channel, ExchangeBinding),

  QueueBinding = #'queue.bind'{exchange      = ExchangeName,
                               queue = list_to_binary(["C_", SessionId]),
                               routing_key = list_to_binary( [ApiKey, <<".client.">>, SessionId, <<".#">>] )},
  #'queue.bind_ok'{} = amqp_channel:call(Channel, QueueBinding),

  amqp_channel:register_return_handler(Channel, self()),

  Sub = #'basic.consume'{queue = QueueName},
  #'basic.consume_ok'{} = amqp_channel:subscribe(Channel, Sub, self()),

  {reply, ok,
    State#state{
      protocol=Protocol,
      queues=[QueueName|Queues],
      exchanges=[ExchangeName|Exchanges],
      sessionid=SessionId,
      api_key = ApiKey
    }
  };
  
handle_call(_Msg, _From, State) ->
  gateway_util:warn("Error #213 : Unknown Command: ~p~n", [_Msg]),
  {reply, unknown_command, State}.

handle_cast({change_protocol, Protocol}, State) ->
  {noreply, State#state{protocol=Protocol}};

handle_cast({join_workerpool, Name}, State = #state{channel = Channel, subscriptions=Subscriptions, api_key = ApiKey}) ->
  QueueName = list_to_binary([<<"W_">>, Name, <<"_">>, ApiKey]),
  QueueDeclare = #'queue.declare'{queue = QueueName},
  #'queue.declare_ok'{queue = QueueName} = amqp_channel:call(Channel, QueueDeclare),
  QueueBinding = #'queue.bind'{queue = QueueName,
                               exchange = <<"T_NAMED">>,
                               routing_key = list_to_binary([ApiKey, <<".named.">>, Name, <<".#">>])},
  #'queue.bind_ok'{} = amqp_channel:call(Channel, QueueBinding),

  Sub = #'basic.consume'{queue = QueueName},
  #'basic.consume_ok'{consumer_tag = Tag} = amqp_channel:subscribe(Channel, Sub, self()),
  {noreply, State#state{subscriptions=[{QueueName, Tag}|Subscriptions]}};
handle_cast({join_channel, Name, HandlerSessionId}, State = #state{channel = Channel, api_key = ApiKey}) ->
  ChannelExchange = list_to_binary([<<"F_">>, Name, <<"_">>, ApiKey]),
  ExchangeDeclare = #'exchange.declare'{exchange = ChannelExchange,
                                  type = <<"fanout">>
                                  %, arguments = [{"alternate-exchange", longstr, "F_ERROR"}]
                                },
  #'exchange.declare_ok'{} = amqp_channel:call(Channel, ExchangeDeclare),
  ExchangeBinding = #'exchange.bind'{source  = list_to_binary([<<"T_">>, HandlerSessionId]),
                                 destination = ChannelExchange,
                                 routing_key = list_to_binary([ApiKey, <<".channel.">>, Name, <<".#">>])},
  #'exchange.bind_ok'{} = amqp_channel:call(Channel, ExchangeBinding),
  QueueBinding = #'queue.bind'{queue = list_to_binary(["C_", HandlerSessionId]),
                               exchange = ChannelExchange},
                               % routing_key = <<"#">>},
  #'queue.bind_ok'{} = amqp_channel:call(Channel, QueueBinding),
  {noreply, State};
handle_cast({get_channel, Name, HandlerSessionId}, State = #state{channel = Channel, api_key = ApiKey}) ->
  ChannelExchange = list_to_binary([<<"F_">>, Name, <<"_">>, ApiKey]),
  ExchangeDeclare = #'exchange.declare'{exchange = ChannelExchange,
                                  type = <<"fanout">>
                                  %, arguments = [{"alternate-exchange", longstr, "F_ERROR"}]
                                },
  #'exchange.declare_ok'{} = amqp_channel:call(Channel, ExchangeDeclare),
  ExchangeBinding = #'exchange.bind'{source  = list_to_binary([<<"T_">>, HandlerSessionId]),
                                 destination = ChannelExchange,
                                 routing_key = list_to_binary([ApiKey, <<".channel.">>, Name, <<".#">>])},
  #'exchange.bind_ok'{} = amqp_channel:call(Channel, ExchangeBinding),
  {noreply, State};
handle_cast({leave_channel, Name, HandlerSessionId}, State = #state{channel = Channel, api_key = ApiKey}) ->
  ChannelExchange = list_to_binary([<<"F_">>, Name, <<"_">>, ApiKey]),
  ExchangeBinding = #'exchange.unbind'{source  = list_to_binary(["T_", HandlerSessionId]),
                                 destination = ChannelExchange,
                                 routing_key = list_to_binary([ApiKey, <<".channel.">>, Name, <<".#">>])},
  #'exchange.unbind_ok'{} = amqp_channel:call(Channel, ExchangeBinding),
  QueueBinding = #'queue.unbind'{queue = list_to_binary(["C_", HandlerSessionId]),
                               exchange = ChannelExchange},
                               % routing_key = <<"#">>},
  #'queue.unbind_ok'{} = amqp_channel:call(Channel, QueueBinding),
  {noreply, State};

handle_cast({publish_message, SessionId, Message}, State = #state{channel = Channel, api_key = ApiKey, protocol = Protocol}) ->
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
          Payload = gateway_util:encode( {Message} ),
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
  lists:map( fun(Sub = {_QueueName, Tag}) ->
                amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = Tag}),
                Sub
              end, Subscriptions ),
  {noreply, State};

%% Resume listening on service bindings
handle_cast(resume_subs, State = #state{channel = Channel, subscriptions = Subscriptions}) ->
  Subs = lists:map(fun({QueueName, _Tag}) ->
              Sub = #'basic.consume'{queue = QueueName},
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

handle_info({#'basic.deliver'{delivery_tag = Tag}, Content},
            State = #state{channel = Channel, protocol = Protocol}
           ) ->
  amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = Tag}),
  #amqp_msg{payload = Payload} = Content,
  try
    {ok, Message} = gateway_util:decode(Payload),
    {DataList} = Message,
    case proplists:is_defined(<<"args">>, DataList) of
      false ->  %% Rabbit handler system call
                [CastHead | CastArgs] = proplists:get_value(<<"cast">>, DataList),
                Cast = list_to_tuple([list_to_atom(CastHead) | CastArgs]),
                gen_server:cast(self(), Cast);
       true ->  Links = gateway_util:now_decode(Message),
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

terminate(_, #state{channel = Channel, subscriptions = Subscriptions, exchanges = Exchanges, queues = Queues}) ->
  lists:map( fun(ExchangeName) -> amqp_channel:call(Channel, #'exchange.delete'{exchange = ExchangeName}) end, Exchanges ),
  lists:map( fun(QueueName) -> amqp_channel:call(Channel, #'queue.delete'{queue = QueueName}) end, Queues ),
  amqp_channel:close(Channel),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

