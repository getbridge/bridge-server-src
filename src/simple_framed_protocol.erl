-module(simple_framed_protocol).
-behaviour(cowboy_protocol).
-behaviour(gateway_callbacks).

-include_lib("gateway.hrl").

% cowboy_protocol
-export([start_link/4]).
-export([init/4]).
-export([send/2, close/1]).

-record(state, {
    buffer = <<>>,
    socket,
    transport,
    connection
  }).

start_link(ListenerPid, Socket, Transport, Opts) ->
  Pid = spawn_link(?MODULE, init, [ListenerPid, Socket, Transport, Opts]),
  {ok, Pid}.

init(ListenerPid, Socket, Transport, _Opts) ->
  ok = cowboy:accept_ack(ListenerPid),
  inet:setopts(Socket, [{packet, 4}, {nodelay, true}]),
  {ok, Pid} = gateway_client_sup:start_child(),
  OutConn = #gateway_connection{client = Pid, impl = {Transport, Socket},
				callback_module = ?MODULE},
  gen_server:call(OutConn#gateway_connection.client,
		  {ready, OutConn}),
  collect(#state{socket = Socket, transport = Transport, connection = OutConn}),
  done.


connection_died(Connection) ->
  Pid = Connection#gateway_connection.client,
  gen_server:cast(Pid, stop),
  close(Connection).

collect(State = #state{
          socket = Socket,
          transport = Transport,
          connection = OutConn
        }) ->
  case Transport:recv(Socket, 0, infinity) of
    {ok, Data} ->
      Pid = OutConn#gateway_connection.client,
      gen_server:cast(Pid, {msg, Data}),
      collect(State);
    {error, _Reason} ->
      connection_died(OutConn),
      ok
  end.

send(OutConn = #gateway_connection{impl = {Transport, Sock}}, Data) ->
  case Transport:send(Sock, Data) of
    ok ->
      ok;
    {error, _Reason} ->
      connection_died(OutConn),
      error
  end.

close(#gateway_connection{impl = {Transport, Sock}}) ->
  Transport:close(Sock).
