-module(gateway_app_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
     supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
  RestartStrategy = {one_for_one, 10, 10},
  ClientSup = {
    gateway_client_sup, % name
    {gateway_client_sup, start_link, []}, % module
    permanent,
    infinity, % is a supervisor. must be infinity
    supervisor,
    [gateway_client_sup]
  },

  RabbitSup = {
    gateway_rabbit_sup, % name
    {gateway_rabbit_sup, start_link, []}, % module
    permanent,
    infinity, % is a supervisor. must be infinity
    supervisor,
    [gateway_rabbit_sup]
  },

  Cowboy = {
    cowboy_server,
    {cowboy_server, start_link, []},
    permanent,
    10000,
    worker,
    [cowboy_server]
  },

  GatewayGamqp = {
    gateway_gamqp,
    {gateway_gamqp, start_link, []},
    permanent,
    10000,
    worker,
    [gateway_gamqp]
  },
  
  GatewayMetrics = {
    gateway_metrics,
    {gateway_metrics, start_link, []},
    permanent,
    10000,
    worker,
    [gateway_metrics]
  },

  Children = [ClientSup, RabbitSup, Cowboy, GatewayGamqp, GatewayMetrics],
  {ok, {RestartStrategy, Children}}.


