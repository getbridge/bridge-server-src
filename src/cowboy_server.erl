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
       Dispatch = [{'_', % domain specifier
                    [{
                      '_', % path specifier
                      sockjs_cowboy_handler, % handler module name. This is the sockjs one
                      {fun handle/1, fun ws_handle/1} % handler functions. gets passed to sockjs_cowboy_handler
                    }]
                  }],
       cowboy:start_listener(http, 100,
                             cowboy_tcp_transport, [{port,     WebPort}],
                             cowboy_http_protocol, [{dispatch, Dispatch}]),
       cowboy:start_listener(tcp, 100,
                             cowboy_tcp_transport, [{port, TCPPort }],
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

  gateway_sockjs:mqb_handle(start),
  receive
     _ -> ok
  end.

% --------------------------------------------------------------------------

handle(Req) ->
    gateway_util:info("Reached handler~n"),
    {Path0, Req1} = sockjs_http:path(Req),
    Path = clean_path(Path0),
    case sockjs_filters:handle_req(Req1, Path, gateway_sockjs:dispatcher()) of
        nomatch -> ok;
        Req2    -> Req2
    end.

ws_handle(Req) ->
    gateway_util:info("Reached WS handler~n"),
    {Path0, Req1} = sockjs_http:path(Req),
    Path = clean_path(Path0),
    {Receive, _, SessionId, _} = sockjs_filters:dispatch('GET', Path,
                                                 gateway_sockjs:dispatcher()),
    {Receive, Req1, SessionId}.

clean_path("/")         -> "index.html";
clean_path("/" ++ Path) -> Path.

%% --------------------------------------------------------------------------

