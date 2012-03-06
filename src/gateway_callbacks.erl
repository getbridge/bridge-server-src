-module(gateway_callbacks).

-export([behaviour_info/1]).

behaviour_info(callbacks) ->
    [
      {send, 2},
      {close, 1}
    ];
behaviour_info(_Other) ->
    undefined.
