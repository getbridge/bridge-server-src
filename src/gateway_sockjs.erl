-module(gateway_sockjs).

-include_lib("gateway.hrl").

-behavior(gateway_callbacks).

% For sockjs input
-export([handle_sockjs/2]).

% For gateway_callbacks behavior
-export([send/2, close/1]).


% Create SessionId, and register Connection with SessionId
handle_sockjs(Conn, init) ->
    {ok, Handler} = gateway_client_sup:start_child(),
    OutConn = #gateway_connection{client = Handler, impl = Conn, callback_module = ?MODULE},
    true = ets:insert(sockjs_handler_table, {Conn, OutConn} ),
    gen_server:call(Handler, {ready, OutConn} ),
    ok;

% Look up SockId, Shutdown Handler, Delete SockId
handle_sockjs(Conn, closed) ->
    LookUp = ets:lookup(sockjs_handler_table, Conn),
    case LookUp of
      [{Conn, #gateway_connection{client = Handler}}] ->
            true = ets:delete(sockjs_handler_table, Conn),
            gen_server:cast(Handler, stop),
            true;
        _ ->
            gateway_util:error("Error #201: Failed to find sockjs connection~n"),
            false
    end,
    ok;

handle_sockjs(Conn, {recv, Data}) ->
    LookUp = ets:lookup(sockjs_handler_table, Conn),
    case LookUp of
        [{Conn, #gateway_connection{client = Handler}}] ->
            gen_server:cast(Handler, {msg, Data}),
            true;
        _ ->
            gateway_util:error("Error #202: Failed to find sockjs connection~n"),
            false
    end,
    ok.


%% --------------------------------------------------------------------------
send(#gateway_connection{impl=Conn}, Data) ->
  sockjs:send(Conn, Data).

close(#gateway_connection{impl=Conn}) ->
  sockjs:close(Conn, 666, "Connection closed").

%% --------------------------------------------------------------------------
