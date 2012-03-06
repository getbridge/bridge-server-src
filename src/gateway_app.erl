% This is the Gateway Launch Module.
% The first code that runs.

-module(gateway_app).

-behaviour(application).

-export([start/0, start/2, stop/1]).

% Start from the commandline
start() ->
  application:start(inets),
  application:start(sockjs),
  application:start(gateway).
  

% Start via application interface
start(_Type, _Args) ->
  case application:get_env(gateway, log) of
    {ok, file} -> gateway_util:display_log(false),
                  error_logger:logfile({open, "log/" ++ integer_to_list(gateway_util:timestamp()) ++ ".log"});
    {ok, none} -> gateway_util:display_log(false);
            _  -> gateway_util:display_log(true)
  end,
  
  gateway_util:info("Starting Bridge Gateway!~n"),
  gateway_app_sup:start_link().

stop(_State) ->
    ok.