-module(cowboy_server).
-export([start_link/0]).
-export([init/0]).

-include("metering.hrl").

start_link() ->
  Pid = spawn_link(?MODULE, init, []),
  {ok, Pid}.

init()->
  {ok, WebPort} = application:get_env(gateway, web_port),
  {ok, TCPPort} = application:get_env(gateway, tcp_port),
  {ok, CtlPort} = application:get_env(gateway, ctl_port),
  
  application:start(cowboy),
       
      GatewaySockJs = sockjs_handler:init_state(<<"/bridge">>, fun gateway_sockjs:handle_sockjs/2, [{logger, fun(_,_) -> ok end}]),

       
       Dispatch = [{'_', % domain specifier
                    [{
                      [<<"bridge">>, '...'], 
                      sockjs_cowboy_handler, 
                      GatewaySockJs
                    }]
                  }],
       cowboy:start_listener(http, 100,
                             cowboy_tcp_transport, [{port,     WebPort}, {max_connections, 100000}],
                             cowboy_http_protocol, [{dispatch, Dispatch}]),
       cowboy:start_listener(tcp, 100,
                             cowboy_tcp_transport, [{port, TCPPort }, {max_connections, 100000}],
                             simple_framed_protocol, [{handler, none}]),

       CtlDispatch = [{'_', 
          [
            {[<<"ctl">>, cmd], ctl_handler, []}
          ]
       }],
       cowboy:start_listener(ctl_http_listener, 1,
                             cowboy_tcp_transport, [{port, CtlPort}],
                             cowboy_http_protocol, [{dispatch, CtlDispatch}]),

  io:format("~nRunning on web port ~p and tcp port ~p~n", [WebPort, TCPPort]),
  io:format("~nRunning control server on port ~p~n~n", [CtlPort]),

  receive
     _ -> ok
  end.


