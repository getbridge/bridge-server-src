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
  {ok, SSLPort} = application:get_env(gateway, ssl_port),
  {ok, HTTPSPort} = application:get_env(gateway, https_port),
  {ok, CtlPort} = application:get_env(gateway, ctl_port),
  Cert = case application:get_env(gateway, certfile) of
          undefined ->
            "flotype.crt";
          {ok, Cert0} ->
            Cert0
         end,
   Key = case application:get_env(gateway, keyfile) of
    undefined ->
      "flotype.key";
    {ok, Key0} ->
      Key0
   end,
  
  application:start(cowboy),
       
      GatewaySockJs = sockjs_handler:init_state(<<"/bridge">>, fun gateway_sockjs:handle_sockjs/2, [{logger, fun(_,Req,_) -> Req end}]),

       
       Dispatch = [{'_', % domain specifier
                    [{
                      [<<"bridge">>, '...'], 
                      sockjs_cowboy_handler, 
                      GatewaySockJs
                    }]
                  }],
       cowboy:start_listener(http, 4,
                             cowboy_tcp_transport, [{port,     WebPort}, {max_connections, 100000}],
                             cowboy_http_protocol, [{dispatch, Dispatch}]),
       cowboy:start_listener(https, 4,
                             cowboy_ssl_transport, [{port,     HTTPSPort}, {max_connections, 100000}],
                             cowboy_http_protocol, [{dispatch, Dispatch}]),
       cowboy:start_listener(ssl, 4,
                             cowboy_ssl_transport, [{port, SSLPort}, {certfile, Cert}, {keyfile, Key}, {password, "5K2**iZr"}],
                             simple_framed_protocol, [{handler, none}]),
       cowboy:start_listener(tcp, 4,
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


