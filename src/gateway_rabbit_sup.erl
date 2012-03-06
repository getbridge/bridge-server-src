-module(gateway_rabbit_sup).

-behaviour(supervisor).

-export([start_link/0, init/1, start_child/0]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, _Arg = []).

init([]) ->
  ClientSpec = {gateway_rabbit, {gateway_rabbit_handler, start_link, []},
                            temporary, 2000, worker, [gateway_rabbit_handler]},
  StartSpecs = {{simple_one_for_one, 0, 1}, [ClientSpec]},
  {ok, StartSpecs}.

start_child() ->
    supervisor:start_child(?MODULE, []).
