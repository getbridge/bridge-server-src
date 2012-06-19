-module(cowboy_server).
-export([start_link/0]).
-export([init/0]).

-include("metering.hrl").

start_link() ->
  Pid = spawn_link(?MODULE, init, []),
  {ok, Pid}.

init()->
  WebPort = maybe_get_env(web_port, 8091),
  TCPPort = maybe_get_env(tcp_port, 8090),
  CtlPort = maybe_get_env(ctl_port, 7002),

  GatewaySockJs = sockjs_handler:init_state(<<"/bridge">>, fun gateway_sockjs:handle_sockjs/2, [{logger, fun(_,Req,_) -> Req end}]),

  ok = application:start(cowboy),


  Dispatch = [{'_', % domain specifier
                [{
                  [<<"bridge">>, '...'], 
                  sockjs_cowboy_handler, 
                  GatewaySockJs
                }]
              }],
   cowboy:start_listener(http, 4,
                         cowboy_tcp_transport, [{port,     WebPort}],
                         cowboy_http_protocol, [{dispatch, Dispatch}]),

   cowboy:start_listener(tcp, 4,
                         cowboy_tcp_transport, [{port, TCPPort }],
                         simple_framed_protocol, [{handler, none}]),
   ok = init_secure(Dispatch, application:get_env(gateway, secure)),

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

init_secure(_ , Secure) when Secure == {ok, false} orelse Secure == undefined ->
  ok;
init_secure(Dispatch, Secure) when Secure == {ok, true} ->

  SSLPort = maybe_get_env(ssl_port, 8093),
  HTTPSPort = maybe_get_env(https_port, 8043),
  {ok, Cert} = application:get_env(gateway, certfile),
  {ok, Key} = application:get_env(gateway, keyfile),


  HTTPSOpts2 = [{port, HTTPSPort}, {certfile, Cert}, {keyfile, Key}],
  SSLOpts2 = [{port, SSLPort}, {certfile, Cert}, {keyfile, Key}],

  HTTPSOpts1 =  maybe_add_prop(HTTPSOpts2, password, application:get_env(password)),
  SSLOpts1 =  maybe_add_prop(SSLOpts2, password, application:get_env(password)),

  HTTPSOpts =  maybe_add_prop(HTTPSOpts1, cacertfile, application:get_env(cacertfile)),
  SSLOpts =  maybe_add_prop(SSLOpts1, cacertfile, application:get_env(cacertfile)),

   cowboy:start_listener(https, 4,
                         cowboy_ssl_transport, HTTPSOpts,
                         cowboy_http_protocol, [{dispatch, Dispatch}]),
   cowboy:start_listener(ssl, 4,
                         cowboy_ssl_transport, SSLOpts,
                         simple_framed_protocol, [{handler, none}]),
   ok.

maybe_add_prop(Opts, _Key, Val) when Val == undefined->
  Opts;
maybe_add_prop(Opts, Key, {ok, Val})->
  [{Key, Val} | Opts].

maybe_get_env(Prop, Default) ->
  case application:get_env(Prop) of
      undefined -> Default;
      {ok, Val} -> Val
  end.

