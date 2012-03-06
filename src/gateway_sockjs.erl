-module(gateway_sockjs).

-include_lib("gateway.hrl").

-behavior(gateway_callbacks).

% For sockjs input
-export([dispatcher/0, mqb_handle/1, mqb_handle/2]).

% For gateway_callbacks behavior
-export([send/2, close/1]).
-export([get_sockId/1]).


dispatcher() ->
    [{bridge, fun mqb_handle/2}].

% Initialize Table
mqb_handle(start) ->
    ets:new(broadcast_table, [public, named_table]),
    ets:new(secret, [public, named_table]),
    ets:new(rabbithandlers, [public, named_table]),
    gateway_util:info("Initializing~n"),
    ok.

% Create SessionId, and register Connection with SessionId
mqb_handle(Conn, init) ->
    SockId = get_sockId(Conn),
    
    {ok, Handler} = gateway_client_sup:start_child(),
    OutConn = #gateway_connection{client = Handler, impl = Conn, callback_module = ?MODULE},
    true = ets:insert(broadcast_table, {SockId, OutConn} ),
    gen_server:call(Handler, {ready, OutConn} ),
    gateway_util:info("Registered ~p with ~p~n", [SockId, {Conn, Handler}]),
    ok;

% Look up SockId, Shutdown Handler, Delete SockId
mqb_handle(Conn, closed) ->
    SockId = get_sockId(Conn),
    LookUp = ets:lookup(broadcast_table, SockId),
    case LookUp of
      [{SockId, #gateway_connection{client = Handler}}] ->
            true = ets:delete(broadcast_table, SockId),
            gen_server:cast(Handler, stop),
            gateway_util:info("~s: Connection closed~n", [SockId]),
            true;
        _ ->
            gateway_util:error("Failed1 to find sockjs connection for ~p ~p~n", [SockId, LookUp]),
            false
    end,
    ok;

mqb_handle(Conn, {recv, Data}) ->
    SockId = get_sockId(Conn),
    LookUp = ets:lookup(broadcast_table, SockId),
    case LookUp of
        [{SockId, #gateway_connection{client = Handler}}] ->
            gen_server:cast(Handler, {msg, Data}),
            true;
        _ ->
            gateway_util:error("Failed2 to find sockjs connection for ~p ~p~n", [SockId, LookUp]),
            false
    end,
    ok.


%% --------------------------------------------------------------------------
send(#gateway_connection{impl=Conn}, Data) ->
  SockId = get_sockId(Conn),
  LookUp = ets:lookup(broadcast_table, SockId),
  case LookUp of
      [{SockId, #gateway_connection{impl=Conn}}] ->
          Conn:send(Data);
      _ ->
          gateway_util:error("Failed3 to find sockjs connection for ~p ~p~n", [SockId, LookUp]),
          false
  end.

close(#gateway_connection{impl=Conn}) ->
  Conn:close(666, "Connection closed").

%% --------------------------------------------------------------------------
get_sockId(Conn) ->
    case Conn of
        {_,_,_,SockId} -> SockId;
        {_,SockId} -> SockId
    end.
