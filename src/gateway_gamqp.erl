% Gateway Global AMQP - Initializes and maintains Node-Global AMQP Connection.
% Can be asked for the connection with a call.

-module(gateway_gamqp).
-behaviour(gen_server).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).


-record(state, {connection}).
-include_lib("amqp_client/include/amqp_client.hrl").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%---------------------------
% Gen Server Implementation
% --------------------------

init([]) ->
    {ok, Hostname} = inet:gethostname(),
    Node = erlang:list_to_atom("rabbit@" ++ Hostname),

    Connect = case net_adm:ping(Node) of
        pong -> gateway_util:info("Connecting using direct messaging~n"),
                #amqp_params_direct{node = Node};
        pang -> gateway_util:warn("Connecting using network messaging~n"),
                #amqp_params_network{}
    end,

    case amqp_connection:start(Connect) of
      {ok, Connection} -> ok;
                     _ -> gateway_util:error("Error #302 : Cannot connect to Rabbit server~n"),
                          Connection = false,
                          exit(cannot_connect_to_rabbit)
    end,

    {ok, Channel} = amqp_connection:open_channel(Connection),

    gateway_util:info("Establishing AMQP and declaring default and error exchange~n"),

    #'exchange.declare_ok'{} = amqp_channel:call(Channel, #'exchange.declare'{exchange = <<"T_NAMED">>,
                                                   type = <<"topic">>
                                                   }),
    {ok, #state{connection = Connection}}.

handle_call(get_new_channel, _From, State = #state{connection = Connection}) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    {reply, Channel, State};
    
handle_call(_Msg, _From, State) ->
    gateway_util:warn("Error #216 : Unknown Command: ~p~n", [_Msg]),
    {reply, unknown_command, State}.

handle_cast(_Cast, State) ->
    gateway_util:warn("Error #215 : Unknown Command: ~p~n", [_Cast]),
    {noreply, State}.

handle_info(_Info, State) ->
    gateway_util:warn("Error #217 : Unknown Command: ~p~n", [_Info]),
    {noreply, State}.

terminate(_, #state{connection = Connection}) ->
    %amqp_channel:call(Channel, #'channel.close'{}),
    gateway_util:info("Terminating ~s~n", [Connection]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


